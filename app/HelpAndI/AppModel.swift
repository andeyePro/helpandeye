import Combine
import Foundation
import HelpAndICore
import UserNotifications

/// The app's state: the group, this phone's calls for help, and the requests it is answering.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var saved: SavedState?
    @Published private(set) var outgoing: [OutgoingRequest] = []
    @Published private(set) var inbox = ResponderInbox()
    @Published var rota = Rota()
    @Published private(set) var lastAnswered: [UInt16: Date] = [:]

    let identity = Store.identity()
    let board = BoardLink()
    let relay = Relay()
    private var budget: AirtimeBudget?
    private var bag: Set<AnyCancellable> = []

    init() {
        saved = Store.loadState()
        rota = saved?.group.defaultRota ?? Rota()
        board.onFrame = { [weak self] in self?.received($0, via: .mesh) }
        relay.onFrame = { [weak self] in self?.received($0, via: .internet) }
        board.$selfInfo.sink { [weak self] info in
            self?.budget = info?.radio.band.map { AirtimeBudget(dutyCycle: $0.dutyCycle) }
        }.store(in: &bag)
        board.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        relay.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        applyGroup()
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    var group: GroupState? { saved?.group }
    var me: Member? { saved.flatMap { $0.group.member($0.me) } }

    func name(ofUnit unit: UInt32) -> String { group?.member(unit: unit)?.name ?? "Unit \(unit)" }
    func name(ofMember n: UInt16) -> String { n == saved?.me ? "You" : (group?.member(n)?.name ?? "Responder \(n)") }

    // MARK: Group

    func createGroup(name: String, myName: String, call: Bool) {
        var g = GroupState(name: name, secrets: .random(), members: [])
        g.members.append(Member(number: 1, name: myName, role: .coordinator, publicKey: identity.publicKey, unit: call ? g.nextUnit : nil))
        setState(SavedState(group: g, me: 1))
    }

    func joined(_ group: GroupState, as number: UInt16) { setState(SavedState(group: group, me: number)) }

    func updateGroup(_ change: (inout GroupState) -> Void) {
        guard var s = saved else { return }
        change(&s.group)
        setState(s)
    }

    func leave() { setState(nil); outgoing = []; inbox = ResponderInbox() }

    private func setState(_ s: SavedState?) {
        saved = s
        Store.save(s)
        rota = s?.group.defaultRota ?? Rota()
        applyGroup()
    }

    private func applyGroup() {
        board.secrets = [group?.secrets.channelSecret, group?.previousSecrets?.channelSecret].compactMap { $0 }
        relay.configure(group: group, identity: identity)
    }

    // MARK: Calling for help

    var current: OutgoingRequest? { outgoing.last }

    /// A press sends at once on every route that works without the caller's help (decision 8).
    func press(_ colour: Colour) {
        guard let unit = me?.unit else { return }
        var r = OutgoingRequest(unit: unit, number: Store.nextRequestNumber(), colour: colour, createdAt: Date())
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        for route in routes { r.update(route, .sending) }
        outgoing.append(r)
        for route in routes { send(r.callFrame, on: route, for: r.number, kind: .call) }
    }

    func add(_ category: CallCategory) {
        guard var r = outgoing.popLast() else { return }
        let frame = r.add(category)
        outgoing.append(r)
        for route in RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false) {
            send(frame, on: route, for: r.number, kind: .optional)
        }
    }

    var availableRoutes: Set<Route> {
        var s: Set<Route> = [.sms]
        if board.state == .ready { s.insert(.mesh) }
        if relay.isConfigured { s.insert(.internet) }
        return s
    }

    private func send(_ frame: HelpFrame, on route: Route, for number: UInt16, kind: AirtimeBudget.Kind) {
        Task {
            let failure: String?
            switch route {
            case .mesh: failure = await sendOnMesh(frame, kind: kind)
            case .internet: failure = await relay.send(frame)
            case .sms: failure = "Needs you to send it"
            }
            // Follow-ups never change what the caller is shown about the call itself.
            guard case .call = frame, let i = outgoing.firstIndex(where: { $0.number == number }) else { return }
            outgoing[i].update(route, failure.map(RouteState.failed) ?? .sent)
        }
    }

    private func sendOnMesh(_ frame: HelpFrame, kind: AirtimeBudget.Kind) async -> String? {
        guard let radio = board.radio, var b = budget else { return "Box not ready, or on a frequency Help&I will not use" }
        let seconds = radio.airtime(bytes: meshPacketBytes(payload: frame.encoded().count))
        guard b.allows(seconds, kind: kind, at: Date()) else { return "Radio time used up for now" }
        let failure = await board.send(frame)
        if failure == nil { b.record(seconds, at: Date()); budget = b }
        return failure
    }

    // MARK: Responding

    private func received(_ frame: HelpFrame, via route: Route) {
        if case let .ack(unit, request, who, at) = frame {
            lastAnswered[who] = Date(timeIntervalSince1970: TimeInterval(at))
            if let i = outgoing.firstIndex(where: { $0.unit == unit && $0.number == request }) { outgoing[i].receive(frame) }
        }
        if case .availability = frame { rota.apply(frame); return }
        guard me?.canRespond == true else { return }
        // A phone does not alert for its own calls.
        if case let .call(unit, _, _, _) = frame, unit == me?.unit { return }
        let event = inbox.receive(frame, via: route, at: Date())
        switch event {
        case let .new(key): scheduleAlerts(for: key)
        case let .updated(key):
            if inbox.requests[key]?.isAcknowledged == true { cancelAlerts(for: key) }
        default: break
        }
    }

    func acknowledge(_ key: IncomingRequest.Key) {
        guard let me = saved?.me, let frame = inbox.acknowledge(key, by: me, at: Date()) else { return }
        lastAnswered[me] = Date()
        cancelAlerts(for: key)
        for route in RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false) {
            send(frame, on: route, for: 0, kind: .call)
        }
    }

    func escalation(for r: IncomingRequest) -> Escalation? {
        guard let group else { return nil }
        let now = Date()
        let responders = group.members.filter { $0.canRespond && $0.unit != r.key.unit }.map {
            ResponderInfo(member: $0.number, availableNow: rota.isAvailable($0.number, at: now), lastAnsweredAt: lastAnswered[$0.number])
        }
        return Escalation(colour: r.colour ?? .red, responders: responders, policy: group.escalationPolicy)
    }

    /// Every phone works out the same order and alerts its own person at their turn. Alerts are
    /// scheduled as local notifications, so they still fire with the app in the background, and
    /// they stop only when someone acknowledges.
    private func scheduleAlerts(for key: IncomingRequest.Key) {
        guard let r = inbox.requests[key], let e = escalation(for: r), let me = saved?.me else { return }
        let myTurn = e.order.firstIndex(of: me).map { TimeInterval($0) * e.interval } ?? TimeInterval(e.order.count) * e.interval
        let content = UNMutableNotificationContent()
        let who = name(ofUnit: key.unit)
        switch r.colour {
        case .amber?: content.title = "\(who): come when convenient"
        case .green?: content.title = "\(who): I'm OK now"
        default: content.title = "\(who): come now"
        }
        content.body = "Open Help&I to acknowledge."
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        let trigger = myTurn < 1 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: myTurn, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alertID(key), content: content, trigger: trigger))
    }

    private func cancelAlerts(for key: IncomingRequest.Key) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [alertID(key)])
    }

    private func alertID(_ key: IncomingRequest.Key) -> String { "req-\(key.unit)-\(key.request)" }

    // MARK: Rota

    func setAvailable(_ available: Bool, hours: Double = 12) {
        guard let me = saved?.me else { return }
        let from = Date(), until = from.addingTimeInterval(hours * 3600)
        rota.add(responder: me, from: from, until: until, available: available)
        let frame = HelpFrame.availability(responder: me, from: UInt32(from.timeIntervalSince1970),
                                           until: UInt32(until.timeIntervalSince1970), available: available)
        for route in RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false) {
            send(frame, on: route, for: 0, kind: .optional)
        }
    }

    var gaps: [DateInterval] { rota.gaps(from: Date()) }
}
