import Combine
import Foundation
import helpandeyeCore
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's two ways of working. With the phone in reach, the buttons send through it and it
/// does the routing. Out of reach, the watch calls and responds by itself over its own internet
/// (Wi-Fi or mobile), as its owner, with what the phone last handed it (WatchHandover).
@MainActor
final class WatchModel: NSObject, ObservableObject {
    struct Open: Identifiable, Equatable {
        let unit: UInt32, request: UInt16, colour: Colour, who: String
        /// The group's tag, so an acknowledgement goes to the right group.
        var group = ""
        var id: String { Self.id(group, key) }
        var key: IncomingRequest.Key { .init(unit: unit, request: request) }
        static func id(_ group: String, _ key: IncomingRequest.Key) -> String { "\(group)-\(key.unit)-\(key.request)" }
    }

    @Published private(set) var phoneInReach = false
    /// What the phone last said about the call it sent, and the calls it can acknowledge.
    @Published private var phoneStatus: String?
    @Published private var phoneFailed = false
    /// Which call the phone's status is about.
    @Published private var phoneCall: IncomingRequest.Key?
    @Published private var phoneOpen: [Open] = []
    /// Calls a person settled on the phone (acknowledged or closed), by group tag: never alerted
    /// for or listed as open here, whatever this watch has heard, in reach of the phone or not.
    @Published private var phoneSettled: [String: Set<IncomingRequest.Key>] = [:]
    /// The phone's signed acknowledgements already given to this watch's engines.
    private var acksTaken: Set<Data> = []
    /// Calls this watch made that the phone has taken, and acknowledgements made here it was told
    /// of, so each is given once.
    private var givenToPhone: Set<UInt16> = []
    private var ackedThroughPhone: Set<String> = []
    /// Acknowledgements the phone confirmed it made, by `Open.id`: one this watch could not send
    /// itself still went.
    @Published private var phoneAcked: Set<String> = []
    /// The acknowledgement last made from the watch, and its group, so whether it went out can be
    /// shown.
    @Published private var lastAck: (group: String, key: IncomingRequest.Key)?
    /// What happened when the watch could not even ask the phone or the internet.
    @Published private var problem: String?
    /// Something to know that is not a failure, so shown and said without the cross or its sound.
    @Published private var warning: String?
    /// Set when the last call went out from the watch itself, so its own status is shown.
    @Published private var sentByWatch = false
    /// The button last pressed here, for what is said after Need a hand.
    @Published private var pressed: Colour?
    /// What the wearer is told after an I'm OK that settled an open call.
    @Published private(set) var okNote: String?
    /// The complication's countdown to Help, while it runs, and the seconds left on it.
    @Published private(set) var countdown: HelpCountdown?
    @Published private(set) var secondsLeft = 0
    private var countdownTimer: Timer?
    private var countdownCheckedAt = Date()
    private var runtime: WKExtendedRuntimeSession?
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
            if ProcessInfo.processInfo.arguments.contains("-HelpACountdown") { startCountdown() }
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
                        || e.activity.inbox.requests.values.contains { $0.isOpen && $0.colour != .green }
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
        let words = r.map { ButtonWords.words($0.colour, in: engine.profile) } ?? ""
        let note = r?.colour == .amber ? ButtonWords.amberNote(in: engine.profile) : (r?.colour == .green ? okNote : nil)
        if let f = voiceTracker.update(r, words: words, note: note, name: engine.name(ofMember:)) { CallerVoice.shared.tell(f, profile: engine.profile) }
    }

    /// Whether the owner has turned Help&I's notifications off on this watch.
    func checkAlerts() async {
        alertsOff = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Takes in what the phone handed over: the first time, or with new keys, as a fresh start that
    /// still keeps the watch's own call numbering, so no number is ever used twice.
    fileprivate func take(_ data: Data) {
        guard let handover = try? JSONDecoder().decode(WatchHandover.self, from: data), let identity = handover.identity else { return }
        // The old group's calls, alerts and relay polling go with it, and its call numbers, which
        // the new group's calls may use again.
        if let engine, handover.startsAfresh(from: engine.saved) { engine.leave(); givenToPhone = [] }
        if engine?.take(handover) != true {
            // Other keys are another phone (or a phone set up afresh): what the old one's watch
            // heard and sent is not this one's.
            if engine != nil { alerts.cancelAll(); Store.save(Activity()) }
            Store.keep(handedOver: identity)
            Store.save(handover.state(keeping: Store.loadState()))
            start(identity)
            engine?.take(handover)
        }
        takeOthers(Array(handover.each.dropFirst()), identity: identity)
        // Told through the handover that the owner no longer responds in a group (removed, or
        // made a caller only): nothing should keep alerting for calls they cannot answer.
        if engine?.me?.canRespond != true { alerts.cancelAll() }
        for o in others.values where o.engine.me?.canRespond != true { o.alerts.cancelAll() }
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

    /// Each group's alerts stay quiet only for calls the phone, in reach, says it has, and never
    /// sound for those it has settled.
    private func settleAlerts() {
        let first = engine?.group?.tag ?? ""
        let has = phoneInReach ? phoneOpen : []
        alerts.phoneHas = Set(has.filter { $0.group == first }.map(\.key))
        alerts.phoneSettled = phoneSettled[first] ?? []
        for (tag, o) in others {
            o.alerts.phoneHas = Set(has.filter { $0.group == tag }.map(\.key))
            o.alerts.phoneSettled = phoneSettled[tag] ?? []
        }
    }

    /// A group's tag as this watch names it: a phone from before several groups names none,
    /// meaning the first.
    private func tag(_ raw: String) -> String { raw.isEmpty ? (engine?.group?.tag ?? "") : raw }

    /// The owner left the group on their phone: the watch stops acting for them at once.
    fileprivate func forget() {
        alerts.cancelAll()
        for (tag, o) in others { o.alerts.cancelAll(); o.engine.leave(); Store.forget(group: tag) }
        others = [:]
        Store.otherGroups = []
        // Leaving stops its relay polling for the group too.
        engine?.leave()
        engine = nil
        givenToPhone = []
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
            return Open(unit: u, request: r, colour: c, who: w, group: tag(d["group"] as? String ?? ""))
        }
        var settled: [String: Set<IncomingRequest.Key>] = [:]
        for d in context["settled"] as? [[String: Any]] ?? [] {
            guard let u = (d["unit"] as? Int).flatMap(UInt32.init(exactly:)), let r = (d["request"] as? Int).flatMap(UInt16.init(exactly:)) else { continue }
            let group = tag(d["group"] as? String ?? ""), key = IncomingRequest.Key(unit: u, request: r)
            let e = engine(forGroup: group)
            // The signed acknowledgements the phone holds, checked here as if heard on air, so
            // this watch's own copy of the group settles as the phone's did.
            for ack in d["acks"] as? [Data] ?? [] where acksTaken.insert(ack).inserted {
                if let f = HelpFrame(ack) { e?.receive(f, via: .internet) }
            }
            // Settled by a signature checked here, the engine takes it back itself if the person who
            // acknowledged is removed. Only what it could not check (a close, or a member it does
            // not know yet) is held settled on the phone's word: a word that goes stale once the
            // phone is out of reach, so it must not silence a call the engine knows is open again.
            if e?.activity.inbox.requests[key]?.isOpen != false { settled[group, default: []].insert(key) }
        }
        phoneSettled = settled
        settleAlerts()
        reconcileWithPhone()
    }

    fileprivate func setReach(_ reachable: Bool) {
        phoneInReach = reachable
        // The watch stays quiet only for calls its phone, in reach, has itself heard and is
        // alerting for; any other call it alerts for at once.
        settleAlerts()
        reconcileWithPhone()
    }

    /// Back in reach, the phone is given what this watch did while they were apart: every call it
    /// is still sending (made out of reach, or one the phone did not take), so the phone sends it
    /// on its own routes too, under the watch's number; and the acknowledgements made here for
    /// calls the phone still lists as open, so it stops alerting its owner for what they have
    /// already answered and sends its acknowledgement where the watch cannot.
    private func reconcileWithPhone() {
        guard phoneInReach, WCSession.default.activationState == .activated else { return }
        for r in engine?.activity.outgoing ?? [] where r.number >= 0x8000 && r.unit != 0 && r.nextResend != nil && !givenToPhone.contains(r.number) {
            give(r.callFrame)
        }
        for o in phoneOpen where !ackedThroughPhone.contains(o.id) {
            guard let e = engine(forGroup: o.group), let me = e.saved?.me, e.activity.inbox.requests[o.key]?.acknowledgedBy.contains(me) == true else { continue }
            tellPhone(acknowledged: o, mine: true)
        }
    }

    /// Gives the phone a call this watch made and is sending itself, to send on the phone's routes
    /// too: one call, however many ways it goes, so a lost reply can never send it twice.
    private func give(_ call: HelpFrame) {
        guard case let .call(_, number, _, _) = call else { return }
        givenToPhone.insert(number)
        // With a reply handler, so the phone's reply-taking delegate gets it.
        WCSession.default.sendMessage(["call": call.encoded()], replyHandler: { _ in },
                                      errorHandler: { _ in Task { @MainActor in self.givenToPhone.remove(number) } })
    }

    /// Acknowledges through the phone: the same as pressing it there. `mine` is whether this watch
    /// acknowledged itself, so a phone that could not is a problem only when it did not.
    private func tellPhone(acknowledged r: Open, mine: Bool) {
        ackedThroughPhone.insert(r.id)
        WCSession.default.sendMessage(["ackUnit": Int(r.unit), "ackRequest": Int(r.request), "group": r.group], replyHandler: { reply in
            let ok = reply["ok"] as? Bool == true
            Task { @MainActor in
                if ok { self.phoneOpen.removeAll { $0 == r }; self.phoneAcked.insert(r.id) } else if !mine { self.problem = "Not acknowledged. Use your phone." }
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                self.ackedThroughPhone.remove(r.id)
                if !mine { self.problem = "Not acknowledged: your phone did not answer. Use your phone." }
            }
        })
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

    /// The owner's settings, from their phone.
    var profile: Profile { engine?.profile ?? .standard }

    /// When this watch's keys stop reaching the group, after a removal whose new code the phone
    /// has not scanned; and whether they already have.
    var keysEndAt: Date? { Self.screensKeysNeeded ? Date().addingTimeInterval(5 * 86_400) : engine?.keysEndAt }
    var keysExpired: Bool { Self.screensKeysNeeded ? false : engine?.keysExpired == true }

    func words(_ colour: Colour) -> String { ButtonWords.words(colour, in: profile) }

    /// Another's call, in the words they see on their own buttons.
    func words(_ call: Open) -> String {
        ButtonWords.words(call.colour, in: engine(forGroup: call.group)?.group?.profile(ofUnit: call.unit))
    }

    /// Not set up and no phone to send through: the buttons could not reach anyone.
    var cannotCall: Bool { engine?.me == nil && !phoneInReach }

    /// Nothing to show at all: no group on this watch, even one that could still alert, and no phone.
    var needsSetUp: Bool { allEngines.allSatisfy { $0.me == nil } && !phoneInReach }

    /// What is said after Need a hand, while that call has not failed.
    var amberNote: String? {
        pressed == .amber && status?.cross == false ? ButtonWords.amberNote(in: profile) : nil
    }

    var status: (text: String, cross: Bool)? {
        if let problem { return (problem, true) }
        if let warning { return (warning, false) }
        if let ack = lastAck, let s = engine(forGroup: ack.group)?.ackSendStatus(ack.key) {
            switch s {
            case .notSent where phoneAcked.contains(Open.id(ack.group, ack.key)): return ("Acknowledged through your phone.", false)
            case .notSent where keysExpired: return ("Not acknowledged: the new code must be scanned on your phone first.", true)
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

    /// Every open call from the phone and from the watch's own groups, most urgent first. None is cut
    /// off: a call whose alert sounds here must stay reachable however many others there are.
    var open: [Open] {
        let all = allEngines.flatMap { e in e.activity.inbox.requests.values.filter(\.isOpen).map { (e, $0) } }
        let own = all.sorted { ResponderInbox.moreUrgent($0.1, $1.1) }.map { e, r in
            Open(unit: r.key.unit, request: r.key.request, colour: r.colour ?? .red, who: e.name(ofUnit: r.key.unit), group: e.group?.tag ?? "")
        }.filter { phoneSettled[$0.group]?.contains($0.key) != true }
        guard phoneInReach else { return own }
        // Calls only the watch has heard are shown too, as their alerts ring here.
        let watchOnly = own.filter { o in !phoneOpen.contains { $0.key == o.key && $0.group == o.group } }
        // Red before amber before green; calls of one colour keep the order they came in.
        return (phoneOpen + watchOnly).enumerated()
            .sorted { ($0.element.colour.rawValue, $0.offset) < ($1.element.colour.rawValue, $1.offset) }
            .map(\.element)
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
        // A press during the countdown stops it; I'm OK then sends nothing, the others go now.
        if countdown != nil {
            stopCountdown()
            if colour == .green {
                CallerVoice.shared.pressed()
                // Said as well as shown: with poor sight, or VoiceOver, the button changing back is not enough to know it stopped.
                let why = "Stopped. Nothing has been sent."
                warning = why
                CallerVoice.shared.tell(.init(sound: nil, spoken: why), profile: profile)
                return
            }
        }
        CallerVoice.shared.pressed()
        pressed = colour
        okNote = colour == .green && !(engine?.settledByOK.isEmpty ?? true) ? profile.okSpoken : nil
        problem = nil
        warning = nil
        lastAck = nil
        if let engine, engine.me?.canCall == true {
            sentByWatch = true
            engine.press(colour)
            // The watch sends the call itself either way; the phone, in reach, sends it on its routes too.
            if phoneInReach, let call = engine.current?.callFrame { give(call) }
            return
        }
        sentByWatch = false
        // A coordinator or responder who does not call in this group: the phone would say the same.
        if engine?.me != nil {
            failed("Not sent: you are not a caller in this group. Use your phone, or call 999.")
            return
        }
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

    // MARK: The complication's countdown

    /// From the Help complication: Help goes in 60 seconds unless the wearer presses I'm OK. It
    /// keeps running with the wrist lowered, in an extended runtime session.
    func startCountdown() {
        guard countdown == nil, !cannotCall else { return }
        // Someone who does not call in this group is told so now, not after a minute of counting.
        if let me = engine?.me, !me.canCall { press(.red); return }
        let now = Date()
        countdown = HelpCountdown(startedAt: now)
        countdownCheckedAt = now
        secondsLeft = Int(HelpCountdown.length)
        CallerVoice.shared.pressed()
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtime = session
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCountdown() }
        }
    }

    private func checkCountdown() {
        guard let c = countdown else { return }
        let now = Date()
        secondsLeft = c.remaining(at: now)
        for event in c.events(from: countdownCheckedAt, to: now) {
            switch event {
            case .vibrate: WKInterfaceDevice.current().play(.notification)
            case .warn: CallerVoice.shared.tell(.init(sound: nil, spoken: HelpCountdown.warning(in: profile)), profile: profile)
            case .send: press(.red)
            }
        }
        countdownCheckedAt = now
    }

    private func stopCountdown() {
        warning = nil
        countdown = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        runtime?.invalidate()
        runtime = nil
    }

    /// A call that could not even be handed on: shown, and heard as not sent.
    private func failed(_ why: String) {
        problem = why
        CallerVoice.shared.tell(.init(sound: .notSent, spoken: why), profile: profile)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The screenshot test's made-up phone in reach, with one call to acknowledge. Locked three
    /// ways: a debug build, on a simulator, and only with the test's own launch argument. A real
    /// watch can never show it.
    private static var isScreensTest: Bool { ProcessInfo.processInfo.arguments.contains("-HelpAScreensTest") }
    /// The screens of a watch whose keys stop in five days, by the test's launch argument.
    private static let screensKeysNeeded = isScreensTest && ProcessInfo.processInfo.arguments.contains("-HelpAKeysNeeded")
    #else
    private static let screensKeysNeeded = false
    #endif

    /// Acknowledges from the watch itself (signed as its owner) and through the phone when it is in
    /// reach. Two copies of one person's acknowledgement are one acknowledgement.
    func acknowledge(_ r: Open) {
        problem = nil
        warning = nil
        let mine = engine(forGroup: r.group)?.acknowledge(r.key) == true
        lastAck = mine ? (r.group, r.key) : nil
        guard phoneInReach else {
            if !mine { problem = "Not acknowledged: use your phone." }
            return
        }
        tellPhone(acknowledged: r, mine: mine)
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
/// being true, as one alert now rather than a burst of the ones missed; one the phone settled is
/// cancelled instead, never let go.
@MainActor final class WatchAlerts: AlertScheduler {
    private let inner: NotificationAlerts
    init(prefix: String = "") { inner = NotificationAlerts(prefix: prefix, ownsCheckIns: false) }
    private var held: [IncomingRequest.Key: Alert] = [:]
    private var sounding: Set<IncomingRequest.Key> = []
    var phoneHas: Set<IncomingRequest.Key> = [] { didSet { if phoneHas != oldValue { settle() } } }
    /// Calls a person settled on the phone: never sounded here, whatever this watch has heard.
    var phoneSettled: Set<IncomingRequest.Key> = [] { didSet { for k in phoneSettled.subtracting(oldValue) { cancel(k) } } }

    func schedule(_ alert: Alert) {
        guard !phoneSettled.contains(alert.key) else { return }
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

/// Without its session the countdown stops whenever the screen goes off, so the wearer is told
/// at once rather than left thinking it will call for them.
extension WatchModel: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSession(_ session: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        Task { @MainActor in
            guard self.countdown != nil, session === self.runtime else { return }
            // Nothing has failed: the countdown is still running while the screen is on.
            let why = "The countdown may stop if the screen goes dark. Keep your wrist raised, or press \(self.words(.red)) now."
            self.warning = why
            CallerVoice.shared.tell(.init(sound: nil, spoken: why), profile: self.profile)
        }
    }
}
