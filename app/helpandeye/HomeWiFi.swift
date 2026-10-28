import Foundation
import helpandeyeCore
import Network

/// The home Wi-Fi route (decision 19): the group's phones on the same Wi-Fi network find each
/// other with Bonjour and keep a direct connection open, so a call needs no box, no server and no
/// internet. Every message is sealed with the group key (`LocalWire`); the advertised name says
/// nothing about the group. Only while the app is running: iOS stops it in the background.
@MainActor final class HomeWiFi: ObservableObject, LocalLink {
    /// The group's phones connected now.
    @Published private(set) var peerCount = 0
    var onFrame: ((HelpFrame) -> Void)?

    private var group: GroupState?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [ObjectIdentifier: Peer] = [:]
    /// This phone's own instance name: the group's name and a random part, so phones can tell
    /// themselves apart and only one of each pair dials the other.
    private var myName = ""

    private final class Peer {
        let connection: NWConnection
        var reader = LocalWire.Reader()
        var ready = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    let isEnabled = true
    var hasPeers: Bool { peers.values.contains(where: \.ready) }
    var unavailableReason: String { group == nil ? "Not in a group" : "No other phones of the group on this Wi-Fi" }

    func configure(group: GroupState?) {
        let changed = group?.secrets != self.group?.secrets
        self.group = group
        if changed { restart() }
    }

    /// After the app was in the background, where iOS stops listening.
    func resume() {
        if listener?.state != .ready || browser?.state != .ready { restart() }
    }

    func send(_ frame: HelpFrame) async -> String? {
        guard let g = group, let message = LocalWire.message(frame, in: g) else { return "Could not seal the message" }
        var delivered = false
        for p in peers.values where p.ready {
            let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                p.connection.send(content: message, completion: .contentProcessed { done.resume(returning: $0 == nil) })
            }
            delivered = delivered || ok
        }
        return delivered ? nil : unavailableReason
    }

    private func restart() {
        listener?.cancel(); browser?.cancel()
        for p in peers.values { p.connection.cancel() }
        peers = [:]
        peerCount = 0
        guard let g = group else { return }
        let base = LocalWire.serviceName(for: g)
        myName = base + "-" + String(UInt32.random(in: 0...UInt32.max), radix: 16)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let l = try? NWListener(using: parameters) {
            l.service = NWListener.Service(name: myName, type: LocalWire.serviceType)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.add(c) } }
            l.start(queue: .main)
            listener = l
        }
        let b = NWBrowser(for: .bonjour(type: LocalWire.serviceType, domain: nil), using: parameters)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found(results, base: base) }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Dials each of the group's phones whose name sorts after this one's; the others dial here.
    private func found(_ results: Set<NWBrowser.Result>, base: String) {
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, name.hasPrefix(base + "-"), name > myName,
                  !peers.values.contains(where: { $0.connection.endpoint == r.endpoint }) else { continue }
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            add(NWConnection(to: r.endpoint, using: parameters))
        }
    }

    private func add(_ c: NWConnection) {
        let p = Peer(c)
        let id = ObjectIdentifier(p)
        peers[id] = p
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, let p = self.peers[id] else { return }
                switch state {
                case .ready: p.ready = true
                case .failed, .cancelled: self.peers[id] = nil
                default: break
                }
                self.peerCount = self.peers.values.filter(\.ready).count
            }
        }
        c.start(queue: .main)
        receive(on: p, id: id)
    }

    private func receive(on p: Peer, id: ObjectIdentifier) {
        p.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let p = self.peers[id] else { return }
                if let data, let g = self.group {
                    for sealed in p.reader.take(data) {
                        if let frame = LocalWire.open(sealed, in: g, at: Date()) { self.onFrame?(frame) }
                    }
                }
                // Not one of the group's phones, or gone: drop it; the browser finds it again.
                if complete || error != nil || p.reader.broken {
                    p.connection.cancel()
                    self.peers[id] = nil
                    self.peerCount = self.peers.values.filter(\.ready).count
                } else {
                    self.receive(on: p, id: id)
                }
            }
        }
    }
}
