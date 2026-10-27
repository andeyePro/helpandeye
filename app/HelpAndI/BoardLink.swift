import CoreBluetooth
import Foundation
import HelpAndICore

/// The Bluetooth link to a Heltec board running MeshCore's standard companion firmware.
///
/// Commands go one at a time and wait for their reply, as the companion protocol requires.
/// Incoming Help&I datagrams on the group's channel are handed to `onFrame`.
@MainActor
final class BoardLink: NSObject, ObservableObject {
    enum State: Equatable { case off, unauthorised, searching, connecting, ready, failed(String) }

    @Published private(set) var state: State = .off
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
    /// move to new secrets.
    var secrets: [Data] = [] { didSet { if state == .ready, secrets != oldValue { Task { await setUpChannels() } } } }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var listenChannels: Set<UInt8> = []
    private var pending: (id: UUID, expect: (MeshCore.Response) -> Bool, done: CheckedContinuation<MeshCore.Response?, Never>)?
    private var queue: [() async -> Void] = []
    private var busy = false
    private var syncing = false
    private var needsDrain = false
    private var backoff: TimeInterval = 1

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "org.andeye.helpandi.central"])
    }

    var radio: RadioSettings? { selfInfo?.radio }

    func startSearch() {
        guard central.state == .poweredOn else { return }
        found = []
        state = .searching
        central.scanForPeripherals(withServices: [CBUUID(string: MeshCore.serviceUUID)])
    }

    func connect(_ p: CBPeripheral) {
        central.stopScan()
        if let old = peripheral, old !== p { peripheral = nil; central.cancelPeripheralConnection(old) }
        Store.boardID = p.identifier
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    func forget() {
        let p = peripheral
        Store.boardID = nil
        peripheral = nil; rx = nil; selfInfo = nil; helpChannel = nil
        if let p { central.cancelPeripheralConnection(p) }
        state = .off
    }

    /// Adds another member's box as a contact, so direct messages can go to it.
    func addContact(_ key: Data, name: String) async {
        guard state == .ready, key.count == 32, key != selfInfo?.publicKey else { return }
        _ = await run(.addContact(publicKey: key, name: name), expect: { if case .ok = $0 { return true }; if case .error = $0 { return true }; return false })
    }

    /// Sends a direct message, which MeshCore encrypts to the receiving box's own key.
    func sendText(_ text: String, to key: Data) async -> MeshSendResult {
        guard state == .ready, key.count == 32 else { return .refused("Box not connected") }
        let cmd = MeshCore.Command.sendText(publicKeyPrefix: key.prefix(6), text: text, sentAt: UInt32(Date().timeIntervalSince1970), attempt: 0)
        switch await run(cmd, expect: { if case .sent = $0 { return true }; if case .error = $0 { return true }; return false }) {
        case .sent?: return .sent
        case let .error(code)?: return .refused("Box refused it (error \(code))")
        default: return rx == nil ? .refused("Box not connected") : .unknown("Box did not answer")
        }
    }

    /// Sends a Help&I frame as a datagram on the group's channel.
    func send(_ frame: HelpFrame, urgent: Bool) async -> MeshSendResult {
        guard state == .ready, let ch = helpChannel else { return .refused("Box not connected") }
        let result = await sendOn(ch, frame, urgent: urgent)
        guard let old = previousChannel, old != ch else { return result }
        // Sent if either channel took it, so airtime is never given back for a packet on air.
        let second = await sendOn(old, frame, urgent: urgent)
        return result == .sent || second == .sent ? .sent : result
    }

    /// How many packets a send puts on air, for the airtime budget.
    var channelsPerSend: Int { previousChannel == nil || previousChannel == helpChannel ? 1 : 2 }

    private func sendOn(_ ch: UInt8, _ frame: HelpFrame, urgent: Bool) async -> MeshSendResult {
        let cmd = MeshCore.Command.sendChannelData(index: ch, dataType: HelpFrame.meshDataType, payload: frame.encoded())
        switch await run(cmd, urgent: urgent, expect: { if case .ok = $0 { return true }; if case .error = $0 { return true }; return false }) {
        case .ok?: return .sent
        case let .error(code)?: return .refused("Box refused it (error \(code))")
        default: return rx == nil ? .refused("Box not connected") : .unknown("Box did not answer")
        }
    }

    // MARK: Command queue

    /// Runs one command and waits for its reply. Calls for help go to the front of the queue, so
    /// they never wait behind setup or message syncing.
    private func run(_ cmd: MeshCore.Command, urgent: Bool = false, expect: @escaping (MeshCore.Response) -> Bool) async -> MeshCore.Response? {
        await withCheckedContinuation { (c: CheckedContinuation<MeshCore.Response?, Never>) in
            let job: () async -> Void = { [weak self] in
                guard let self else { c.resume(returning: nil); return }
                c.resume(returning: await self.transmit(cmd, expect: expect))
            }
            if urgent { queue.insert(job, at: 0) } else { queue.append(job) }
            pump()
        }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let next = queue.removeFirst()
        Task { await next(); busy = false; pump() }
    }

    private func transmit(_ cmd: MeshCore.Command, expect: @escaping (MeshCore.Response) -> Bool) async -> MeshCore.Response? {
        guard let p = peripheral, let rx, let data = try? cmd.encoded() else { return nil }
        let id = UUID()
        return await withCheckedContinuation { c in
            pending = (id, expect, c)
            p.writeValue(data, for: rx, type: .withResponse)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.timedOut(id)
            }
        }
    }

    /// Replies carry no command ID, so after a timeout a late reply could be taken for the next
    /// command's. Reconnecting starts the conversation afresh.
    private func timedOut(_ id: UUID) {
        guard pending?.id == id else { return }
        // Nothing more is written on this link: the next command waits for a fresh handshake.
        rx = nil
        finish(nil, only: id)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    private func finish(_ r: MeshCore.Response?, only id: UUID? = nil) {
        guard let p = pending, id == nil || p.id == id else { return }
        pending = nil
        p.done.resume(returning: r)
    }

    // MARK: After connecting

    private func handshake() async {
        guard case .selfInfo(let info)? = await run(.appStart(name: "Help&I"), expect: { if case .selfInfo = $0 { return true }; return false }) else {
            state = .failed("Box did not answer"); return
        }
        selfInfo = info
        _ = await run(.setDeviceTime(UInt32(Date().timeIntervalSince1970)), expect: { if case .ok = $0 { return true }; if case .error = $0 { return true }; return false })
        await setUpChannels()
        await refreshBattery()
        // Ready only if the group's channel is on the board and the link is still up; otherwise
        // the failure from setUpChannels stays on screen.
        guard rx != nil, helpChannel != nil || secrets.isEmpty else {
            if case .failed = state {} else { state = .failed("Box is not set up for this group") }
            return
        }
        state = .ready
        backoff = 1
        await drainMessages()
    }

    /// Finds the group's channel on the board, or writes it into the first free slot.
    private func setUpChannels() async {
        guard case .deviceInfo(let dev)? = await run(.deviceQuery, expect: { if case .deviceInfo = $0 { return true }; return false }) else { return }
        var slots: [UInt8: Data] = [:]
        var free: [UInt8] = []
        for i in 0..<UInt8(clamping: dev.maxChannels) {
            if case let .channelInfo(index, name, secret)? = await run(.getChannel(index: i), expect: {
                if case let .channelInfo(index, _, _) = $0 { return index == i }; if case .error = $0 { return true }; return false
            }), index == i {
                slots[i] = secret
                let empty = name.isEmpty && !secret.contains(where: { $0 != 0 })
                // Slots this app wrote for keys the group no longer uses are free again.
                let stale = name.hasPrefix("Help&I") && !secrets.contains(secret)
                if empty || stale { free.append(i) }
            }
        }
        var listen: Set<UInt8> = []
        var current: UInt8?
        var previous: UInt8?
        for (n, secret) in secrets.enumerated() {
            var slot = slots.first { $0.value == secret }?.key
            if slot == nil, !free.isEmpty {
                let i = free.removeFirst()
                if case .ok? = await run(.setChannel(index: i, name: n == 0 ? "Help&I" : "Help&I old", secret: secret),
                                         expect: { if case .ok = $0 { return true }; if case .error = $0 { return true }; return false }) {
                    slot = i
                }
            }
            if let slot { listen.insert(slot); if n == 0 { current = slot } else { previous = slot } }
        }
        listenChannels = listen
        helpChannel = current
        previousChannel = previous
        if current == nil, !secrets.isEmpty { state = .failed("No free channel on the box") }
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
        // Before the handshake has found the group's channel, the handshake's own drain will fetch
        // these; draining now would take them off the board and throw them away.
        if case .messagesWaiting = r { if state == .ready { Task { await drainMessages() } }; return }
        if let p = pending, p.expect(r) { finish(r); return }
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
            if let id = Store.boardID, let p = c.retrievePeripherals(withIdentifiers: [id]).first { connect(p) } else { state = .off }
        case .unauthorized: state = .unauthorised
        default: state = .off
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
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
        reconnectLater(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        rx = nil; helpChannel = nil
        finish(nil)
        // Keep a failure on screen, so a box that connects but never answers is not shown as
        // "Connecting…" for ever.
        if case .failed = state {} else { state = .connecting }
        reconnectLater(p)
    }

    /// Bluetooth links drop (decision 9). A pending connection stays open until the box is back in
    /// range, even with the app in the background; failures that come back at once are retried
    /// with a growing pause so they cannot drain the battery.
    private func reconnectLater(_ p: CBPeripheral) {
        guard Store.boardID == p.identifier else { return }
        let wait = backoff
        backoff = min(backoff * 2, 60)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.peripheral === p, Store.boardID == p.identifier else { return }
            self.central.connect(p)
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
        guard error == nil, ch.isNotifying, rx != nil else { state = .failed("Box would not talk"); return }
        Task { await handshake() }
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
