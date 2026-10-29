import Foundation
import helpandeyeCore

/// The internet route: the group's relay (relay/ in this repository). Frames are sealed with the
/// group key on this phone; the relay stores ciphertext and public keys only.
@MainActor
final class Relay: ObservableObject, RelayLink {
    var onFrame: ((HelpFrame) -> Void)?
    /// Set while a call is open on this phone, as caller or responder, to poll more often.
    var busy = false
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
        registerPushToken()
        // Every 30 seconds while something is open, every two minutes otherwise: each poll costs two
        // of the free tier's daily Durable Object requests, shared by every group.
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(self?.busy == true ? 30 : 120))
            }
        }
    }

    /// Sends the member list. Only a coordinator's list is accepted by the relay.
    func publishMembers() async -> PublishResult {
        guard let group, let body = try? JSONEncoder().encode(RelayProtocol.memberList(group)) else { return .refused }
        switch await request("PUT", RelayProtocol.path(for: group.secrets, "members"), body: body) {
        case .some((200, _)): return .accepted
        case let .some((status, _)) where status >= 500 || status == 429: return .unreachable
        // Another coordinator's list, before the first coordinator has registered the group.
        case .some((425, _)): return .notYet
        case let .some((status, _)): lastProblem = "The relay did not take the member list (\(status))."; return .refused
        case .none: return .unreachable
        }
    }

    /// `wake` asks the relay to push to the other members: `.call` visibly (a new call), `.quiet`
    /// to wake their app without showing anything (an acknowledgement). Resends do not push.
    /// During a changeover after a removal, the message is sealed and posted once with each key, so
    /// members who have not scanned their update yet can still open it.
    func send(_ frame: HelpFrame, wake: RelayWake?) async -> String? {
        guard let group else { return "Internet route not set up" }
        var failure: String?
        for (n, secrets) in group.listening(at: Date()).enumerated() {
            var fields = ["sealed": ""]
            guard let sealed = try? RelayProtocol.seal(frame, with: secrets) else { return "Could not seal the message" }
            fields["sealed"] = sealed
            // One push per call, not one per key.
            if let wake, n == 0 { fields["wake"] = wake.rawValue }
            guard let body = try? JSONEncoder().encode(fields) else { return "Could not seal the message" }
            let result: String?
            switch await request("POST", RelayProtocol.path(for: group.secrets, "messages"), body: body) {
            // Kept on the relay, but Apple could not wake anyone yet: not counted as sent, so the
            // next resend asks for the wake again.
            case let .some((200, data)) where (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["woke"] as? Bool == false:
                result = "On the relay, but no phone could be woken yet"
            case .some((200, _)): result = nil
            case let .some((status, _)): result = "Relay refused it (\(status))"
            case .none: result = lastProblem ?? "No internet"
            }
            if n == 0 { failure = result }
        }
        return failure
    }

    /// Where Apple can push to wake this phone. Sent whenever the relay or group changes.
    var pushToken: Data? { didSet { registerPushToken() } }
    /// "watch" on a watch acting for its phone: the relay keeps one token of each per member and
    /// wakes a watch quietly.
    var device = "phone"

    /// The group, relay address and token the relay last took. Until it takes the current ones
    /// (refused until a coordinator's phone has listed this one, or not reached), they are tried
    /// again after a growing pause, for as long as they stay the current ones.
    private var registered: String?
    private var registration: Task<Void, Never>?
    private var wanted: String? {
        guard let group, let base, let pushToken else { return nil }
        return [group.secrets.groupID.base64EncodedString(), base.absoluteString, pushToken.base64EncodedString()].joined(separator: " ")
    }

    /// Starts registering now, in place of any attempt waiting out its pause.
    private func registerPushToken() {
        guard wanted != registered else { return }
        registration?.cancel()
        registration = Task { await publishPushToken() }
    }

    private func publishPushToken() async {
        var pause: TimeInterval = 60
        while !Task.isCancelled, let group, let pushToken, let wanted, wanted != registered {
            #if DEBUG
            let sandbox = true
            #else
            let sandbox = false
            #endif
            let hex = pushToken.map { String(format: "%02x", $0) }.joined()
            guard let body = try? JSONSerialization.data(withJSONObject: ["token": hex, "sandbox": sandbox, "device": device] as [String: Any]) else { return }
            if case .some((200, _)) = await request("PUT", RelayProtocol.path(for: group.secrets, "push"), body: body) {
                registered = wanted
                return
            }
            try? await Task.sleep(for: .seconds(pause))
            pause = min(pause * 2, 600)
        }
    }

    /// This phone's place in the group's message log, kept per group and relay address, so
    /// joining another group or changing relay never skips that group's messages.
    private var positionKey: String? {
        guard let group, let base else { return nil }
        return "relay-after-\(group.secrets.groupID.base64EncodedString())-\(base.absoluteString)"
    }

    /// Reads what is waiting, page by page (RelayPoll in helpandeyeCore decides what to act on and
    /// where to carry on).
    func poll() async {
        guard let group, let positionKey else { return }
        for _ in 0..<5 {
            let stored = RelayPoll.Position.saved(UserDefaults.standard.object(forKey: positionKey))
            let response = await request("GET", RelayProtocol.path(for: group.secrets, "messages") + "?after=\(RelayPoll.after(stored))", body: Data())
            if case .some((403, _)) = response { lastProblem = "The relay does not list this phone. Ask your coordinator to open Help&I."; return }
            guard case let .some((200, data)) = response, let page = try? JSONDecoder().decode(RelayPoll.Page.self, from: data) else { return }
            // The group or relay changed while waiting: this page belongs to the old one.
            guard self.group?.secrets.groupID == group.secrets.groupID, self.positionKey == positionKey else { return }
            // Answered, so this phone is listed now: a registration still waiting can go.
            registerPushToken()
            let outcome = RelayPoll.read(page, from: stored, at: Date(), keys: group.listening(at: Date()))
            for f in outcome.frames { onFrame?(f) }
            UserDefaults.standard.set(try? JSONEncoder().encode(outcome.position), forKey: positionKey)
            if !outcome.more { return }
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
            if http.value(forHTTPHeaderField: "X-HelpA-Allowance-Low") == "1" { onAllowanceLow?() }
            if http.statusCode != 403 { lastProblem = nil }
            return (http.statusCode, data)
        } catch {
            lastProblem = "No internet"
            return nil
        }
    }
}
