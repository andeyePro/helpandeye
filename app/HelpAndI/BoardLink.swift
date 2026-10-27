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

    var onFrame: ((HelpFrame) -> Void)?
    /// The channel secrets to listen on: the current one first, then the previous one while boards
    /// move to new secrets.
    var secrets: [Data] = [] { didSet { if state == .ready { Task { await setUpChannels() } } } }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var listenChannels: Set<UInt8> = []
    private var pending: (id: UUID, expect: (MeshCore.Response) -> Bool, done: CheckedContinuation<MeshCore.Response?, Never>)?
    private var queue: [() async -> Void] = []
    private var busy = false
    private var syncing = false

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
        Store.boardID = p.identifier
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    func forget() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        Store.boardID = nil
        peripheral = nil; rx = nil; selfInfo = nil; helpChannel = nil
        state = .off
    }

    /// Sends a Help&I frame as a datagram on the group's channel. Returns nil on success or the
    /// reason it failed, which the caller shows next to the cross.
    func send(_ frame: HelpFrame) async -> String? {
        guard state == .ready, let ch = helpChannel else { return "Box not connected" }
        let cmd = MeshCore.Command.sendChannelData(index: ch, dataType: HelpFrame.meshDataType, payload: frame.encoded())
        switch await run(cmd, expect: { if case .ok = $0 { return true }; if case .error = $0 { return true }; return false }) {
        case .ok?: return nil
        case let .error(code)?: return "Box refused it (error \(code))"
        default: return "Box did not answer"
        }
    }

    // MARK: Command queue

    private func run(_ cmd: MeshCore.Command, expect: @escaping (MeshCore.Response) -> Bool) async -> MeshCore.Response? {
        await withCheckedContinuation { (c: CheckedContinuation<MeshCore.Response?, Never>) in
            queue.append { [weak self] in
                guard let self else { c.resume(returning: nil); return }
                c.resume(returning: await self.transmit(cmd, expect: expect))
            }
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
                self?.finish(nil, only: id)
            }
        }
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
        _ = await run(.setDeviceTime(UInt32(Date().timeIntervalSince1970)), expect: { _ in true })
        await setUpChannels()
        await refreshBattery()
        state = .ready
        await drainMessages()
    }

    /// Finds the group's channel on the board, or writes it into the first free slot.
    private func setUpChannels() async {
        guard case .deviceInfo(let dev)? = await run(.deviceQuery, expect: { if case .deviceInfo = $0 { return true }; return false }) else { return }
        var slots: [UInt8: Data] = [:]
        var free: [UInt8] = []
        for i in 0..<UInt8(clamping: dev.maxChannels) {
            if case let .channelInfo(_, name, secret)? = await run(.getChannel(index: i), expect: { if case .channelInfo = $0 { return true }; if case .error = $0 { return true }; return false }) {
                slots[i] = secret
                if name.isEmpty && !secret.contains(where: { $0 != 0 }) { free.append(i) }
            }
        }
        var listen: Set<UInt8> = []
        var current: UInt8?
        for (n, secret) in secrets.enumerated() {
            var slot = slots.first { $0.value == secret }?.key
            if slot == nil, !free.isEmpty {
                let i = free.removeFirst()
                if case .ok? = await run(.setChannel(index: i, name: n == 0 ? "Help&I" : "Help&I old", secret: secret),
                                         expect: { if case .ok = $0 { return true }; if case .error = $0 { return true }; return false }) {
                    slot = i
                }
            }
            if let slot { listen.insert(slot); if n == 0 { current = slot } }
        }
        listenChannels = listen
        helpChannel = current
        if current == nil, !secrets.isEmpty { state = .failed("No free channel on the box") }
    }

    func refreshBattery() async {
        if case let .battery(mv)? = await run(.getBattery, expect: { if case .battery = $0 { return true }; return false }) {
            batteryMillivolts = mv
        }
    }

    private func drainMessages() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        for _ in 0..<64 {
            let r = await run(.syncNextMessage, expect: {
                switch $0 { case .channelData, .channelText, .contactText, .noMoreMessages: return true; default: return false }
            })
            switch r {
            case let .channelData(ch, type, payload, _)?:
                if listenChannels.contains(ch), type == HelpFrame.meshDataType, let f = HelpFrame(payload) { onFrame?(f) }
            case .channelText?, .contactText?: continue
            default: return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let r = MeshCore.Response(data) else { return }
        if case .messagesWaiting = r { Task { await drainMessages() }; return }
        if let p = pending, p.expect(r) { finish(r); return }
        if case let .channelData(ch, type, payload, _) = r, listenChannels.contains(ch), type == HelpFrame.meshDataType, let f = HelpFrame(payload) {
            onFrame?(f)
        }
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
        p.discoverServices([CBUUID(string: MeshCore.serviceUUID)])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = .failed("Could not connect to the box")
        reconnectLater(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        rx = nil; helpChannel = nil
        finish(nil)
        state = .connecting
        reconnectLater(p)
    }

    /// Bluetooth links drop (decision 9). iOS keeps a pending connection open indefinitely and
    /// completes it when the box comes back in range, even with the app in the background.
    private func reconnectLater(_ p: CBPeripheral) {
        guard Store.boardID == p.identifier else { return }
        central.connect(p)
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
