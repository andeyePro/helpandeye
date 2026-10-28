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
    /// The group this person is in first: the one they may call for help in, and coordinate.
    let engine: HelpEngine
    /// Other groups they respond in (responders only), each with its own engine and relay.
    @Published private(set) var others: [Other] = []
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?

    struct Other: Identifiable {
        let tag: String
        let engine: HelpEngine
        let relay: Relay
        var id: String { tag }
    }

    /// Every engine, the first group's first.
    var engines: [HelpEngine] { [engine] + others.map(\.engine) }

    private init() {
        let airtime = AirtimeLedger(budget: Store.loadAirtime() ?? Store.loadActivity().airtime)
        airtime.onChange = { Store.save(airtime: $0) }
        hub = MeshHub(box: board, airtime: airtime)
        let link = hub.link(for: Self.firstGroup)
        engine = HelpEngine(identity: Store.identity(), mesh: link, relay: relay, alerts: NotificationAlerts(), store: AppStore(),
                            saved: Store.loadState(), activity: Store.loadActivity())
        link.onFrame = { [weak self] in self?.engine.receive($0, via: .mesh) }
        link.onText = { [weak self] in self?.engine.receiveText(from: $0, $1) }
        board.onFrame = { [weak self] in self?.hub.received($0, on: $1) }
        board.onText = { [weak self] in self?.hub.receivedText(from: $0, $1) }
        relay.onFrame = { [weak self] in self?.engine.receive($0, via: .internet) }
        relay.onAllowanceLow = { [weak self] in self?.engine.raise(.allowanceLow) }
        board.$state.removeDuplicates().sink { [weak self] state in
            if state == .ready { Task { @MainActor in for e in self?.engines ?? [] { await e.boxReady() } } }
        }.store(in: &bag)
        board.$selfInfo.map { $0?.radio.band }.sink { [weak self] band in self?.engines.forEach { $0.bandChanged(band) } }.store(in: &bag)
        for publisher in [engine.objectWillChange.eraseToAnyPublisher(), board.objectWillChange.eraseToAnyPublisher(),
                          relay.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        for tag in Store.otherGroups { start(tag) }
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (e, r) in zip(self.engines, [self.relay] + self.others.map(\.relay)) {
                    e.tick()
                    r.busy = e.activity.outgoing.contains { $0.nextResend != nil && $0.unit != 0 }
                        || e.activity.inbox.requests.values.contains { !$0.isAcknowledged && $0.colour != .green }
                }
            }
        }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    var identity: DeviceIdentity { engine.identity }
    var saved: SavedState? { engine.saved }
    var group: GroupState? { engine.group }
    var me: Member? { engine.me }
    var inbox: ResponderInbox { engine.activity.inbox }
    var rota: Rota { engine.activity.rota }
    var current: OutgoingRequest? { engine.current }
    var gaps: [DateInterval] { engine.gaps }
    var checkIn: CheckInSchedule? { engine.checkIn }
    var canSendPersonal: Bool { engine.canSendPersonal }

    func name(ofUnit unit: UInt32) -> String { engine.name(ofUnit: unit) }
    func name(ofMember n: UInt16) -> String { engine.name(ofMember: n) }

    func createGroup(name: String, myName: String, call: Bool, phone: String?) { engine.createGroup(name: name, myName: myName, call: call, phone: phone) }
    func setMyPhone(_ phone: String) { engine.setMyPhone(phone) }
    func joined(_ group: GroupState, as number: UInt16, invitedBy: UInt16?) {
        // A group already joined as a further one is never joined twice.
        guard !others.contains(where: { $0.engine.group?.secrets.groupID == group.secrets.groupID }) else { return }
        engine.joined(group, as: number, invitedBy: invitedBy)
    }
    func updateGroup(_ change: (inout GroupState) -> Void) { engine.updateGroup(change) }
    func leave() { engine.leave() }
    func setRelay(_ url: String) { engine.setRelay(url) }

    func press(_ colour: Colour) { engine.press(colour) }
    func add(_ category: CallCategory) { engine.add(category) }
    func withdraw(_ category: CallCategory) { engine.withdraw(category) }
    func addNote(_ text: String) -> String? { engine.addNote(text) }
    func sharePosition(latitude: Double, longitude: Double, accuracy: Double) {
        engine.sharePosition(latitude: latitude, longitude: longitude, accuracy: accuracy)
    }

    @discardableResult func acknowledge(_ key: IncomingRequest.Key) -> Bool { engine.acknowledge(key) }
    func retryAck(_ key: IncomingRequest.Key) { engine.retryAck(key) }
    func ackSendStatus(_ key: IncomingRequest.Key) -> CallerStatus? { engine.ackSendStatus(key) }

    func setAvailable(_ available: Bool) { engine.setAvailable(available) }
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
        let link = hub.link(for: Data(tag.utf8))
        let e = HelpEngine(identity: engine.identity, mesh: link, relay: relay, alerts: NotificationAlerts(prefix: tag + "-", ownsCheckIns: false),
                           store: AppStore(group: tag), saved: Store.loadState(tag), activity: Store.loadActivity(tag))
        link.onFrame = { [weak e] in e?.receive($0, via: .mesh) }
        link.onText = { [weak e] in e?.receiveText(from: $0, $1) }
        relay.onFrame = { [weak e] in e?.receive($0, via: .internet) }
        relay.onAllowanceLow = { [weak e] in e?.raise(.allowanceLow) }
        relay.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        relay.pushToken = self.relay.pushToken
        e.bandChanged(board.selfInfo?.radio.band)
        e.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        others.append(Other(tag: tag, engine: e, relay: relay))
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
        Store.otherGroups.removeAll { $0 == other.tag }
        others.removeAll { $0.tag == other.tag }
    }

    /// Where Apple can push to wake this phone, for every group's relay.
    func setPushToken(_ token: Data) {
        relay.pushToken = token
        others.forEach { $0.relay.pushToken = token }
    }

    /// A push from a relay: fetch what is waiting in every group.
    func wake() async {
        await relay.poll()
        for o in others { await o.relay.poll() }
        tick()
    }
}
