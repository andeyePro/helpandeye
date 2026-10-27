import CoreBluetooth
import Foundation
import HelpAndICore
import UIKit

/// The Bluetooth link to a Heltec board running MeshCore's standard companion firmware.
///
/// Commands go one at a time and wait for their reply, as the companion protocol requires
/// (`CommandQueue` in HelpAndICore). Incoming Help&I datagrams on the group's channel are handed
/// to `onFrame`.
@MainActor
final class BoardLink: NSObject, ObservableObject {
    enum State: Equatable { case off, unauthorised, connecting, ready, failed(String) }

    @Published private(set) var state: State = .off
    /// Looking for boxes nearby. Separate from `state`, so looking never takes a connected box off
    /// the air.
    @Published private(set) var searching = false
    @Published private(set) var found: [CBPeripheral] = []
    @Published private(set) var selfInfo: MeshCore.SelfInfo?
    @Published private(set) var batteryMillivolts: Int?
    @Published private(set) var helpChannel: UInt8?
    /// The previous channel during a changeover after a removal. Sends go on both, so members who
    /// have not scanned their update yet still hear calls and acknowledgements.
    private var previousChannel: UInt8?

    var onFrame: ((HelpFrame) -> Void)?
    /// A direct text message: the sender's key prefix (6 bytes) and the text.
    var onText: ((Data, String) -> Void)?
    /// The channel secrets to listen on: the current one first, then the previous one while boards
    /// move to new secrets. Whenever they change with the link up, the box is set up again.
    var secrets: [Data] = [] { didSet { if secrets != oldValue, commands.isUp { Task { await setUpChannels() } } } }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var listenChannels: Set<UInt8> = []
    /// One command at a time, calls for help first.
    private var commands: CommandQueue!
    private var syncing = false
    private var needsDrain = false
    private var settingUp = false
    private var setUpAgain = false
    /// Grows only after failed connection attempts; a dropped link reconnects at once.
    private var backoff: TimeInterval = 1

    override init() {
        super.init()
        commands = CommandQueue { [weak self] data in
            guard let self else { return }
            guard let p = self.peripheral, let rx = self.rx else {
                // Never reached the box: say so at once, rather than waiting out the timeout.
                Task { @MainActor in self.commands.writeFailed() }
                return
            }
            p.writeValue(data, for: rx, type: .withResponse)
        }
        // After a timeout the queue has stopped; reconnecting starts the conversation afresh.
        commands.onTimeout = { [weak self] in
            guard let self, let p = self.peripheral else { return }
            self.central.cancelPeripheralConnection(p)
        }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "org.andeye.helpandi.central"])
    }

    var radio: RadioSettings? { selfInfo?.radio }

    /// The Bluetooth code this app set on a box, from the keychain, so it can be shown before
    /// pairing, which is when it is needed.
    func pin(for id: UUID?) -> UInt32? { id.flatMap(Store.boxPin) }
    var boxPin: UInt32? { pin(for: Store.boardID ?? peripheral?.identifier) }

    func startSearch() {
        guard central.state == .poweredOn else { return }
        found = []
        searching = true
        central.scanForPeripherals(withServices: [CBUUID(string: MeshCore.serviceUUID)])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.stopSearch()
        }
    }

    func stopSearch() {
        guard searching else { return }
        central.stopScan()
        searching = false
    }

    func connect(_ p: CBPeripheral) {
        stopSearch()
        if let old = peripheral, old !== p { peripheral = nil; tearDown(); central.cancelPeripheralConnection(old) }
        Store.boardID = p.identifier
        peripheral = p
        p.delegate = self
        backoff = 1
        state = .connecting
        if p.state == .connected { p.discoverServices([CBUUID(string: MeshCore.serviceUUID)]) } else { central.connect(p) }
    }

    func forget() {
        let p = peripheral
        Store.boardID = nil
        peripheral = nil
        tearDown()
        selfInfo = nil
        if let p { central.cancelPeripheralConnection(p) }
        state = .off
    }

    /// The link is gone: nothing in flight will be answered, and nothing is listened to.
    private func tearDown() {
        rx = nil; helpChannel = nil; previousChannel = nil; listenChannels = []
        commands.linkDown()
    }

    /// Adds another member's box as a contact, so direct messages can go to it.
    func addContact(_ key: Data, name: String) async {
        guard state == .ready, key.count == 32, key != selfInfo?.publicKey else { return }
        _ = await run(.addContact(publicKey: key, name: name), expect: okOrError)
    }

    /// Sends a direct message, which MeshCore encrypts to the receiving box's own key.
    func sendText(_ text: String, to key: Data) async -> MeshSendResult {
        guard state == .ready, key.count == 32 else { return .refused("Box not connected") }
        let cmd = MeshCore.Command.sendText(publicKeyPrefix: key.prefix(6), text: text, sentAt: UInt32(Date().timeIntervalSince1970), attempt: 0)
        let isSent: (MeshCore.Response) -> Bool = { if case .sent = $0 { return true }; return false }
        return outcome(await commands.send(cmd, expect: { isSent($0) || self.okOrError($0) }), isSent: isSent)
    }

    /// Sends a Help&I frame as a datagram on the group's channel, and on the previous one during a
    /// changeover. The channels are taken once, before anything is awaited, so the packets sent
    /// are exactly the ones the engine counted (`channelsPerSend`).
    func send(_ frame: HelpFrame, urgent: Bool) async -> MeshSendResult {
        guard state == .ready, let ch = helpChannel else { return .refused("Box not connected") }
        let old = previousChannel.flatMap { $0 == ch ? nil : $0 }
        let result = await sendOn(ch, frame, urgent: urgent)
        guard let old else { return result }
        let second = await sendOn(old, frame, urgent: urgent)
        // Sent if either channel took it, so airtime is never given back for a packet on air.
        return result == .sent || second == .sent ? .sent : result
    }

    /// How many packets a send puts on air, for the airtime budget.
    var channelsPerSend: Int { previousChannel == nil || previousChannel == helpChannel ? 1 : 2 }

    private func sendOn(_ ch: UInt8, _ frame: HelpFrame, urgent: Bool) async -> MeshSendResult {
        let cmd = MeshCore.Command.sendChannelData(index: ch, dataType: HelpFrame.meshDataType, payload: frame.encoded())
        return outcome(await commands.send(cmd, urgent: urgent, expect: okOrError), isSent: { $0 == .ok })
    }

    /// Only a command never written certainly did not go on air; a timeout may have.
    private func outcome(_ o: CommandQueue.Outcome, isSent: (MeshCore.Response) -> Bool) -> MeshSendResult {
        switch o {
        case let .reply(r) where isSent(r): return .sent
        case let .reply(.error(code)): return .refused("Box refused it (error \(code))")
        case .reply, .timedOut: return .unknown("Box did not answer")
        case .notWritten: return .refused("Box not connected")
        }
    }

    private func okOrError(_ r: MeshCore.Response) -> Bool {
        if case .ok = r { return true }
        if case .error = r { return true }
        return false
    }

    private func run(_ cmd: MeshCore.Command, urgent: Bool = false, expect: @escaping (MeshCore.Response) -> Bool) async -> MeshCore.Response? {
        await commands.run(cmd, urgent: urgent, expect: expect)
    }

    // MARK: After connecting

    private func handshake() async {
        guard case .selfInfo(let info)? = await run(.appStart(name: "Help&I"), expect: { if case .selfInfo = $0 { return true }; return false }) else {
            state = .failed("Box did not answer"); return
        }
        selfInfo = info
        _ = await run(.setDeviceTime(UInt32(Date().timeIntervalSince1970)), expect: okOrError)
        await setUpChannels()
        await refreshBattery()
        if state == .ready { backoff = 1; await drainMessages() }
    }

    /// Sets the box up for the group: the Bluetooth code, then the channels. One run at a time; a
    /// change of secrets during a run starts another when it ends. Afterwards the box is ready only
    /// if the group's channel is on it.
    private func setUpChannels() async {
        if settingUp { setUpAgain = true; return }
        settingUp = true
        defer { settingUp = false }
        repeat {
            setUpAgain = false
            await setUpOnce()
        } while setUpAgain
        guard commands.isUp else { return }
        if helpChannel != nil || secrets.isEmpty {
            if state != .ready { state = .ready; await drainMessages() }
        } else {
            state = .failed("No free channel on the box")
        }
    }

    private func setUpOnce() async {
        guard case .deviceInfo(let dev)? = await run(.deviceQuery, expect: { if case .deviceInfo = $0 { return true }; return false }) else { return }
        // A box without a screen uses MeshCore's fixed code, 123456, the same on every box, so a
        // stranger's phone could pair. Replace it with a random one. (A box with a screen shows a
        // fresh random code at each start, and reports 0; that is left alone.) Only a code safely
        // kept is sent.
        if dev.blePin == 123_456, let id = peripheral?.identifier {
            let pin = Store.boxPin(id) ?? UInt32.random(in: 100_000...999_999)
            if Store.setBoxPin(pin, for: id) {
                _ = await run(.setPin(pin), expect: okOrError)
                objectWillChange.send()
            }
        }
        var slots: [ChannelPlan.Slot] = []
        for i in 0..<UInt8(clamping: dev.maxChannels) {
            if case let .channelInfo(index, name, secret)? = await run(.getChannel(index: i), expect: {
                if case let .channelInfo(index, _, _) = $0 { return index == i }; if case .error = $0 { return true }; return false
            }), index == i {
                slots.append(.init(index: i, name: name, secret: secret))
            }
        }
        let want = secrets
        let plan = ChannelPlan.plan(slots: slots, secrets: want)
        // Listen on what is already there straight away, and on each slot as soon as it is written,
        // so a drain running meanwhile never throws away a frame on a channel just set up.
        let existing = Set(slots.filter { want.contains($0.secret) }.map(\.index))
        listenChannels.formUnion(existing)
        var written: Set<UInt8> = []
        for w in plan.writes {
            if case .ok? = await run(.setChannel(index: w.index, name: w.name, secret: w.secret), expect: okOrError) {
                written.insert(w.index)
                listenChannels.insert(w.index)
            }
        }
        let ok = { (i: UInt8?) in i.map { existing.contains($0) || written.contains($0) } ?? false }
        helpChannel = ok(plan.current) ? plan.current : nil
        previousChannel = ok(plan.previous) ? plan.previous : nil
        // Stop listening on slots that no longer hold the group's channels, last.
        listenChannels = Set([helpChannel, previousChannel].compactMap { $0 })
    }

    func refreshBattery() async {
        if case let .battery(mv)? = await run(.getBattery, expect: { if case .battery = $0 { return true }; return false }) {
            batteryMillivolts = mv
        }
    }

    /// Fetches every message waiting on the board. A "messages waiting" push that arrives while
    /// this runs sets `needsDrain`, so it is never lost.
    private func drainMessages() async {
        needsDrain = true
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while needsDrain {
            needsDrain = false
            await drainOnce()
        }
    }

    private func drainOnce() async {
        for _ in 0..<1000 {
            let r = await run(.syncNextMessage, expect: {
                switch $0 { case .channelData, .channelText, .contactText, .noMoreMessages: return true; default: return false }
            })
            switch r {
            case let .channelData(ch, type, payload, _)?:
                if listenChannels.contains(ch), type == HelpFrame.meshDataType, let f = HelpFrame(payload) { onFrame?(f) }
            case let .contactText(prefix, text, _)?: onText?(prefix, text)
            case .channelText?: continue
            default: return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let r = MeshCore.Response(data) else { return }
        // Before the box is set up for the group, the setup's own drain will fetch these; draining
        // now would take them off the board and throw them away.
        if case .messagesWaiting = r { if state == .ready { Task { await drainMessages() } }; return }
        if commands.receive(r) { return }
        if case let .channelData(ch, type, payload, _) = r, listenChannels.contains(ch), type == HelpFrame.meshDataType, let f = HelpFrame(payload) {
            onFrame?(f)
        }
        if case let .contactText(prefix, text, _) = r { onText?(prefix, text) }
    }
}

extension BoardLink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            if let p = peripheral ?? Store.boardID.flatMap({ c.retrievePeripherals(withIdentifiers: [$0]).first }) { connect(p) } else { state = .off }
        case .unauthorized:
            tearDown(); state = .unauthorised
        default:
            // Bluetooth off or reset: no callback may come for the link, so drop it here.
            tearDown(); searching = false; state = .off
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Relaunched in the background: the link is rebuilt when Bluetooth reports it is on.
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first { peripheral = p; p.delegate = self }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if !found.contains(where: { $0.identifier == p.identifier }) { found.append(p) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { return }
        p.discoverServices([CBUUID(string: MeshCore.serviceUUID)])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        if (error as? CBError)?.code == .peerRemovedPairingInformation {
            state = .failed("The box was reset. In iPhone Settings, Bluetooth, forget it, then pair it again here.")
            return
        }
        state = .failed("Could not connect to the box")
        reconnect(p, afterFailure: true)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        tearDown()
        // Keep a failure on screen, so a box that connects but never answers is not shown as
        // "Connecting…" for ever.
        if case .failed = state {} else { state = .connecting }
        reconnect(p, afterFailure: state != .connecting)
    }

    /// Bluetooth links drop (decision 9). After a drop the app asks to reconnect at once: iOS keeps
    /// the request open until the box is back in range, even with the app suspended, at no cost.
    /// Only after a failure is there a pause, growing to a minute, kept alive in the background
    /// for up to twenty seconds, so a box that fails at once cannot drain the battery.
    private func reconnect(_ p: CBPeripheral, afterFailure: Bool) {
        guard Store.boardID == p.identifier else { return }
        guard afterFailure else { central.connect(p); return }
        let wait = min(backoff, 20)
        backoff = min(backoff * 2, 60)
        let task = UIApplication.shared.beginBackgroundTask(withName: "Reconnect to the box")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if let self, self.peripheral === p, Store.boardID == p.identifier { self.central.connect(p) }
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}

extension BoardLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == CBUUID(string: MeshCore.serviceUUID) }) else { return }
        p.discoverCharacteristics([CBUUID(string: MeshCore.rxUUID), CBUUID(string: MeshCore.txUUID)], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == CBUUID(string: MeshCore.rxUUID) { rx = ch }
            if ch.uuid == CBUUID(string: MeshCore.txUUID) { p.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, ch.isNotifying, rx != nil else {
            // Often a wrong pairing code: drop the link, so the reconnect path tries again.
            state = .failed("Box would not talk. If it asked for a code, check the code and try again.")
            central.cancelPeripheralConnection(p)
            return
        }
        commands.linkUp()
        Task { await handshake() }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if error != nil { commands.writeFailed() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let v = ch.value { handle(v) }
    }
}

extension BoardLink: MeshLink {
    var isReady: Bool { state == .ready }
    var boxPublicKey: Data? { selfInfo?.publicKey }

    var unavailableReason: String {
        switch state {
        case .ready: "Box not ready"
        case .off: "No box connected"
        case let .failed(why): why
        default: "Box not connected"
        }
    }
}
