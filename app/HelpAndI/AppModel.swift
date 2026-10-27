import Combine
import Foundation
import HelpAndICore
import UserNotifications

/// The app's state: the group, this phone's calls for help, and the requests it is answering.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var saved: SavedState?
    @Published private(set) var activity: Activity { didSet { Store.save(activity) } }
    /// Notices a coordinator must acknowledge. Each phone widens its own copy until it hears an
    /// acknowledgement (app spec, "Tiers and cost" and "Rota gaps").
    @Published private(set) var notices: [Notice: CoordinatorAlert] = [:]
    /// Whether this responder's own acknowledgements went out.
    @Published private(set) var ackSends: [IncomingRequest.Key: [Route: RouteState]] = [:]

    let identity = Store.identity()
    let board = BoardLink()
    let relay = Relay()
    private var budget: AirtimeBudget?
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?

    private init() {
        saved = Store.loadState()
        activity = Store.loadActivity()
        board.onFrame = { [weak self] in self?.received($0, via: .mesh) }
        relay.onFrame = { [weak self] in self?.received($0, via: .internet) }
        relay.onAllowanceLow = { [weak self] in self?.raise(.allowanceLow) }
        // A new budget only when the band changes: reconnecting must not forget what was sent.
        board.$selfInfo.map { $0?.radio.band }.removeDuplicates().sink { [weak self] band in
            self?.budget = band.map { AirtimeBudget(dutyCycle: $0.dutyCycle) }
        }.store(in: &bag)
        board.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        relay.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        applyGroup()
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    var group: GroupState? { saved?.group }
    var me: Member? { saved.flatMap { $0.group.member($0.me) } }
    var inbox: ResponderInbox { activity.inbox }
    var rota: Rota { activity.rota }

    func name(ofUnit unit: UInt32) -> String { group?.member(unit: unit)?.name ?? "Unit \(unit)" }
    func name(ofMember n: UInt16) -> String { n == saved?.me ? "You" : (group?.member(n)?.name ?? "Responder \(n)") }

    // MARK: Group

    func createGroup(name: String, myName: String, call: Bool) {
        var g = GroupState(name: name, secrets: .random(), members: [])
        g.members.append(Member(number: 1, name: myName, role: .coordinator, publicKey: identity.publicKey,
                                unit: call ? g.nextUnit : nil, signingKey: identity.signingPublicKey))
        setState(SavedState(group: g, me: 1))
    }

    func joined(_ group: GroupState, as number: UInt16) { setState(SavedState(group: group, me: number)) }

    func updateGroup(_ change: (inout GroupState) -> Void) {
        guard var s = saved else { return }
        change(&s.group)
        setState(s)
    }

    func leave() {
        setState(nil)
        activity = Activity()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    private func setState(_ s: SavedState?) {
        saved = s
        Store.save(s)
        applyGroup()
    }

    private func applyGroup() {
        // The rota keeps what people said about their availability; only the list of who can
        // respond follows the group.
        activity.rota.responders = group?.members.filter(\.canRespond).map(\.number) ?? []
        activity.rota.defaultAvailable = true
        board.secrets = group?.listening(at: Date()).map(\.channelSecret) ?? []
        relay.configure(group: group, identity: identity)
        if me?.role == .coordinator, relay.isConfigured { Task { await relay.publishMembers() } }
        checkGaps()
    }

    // MARK: Calling for help

    var current: OutgoingRequest? { activity.outgoing.last }

    private func nextRequestNumber() -> UInt16 {
        guard var s = saved else { return 0 }
        s.lastRequest &+= 1
        if s.lastRequest == 0 { s.lastRequest = 1 }
        saved = s
        Store.save(s)
        return s.lastRequest
    }

    /// A press sends at once on every route that works without the caller's help (decision 8).
    /// Routes that are not available are shown as not sent, with the reason, so that a press with
    /// no route at all gives the cross at once.
    func press(_ colour: Colour) {
        guard let unit = me?.unit else { return }
        var r = OutgoingRequest(unit: unit, number: nextRequestNumber(), colour: colour, createdAt: Date())
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        if !routes.contains(.mesh) { r.update(.mesh, .failed(meshUnavailableReason)) }
        if !routes.contains(.internet) { r.update(.internet, .failed(relay.lastProblem ?? "Internet route not set up")) }
        for route in routes { r.update(route, .sending) }
        activity.outgoing.append(r)
        if activity.outgoing.count > 50 { activity.outgoing.removeFirst(activity.outgoing.count - 50) }
        if colour == .green { activity.greens.append(r.createdAt) }
        for route in routes {
            Task {
                let failure = await send(r.callFrame, on: route, kind: .call)
                guard let i = activity.outgoing.firstIndex(where: { $0.number == r.number && $0.unit == r.unit }) else { return }
                activity.outgoing[i].update(route, failure.map(RouteState.failed) ?? .sent)
            }
        }
    }

    private var meshUnavailableReason: String {
        switch board.state {
        case .ready: return "Box not ready"
        case .off: return "No box connected"
        case let .failed(why): return why
        default: return "Box not connected"
        }
    }

    func add(_ category: CallCategory) {
        guard var r = activity.outgoing.popLast() else { return }
        let frame = r.add(category)
        activity.outgoing.append(r)
        Task { _ = await sendOptional(frame) }
    }

    /// Typed text goes only over the internet route, sealed with the group key (decision 12).
    func addNote(_ text: String) -> String? {
        guard relay.isConfigured else { return "Typed messages need the internet route, which is not set up." }
        guard var r = activity.outgoing.popLast() else { return nil }
        let frame = r.addNote(text)
        activity.outgoing.append(r)
        Task { _ = await relay.send(frame) }
        return nil
    }

    func sharePosition(latitude: Double, longitude: Double, accuracy: Double) {
        guard relay.isConfigured, let r = current else { return }
        let frame = HelpFrame.position(unit: r.unit, request: r.number, latitudeE7: Int32(latitude * 1e7),
                                       longitudeE7: Int32(longitude * 1e7), accuracy: UInt16(clamping: Int(accuracy)))
        Task { _ = await relay.send(frame) }
    }

    var availableRoutes: Set<Route> {
        var s: Set<Route> = [.sms]
        if board.state == .ready { s.insert(.mesh) }
        if relay.isConfigured { s.insert(.internet) }
        return s
    }

    private func send(_ frame: HelpFrame, on route: Route, kind: AirtimeBudget.Kind) async -> String? {
        switch route {
        case .mesh: return await sendOnMesh(frame, kind: kind)
        case .internet: return await relay.send(frame)
        case .sms: return "Needs you to send it"
        }
    }

    /// Follow-ups, availability and notice acknowledgements use the internet when it works and the
    /// mesh only when it does not, to keep radio time for calls.
    private func sendOptional(_ frame: HelpFrame) async -> String? {
        if relay.isConfigured, await relay.send(frame) == nil { return nil }
        return await sendOnMesh(frame, kind: .optional)
    }

    private func sendOnMesh(_ frame: HelpFrame, kind: AirtimeBudget.Kind) async -> String? {
        // Personal content never goes on the shared group channel (decision 12).
        guard frame.mayGoOnGroupChannel else { return "Only goes over the internet" }
        guard board.state == .ready, let radio = board.radio else { return meshUnavailableReason }
        guard budget != nil else { return "Box is on a frequency Help&I will not use" }
        let seconds = radio.airtime(bytes: meshPacketBytes(payload: frame.encoded().count))
        guard budget!.allows(seconds, kind: kind, at: Date()) else { return "Radio time used up for now" }
        // Reserve before sending, so overlapping sends cannot each see the same allowance.
        let reservation = budget!.record(seconds, at: Date())
        let failure = await board.send(frame, urgent: kind == .call)
        if failure != nil { budget?.cancel(reservation) }
        return failure
    }

    /// Runs every 15 seconds while the app runs, and whenever the box or relay wakes it.
    func tick() {
        checkResends()
        checkMissedCheckIn()
        topUpAlerts()
    }

    /// Sends the latest call again until a responder acknowledges it (see `Resend`). A route that
    /// failed before is tried again, so a box that comes back in range still gets the call out.
    private func checkResends() {
        guard let r = current, r.resendDue(at: Date()), let i = activity.outgoing.indices.last else { return }
        activity.outgoing[i].markResent()
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        for route in routes {
            Task {
                // Resends count as optional airtime, so they never use up what a new press needs.
                let failure = await send(r.callFrame, on: route, kind: .optional)
                guard failure == nil, let j = activity.outgoing.firstIndex(where: { $0.number == r.number && $0.unit == r.unit }) else { return }
                activity.outgoing[j].update(route, .sent)
            }
        }
    }

    // MARK: Receiving

    private func received(_ frame: HelpFrame, via route: Route) {
        switch frame {
        case let .ack(unit, request, who, at, _):
            // Only a current responder's own signature counts (decision 6, AGENTS.md).
            guard group?.acceptsAck(frame) == true else { return }
            activity.lastAnswered[who] = max(activity.lastAnswered[who] ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(at)))
            if let i = activity.outgoing.firstIndex(where: { $0.unit == unit && $0.number == request }) {
                activity.outgoing[i].receive(frame)
            }
        case .availability:
            activity.rota.apply(frame); checkGaps(); return
        case let .noticeAck(notice, by, _):
            notices[notice]?.acknowledge(by: by); return
        case let .call(unit, _, _, _), let .followUp(unit, _, _, _), let .note(unit, _, _, _), let .position(unit, _, _, _, _):
            // A phone never alerts for its own calls, however they come back to it.
            if unit == me?.unit { return }
        }
        guard me?.canRespond == true else { return }
        switch activity.inbox.receive(frame, via: route, at: Date()) {
        case let .new(key): scheduleAlerts(for: key)
        case let .updated(key) where activity.inbox.requests[key]?.isAcknowledged == true: cancelAlerts(for: key)
        case .duplicate:
            // The caller is still sending, so it has not heard an acknowledgement. If this phone
            // acknowledged, say so again.
            if case let .call(unit, request, _, _) = frame { reAck(IncomingRequest.Key(unit: unit, request: request)) }
        default: break
        }
        tick()
    }

    private var lastReAck: [IncomingRequest.Key: Date] = [:]

    private func reAck(_ key: IncomingRequest.Key) {
        guard let me = saved?.me, activity.inbox.requests[key]?.acknowledgedBy.contains(me) == true,
              Date().timeIntervalSince(lastReAck[key] ?? .distantPast) >= 25 else { return }
        lastReAck[key] = Date()
        retryAck(key)
    }

    // MARK: Responding

    func acknowledge(_ key: IncomingRequest.Key) {
        guard let me = saved?.me, let frame = activity.inbox.acknowledge(key, by: me, at: Date(), identity: identity) else { return }
        activity.lastAnswered[me] = Date()
        cancelAlerts(for: key)
        sendAck(frame, for: key)
    }

    func retryAck(_ key: IncomingRequest.Key) {
        guard let me = saved?.me else { return }
        sendAck(.signedAck(unit: key.unit, request: key.request, responder: me, at: Date(), identity: identity), for: key)
    }

    private func sendAck(_ frame: HelpFrame, for key: IncomingRequest.Key) {
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        ackSends[key] = Dictionary(uniqueKeysWithValues: routes.map { ($0, RouteState.sending) })
        for route in routes {
            Task {
                let failure = await send(frame, on: route, kind: .call)
                ackSends[key]?[route] = failure.map(RouteState.failed) ?? .sent
            }
        }
    }

    /// What the responder is told about their own acknowledgement.
    func ackSendStatus(_ key: IncomingRequest.Key) -> CallerStatus? {
        guard let s = ackSends[key] else { return nil }
        if s.values.contains(.sent) { return .waitingForResponder }
        if s.values.contains(.sending) { return .sending }
        return .notSent
    }

    func escalation(for r: IncomingRequest) -> Escalation? {
        guard let group else { return nil }
        let at = r.sentAt ?? r.firstHeardAt
        let responders = group.members.filter { $0.canRespond && $0.unit != r.key.unit }.map {
            ResponderInfo(member: $0.number, availableNow: rota.isAvailable($0.number, at: at), lastAnsweredAt: activity.lastAnswered[$0.number])
        }
        return Escalation(colour: r.colour ?? .red, responders: responders, policy: group.escalationPolicy)
    }

    /// Every phone works out the order from the same group, rota and record of who answered, and
    /// alerts its own person at their turn, counted from when the caller pressed. Alerts are local
    /// notifications, so they still fire with the app in the background, and they stop only when
    /// someone acknowledges.
    private func scheduleAlerts(for key: IncomingRequest.Key) {
        guard let r = activity.inbox.requests[key], !r.isAcknowledged, let e = escalation(for: r), let me = saved?.me else { return }
        let turn = TimeInterval(e.order.firstIndex(of: me) ?? e.order.count) * e.interval
        let turnAt = (r.sentAt ?? r.firstHeardAt).addingTimeInterval(turn)
        // iOS keeps at most 64 pending notifications per app, shared between open requests.
        let open = max(activity.inbox.requests.values.filter { !$0.isAcknowledged }.count, 1)
        let times = alertTimes(turnAt: turnAt, every: r.colour == .red || r.colour == nil ? 60 : 300, from: Date(),
                               count: max(2, min(alertsPerRequest, 56 / open)))
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
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: alertIDs(key))
        for (n, at) in times.enumerated() {
            let due = at.timeIntervalSinceNow
            let trigger = due < 1 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: due, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(alertID(key))-\(n)", content: content, trigger: trigger))
        }
    }

    private let alertsPerRequest = 10

    private func cancelAlerts(for key: IncomingRequest.Key) {
        let ids = alertIDs(key)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Re-schedules each open request's alerts from now, so they keep coming however long it takes.
    private func topUpAlerts() {
        let open = activity.inbox.requests.values.filter { !$0.isAcknowledged }
        let due = open.filter { r in (lastTopUp[r.key] ?? .distantPast).timeIntervalSinceNow < -120 }
        for r in due { lastTopUp[r.key] = Date(); scheduleAlerts(for: r.key) }
    }

    private var lastTopUp: [IncomingRequest.Key: Date] = [:]

    private func alertID(_ key: IncomingRequest.Key) -> String { "req-\(key.unit)-\(key.request)" }
    private func alertIDs(_ key: IncomingRequest.Key) -> [String] { (0..<64).map { "\(alertID(key))-\($0)" } }

    // MARK: Rota and notices

    func setAvailable(_ available: Bool, hours: Double = 12) {
        guard let me = saved?.me else { return }
        let from = Date(), until = from.addingTimeInterval(hours * 3600)
        activity.rota.add(responder: me, from: from, until: until, available: available)
        checkGaps()
        let frame = HelpFrame.availability(responder: me, from: UInt32(from.timeIntervalSince1970),
                                           until: UInt32(until.timeIntervalSince1970), available: available)
        Task { _ = await sendOptional(frame) }
    }

    var gaps: [DateInterval] { rota.gaps(from: Date()) }

    /// Every phone works out gaps for itself, so the coordinator hears with no network at all.
    private func checkGaps() {
        if group != nil, !gaps.isEmpty { raise(.rotaGap) } else { notices[.rotaGap] = nil }
    }

    func raise(_ notice: Notice) {
        guard notices[notice] == nil else { return }
        notices[notice] = CoordinatorAlert(raisedAt: Date())
    }

    /// Whether this phone should be showing the notice now.
    func showing(_ notice: Notice) -> Bool {
        guard let a = notices[notice], let me else { return false }
        switch a.audience(at: Date()) {
        case .firstCoordinator?: return me.role == .coordinator && group?.members.first(where: { $0.role == .coordinator })?.number == me.number
        case .allCoordinators?: return me.role == .coordinator
        case .wholeGroup?: return true
        case nil: return false
        }
    }

    func acknowledge(_ notice: Notice) {
        guard let me = saved?.me else { return }
        notices[notice]?.acknowledge(by: me)
        Task { _ = await sendOptional(.noticeAck(notice: notice, by: me, at: UInt32(Date().timeIntervalSince1970))) }
    }

    func setRelay(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        updateGroup { $0.relayURL = trimmed.isEmpty ? nil : trimmed }
    }

    // MARK: Check-ins (decision 16)

    var checkIn: CheckInSchedule? { saved?.checkIn }

    /// Off unless the caller turns it on. Reminders come as notifications at each time.
    func setCheckIn(_ schedule: CheckInSchedule?) {
        guard var s = saved else { return }
        s.checkIn = schedule
        s.checkInSince = schedule == nil ? nil : Date()
        saved = s
        Store.save(s)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<1440).map { "checkin-\($0)" })
        for t in schedule?.times ?? [] {
            let content = UNMutableNotificationContent()
            content.title = "Time to check in"
            content.body = "Open Help&I and press I'm OK now."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: t / 60, minute: t % 60), repeats: true)
            center.add(UNNotificationRequest(identifier: "checkin-\(t)", content: content, trigger: trigger))
        }
    }

    /// A missed check-in raises an amber request, once per missed time.
    func checkMissedCheckIn() {
        guard let s = saved, let schedule = s.checkIn, let since = s.checkInSince, me?.canCall == true else { return }
        guard let missed = schedule.missed(greens: activity.greens, since: since, now: Date(), calendar: .current),
              UserDefaults.standard.double(forKey: "checkin-raised") < missed.timeIntervalSince1970 else { return }
        UserDefaults.standard.set(missed.timeIntervalSince1970, forKey: "checkin-raised")
        press(.amber)
        add(.missedCheckIn)
    }
}
