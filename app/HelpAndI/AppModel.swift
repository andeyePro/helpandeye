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
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?

    private init() {
        saved = Store.loadState()
        activity = Store.loadActivity()
        board.onFrame = { [weak self] in self?.received($0, via: .mesh) }
        board.onText = { [weak self] in self?.receivedText(from: $0, $1) }
        board.$state.removeDuplicates().sink { [weak self] state in
            if state == .ready { Task { @MainActor in await self?.boardReady() } }
        }.store(in: &bag)
        relay.onFrame = { [weak self] in self?.received($0, via: .internet) }
        relay.onAllowanceLow = { [weak self] in self?.raise(.allowanceLow) }
        // A new budget only when the box is on a band with a different limit: reconnecting,
        // re-pairing or relaunching must not forget what was sent this hour.
        board.$selfInfo.compactMap { $0?.radio.band }.sink { [weak self] band in
            guard let self, self.activity.airtime?.dutyCycle != band.dutyCycle else { return }
            self.activity.airtime = AirtimeBudget(dutyCycle: band.dutyCycle)
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
        let before = Set(s.group.members.map(\.number))
        change(&s.group)
        setState(s)
        // A coordinator tells everyone who joined or left, signed, so their acknowledgements
        // count (or stop counting) on every phone at once.
        guard me?.role == .coordinator, let me = saved?.me else { return }
        let after = Set(s.group.members.map(\.number))
        let frames = after.subtracting(before).compactMap { s.group.addedFrame($0) }
            + before.subtracting(after).map { HelpFrame.memberRemoved(member: $0) }
        for f in frames { Task { await sendToAll(.signing(f, as: me, identity: identity)) } }
    }

    /// Over the internet if it is set up, and over the mesh as well, so members without internet
    /// hear too. Optional airtime.
    private func sendToAll(_ frame: HelpFrame) async {
        if relay.isConfigured { _ = await relay.send(frame) }
        _ = await sendOnMesh(frame, kind: .optional)
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
                let failure = route == .internet ? await relay.send(r.callFrame, wake: .call) : await send(r.callFrame, on: route, kind: .call)
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

    /// Typed text and position never go on the group channel (decision 12): over the internet,
    /// sealed with the group key, or else as direct messages to each responder's box.
    var canSendPersonal: Bool { relay.isConfigured || board.state == .ready }

    func addNote(_ text: String) -> String? {
        guard canSendPersonal else { return "Typed messages need the internet or your box." }
        guard var r = activity.outgoing.popLast() else { return nil }
        let frame = r.addNote(text)
        activity.outgoing.append(r)
        Task { await sendPersonal(frame) }
        return nil
    }

    func sharePosition(latitude: Double, longitude: Double, accuracy: Double) {
        guard canSendPersonal, let r = current else { return }
        let frame = HelpFrame.position(unit: r.unit, request: r.number, latitudeE7: Int32(latitude * 1e7),
                                       longitudeE7: Int32(longitude * 1e7), accuracy: UInt16(clamping: Int(accuracy)))
        Task { await sendPersonal(frame) }
    }

    private func sendPersonal(_ frame: HelpFrame) async {
        if relay.isConfigured, await relay.send(frame) == nil { return }
        guard let text = MeshText.encode(frame), let radio = board.radio, activity.airtime != nil else { return }
        let seconds = radio.airtime(bytes: meshPacketBytes(payload: text.utf8.count + 8))
        for m in group?.members ?? [] where m.canRespond && m.number != saved?.me {
            guard let key = activity.boardKeys[m.number], activity.airtime!.allows(seconds, kind: .optional, at: Date()) else { continue }
            let reservation = activity.airtime!.record(seconds, at: Date())
            if case .refused = await board.sendText(text, to: key) { activity.airtime?.cancel(reservation) }
        }
    }

    /// Tells the group which box is this phone's, and adds the other members' boxes as contacts.
    private func boardReady() async {
        guard let me = saved?.me, let key = board.selfInfo?.publicKey else { return }
        activity.boardKeys[me] = key
        for (member, k) in activity.boardKeys where member != me { await board.addContact(k, name: "Help&I \(member)") }
        await sendToAll(.signedBoard(member: me, publicKey: key, identity: identity))
        // A coordinator repeats who is in the group, for members who missed it.
        if me == saved?.me, self.me?.role == .coordinator, let g = group {
            for m in g.members where m.number != me {
                if let f = g.addedFrame(m.number) { await sendToAll(.signing(f, as: me, identity: identity)) }
            }
        }
    }

    /// A direct message counts only if it came from the box of the member whose unit it names.
    private func receivedText(from prefix: Data, _ text: String) {
        guard let frame = MeshText.decode(text) else { return }
        let unit: UInt32
        switch frame {
        case let .note(u, _, _, _), let .position(u, _, _, _, _): unit = u
        default: return
        }
        guard let sender = group?.member(unit: unit), let key = activity.boardKeys[sender.number], key.prefix(6) == prefix else { return }
        received(frame, via: .mesh)
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
        guard radio.band != nil, activity.airtime != nil else { return "Box is on a frequency Help&I will not use" }
        let seconds = radio.airtime(bytes: meshPacketBytes(payload: frame.encoded().count)) * Double(board.channelsPerSend)
        guard activity.airtime!.allows(seconds, kind: kind, at: Date()) else { return "Radio time used up for now" }
        // Reserve before sending, so overlapping sends cannot each see the same allowance. Give it
        // back only when the box certainly did not transmit.
        let reservation = activity.airtime!.record(seconds, at: Date())
        let result = await board.send(frame, urgent: kind == .call)
        if case .refused = result { activity.airtime?.cancel(reservation) }
        return result.failure
    }

    /// Runs every 15 seconds while the app runs, and whenever the box or relay wakes it.
    func tick() {
        checkResends()
        checkMissedCheckIn()
        watchOthersCheckIns()
        topUpAlerts()
        // Stop listening on the old channel once the changeover after a removal is over.
        let listening = group?.listening(at: Date()).map(\.channelSecret) ?? []
        if board.secrets != listening { board.secrets = listening }
    }

    /// Sends every call nobody has acknowledged yet again (see `Resend`), not only the latest, so a
    /// later press never strands an earlier one. A route that failed before is tried again, so a
    /// box that comes back in range still gets the call out.
    private func checkResends() {
        let now = Date()
        for i in activity.outgoing.indices where activity.outgoing[i].resendDue(at: now) {
            activity.outgoing[i].markResent(at: now)
            let r = activity.outgoing[i]
            for route in RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false) {
                Task {
                    // Resends count as optional airtime, so they never use up what a new press needs.
                    let failure = await send(r.callFrame, on: route, kind: .optional)
                    guard failure == nil, let j = activity.outgoing.firstIndex(where: { $0.number == r.number && $0.unit == r.unit }) else { return }
                    activity.outgoing[j].update(route, .sent)
                }
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
        case .availability, .noticeAck:
            // Counted only when signed (below), so a removed phone cannot fake them.
            return
        case let .signed(signer, _, _):
            guard let sender = group?.member(signer), let inner = frame.verifiedInner(signedBy: sender.signingKey) else { return }
            switch inner {
            case let .noticeAck(notice, by, _):
                if sender.role == .coordinator { notices[notice]?.acknowledge(by: by) }
            case .availability:
                if sender.canRespond { activity.rota.apply(inner); checkGaps() }
            case .memberAdded, .memberRemoved:
                // Only a coordinator changes who is in the group.
                if sender.role == .coordinator, me?.role != .coordinator { updateGroup { $0.apply(membership: inner) } }
            default: break
            }
            return
        case .memberAdded, .memberRemoved:
            return
        case let .board(member, key, _):
            guard member != saved?.me, frame.isValidBoard(signedBy: group?.member(member)?.signingKey),
                  activity.boardKeys[member] != key else { return }
            activity.boardKeys[member] = key
            Task { await board.addContact(key, name: "Help&I \(member)") }
            return
        case let .checkIns(unit, _, _, _):
            guard unit != me?.unit, group?.member(unit: unit) != nil else { return }
            activity.checkInWatch.apply(frame); return
        case let .call(unit, _, _, _), let .followUp(unit, _, _, _), let .note(unit, _, _, _), let .position(unit, _, _, _, _):
            // A phone never alerts for its own calls, however they come back to it.
            if unit == me?.unit { return }
            activity.checkInWatch.apply(frame)
            if case .followUp(_, _, _, .missedCheckIn) = frame { activity.checkInWatch.heardRaised(unit: unit, at: Date(), calendar: .current) }
        }
        guard me?.canRespond == true else { return }
        switch activity.inbox.receive(frame, via: route, at: Date()) {
        case let .new(key): scheduleAlerts(for: key)
        case let .updated(key) where activity.inbox.requests[key]?.isAcknowledged == true: cancelAlerts(for: key)
        case .duplicate:
            // The caller is still sending, so it has not heard an acknowledgement. Pass on the
            // signed acknowledgements this phone has, its own or another responder's.
            if case let .call(unit, request, _, _) = frame { reAck(IncomingRequest.Key(unit: unit, request: request)) }
        default: break
        }
        tick()
    }

    private var lastReAck: [IncomingRequest.Key: Date] = [:]

    /// The phone that acknowledged repeats its ack at most every 25 seconds; others pass one on
    /// at most every five minutes, so a crowd of phones does not fill the radio.
    private func reAck(_ key: IncomingRequest.Key) {
        guard let me = saved?.me, let r = activity.inbox.requests[key], !r.acks.isEmpty else { return }
        let mine = r.acks[me]
        guard Date().timeIntervalSince(lastReAck[key] ?? .distantPast) >= (mine != nil ? 25 : 300) else { return }
        lastReAck[key] = Date()
        let frame = mine ?? r.acks.values.first!
        Task { _ = await sendOptional(frame); if relay.isConfigured { _ = await sendOnMesh(frame, kind: .optional) } }
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
                let failure = route == .internet ? await relay.send(frame, wake: .quiet) : await send(frame, on: route, kind: .call)
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
        // iOS keeps at most 64 pending notifications per app: up to four go to check-in reminders,
        // the rest are shared between open requests. A long tail keeps alerting with the app asleep.
        let open = max(activity.inbox.requests.values.filter { !$0.isAcknowledged }.count, 1)
        let count = max(3, 58 / open)
        let times: [Date]
        switch r.colour {
        case .green?: times = [max(turnAt, Date())]  // "I'm OK now" asks for no one: tell them once, calmly.
        case .amber?: times = alertTimes(turnAt: turnAt, every: 300, quick: 6, later: 1800, from: Date(), count: count)
        default: times = alertTimes(turnAt: turnAt, every: 60, quick: 10, later: 600, from: Date(), count: count)
        }
        let content = UNMutableNotificationContent()
        let who = name(ofUnit: key.unit)
        switch r.colour {
        case .amber?: content.title = "\(who): come when convenient"
        case .green?: content.title = "\(who): I'm OK now"
        default: content.title = "\(who): come now"
        }
        if r.key.request == 0 { content.title = "\(who) missed a check-in" }
        content.body = "Open Help&I to acknowledge."
        content.sound = r.colour == .green ? .default : .defaultCritical
        content.interruptionLevel = r.colour == .green ? .active : .timeSensitive
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: alertIDs(key))
        for (n, at) in times.enumerated() {
            let due = at.timeIntervalSinceNow
            let trigger = due < 1 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: due, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(alertID(key))-\(n)", content: content, trigger: trigger))
        }
    }

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
        Task { _ = await sendOptional(.signing(frame, as: me, identity: identity)) }
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
        let frame = HelpFrame.noticeAck(notice: notice, by: me, at: UInt32(Date().timeIntervalSince1970))
        Task { _ = await sendOptional(.signing(frame, as: me, identity: identity)) }
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
        // Responders' phones watch too. A routine is personal, so it goes over the internet only.
        if let unit = me?.unit {
            let frame = HelpFrame.checkIns(unit: unit, since: UInt32((s.checkInSince ?? Date()).timeIntervalSince1970),
                                           grace: UInt16((schedule?.grace ?? 1800) / 60), times: (schedule?.times ?? []).map { UInt16($0) })
            Task { _ = await relay.send(frame) }
        }
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

    /// A missed check-in raises an amber request, once per missed time, unless a red or amber call
    /// is already waiting for a responder: that one matters more and must stay on screen.
    func checkMissedCheckIn() {
        guard let s = saved, let schedule = s.checkIn, let since = s.checkInSince, me?.canCall == true else { return }
        let waiting = activity.outgoing.contains { r in
            if case .seen = r.status { return false }
            return r.colour != .green && Date().timeIntervalSince(r.createdAt) < 86_400
        }
        guard !waiting else { return }
        guard let missed = schedule.missed(greens: activity.greens, since: since, now: Date(), calendar: .current),
              UserDefaults.standard.double(forKey: "checkin-raised") < missed.timeIntervalSince1970 else { return }
        UserDefaults.standard.set(missed.timeIntervalSince1970, forKey: "checkin-raised")
        press(.amber)
        add(.missedCheckIn)
    }

    /// Raises another caller's missed check-in on this phone, if their own phone has not. The
    /// request is numbered 0, which callers never use, and needs a person to acknowledge it.
    private func watchOthersCheckIns() {
        guard me?.canRespond == true else { return }
        for (unit, missed) in activity.checkInWatch.due(at: Date(), calendar: .current) {
            let at = UInt32(missed.timeIntervalSince1970)
            if case let .new(key) = activity.inbox.receive(.call(unit: unit, request: 0, colour: .amber, sentAt: at), via: .internet, at: Date()) {
                activity.inbox.receive(.followUp(unit: unit, request: 0, part: 1, category: .missedCheckIn), via: .internet, at: Date())
                scheduleAlerts(for: key)
            }
        }
    }
}
