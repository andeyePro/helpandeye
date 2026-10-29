import Foundation
import helpandeyeCore
import Network

/// The home Wi-Fi route (decision 19): the group's phones on the same Wi-Fi network find each
/// other with Bonjour and keep a direct connection open, so a call needs no box, no server and no
/// internet. A connection counts only once the other end has proved it is another member
/// (`LocalWire.Session`), and a frame counts as sent only once that member's Help&I confirms it
/// took it in. The advertised name says nothing about the group. In the app it runs while Help&I is
/// open; the local push extension runs the same with the phone locked, and confirms only what it
/// keeps (`keeps`).
@MainActor final class HomeWiFi: ObservableObject, LocalLink {
    /// Other members' phones connected and proven now.
    @Published private(set) var peerCount = 0
    /// Why the route cannot work at all here, such as Local Network access being turned off.
    @Published private(set) var problem: String?
    var onFrame: ((HelpFrame) -> Void)?
    /// Whether a frame heard is one this end takes in, so is confirmed. Everything, in the app.
    var keeps: (HelpFrame) -> Bool = { _ in true }

    private var group: GroupState?
    private var me: UInt16?
    private var identity: DeviceIdentity?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [Int: Peer] = [:]
    private var nextPeer = 0
    private var nextMessage: UInt32 = 0
    private var waiting: [UInt32: (count: Int, done: CheckedContinuation<Bool, Never>)] = [:]
    /// This phone's own instance name: the group's name and a random part, so phones can tell
    /// themselves apart and only one of each pair dials the other.
    private var myName = ""
    /// Advertised names that turned out not to be another member (this phone's own extension, a
    /// stranger): not dialled again until the next restart.
    private var refused: Set<String> = []

    private final class Peer {
        let connection: NWConnection
        var session: LocalWire.Session
        let name: String?
        init(_ connection: NWConnection, _ session: LocalWire.Session, name: String?) {
            self.connection = connection; self.session = session; self.name = name
        }
        var proven: Bool { session.peer != nil }
    }

    /// Shown as a route only once this phone has met another member on Wi-Fi, so someone who never
    /// uses it is not shown a cross for it on every call.
    private static let usedKey = "homeWiFiUsed"
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.usedKey) }
    var hasPeers: Bool { peers.values.contains(where: \.proven) }
    var unavailableReason: String { problem ?? (group == nil ? "Not in a group" : "No other phones of the group on this Wi-Fi") }

    /// Starts afresh when the keys, this phone's number or who is in the group changes, so a
    /// connection proven by someone since removed does not stay open.
    func configure(group: GroupState?, me: UInt16?, identity: DeviceIdentity) {
        let changed = group?.secrets != self.group?.secrets || me != self.me || Self.who(group) != Self.who(self.group)
        self.group = group; self.me = me; self.identity = identity
        if changed { restart() }
    }

    private static func who(_ g: GroupState?) -> [UInt16: Data] {
        Dictionary((g?.members ?? []).map { ($0.number, $0.signingKey ?? Data()) }, uniquingKeysWith: { a, _ in a })
    }

    /// After the app was in the background, where iOS stops listening.
    func resume() {
        if Self.stopped(listener?.state) || Self.stopped(browser?.state) { restart() }
    }

    private static func stopped(_ s: NWListener.State?) -> Bool {
        switch s { case .failed?, .cancelled?, nil: true; default: false }
    }

    private static func stopped(_ s: NWBrowser.State?) -> Bool {
        switch s { case .failed?, .cancelled?, nil: true; default: false }
    }

    func send(_ frame: HelpFrame, to only: Set<UInt16>?) async -> String? {
        let ready = peers.values.filter { p in p.session.peer.map { n in only?.contains(n) ?? true } ?? false }
        guard !ready.isEmpty else { return only == nil ? unavailableReason : "None of the phones it is for is on this Wi-Fi" }
        nextMessage &+= 1
        let id = nextMessage
        let confirmed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            waiting[id] = (ready.count, done)
            for p in ready {
                guard let m = p.session.message(frame, id: id) else { settle(id, confirmed: false); continue }
                p.connection.send(content: m, completion: .contentProcessed { [weak self] error in
                    if error != nil { Task { @MainActor in self?.settle(id, confirmed: false) } }
                })
            }
            // A phone that has the bytes but not Help&I running (suspended, say) never confirms.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.waiting.removeValue(forKey: id)?.done.resume(returning: false)
            }
        }
        return confirmed ? nil : "No other member's Help&I confirmed it"
    }

    /// The first confirmation counts; once every end has failed, it did not go.
    private func settle(_ id: UInt32, confirmed: Bool) {
        guard var w = waiting[id] else { return }
        if confirmed {
            waiting[id] = nil
            w.done.resume(returning: true)
        } else {
            w.count -= 1
            if w.count <= 0 { waiting[id] = nil; w.done.resume(returning: false) } else { waiting[id] = w }
        }
    }

    private func restart() {
        listener?.cancel(); browser?.cancel()
        for p in peers.values { p.connection.cancel() }
        peers = [:]
        refused = []
        update()
        guard let g = group, me != nil, identity != nil else { return }
        let base = LocalWire.serviceName(for: g)
        myName = base + "-" + String(UInt32.random(in: 0...UInt32.max), radix: 16)
        if let l = try? NWListener(using: Self.parameters) {
            l.service = NWListener.Service(name: myName, type: LocalWire.serviceType)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.add(c, name: nil) } }
            l.stateUpdateHandler = { [weak self] s in Task { @MainActor in self?.watch(s) } }
            l.start(queue: .main)
            listener = l
        }
        let b = NWBrowser(for: .bonjour(type: LocalWire.serviceType, domain: nil), using: Self.parameters)
        b.browseResultsChangedHandler = { [weak self] results, _ in Task { @MainActor in self?.found(results) } }
        b.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                if case let .waiting(e) = s { self?.denied(e) } else if case let .failed(e) = s { self?.denied(e) }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private static var parameters: NWParameters {
        let tcp = NWProtocolTCP.Options()
        // A phone that has gone (switched off, left the Wi-Fi) is noticed in seconds, not hours.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    private func watch(_ s: NWListener.State) {
        if case let .failed(e) = s { denied(e) }
    }

    private func denied(_ e: NWError) {
        if case let .dns(code) = e, code == -65570 {
            problem = "Help&I is not allowed to find the group's phones on this Wi-Fi. Turn on Local Network for Help&I in Settings."
        }
    }

    /// Dials each of the group's phones whose name sorts after this one's; the others dial here.
    private func found(_ results: Set<NWBrowser.Result>) {
        guard let g = group else { return }
        let base = LocalWire.serviceName(for: g)
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, name.hasPrefix(base + "-"), name > myName, !refused.contains(name),
                  !peers.values.contains(where: { $0.connection.endpoint == r.endpoint }) else { continue }
            add(NWConnection(to: r.endpoint, using: Self.parameters), name: name)
        }
    }

    private func add(_ c: NWConnection, name: String?) {
        guard let g = group, let me, let identity else { c.cancel(); return }
        nextPeer += 1
        let id = nextPeer
        let p = Peer(c, LocalWire.Session(group: g, me: me, identity: identity), name: name)
        peers[id] = p
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, let p = self.peers[id], p.connection === c else { return }
                switch state {
                case .ready: c.send(content: p.session.opening, completion: .idempotent)
                case .failed, .cancelled: self.drop(id)
                case .waiting:
                    // Refused or stale, such as this phone's own old name: give up, and dial afresh.
                    self.drop(id)
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(id, c)
    }

    private func receive(_ id: Int, _ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let p = self.peers[id], p.connection === c else { return }
                if let data {
                    let (events, reply) = p.session.take(data)
                    if !reply.isEmpty { c.send(content: reply, completion: .idempotent) }
                    for e in events {
                        switch e {
                        case .peer:
                            UserDefaults.standard.set(true, forKey: Self.usedKey)
                            self.update()
                        case let .frame(frame, mid):
                            if self.keeps(frame), let receipt = p.session.receipt(for: mid) { c.send(content: receipt, completion: .idempotent) }
                            self.onFrame?(frame)
                        case let .receipt(mid): self.settle(mid, confirmed: true)
                        }
                    }
                }
                // Not another member's phone, or gone: drop it.
                if complete || error != nil || p.session.broken { self.drop(id) } else { self.receive(id, c) }
            }
        }
    }

    /// Forgets a connection, and dials the group's phones still advertised again.
    private func drop(_ id: Int) {
        guard let p = peers.removeValue(forKey: id) else { return }
        p.connection.cancel()
        if p.session.broken, !p.proven, let name = p.name { refused.insert(name) }
        update()
        if let results = browser?.browseResults { found(results) }
    }

    private func update() { peerCount = peers.values.filter(\.proven).count }
}
