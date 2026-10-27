import Combine
import Foundation
import HelpAndICore
import UserNotifications

/// Wires the engine (HelpAndICore) to the real box, relay, notifications and storage, and gives
/// the screens what they need. The rules themselves are in the engine, where they are tested.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let board = BoardLink()
    let relay = Relay()
    let engine: HelpEngine
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?

    private init() {
        engine = HelpEngine(identity: Store.identity(), mesh: board, relay: relay, alerts: NotificationAlerts(), store: AppStore(),
                            saved: Store.loadState(), activity: Store.loadActivity())
        board.onFrame = { [weak self] in self?.engine.receive($0, via: .mesh) }
        board.onText = { [weak self] in self?.engine.receiveText(from: $0, $1) }
        relay.onFrame = { [weak self] in self?.engine.receive($0, via: .internet) }
        relay.onAllowanceLow = { [weak self] in self?.engine.raise(.allowanceLow) }
        board.$state.removeDuplicates().sink { [weak self] state in
            if state == .ready { Task { @MainActor in await self?.engine.boxReady() } }
        }.store(in: &bag)
        board.$selfInfo.map { $0?.radio.band }.sink { [weak self] in self?.engine.bandChanged($0) }.store(in: &bag)
        for publisher in [engine.objectWillChange.eraseToAnyPublisher(), board.objectWillChange.eraseToAnyPublisher(),
                          relay.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.engine.tick() }
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

    func createGroup(name: String, myName: String, call: Bool) { engine.createGroup(name: name, myName: myName, call: call) }
    func joined(_ group: GroupState, as number: UInt16) { engine.joined(group, as: number) }
    func updateGroup(_ change: (inout GroupState) -> Void) { engine.updateGroup(change) }
    func leave() { engine.leave() }
    func setRelay(_ url: String) { engine.setRelay(url) }

    func press(_ colour: Colour) { engine.press(colour) }
    func add(_ category: CallCategory) { engine.add(category) }
    func addNote(_ text: String) -> String? { engine.addNote(text) }
    func sharePosition(latitude: Double, longitude: Double, accuracy: Double) {
        engine.sharePosition(latitude: latitude, longitude: longitude, accuracy: accuracy)
    }

    func acknowledge(_ key: IncomingRequest.Key) { engine.acknowledge(key) }
    func retryAck(_ key: IncomingRequest.Key) { engine.retryAck(key) }
    func ackSendStatus(_ key: IncomingRequest.Key) -> CallerStatus? { engine.ackSendStatus(key) }

    func setAvailable(_ available: Bool) { engine.setAvailable(available) }
    func showing(_ notice: Notice) -> Bool { engine.showing(notice) }
    func acknowledge(_ notice: Notice) { engine.acknowledge(notice) }
    func setCheckIn(_ schedule: CheckInSchedule?) { engine.setCheckIn(schedule) }

    func tick() { engine.tick() }
}
