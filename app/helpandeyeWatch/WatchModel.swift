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
    /// Which call the phone's status is about.
    @Published private var phoneCall: IncomingRequest.Key?
    @Published private var phoneOpen: [Open] = []
    /// The acknowledgement last made from the watch, so whether it went out can be shown.
    @Published private var lastAck: IncomingRequest.Key?
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

    static let shared = WatchModel()

    override init() {
        super.init()
        relay.device = "watch"
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

    /// Takes in what the phone handed over: the first time, or with new keys, as a fresh start that
    /// still keeps the watch's own call numbering, so no number is ever used twice.
    fileprivate func take(_ data: Data) {
        guard let handover = try? JSONDecoder().decode(WatchHandover.self, from: data), let identity = handover.identity else { return }
        if engine?.take(handover) == true { return }
        Store.keep(handedOver: identity)
        Store.save(handover.state(keeping: Store.loadState()))
        start(identity)
        engine?.take(handover)
    }

    /// The owner left the group on their phone: the watch stops acting for them at once.
    fileprivate func forget() {
        alerts.cancelAll()
        engine = nil
        bag = []
        Store.forgetHandedOver()
        objectWillChange.send()
    }

    fileprivate func received(_ info: [String: Any]) {
        if let data = info["handover"] as? Data { take(data) }
        if info["left"] as? Bool == true { forget() }
    }

    fileprivate func apply(_ context: [String: Any]) {
        phoneStatus = context["status"] as? String
        phoneFailed = context["failed"] as? Bool ?? false
        phoneCall = (context["unit"] as? Int).flatMap(UInt32.init(exactly:)).flatMap { u in
            (context["request"] as? Int).flatMap(UInt16.init(exactly:)).map { IncomingRequest.Key(unit: u, request: $0) }
        }
        phoneOpen = (context["open"] as? [[String: Any]] ?? []).compactMap { d in
            guard let u = (d["unit"] as? Int).flatMap(UInt32.init(exactly:)), let r = (d["request"] as? Int).flatMap(UInt16.init(exactly:)),
                  let c = (d["colour"] as? Int).flatMap({ Colour(rawValue: UInt8($0)) }), let w = d["who"] as? String else { return nil }
            return Open(unit: u, request: r, colour: c, who: w)
        }
        alerts.phoneHas = phoneInReach ? Set(phoneOpen.map(\.key)) : []
    }

    fileprivate func setReach(_ reachable: Bool) {
        phoneInReach = reachable
        // The watch stays quiet only for calls its phone, in reach, has itself heard and is
        // alerting for; any other call it alerts for at once.
        alerts.phoneHas = reachable ? Set(phoneOpen.map(\.key)) : []
    }

    /// Where Apple can push to wake this watch when its phone is out of reach.
    func setPushToken(_ token: Data) { relay.pushToken = token }

    /// A quiet push from the relay: fetch what is waiting. The engine schedules the watch's own
    /// alerts, which sound only while the phone is out of reach.
    func wake() async {
        await relay.poll()
        engine?.tick()
    }

    // MARK: What the screen shows

    func words(_ colour: Colour) -> String { ButtonWords.words(colour, in: engine?.group) }

    var status: (text: String, cross: Bool)? {
        if let problem { return (problem, true) }
        if let key = lastAck, let s = engine?.ackSendStatus(key) {
            switch s {
            case .notSent: return ("Not acknowledged: this watch cannot reach the internet. Use your phone.", true)
            case .sending: return ("Sending your acknowledgement…", false)
            default: return ("Acknowledged.", false)
            }
        }
        if sentByWatch, let r = engine?.current {
            // The phone sends the same call on its own routes: if it got it out, say so.
            if phoneInReach, phoneCall == IncomingRequest.Key(unit: r.unit, request: r.number), let phoneStatus, !phoneFailed {
                return (phoneStatus, false)
            }
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

    /// With the phone's handover, the watch makes the call itself, sends it over its own internet,
    /// and gives the same call to the phone to send on the phone's routes: one call, however many
    /// ways it goes, so a lost reply can never send it twice. Without one, the phone makes it.
    func press(_ colour: Colour) {
        problem = nil
        lastAck = nil
        if let engine, engine.me?.canCall == true {
            sentByWatch = true
            engine.press(colour)
            if phoneInReach, let call = engine.current?.callFrame {
                WCSession.default.sendMessage(["call": call.encoded()], replyHandler: nil, errorHandler: nil)
            }
            return
        }
        sentByWatch = false
        guard phoneInReach, WCSession.default.activationState == .activated else {
            problem = "Not sent: your phone is out of reach. Use your phone, or call 999."
            return
        }
        phoneStatus = "Sending…"; phoneFailed = false
        WCSession.default.sendMessage(["press": Int(colour.rawValue)], replyHandler: { reply in
            let ok = reply["ok"] as? Bool == true
            Task { @MainActor in if !ok { self.problem = "Not sent: set up Help&I on your phone first." } }
        }, errorHandler: { _ in
            Task { @MainActor in self.problem = "Not sent: your phone did not answer. Use your phone, or call 999." }
        })
    }

    /// Acknowledges from the watch itself (signed as its owner) and through the phone when it is in
    /// reach. Two copies of one person's acknowledgement are one acknowledgement.
    func acknowledge(_ r: Open) {
        problem = nil
        if engine?.acknowledge(r.key) == true { lastAck = r.key }
        guard phoneInReach else {
            if lastAck != r.key { problem = "Not acknowledged: use your phone." }
            return
        }
        WCSession.default.sendMessage(["ackUnit": Int(r.unit), "ackRequest": Int(r.request)], replyHandler: { reply in
            let ok = reply["ok"] as? Bool == true
            Task { @MainActor in
                if ok { self.phoneOpen.removeAll { $0 == r } } else if self.lastAck != r.key { self.problem = "Not acknowledged. Use your phone." }
            }
        }, errorHandler: { _ in
            Task { @MainActor in if self.lastAck != r.key { self.problem = "Not acknowledged: your phone did not answer. Use your phone." } }
        })
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

    nonisolated func session(_ s: WCSession, didReceiveUserInfo info: [String: Any]) {
        Task { @MainActor in self.received(info) }
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

/// The watch's own alerts. Each is held back while the phone, in reach, has heard that call and is
/// alerting for it (two buzzes for one call would only confuse), and let go the moment that stops
/// being true, as one alert now rather than a burst of the ones missed.
@MainActor final class WatchAlerts: AlertScheduler {
    private let inner = NotificationAlerts()
    private var held: [IncomingRequest.Key: Alert] = [:]
    private var sounding: Set<IncomingRequest.Key> = []
    var phoneHas: Set<IncomingRequest.Key> = [] { didSet { if phoneHas != oldValue { settle() } } }

    func schedule(_ alert: Alert) {
        held[alert.key] = alert
        sounding.remove(alert.key)
        settle()
    }

    func cancel(_ key: IncomingRequest.Key) { held[key] = nil; sounding.remove(key); inner.cancel(key) }
    func cancelAll() { held = [:]; sounding = []; inner.cancelAll() }
    /// Check-in reminders are the phone's.
    func setCheckInReminders(_ minutesAfterMidnight: [Int]) {}
    func tellCaller(title: String, body: String) { inner.tellCaller(title: title, body: body) }

    private func settle() {
        for (key, alert) in held {
            if phoneHas.contains(key) {
                if sounding.remove(key) != nil { inner.cancel(key) }
            } else if !sounding.contains(key) {
                inner.schedule(alert.fromNow(Date()))
                sounding.insert(key)
            }
        }
    }
}
