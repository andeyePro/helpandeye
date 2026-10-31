import Combine
import Foundation
import helpandeyeCore
import UserNotifications

/// Wires the engine (helpandeyeCore) to the real box, relay, notifications and storage, and gives
/// the screens what they need. The rules themselves are in the engine, where they are tested.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let board = BoardLink()
    /// One box for every group this person is in.
    let hub: MeshHub
    let relay = Relay()
    /// The home Wi-Fi route for the first group (decision 19).
    let home = HomeWiFi()
    /// The group this person is in first: the one they may call for help in, and coordinate.
    let engine: HelpEngine
    /// Other groups they respond in (responders only), each with its own engine and relay.
    @Published private(set) var others: [Other] = []
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var voiceTracker = CallerFeedback.Tracker(nil)
    /// What the caller is told after an I'm OK that settled an open call (their profile's words).
    @Published private(set) var okNote: String?

    struct Other: Identifiable {
        let tag: String
        let engine: HelpEngine
        let relay: Relay
        let home: HomeWiFi
        var id: String { tag }
    }

    /// Every engine, the first group's first.
    var engines: [HelpEngine] { [engine] + others.map(\.engine) }

    /// The screen tests' phone that was removed from its first group but responds in another, which
    /// takes a second phone to arrange for real. Debug simulator builds only, and only with the
    /// test's own launch argument; nothing is saved as the first group or listed as another.
    #if DEBUG && targetEnvironment(simulator)
    private static let screensOtherGroupOnly = ProcessInfo.processInfo.arguments.contains("-HelpAOtherGroupOnly")
    #else
    private static let screensOtherGroupOnly = false
    #endif

    /// Shows the screens of a phone told of a removal it has no new keys for, by a screen test's
    /// launch argument; nothing is saved.
    #if DEBUG && targetEnvironment(simulator)
    private static let screensKeysNeeded = ProcessInfo.processInfo.arguments.contains("-HelpAKeysNeeded")
    /// A further group beside the first, for the screen test of leaving the first; not remembered.
    private static let screensOtherGroup = ProcessInfo.processInfo.arguments.contains("-HelpAOtherGroup")
    #else
    private static let screensKeysNeeded = false
    private static let screensOtherGroup = false
    #endif

    private init() {
        let airtime = AirtimeLedger(budget: Store.loadAirtime() ?? Store.loadActivity().airtime)
        airtime.onChange = { Store.save(airtime: $0) }
        hub = MeshHub(box: board, airtime: airtime)
        let link = hub.link(for: Self.firstGroup)
        engine = HelpEngine(identity: Store.identity(), mesh: link, relay: relay, alerts: NotificationAlerts(), store: AppStore(),
                            saved: Self.screensOtherGroupOnly ? nil : Store.loadState(), activity: Store.loadActivity(), homeWiFi: home)
        link.onFrame = { [weak self] in self?.engine.receive($0, via: .mesh) }
        link.onText = { [weak self] in self?.engine.receiveText(from: $0, $1) }
        board.onFrame = { [weak self] in self?.hub.received($0, on: $1) }
        board.onText = { [weak self] in self?.hub.receivedText(from: $0, $1) }
        board.onBoxFrame = { [weak self] frame in await self?.engine.receiveFromBox(frame) ?? nil }
        board.isGroupBox = { [weak self] in self?.boxMember != nil }
        relay.onFrame = { [weak self] in self?.engine.receive($0, via: .internet) }
        relay.onAllowanceLow = { [weak self] in self?.engine.raise(.allowanceLow) }
        home.onFrame = { [weak self] in self?.engine.receive($0, via: .wifi) }
        home.keeps = { [weak self] in self?.engine.takes($0) ?? false }
        board.$state.removeDuplicates().sink { [weak self] state in
            if state == .ready { Task { @MainActor in for e in self?.engines ?? [] { await e.boxReady() } } }
        }.store(in: &bag)
        board.$selfInfo.map { $0?.radio.band }.sink { [weak self] band in self?.engines.forEach { $0.bandChanged(band) } }.store(in: &bag)
        board.$selfInfo.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateBoxSetup() }.store(in: &bag)
        for publisher in [engine.objectWillChange.eraseToAnyPublisher(), board.objectWillChange.eraseToAnyPublisher(),
                          relay.objectWillChange.eraseToAnyPublisher(), home.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        carryOverOldChoices()
        voiceTracker = .init(engine.current)
        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.tellCaller(); self?.updateBoxSetup() }.store(in: &bag)
        for tag in Store.otherGroups { start(tag) }
        #if DEBUG && targetEnvironment(simulator)
        if Self.screensOtherGroupOnly || Self.screensOtherGroup {
            start("screens")
            others.last?.engine.createGroup(name: "Hill Road", myName: "Sam", call: false)
        }
        #endif
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateBoxSetup()
                // Bluetooth may be slow to answer: never ahead of the engines' resends.
                Task { await self.board.tick() }
                for (e, r) in zip(self.engines, [self.relay] + self.others.map(\.relay)) {
                    e.tick()
                    r.busy = e.activity.outgoing.contains { $0.nextResend != nil && $0.unit != 0 }
                        || e.activity.inbox.requests.values.contains { $0.isOpen && $0.colour != .green }
                }
            }
        }
        AppStore.saved = { [weak self] what, ok in
            guard let self else { return }
            if ok { self.failedSaves.remove(what) } else { self.failedSaves.insert(what) }
            if self.saveFailed == self.failedSaves.isEmpty { self.saveFailed = !self.failedSaves.isEmpty }
        }
        UNUserNotificationCenter.current().delegate = ShowAlertsWhileOpen.shared
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await checkNotifications()
        }
    }

    /// The latest save of the group or its calls did not work, so they could be lost if Help&I closes.
    @Published private(set) var saveFailed = false
    private var failedSaves: Set<String> = []

    /// Why this phone's notifications cannot alert its person as they should, if they cannot.
    @Published private(set) var notificationProblem: String?

    func checkNotifications() async {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-HelpANotificationsOff") { notificationProblem = Self.notificationsOff; return }
        #endif
        let s = await UNUserNotificationCenter.current().notificationSettings()
        let responds = engines.contains { $0.me?.canRespond == true }
        notificationProblem = s.authorizationStatus == .denied ? Self.notificationsOff
            : responds && s.timeSensitiveSetting == .disabled ? "Time Sensitive is off for Help&I, so a Focus can hold back calls for help. Turn it on in Settings, Notifications, Help&I."
            : nil
    }

    private static let notificationsOff = "Notifications are off for Help&I, so it cannot alert you when someone calls for help or sees your call. Turn them on in Settings, Notifications, Help&I."

    /// Says out loud what happened to this phone's own calls. The watch says it for the calls it
    /// made itself (numbered 32768 and up), so they are not heard twice.
    private func tellCaller() {
        if let r = engine.current, r.number >= 0x8000 { return }
        let words = engine.current.map { ButtonWords.words($0.colour, in: profile) } ?? ""
        let note = engine.current?.colour == .amber ? ButtonWords.amberNote(in: profile) : (engine.current?.colour == .green ? okNote : nil)
        if let f = voiceTracker.update(engine.current, words: words, note: note, name: name(ofMember:)) { CallerVoice.shared.tell(f, profile: profile) }
    }

    /// What a Help&I box paired with this phone is given: the first group's set-up, once the box
    /// is a member of it. A changeover's end changes it with no other change, so the ticker asks too.
    private func updateBoxSetup() {
        board.setup = engine.group.flatMap { g in board.selfInfo.flatMap { HelpBox.setup(for: g, box: $0.publicKey, at: Date()) } }
    }

    /// The Help&I box on this phone's Bluetooth, as a member of the first group: what it is called
    /// there. Nil for a stock box, or one not added yet.
    var boxMember: Member? { group?.boxMember(key: board.selfInfo?.publicKey) }

    /// A coordinator adds the Help&I box on this phone's Bluetooth to the group, with the keys it
    /// gave in its info reply, in the home of the member the coordinator chose, if any.
    func addBox(name: String, home: UInt16?) -> String? {
        guard let key = board.selfInfo?.publicKey, let info = board.boxInfo else { return "The box has not answered yet. Try again in a minute." }
        return engine.addBox(key: key, sealKey: info.sealKey, name: name, home: home)
    }

    func tellRespondersOfProbablePowerCut() -> String? { engine.tellRespondersOfProbablePowerCut() }

    /// Before profiles, a caller's sounds and sharing where they are were switches kept on this
    /// phone. They become the caller's own choices once, so an update changes neither.
    private func carryOverOldChoices() {
        let d = UserDefaults.standard
        let sounds = d.object(forKey: "callerSounds") as? Bool, share = d.object(forKey: "shareEveryCall") as? Bool
        guard sounds != nil || share != nil else { return }
        engine.setOwn { p in
            if let sounds { p.soundsAndSpeech = sounds }
            if let share { p.shareWhere = share }
        }
        d.removeObject(forKey: "callerSounds")
        d.removeObject(forKey: "shareEveryCall")
    }

    var identity: DeviceIdentity { engine.identity }
    var saved: SavedState? { engine.saved }
    var group: GroupState? { engine.group }
    var me: Member? { engine.me }
    var profile: Profile { engine.profile }
    var inbox: ResponderInbox { engine.activity.inbox }
    var rota: Rota { engine.activity.rota }
    var current: OutgoingRequest? { engine.current }
    var gaps: [DateInterval] { engine.gaps }
    var checkIn: CheckInSchedule? { engine.checkIn }
    var canSendPersonal: Bool { engine.canSendPersonal }
    var keyProblem: String? { Self.screensKeysNeeded ? HelpEngine.keysNeeded : engine.keyProblem }
    var keysEndAt: Date? { Self.screensKeysNeeded ? Date().addingTimeInterval(5 * 86_400) : engine.keysEndAt }

    func name(ofUnit unit: UInt32) -> String { engine.name(ofUnit: unit) }
    func name(ofMember n: UInt16) -> String { engine.name(ofMember: n) }

    /// A new group uses Help&I's relay, except in the screen tests, which must not reach it.
    func createGroup(name: String, myName: String, call: Bool, phone: String?) {
        engine.createGroup(name: name, myName: myName, call: call, phone: phone, relay: CallerVoice.quiet ? nil : RelayProtocol.defaultRelay)
    }
    func setMyPhone(_ phone: String) { engine.setMyPhone(phone) }
    func joined(_ group: GroupState, as number: UInt16, invitedBy: UInt16?) {
        // A group already joined as a further one is never joined twice.
        guard !others.contains(where: { $0.engine.group?.secrets.groupID == group.secrets.groupID }) else { return }
        engine.joined(group, as: number, invitedBy: invitedBy)
    }
    func updateGroup(_ change: (inout GroupState) -> Void) { engine.updateGroup(change) }

    #if DEBUG && targetEnvironment(simulator)
    /// Asks for settings too big to send, as the engine's own test does, so the screen tests meet
    /// the real refusal. Nothing is kept: the engine refuses them.
    func tryOversizedSettings() {
        updateGroup { g in
            for i in 1...40 {
                var p = Profile(id: UInt8(i), name: UUID().uuidString)
                p.okWords = (0..<6).map { _ in UUID().uuidString }.joined()
                g.policy.profiles.append(p)
            }
        }
    }
    #endif
    func leave() {
        engine.leave()
        forgetSaves("")
    }

    /// A group left can no longer fail to save, so its warning goes.
    private func forgetSaves(_ tag: String) {
        failedSaves.subtract(["state" + tag, "activity" + tag])
        if saveFailed == failedSaves.isEmpty { saveFailed = !failedSaves.isEmpty }
    }
    func setRelay(_ url: String) { engine.setRelay(url) }
    func setRelayPass(_ token: String) -> Bool { engine.setRelayPass(token) }
    func setOwn(_ change: (inout Profile) -> Void) { engine.setOwn(change) }

    func press(_ colour: Colour) {
        okNote = colour == .green && !engine.settledByOK.isEmpty ? profile.okSpoken : nil
        engine.press(colour)
    }
    func closeMyCall() { engine.closeMyCall() }
    func add(_ category: CallCategory) -> String? { engine.add(category) }
    func withdraw(_ category: CallCategory) -> String? { engine.withdraw(category) }
    func addNote(_ text: String) -> String? { engine.addNote(text) }
    func sharePosition(latitude: Double, longitude: Double, accuracy: Double, call: UInt16?, sent: ((Bool) -> Void)? = nil) {
        engine.sharePosition(latitude: latitude, longitude: longitude, accuracy: accuracy, call: call, sent: sent)
    }

    @discardableResult func acknowledge(_ key: IncomingRequest.Key) -> Bool { engine.acknowledge(key) }
    func retryAck(_ key: IncomingRequest.Key) { engine.retryAck(key) }
    func ackSendStatus(_ key: IncomingRequest.Key) -> CallerStatus? { engine.ackSendStatus(key) }

    /// Away is away in every group this person responds in.
    func setAvailable(_ available: Bool) { for e in engines where e.me?.canRespond == true { e.setAvailable(available) } }
    func showing(_ notice: Notice) -> Bool { engine.showing(notice) }
    func acknowledge(_ notice: Notice) { engine.acknowledge(notice) }
    func setCheckIn(_ schedule: CheckInSchedule?) { engine.setCheckIn(schedule) }

    func tick() { engines.forEach { $0.tick() } }

    // MARK: Other groups this person responds in

    /// The first group's place on the box, whichever group it is.
    private static let firstGroup = Data("first".utf8)

    /// Starts the engine for another group, from what was saved under its tag.
    private func start(_ tag: String) {
        let relay = Relay()
        let home = HomeWiFi()
        let link = hub.link(for: Data(tag.utf8))
        let e = HelpEngine(identity: engine.identity, mesh: link, relay: relay, alerts: NotificationAlerts(prefix: tag + "-", ownsCheckIns: false),
                           store: AppStore(group: tag), saved: Store.loadState(tag), activity: Store.loadActivity(tag), homeWiFi: home)
        home.onFrame = { [weak e] in e?.receive($0, via: .wifi) }
        home.keeps = { [weak e] in e?.takes($0) ?? false }
        link.onFrame = { [weak e] in e?.receive($0, via: .mesh) }
        link.onText = { [weak e] in e?.receiveText(from: $0, $1) }
        relay.onFrame = { [weak e] in e?.receive($0, via: .internet) }
        relay.onAllowanceLow = { [weak e] in e?.raise(.allowanceLow) }
        relay.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        relay.pushToken = self.relay.pushToken
        e.bandChanged(board.selfInfo?.radio.band)
        e.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        others.append(Other(tag: tag, engine: e, relay: relay, home: home))
        if board.state == .ready { Task { await e.boxReady() } }
    }

    /// Someone already in a group joins another, as a responder only: they call for help in one
    /// group, so the help buttons always mean the same people.
    func joinedAnother(_ group: GroupState, as number: UInt16, invitedBy: UInt16?) -> Bool {
        guard group.member(number)?.role == .responder,
              !engines.contains(where: { $0.group?.secrets.groupID == group.secrets.groupID }) else { return false }
        let tag = group.tag
        start(tag)
        others.last?.engine.joined(group, as: number, invitedBy: invitedBy)
        // Remembered only once joined, so an interrupted join never comes back as an empty group.
        Store.otherGroups.append(tag)
        return true
    }

    func leave(_ other: Other) {
        other.engine.leave()
        hub.remove(Data(other.tag.utf8))
        Store.forget(group: other.tag)
        forgetSaves(other.tag)
        Store.otherGroups.removeAll { $0 == other.tag }
        others.removeAll { $0.tag == other.tag }
    }

    /// Leaves the first group and makes another this person responds in their first: its Help
    /// button (if they may call there), check-ins and profile become theirs, on the first engine,
    /// and the rest stay groups they respond in.
    func leave(becoming other: Other) {
        guard let saved = other.engine.saved else { return }
        let activity = other.engine.activity
        leave()
        leave(other)
        engine.adopt(saved, activity: activity)
    }

    /// Where Apple can push to wake this phone, for every group's relay.
    func setPushToken(_ token: Data) {
        relay.pushToken = token
        others.forEach { $0.relay.pushToken = token }
    }

    /// Back in the foreground: listen on the home Wi-Fi again, which iOS stops in the background.
    func resume() {
        home.resume()
        others.forEach { $0.home.resume() }
        NotificationAlerts.replan()
        Task { await checkNotifications() }
    }

    /// A push from a relay: fetch what is waiting in every group.
    func wake() async {
        await relay.poll()
        for o in others { await o.relay.poll() }
        tick()
        NotificationAlerts.replan()
    }
}
