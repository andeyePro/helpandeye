import Combine
import Foundation
import helpandeyeCore
import WatchConnectivity

/// The watch's two ways of working. With the phone in reach, the buttons send through it and it
/// does the routing. Out of reach, the watch calls and responds by itself over its own internet
/// (Wi-Fi or mobile), as its owner, with what the phone last handed it (WatchHandover).
@MainActor
final class WatchModel: NSObject, ObservableObject {
    struct Open: Identifiable, Equatable {
        let unit: UInt32, request: UInt16, colour: Colour, who: String
        var id: String { "\(unit)-\(request)" }
        var key: IncomingRequest.Key { .init(unit: unit, request: request) }
    }

    @Published private(set) var phoneInReach = false
    /// What the phone last said about the call it sent, and the calls it can acknowledge.
    @Published private var phoneStatus: String?
    @Published private var phoneFailed = false
    @Published private var phoneOpen: [Open] = []
    /// What happened when the watch could not even ask the phone or the internet.
    @Published private var problem: String?
    /// Set when the last call went out from the watch itself, so its own status is shown.
    @Published private var sentByWatch = false

    private(set) var engine: HelpEngine?
    private let relay = Relay()
    private let box = NoBox()
    private let alerts = WatchAlerts()
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?

    override init() {
        super.init()
        if let id = Store.handedOverIdentity() { start(id) }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                engine.tick()
                self.relay.busy = engine.activity.outgoing.contains { $0.nextResend != nil && $0.unit != 0 }
                    || engine.activity.inbox.requests.values.contains { !$0.isAcknowledged && $0.colour != .green }
            }
        }
    }

    private func start(_ identity: DeviceIdentity) {
        bag = []
        let engine = HelpEngine(identity: identity, mesh: box, relay: relay, alerts: alerts, store: AppStore(),
                                saved: Store.loadState(), activity: Store.loadActivity(), companion: true)
        relay.onFrame = { [weak engine] in engine?.receive($0, via: .internet) }
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        self.engine = engine
    }

    /// Takes in what the phone handed over: the first time, or with new keys, as a fresh start.
    fileprivate func take(_ data: Data) {
        guard let handover = try? JSONDecoder().decode(WatchHandover.self, from: data), let identity = handover.identity else { return }
        if engine?.take(handover) == true { return }
        Store.keep(handedOver: identity)
        Store.save(handover.state(keeping: nil))
        start(identity)
        engine?.take(handover)
    }

    fileprivate func apply(_ context: [String: Any]) {
        phoneStatus = context["status"] as? String
        phoneFailed = context["failed"] as? Bool ?? false
        phoneOpen = (context["open"] as? [[String: Any]] ?? []).compactMap { d in
            guard let u = (d["unit"] as? Int).flatMap(UInt32.init(exactly:)), let r = (d["request"] as? Int).flatMap(UInt16.init(exactly:)),
                  let c = (d["colour"] as? Int).flatMap({ Colour(rawValue: UInt8($0)) }), let w = d["who"] as? String else { return nil }
            return Open(unit: u, request: r, colour: c, who: w)
        }
        if let data = context["handover"] as? Data { take(data) }
    }

    fileprivate func setReach(_ reachable: Bool) {
        phoneInReach = reachable
        // The phone alerts its owner while it is in reach; the watch only when it is not.
        alerts.quiet = reachable
    }

    // MARK: What the screen shows

    func words(_ colour: Colour) -> String { ButtonWords.words(colour, in: engine?.group) }

    var status: (text: String, cross: Bool)? {
        if let problem { return (problem, true) }
        if sentByWatch, let r = engine?.current {
            let w = StatusWords.watch(r.status, name: { self.engine?.name(ofMember: $0) ?? "A responder" })
            return (w.headline, w.cross)
        }
        return phoneStatus.map { ($0, phoneFailed) }
    }

    var open: [Open] {
        if phoneInReach { return phoneOpen }
        guard let engine else { return [] }
        return engine.activity.inbox.sorted.filter { !$0.isAcknowledged }.prefix(5).map {
            Open(unit: $0.key.unit, request: $0.key.request, colour: $0.colour ?? .red, who: engine.name(ofUnit: $0.key.unit))
        }
    }

    // MARK: Buttons

    func press(_ colour: Colour) {
        problem = nil
        if phoneInReach, WCSession.default.activationState == .activated {
            sentByWatch = false
            phoneStatus = "Sending…"; phoneFailed = false
            WCSession.default.sendMessage(["press": Int(colour.rawValue)], replyHandler: { reply in
                let ok = reply["ok"] as? Bool == true
                Task { @MainActor in if !ok { self.pressAlone(colour) } }
            }, errorHandler: { _ in
                Task { @MainActor in self.pressAlone(colour) }
            })
        } else {
            pressAlone(colour)
        }
    }

    /// The phone did not answer: send from the watch itself if it can.
    private func pressAlone(_ colour: Colour) {
        guard let engine, engine.me?.canCall == true else {
            problem = "Not sent: your phone is out of reach. Use your phone, or call 999."
            return
        }
        sentByWatch = true
        engine.press(colour)
    }

    func acknowledge(_ r: Open) {
        problem = nil
        if phoneInReach {
            WCSession.default.sendMessage(["ackUnit": Int(r.unit), "ackRequest": Int(r.request)], replyHandler: { reply in
                let ok = reply["ok"] as? Bool == true
                Task { @MainActor in
                    if ok { self.phoneOpen.removeAll { $0 == r } } else if self.engine?.acknowledge(r.key) != true { self.problem = "Not acknowledged. Use your phone." }
                }
            }, errorHandler: { _ in
                Task { @MainActor in if self.engine?.acknowledge(r.key) != true { self.problem = "Not acknowledged: use your phone." } }
            })
        } else if engine?.acknowledge(r.key) != true {
            problem = "Not acknowledged: this watch cannot reach the internet. Use your phone."
        }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = s.receivedApplicationContext, reachable = s.isReachable
        Task { @MainActor in self.apply(context); self.setReach(reachable) }
    }

    nonisolated func session(_ s: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func sessionReachabilityDidChange(_ s: WCSession) {
        let reachable = s.isReachable
        Task { @MainActor in self.setReach(reachable) }
    }
}

/// The watch has no box of its own (yet): it reaches the group over the internet only.
@MainActor final class NoBox: MeshLink {
    let isReady = false
    let radio: RadioSettings? = nil
    let boxPublicKey: Data? = nil
    let channelsPerSend = 1
    let unavailableReason = "The watch has no box"
    var secrets: [Data] = []
    func send(_ frame: HelpFrame, urgent: Bool) async -> MeshSendResult { .refused(unavailableReason) }
    func sendText(_ text: String, to key: Data) async -> MeshSendResult { .refused(unavailableReason) }
    func addContact(_ key: Data, name: String) async {}
}

/// The watch's own alerts, held back while the phone is in reach (it alerts its owner then, and
/// two buzzes for one call would only confuse) and let go the moment it is not.
@MainActor final class WatchAlerts: AlertScheduler {
    private let inner = NotificationAlerts()
    private var held: [IncomingRequest.Key: Alert] = [:]
    var quiet = false {
        didSet {
            guard quiet != oldValue else { return }
            if quiet { held.keys.forEach(inner.cancel) } else { held.values.forEach(inner.schedule) }
        }
    }

    func schedule(_ alert: Alert) { held[alert.key] = alert; if !quiet { inner.schedule(alert) } }
    func cancel(_ key: IncomingRequest.Key) { held[key] = nil; inner.cancel(key) }
    func cancelAll() { held = [:]; inner.cancelAll() }
    /// Check-in reminders are the phone's.
    func setCheckInReminders(_ minutesAfterMidnight: [Int]) {}
    func tellCaller(title: String, body: String) { if !quiet { inner.tellCaller(title: title, body: body) } }
}
