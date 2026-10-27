import Foundation
import HelpAndICore

/// The internet route: the group's relay (relay/ in this repository). Frames are sealed with the
/// group key on this phone; the relay stores ciphertext and public keys only.
@MainActor
final class Relay: ObservableObject {
    var onFrame: ((HelpFrame) -> Void)?
    /// Set when the relay says Cloudflare's free daily allowance is nearly used.
    var onAllowanceLow: (() -> Void)?
    @Published private(set) var isConfigured = false
    @Published private(set) var lastProblem: String?

    private var base: URL?
    private var group: GroupState?
    private var identity: DeviceIdentity?
    private var poller: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    func configure(group: GroupState?, identity: DeviceIdentity) {
        self.group = group
        self.identity = identity
        base = group?.relayURL.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        isConfigured = base != nil && group != nil
        poller?.cancel()
        guard isConfigured else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Sends the member list. Only a coordinator's list is accepted by the relay.
    func publishMembers() async {
        guard let group, let body = try? JSONEncoder().encode(RelayProtocol.memberList(group)) else { return }
        _ = await request("PUT", RelayProtocol.path(for: group.secrets, "members"), body: body)
    }

    func send(_ frame: HelpFrame) async -> String? {
        guard let group else { return "Internet route not set up" }
        guard let sealed = try? RelayProtocol.seal(frame, with: group.secrets),
              let body = try? JSONEncoder().encode(["sealed": sealed]) else { return "Could not seal the message" }
        switch await request("POST", RelayProtocol.path(for: group.secrets, "messages"), body: body) {
        case .some((200, _)): return nil
        case let .some((status, _)): return "Relay refused it (\(status))"
        case .none: return lastProblem ?? "No internet"
        }
    }

    private var after: Int {
        get { UserDefaults.standard.integer(forKey: "relay-after") }
        set { UserDefaults.standard.set(newValue, forKey: "relay-after") }
    }

    func poll() async {
        guard let group else { return }
        struct Page: Decodable { struct M: Decodable { let seq: Int; let sealed: String }; let messages: [M] }
        guard case let .some((200, data)) = await request("GET", RelayProtocol.path(for: group.secrets, "messages") + "?after=\(after)", body: Data()),
              let page = try? JSONDecoder().decode(Page.self, from: data) else { return }
        let keys = [group.secrets, group.previousSecrets].compactMap { $0 }
        for m in page.messages {
            if let f = RelayProtocol.open(m.sealed, with: keys) { onFrame?(f) }
            after = max(after, m.seq)
        }
    }

    private func request(_ method: String, _ path: String, body: Data) async -> (Int, Data)? {
        guard let base, let identity, let url = URL(string: path, relativeTo: base) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        if method != "GET" { req.httpBody = body }
        guard let headers = try? RelayProtocol.headers(method: method, pathAndQuery: path, body: method == "GET" ? Data() : body,
                                                       identity: identity, now: Date()) else { return nil }
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.value(forHTTPHeaderField: "X-HelpAndI-Allowance-Low") == "1" { onAllowanceLow?() }
            lastProblem = nil
            return (http.statusCode, data)
        } catch {
            lastProblem = "No internet"
            return nil
        }
    }
}
