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
        Task { await publishPushToken() }
        // Every 30 seconds while open: each poll costs two of the free tier's daily Durable Object
        // requests, shared by every group.
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Sends the member list. Only a coordinator's list is accepted by the relay.
    func publishMembers() async {
        guard let group, let body = try? JSONEncoder().encode(RelayProtocol.memberList(group)) else { return }
        _ = await request("PUT", RelayProtocol.path(for: group.secrets, "members"), body: body)
    }

    enum Wake: String { case call, quiet }

    /// `wake` asks the relay to push to the other members: `.call` visibly (a new call), `.quiet`
    /// to wake their app without showing anything (an acknowledgement). Resends do not push.
    func send(_ frame: HelpFrame, wake: Wake? = nil) async -> String? {
        guard let group else { return "Internet route not set up" }
        var fields = ["sealed": ""]
        guard let sealed = try? RelayProtocol.seal(frame, with: group.secrets) else { return "Could not seal the message" }
        fields["sealed"] = sealed
        if let wake { fields["wake"] = wake.rawValue }
        guard let body = try? JSONEncoder().encode(fields) else { return "Could not seal the message" }
        switch await request("POST", RelayProtocol.path(for: group.secrets, "messages"), body: body) {
        case .some((200, _)): return nil
        case let .some((status, _)): return "Relay refused it (\(status))"
        case .none: return lastProblem ?? "No internet"
        }
    }

    /// Where Apple can push to wake this phone. Sent whenever the relay or group changes.
    var pushToken: Data? { didSet { Task { await publishPushToken() } } }

    func publishPushToken() async {
        guard let group, let pushToken else { return }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        let hex = pushToken.map { String(format: "%02x", $0) }.joined()
        guard let body = try? JSONSerialization.data(withJSONObject: ["token": hex, "sandbox": sandbox]) else { return }
        _ = await request("PUT", RelayProtocol.path(for: group.secrets, "push"), body: body)
    }

    /// This phone's place in the group's message log, kept per group and relay address, so
    /// joining another group or changing relay never skips that group's messages.
    private var positionKey: String? {
        guard let group, let base else { return nil }
        return "relay-after-\(group.secrets.groupID.base64EncodedString())-\(base.absoluteString)"
    }

    func poll() async {
        guard let group, let positionKey else { return }
        struct Page: Decodable { struct M: Decodable { let seq: Int; let sealed: String }; let latest: Int; let messages: [M] }
        let stored = UserDefaults.standard.object(forKey: positionKey) as? Int
        let response = await request("GET", RelayProtocol.path(for: group.secrets, "messages") + "?after=\(stored ?? 0)", body: Data())
        if case .some((403, _)) = response { lastProblem = "The relay does not list this phone. Ask your coordinator to open Help&I."; return }
        guard case let .some((200, data)) = response, let page = try? JSONDecoder().decode(Page.self, from: data) else { return }
        // A first poll starts from now rather than replaying a week of old calls as new alerts;
        // calls still open are sent again by their callers, so they arrive within minutes. A place
        // ahead of the relay means the relay was reset: start again from its beginning.
        guard let stored, stored <= page.latest else {
            UserDefaults.standard.set(stored == nil ? page.latest : 0, forKey: positionKey)
            return
        }
        let keys = group.listening(at: Date())
        var position = stored
        for m in page.messages.sorted(by: { $0.seq < $1.seq }) {
            if let f = RelayProtocol.open(m.sealed, with: keys) { onFrame?(f) }
            position = max(position, m.seq)
        }
        UserDefaults.standard.set(position, forKey: positionKey)
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
            if http.statusCode != 403 { lastProblem = nil }
            return (http.statusCode, data)
        } catch {
            lastProblem = "No internet"
            return nil
        }
    }
}
