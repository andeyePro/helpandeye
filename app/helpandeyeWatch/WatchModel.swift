import Combine
import Foundation
import helpandeyeCore
import UserNotifications
import WatchConnectivity

/// The watch's two ways of working. With the phone in reach, the buttons send through it and it
/// does the routing. Out of reach, the watch calls and responds by itself over its own internet
/// (Wi-Fi or mobile), as its owner, with what the phone last handed it (WatchHandover).
@MainActor
final class WatchModel: NSObject, ObservableObject {
    struct Open: Identifiable, Equatable {
        let unit: UInt32, request: UInt16, colour: Colour, who: String
        /// The group's tag, so an acknowledgement goes to the right group.
        var group = ""
        var id: String { "\(group)-\(unit)-\(request)" }
        var key: IncomingRequest.Key { .init(unit: unit, request: request) }
    }

    @Published private(set) var phoneInReach = false
    /// What the phone last said about the call it sent, and the calls it can acknowledge.
    @Published private var phoneStatus: String?
    @Published private var phoneFailed = false
    /// Which call the phone's status is about.
    @Published private var phoneCall: IncomingRequest.Key?
    @Published private var phoneOpen: [Open] = []
    /// The acknowledgement last made from the watch, and its group, so whether it went out can be
    /// shown.
    @Published private var lastAck: (group: String, key: IncomingRequest.Key)?
    /// What happened when the watch could not even ask the phone or the internet.
    @Published private var problem: String?
    /// Set when the last call went out from the watch itself, so its own status is shown.
    @Published private var sentByWatch = false
    /// The button last pressed here, for what is said after Need a hand.
    @Published private var pressed: Colour?
    /// Notifications for Help&I are turned off on this watch, so it cannot alert its owner.
    @Published private(set) var alertsOff = false
    private var voiceTracker = CallerFeedback.Tracker(nil)

    private(set) var engine: HelpEngine?
    private let relay = Relay()
    private let box = NoBox()
    private let alerts = WatchAlerts()
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?
    /// Other groups the owner responds in, by tag, each with its own engine, relay and alerts.
    private var others: [String: Other] = [:]

    private struct Other {
        let engine: HelpEngine
        let relay: Relay
        let alerts: WatchAlerts
    }

    private var allEngines: [HelpEngine] { [engine].compactMap { $0 } + others.values.map(\.engine) }

    static let shared = WatchModel()

    override init() {
        super.init()
        relay.device = "watch"
        if let id = Store.handedOverIdentity() {
            start(id)
            // The other groups come back too: a handover may not come again after a relaunch.
            for tag in Store.otherGroups { makeOther(tag, identity: id) }
        }
        #if DEBUG && targetEnvironment(simulator)
        if Self.isScreensTest {
            phoneInReach = true
            phoneOpen = [Open(unit: 70001, request: 1, colour: .red, who: "Sam")]
            return
        }
        #endif
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (e, r) in [(self.engine, self.relay)] + self.others.values.map({ ($0.engine as HelpEngine?, $0.relay) }) {
                    guard let e else { continue }
                    e.tick()
                    r.busy = e.activity.outgoing.contains { $0.nextResend != nil && $0.unit != 0 }
                        || e.activity.inbox.requests.values.contains { !$0.isAcknowledged && $0.colour != .green }
                }
            }
        }
    }

    private func start(_ identity: DeviceIdentity) {
        bag = []
        let engine = HelpEngine(identity: identity, mesh: box, relay: relay, alerts: alerts, store: AppStore(),
                                saved: Store.loadState(), activity: Store.loadActivity(), companion: true)
        relay.onFrame = { [weak engine] in engine?.receive($0, via: .internet) }
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // Every call this engine makes is the watch's own (numbered 32768 and up): it says what happened.
        voiceTracker = .init(engine.current)
        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.tellCaller() }.store(in: &bag)
        self.engine = engine
    }

    private func tellCaller() {
        guard let engine else { return }
        let r = engine.current
        let words = r.map { ButtonWords.words($0.colour, in: engine.group) } ?? ""
        let note = r?.colour == .amber ? ButtonWords.amberNote(in: engine.group) : nil
        if let f = voiceTracker.update(r, words: words, note: note, name: engine.name(ofMember:)) { CallerVoice.shared.tell(f) }
    }

    /// Whether the owner has turned Help&I's notifications off on this watch.
    func checkAlerts() async {
        alertsOff = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Takes in what the phone handed over: the first time, or with new keys, as a fresh start that
    /// still keeps the watch's own call numbering, so no number is ever used twice.
    fileprivate func take(_ data: Data) {
        guard let handover = try? JSONDecoder().decode(WatchHandover.self, from: data), let identity = handover.identity else { return }
        if engine?.take(handover) != true {
            Store.keep(handedOver: identity)
            Store.save(handover.state(keeping: Store.loadState()))
            start(identity)
            engine?.take(handover)
        }
        takeOthers(Array(handover.each.dropFirst()), identity: identity)
    }

    /// The other groups' handovers: new ones started, gone ones forgotten.
    private func takeOthers(_ parts: [WatchHandover], identity: DeviceIdentity) {
        let wanted = Set(parts.map(\.group.tag))
        for (tag, o) in others where !wanted.contains(tag) {
            o.alerts.cancelAll()
            o.engine.leave()
            Store.forget(group: tag)
            others[tag] = nil
        }
        for part in parts {
            let tag = part.group.tag
            if let o = others[tag] {
                if o.engine.take(part) { continue }
                // Made with other keys: start again, and nothing held back is let go later.
                o.alerts.cancelAll()
            }
            Store.save(part.state(keeping: Store.loadState(tag)), group: tag)
            makeOther(tag, identity: identity)
            others[tag]?.engine.take(part)
        }
        Store.otherGroups = others.keys.sorted()
        settleAlerts()
    }

    /// An engine, relay and alerts for another group, from what is saved under its tag.
    private func makeOther(_ tag: String, identity: DeviceIdentity) {
        let relay = Relay(), alerts = WatchAlerts(prefix: tag + "-")
        relay.device = "watch"
        relay.pushToken = self.relay.pushToken
        let e = HelpEngine(identity: identity, mesh: NoBox(), relay: relay, alerts: alerts, store: AppStore(group: tag),
                           saved: Store.loadState(tag), activity: Store.loadActivity(tag), companion: true)
        relay.onFrame = { [weak e] in e?.receive($0, via: .internet) }
        e.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        others[tag] = Other(engine: e, relay: relay, alerts: alerts)
    }

    /// Each group's alerts stay quiet only for calls the phone, in reach, says it has.
    private func settleAlerts() {
        let first = engine?.group?.tag ?? ""
        let has = phoneInReach ? phoneOpen : []
        alerts.phoneHas = Set(has.filter { $0.group.isEmpty || $0.group == first }.map(\.key))
        for (tag, o) in others { o.alerts.phoneHas = Set(has.filter { $0.group == tag }.map(\.key)) }
    }

    /// The owner left the group on their phone: the watch stops acting for them at once.
    fileprivate func forget() {
        alerts.cancelAll()
        for (tag, o) in others { o.alerts.cancelAll(); Store.forget(group: tag) }
        others = [:]
        Store.otherGroups = []
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
            return Open(unit: u, request: r, colour: c, who: w, group: d["group"] as? String ?? "")
        }
        settleAlerts()
    }

    fileprivate func setReach(_ reachable: Bool) {
        phoneInReach = reachable
        // The watch stays quiet only for calls its phone, in reach, has itself heard and is
        // alerting for; any other call it alerts for at once.
        settleAlerts()
    }

    /// Where Apple can push to wake this watch when its phone is out of reach.
    func setPushToken(_ token: Data) {
        relay.pushToken = token
        others.values.forEach { $0.relay.pushToken = token }
    }

    /// A quiet push from the relay: fetch what is waiting. The engine schedules the watch's own
    /// alerts, which sound only while the phone is out of reach.
    func wake() async {
        await relay.poll()
        for o in others.values { await o.relay.poll() }
        allEngines.forEach { $0.tick() }
    }

    // MARK: What the screen shows

    func words(_ colour: Colour) -> String { ButtonWords.words(colour, in: engine?.group) }

    /// Not set up and no phone to send through: the buttons could not reach anyone.
    var needsSetUp: Bool { engine?.me == nil && !phoneInReach }

    /// What is said after Need a hand, while that call has not failed.
    var amberNote: String? {
        pressed == .amber && status?.cross == false ? ButtonWords.amberNote(in: engine?.group) : nil
    }

    var status: (text: String, cross: Bool)? {
        if let problem { return (problem, true) }
        if let ack = lastAck, let s = engine(forGroup: ack.group)?.ackSendStatus(ack.key) {
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

    /// Every group's open calls together, most urgent first, then the first five.
    var open: [Open] {
        if phoneInReach { return phoneOpen }
        let all = allEngines.flatMap { e in e.activity.inbox.requests.values.filter { !$0.isAcknowledged }.map { (e, $0) } }
        return all.sorted { ResponderInbox.moreUrgent($0.1, $1.1) }.prefix(5).map { e, r in
            Open(unit: r.key.unit, request: r.key.request, colour: r.colour ?? .red, who: e.name(ofUnit: r.key.unit), group: e.group?.tag ?? "")
        }
    }

    /// The engine for a group's tag; an empty tag (from a phone before several groups) is the first.
    private func engine(forGroup tag: String) -> HelpEngine? {
        tag.isEmpty || tag == engine?.group?.tag ? engine : others[tag]?.engine
    }

    // MARK: Buttons

    /// With the phone's handover, the watch makes the call itself, sends it over its own internet,
    /// and gives the same call to the phone to send on the phone's routes: one call, however many
    /// ways it goes, so a lost reply can never send it twice. Without one, the phone makes it.
    func press(_ colour: Colour) {
        CallerVoice.shared.pressed()
        pressed = colour
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
            failed("Not sent: your phone is out of reach. Use your phone, or call 999.")
            return
        }
        phoneStatus = "Sending…"; phoneFailed = false
        WCSession.default.sendMessage(["press": Int(colour.rawValue)], replyHandler: { reply in
            let ok = reply["ok"] as? Bool == true
            Task { @MainActor in if !ok { self.failed("Not sent: set up Help&I on your phone first. Until then, use your phone, or call 999.") } }
        }, errorHandler: { _ in
            Task { @MainActor in self.failed("Not sent: your phone did not answer. Use your phone, or call 999.") }
        })
    }

    /// A call that could not even be handed on: shown, and heard as not sent.
    private func failed(_ why: String) {
        problem = why
        CallerVoice.shared.tell(.init(sound: .notSent, spoken: why))
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The screenshot test's made-up phone in reach, with one call to acknowledge. Locked three
    /// ways: a debug build, on a simulator, and only with the test's own launch argument. A real
    /// watch can never show it.
    private static var isScreensTest: Bool { ProcessInfo.processInfo.arguments.contains("-HelpAScreensTest") }
    #endif

    /// Acknowledges from the watch itself (signed as its owner) and through the phone when it is in
    /// reach. Two copies of one person's acknowledgement are one acknowledgement.
    func acknowledge(_ r: Open) {
        problem = nil
        let mine = engine(forGroup: r.group)?.acknowledge(r.key) == true
        lastAck = mine ? (r.group, r.key) : nil
        guard phoneInReach else {
            if !mine { problem = "Not acknowledged: use your phone." }
            return
        }
        WCSession.default.sendMessage(["ackUnit": Int(r.unit), "ackRequest": Int(r.request), "group": r.group], replyHandler: { reply in
            let ok = reply["ok"] as? Bool == true
            Task { @MainActor in
                if ok { self.phoneOpen.removeAll { $0 == r } } else if !mine { self.problem = "Not acknowledged. Use your phone." }
            }
        }, errorHandler: { _ in
            Task { @MainActor in if !mine { self.problem = "Not acknowledged: your phone did not answer. Use your phone." } }
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
    private let inner: NotificationAlerts
    init(prefix: String = "") { inner = NotificationAlerts(prefix: prefix, ownsCheckIns: false) }
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
