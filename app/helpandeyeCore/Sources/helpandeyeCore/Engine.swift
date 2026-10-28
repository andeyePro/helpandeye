import Combine
import Foundation

// The app's rules, free of iOS frameworks so `swift test` can run several phones against each
// other over a fake mesh and relay. The app wires in the real box, relay and notifications.

public enum MeshSendResult: Equatable, Sendable {
    case sent
    /// It certainly did not go on air.
    case refused(String)
    /// The box did not answer, so it may or may not have gone on air.
    case unknown(String)

    public var failure: String? {
        switch self { case .sent: nil; case let .refused(why), let .unknown(why): why }
    }
}

/// The box: a Heltec board on MeshCore's companion firmware, over Bluetooth.
@MainActor public protocol MeshLink: AnyObject {
    var isReady: Bool { get }
    var radio: RadioSettings? { get }
    var boxPublicKey: Data? { get }
    /// 2 during a changeover, when every send also goes on the previous channel.
    var channelsPerSend: Int { get }
    var unavailableReason: String { get }
    /// The channel secrets to listen on, current first.
    var secrets: [Data] { get set }
    func send(_ frame: HelpFrame, urgent: Bool) async -> MeshSendResult
    func sendText(_ text: String, to key: Data) async -> MeshSendResult
    func addContact(_ key: Data, name: String) async
    /// Set when one box serves several groups (MeshHub): their sends share one hour's allowance.
    var sharedAirtime: AirtimeLedger? { get }
}

extension MeshLink {
    public var sharedAirtime: AirtimeLedger? { nil }
}

public enum RelayWake: String, Sendable { case call, quiet }

public enum PublishResult: Equatable, Sendable {
    case accepted
    /// The relay said no; trying the same list again will not help.
    case refused
    /// No answer; worth trying again later.
    case unreachable
}

/// The internet route.
@MainActor public protocol RelayLink: AnyObject {
    var isConfigured: Bool { get }
    var lastProblem: String? { get }
    func configure(group: GroupState?, identity: DeviceIdentity)
    func publishMembers() async -> PublishResult
    func send(_ frame: HelpFrame, wake: RelayWake?) async -> String?
}

/// One responder alert: the same words at each of `times`.
public struct Alert: Equatable, Sendable {
    public let key: IncomingRequest.Key
    public let title: String
    public let body: String
    /// "I'm OK": an ordinary notification, not a time-sensitive one with an urgent sound.
    public let calm: Bool
    public let times: [Date]

    /// The same alert, let go late (a watch's, held while the phone was in reach): times already
    /// past become one alert now, never a burst of them.
    public func fromNow(_ now: Date) -> Alert {
        let future = times.filter { $0 > now }
        return Alert(key: key, title: title, body: body, calm: calm, times: (times.count > future.count ? [now] : []) + future)
    }
}

@MainActor public protocol AlertScheduler: AnyObject {
    /// Replaces any alerts already scheduled for the request.
    func schedule(_ alert: Alert)
    /// Removes scheduled and delivered alerts for the request.
    func cancel(_ key: IncomingRequest.Key)
    func cancelAll()
    func setCheckInReminders(_ minutesAfterMidnight: [Int])
    /// Tells this phone's own caller something they must not miss, such as their call no longer
    /// being seen by anyone.
    func tellCaller(title: String, body: String)
}

@MainActor public protocol EngineStore: AnyObject {
    func save(_ state: SavedState?)
    func save(_ activity: Activity)
}

/// The group, this phone's place in it, and its request counter.
public struct SavedState: Codable, Equatable, Sendable {
    public var group: GroupState
    public var me: UInt16
    public var lastRequest: UInt16 = 0
    public var checkIn: CheckInSchedule?
    public var checkInSince: Date?
    /// The last missed check-in this phone raised for its own caller.
    public var checkInRaised: Date?
    /// When this caller's check-ins were last sent to responders, so a relaunch does not resend.
    public var checkInSharedAt: Date?
    /// The coordinator who invited this phone, and whether the first coordinator has since been
    /// heard listing it, so the whole group knows it is in.
    public var invitedBy: UInt16?
    public var confirmed = true
    public var joinedAt: Date?

    public init(group: GroupState, me: UInt16) { self.group = group; self.me = me }
}

/// What is happening now: open calls, the responder's list, the rota, radio use.
public struct Activity: Codable, Sendable {
    public var outgoing: [OutgoingRequest] = []
    public var inbox = ResponderInbox()
    public var rota = Rota()
    public var lastAnswered: [UInt16: Date] = [:]
    public var greens: [Date] = []
    /// This phone's own radio use in the last hour (IR 2030), kept across relaunches.
    public var airtime: AirtimeBudget?
    public var checkInWatch = CheckInWatch()
    /// Members' boxes, by member number, for direct messages over the mesh.
    public var boardKeys: [UInt16: Data] = [:]
    /// Notices a coordinator must acknowledge. Saved, so a relaunch does not restart their widening.
    public var notices: [Notice: CoordinatorAlert] = [:]
    /// "I'm OK" calls already alerted once; they are never alerted again.
    public var alertedGreens: Set<IncomingRequest.Key> = []

    public init() {}
}

@MainActor
public final class HelpEngine: ObservableObject {
    @Published public private(set) var saved: SavedState?
    @Published public private(set) var activity: Activity { didSet { store.save(activity) } }
    /// Notices a coordinator must acknowledge. Each phone widens its own copy until it hears an
    /// acknowledgement (app spec, "Tiers and cost" and "Rota gaps").
    public var notices: [Notice: CoordinatorAlert] { activity.notices }
    /// Whether this responder's own acknowledgements went out.
    @Published public private(set) var ackSends: [IncomingRequest.Key: [Route: RouteState]] = [:]

    public let identity: DeviceIdentity
    public let mesh: MeshLink
    public let relay: RelayLink
    let alerts: AlertScheduler
    let store: EngineStore
    let now: () -> Date
    let calendar: Calendar

    private var lastReAck: [IncomingRequest.Key: Date] = [:]
    private var lastTopUp: [IncomingRequest.Key: Date] = [:]
    private var ackAttempt: [IncomingRequest.Key: UUID] = [:]
    private var lastMembershipRepeat: Date?
    private var answeredBoxes: Set<UInt16> = []
    private var boxesToAnswer: Set<UInt16> = []
    /// Number blocks of coordinators just removed, to re-list the people they added.
    private var previousBlocks: [UInt16: UInt16] = [:]
    /// The member list the relay last took from this phone, and when; and the last attempt.
    private var publishedList: RelayProtocol.MemberList?
    private var publishedAt: Date?
    private var refusedList: RelayProtocol.MemberList?
    private var lastPublishTry: Date?
    private var publishBackoff: TimeInterval = 60
    /// An answer is a broadcast every box hears, so one a minute covers a newcomer hearing many.
    private var lastBoxAnswer: Date?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// A watch acting for its owner's phone while the phone is out of reach. It calls and responds
    /// as the same member, numbering its calls apart from the phone's, and leaves the phone's other
    /// duties (the member list, check-ins, rota gaps) to the phone.
    public let companion: Bool

    public init(identity: DeviceIdentity, mesh: MeshLink, relay: RelayLink, alerts: AlertScheduler, store: EngineStore,
                saved: SavedState?, activity: Activity, calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
                companion: Bool = false) {
        self.identity = identity; self.mesh = mesh; self.relay = relay; self.alerts = alerts; self.store = store
        self.saved = saved; self.activity = activity; self.calendar = calendar; self.now = now; self.companion = companion
        applyGroup()
    }

    public var group: GroupState? { saved?.group }
    private var groupID: Data { group?.secrets.groupID ?? Data() }
    public var me: Member? { saved.flatMap { $0.group.member($0.me) } }
    public var current: OutgoingRequest? { activity.outgoing.last }

    public func name(ofUnit unit: UInt32) -> String { group?.member(unit: unit)?.name ?? "Unit \(unit)" }
    public func name(ofMember n: UInt16) -> String { n == saved?.me ? "You" : (group?.member(n)?.name ?? "Responder \(n)") }

    /// Runs `work` and remembers it, so tests can wait for every send to finish.
    private func spawn(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await work()
            self?.tasks[id] = nil
        }
    }

    /// Waits until nothing this engine started is still running.
    public func settle() async {
        while let t = tasks.values.first { await t.value }
    }

    // MARK: Group

    public func createGroup(name: String, myName: String, call: Bool, phone: String? = nil) {
        var g = GroupState(name: name, secrets: .forOwner(signingKey: identity.signingPublicKey), members: [])
        g.members.append(Member(number: 1, name: myName, role: .coordinator, publicKey: identity.publicKey,
                                unit: call ? g.nextUnit : nil, phone: phone, signingKey: identity.signingPublicKey))
        g.highestMember = 1
        setState(SavedState(group: g, me: 1))
    }

    /// `invitedBy` is the coordinator whose code was scanned. Invited by anyone but the first
    /// coordinator, a phone is not confirmed until it hears the first coordinator list it.
    public func joined(_ group: GroupState, as number: UInt16, invitedBy: UInt16? = nil) {
        var s = SavedState(group: group, me: number)
        s.invitedBy = invitedBy
        s.confirmed = invitedBy == nil || invitedBy == group.primaryCoordinator
        s.joinedAt = now()
        setState(s)
    }

    /// Changes the group. On a coordinator's phone, everyone is told who joined or left, signed,
    /// so their acknowledgements count (or stop counting) on every phone at once.
    public func updateGroup(_ change: (inout GroupState) -> Void) {
        guard var s = saved else { return }
        let old = s.group
        let before = Set(s.group.members.map(\.number))
        change(&s.group)
        // Changed settings go to every member at once, under a newer version.
        let settingsChanged = actsAsCoordinator && s.group.settings != old.settings
        if settingsChanged { s.group.settingsVersion = old.settingsVersion + 1 }
        setState(s)
        guard actsAsCoordinator else { return }
        if settingsChanged, let f = s.group.settingsFrame(as: s.me, identity: identity) {
            spawn { _ = await self.sendOptional(f) }
        }
        let roleChanged = s.group.members.filter { m in old.member(m.number).map { $0.role != m.role } ?? false }.map(\.number)
        announce(membershipOf: s.group, added: Set(s.group.members.map(\.number)).subtracting(before),
                 removed: before.subtracting(s.group.members.map(\.number)), roles: Set(roleChanged))
    }

    private func announce(membershipOf g: GroupState, added: Set<UInt16>, removed: Set<UInt16>, roles: Set<UInt16> = []) {
        guard let me = saved?.me else { return }
        let gid = g.secrets.groupID
        // Before a coordinator is removed, everyone they added that this phone knows of is listed
        // again, so those people are confirmed rather than told their inviter left.
        let theirs = removed.compactMap { r -> [UInt16]? in
            guard let b = previousBlocks[r], b > 0 else { return nil }
            return g.members.map(\.number).filter { $0 > b && $0 <= b + 999 }
        }.flatMap { $0 }
        let frames = (added.sorted() + theirs.sorted()).compactMap { g.addedFrame($0) }
            + removed.sorted().map { HelpFrame.memberRemoved(member: $0, version: g.membershipVersion) }
            + roles.sorted().compactMap { g.roleFrame($0) }
        for f in frames {
            let signed = HelpFrame.signing(f, as: me, identity: identity, group: gid)
            spawn { await self.sendToAll(signed) }
        }
        // Names are personal, so they go over the internet only.
        for n in added.sorted() {
            guard let m = g.member(n) else { continue }
            let signed = HelpFrame.signing(.memberName(member: n, name: m.name), as: me, identity: identity, group: gid)
            spawn { _ = await self.relay.send(signed, wake: nil) }
            if let phone = m.phone {
                let at = g.phoneVersions[n] ?? UInt32(now().timeIntervalSince1970)
                let signed = HelpFrame.signing(.memberPhone(member: n, phone: phone, at: at), as: me, identity: identity, group: gid)
                spawn { _ = await self.relay.send(signed, wake: nil) }
            }
        }
    }

    /// Changes this member's own mobile number and tells the group over the internet: a number is
    /// personal, so it never goes on the radio (decision 12).
    public func setMyPhone(_ phone: String?) {
        guard var s = saved, let i = s.group.members.firstIndex(where: { $0.number == s.me }) else { return }
        let number = String((phone ?? "").filter { "0123456789+".contains($0) }.prefix(HelpFrame.maxPhoneBytes))
        let at = UInt32(now().timeIntervalSince1970)
        s.group.members[i].phone = number.isEmpty ? nil : number
        s.group.phoneVersions[s.me] = at
        setState(s)
        let signed = HelpFrame.signing(.memberPhone(member: s.me, phone: number, at: at), as: s.me, identity: identity, group: groupID)
        spawn { _ = await self.relay.send(signed, wake: nil) }
    }

    public func leave() {
        setState(nil)
        // The radio's record of the last hour belongs to the box, not the group: keep it.
        var fresh = Activity()
        fresh.airtime = activity.airtime
        activity = fresh
        alerts.cancelAll()
    }

    /// On a watch: takes in what the paired phone sent. Returns false if it was made with other keys,
    /// so the watch must start a new engine with them.
    @discardableResult
    public func take(_ handover: WatchHandover) -> Bool {
        guard companion, handover.keys == identity.rawRepresentation else { return false }
        let next = handover.state(keeping: saved)
        if next != saved { setState(next) }
        return true
    }

    private func setState(_ s: SavedState?) {
        saved = s
        store.save(s)
        applyGroup()
    }

    private func applyGroup() {
        // The rota keeps what people said about their availability; only the list of who can
        // respond follows the group.
        activity.rota.responders = group?.members.filter(\.canRespond).map(\.number) ?? []
        activity.rota.defaultAvailable = true
        // Forget removed members' boxes, availability and answering record, so nothing meant for a
        // current member can reach a removed one.
        let current = Set(group?.members.map(\.number) ?? [])
        if activity.boardKeys.keys.contains(where: { !current.contains($0) }) { activity.boardKeys = activity.boardKeys.filter { current.contains($0.key) } }
        if activity.lastAnswered.keys.contains(where: { !current.contains($0) }) { activity.lastAnswered = activity.lastAnswered.filter { current.contains($0.key) } }
        if activity.rota.entries.contains(where: { !current.contains($0.responder) }) { activity.rota.keepOnly(current) }
        // An acknowledgement from someone since removed stops counting: the caller is told they are
        // waiting again, the call is resent, and responders are alerted again.
        if group != nil {
            for i in activity.outgoing.indices where activity.outgoing[i].acknowledgedBy.contains(where: { !current.contains($0) }) {
                activity.outgoing[i].revoke(keeping: current)
                // Someone told their call was seen may have put the phone down: say so plainly.
                if activity.outgoing[i].acknowledgedBy.isEmpty {
                    alerts.tellCaller(title: "Your call is going out again",
                                      body: "The person who saw it has left the group, so nobody has seen it now. If you need help now, call 999.")
                }
            }
            if activity.inbox.requests.values.contains(where: { $0.acknowledgedBy.contains { !current.contains($0) } }) {
                for k in activity.inbox.revoke(keeping: current) { scheduleAlerts(for: k) }
            }
        }
        let units = Set(group?.members.compactMap(\.unit) ?? [])
        if activity.checkInWatch.callers.keys.contains(where: { !units.contains($0) }) { activity.checkInWatch.keepOnly(units: units) }
        let listening = group?.listening(at: now()).map(\.channelSecret) ?? []
        if mesh.secrets != listening { mesh.secrets = listening }
        if budget == nil { bandChanged(mesh.radio?.band) }
        // A box already connected when the phone joins a group is announced now, not at the next
        // reconnect, so direct messages work both ways.
        if mesh.isReady, let me = saved?.me, let key = mesh.boxPublicKey, activity.boardKeys[me] != key {
            spawn { await self.boxReady() }
        }
        relay.configure(group: group, identity: identity)
        publishMembersIfDue()
        checkGaps()
    }

    /// The box's radio band changed (or a box was paired): start a budget only if its limit
    /// differs, so re-pairing or relaunching never gives a fresh allowance within the hour.
    public func bandChanged(_ band: Band?) {
        guard let band, budget?.dutyCycle != band.dutyCycle else { return }
        budget = AirtimeBudget(dutyCycle: band.dutyCycle)
    }

    /// The box's use of the radio in the last hour (IR 2030): shared by every group when one box
    /// serves several, otherwise this engine's own.
    private var budget: AirtimeBudget? {
        get { mesh.sharedAirtime?.budget ?? activity.airtime }
        set { if let shared = mesh.sharedAirtime { shared.budget = newValue } else { activity.airtime = newValue } }
    }

    func setAirtimeForTesting(_ b: AirtimeBudget) { budget = b }
    func resetMembershipRepeatForTesting() { lastMembershipRepeat = nil }

    // MARK: Calling for help

    /// The phone numbers its calls 1 to 32767 and a watch acting for it 32768 to 65535, so the
    /// two never give different calls the same number.
    private func nextRequestNumber() -> UInt16 {
        guard var s = saved else { return 0 }
        let low: UInt16 = companion ? 0x8000 : 1, high: UInt16 = companion ? 0xFFFF : 0x7FFF
        s.lastRequest = s.lastRequest >= low && s.lastRequest < high ? s.lastRequest + 1 : low
        saved = s
        store.save(s)
        return s.lastRequest
    }

    public var availableRoutes: Set<Route> {
        var s: Set<Route> = [.sms]
        if mesh.isReady { s.insert(.mesh) }
        if relay.isConfigured { s.insert(.internet) }
        return s
    }

    /// A press sends at once on every route that works without the caller's help (decision 8).
    /// Routes that are not available are shown as not sent, with the reason, so that a press with
    /// no route at all gives the cross at once.
    public func press(_ colour: Colour) {
        guard let unit = me?.unit else {
            // Removed from the group, or not a caller: say so with the cross, never nothing.
            guard saved != nil else { return }
            var r = OutgoingRequest(unit: 0, number: 0, colour: colour, createdAt: now())
            for route in [Route.mesh, .internet] { r.update(route, .failed("You are not a caller in this group")) }
            activity.outgoing.append(r)
            return
        }
        launch(OutgoingRequest(unit: unit, number: nextRequestNumber(), colour: colour, createdAt: now()))
    }

    /// On the phone: sends a call its watch made, under the watch's number, on the phone's own
    /// routes too. Responders hear one call however many ways it comes, and both devices hear its
    /// acknowledgement. Returns false if it is not this phone's caller's call.
    @discardableResult
    public func adopt(_ call: HelpFrame) -> Bool {
        guard !companion, case let .call(unit, number, colour, sentAt) = call, unit == me?.unit, number >= 0x8000 else { return false }
        if activity.outgoing.contains(where: { $0.unit == unit && $0.number == number }) { return true }
        launch(OutgoingRequest(unit: unit, number: number, colour: colour, createdAt: Date(timeIntervalSince1970: TimeInterval(sentAt))))
        return true
    }

    private func launch(_ request: OutgoingRequest) {
        var r = request
        let colour = r.colour
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        if !routes.contains(.mesh) { r.update(.mesh, .failed(mesh.unavailableReason)) }
        if !routes.contains(.internet) { r.update(.internet, .failed(relay.lastProblem ?? "Internet route not set up")) }
        for route in routes { r.update(route, .sending) }
        activity.outgoing.append(r)
        trimOutgoing()
        if colour == .green { activity.greens.append(r.createdAt) }
        let frame = r.callFrame
        for route in routes {
            spawn {
                let failure = route == .internet ? await self.relay.send(frame, wake: .call) : await self.send(frame, on: route, kind: .call)
                self.updateOutgoing(r, route, failure.map(RouteState.failed) ?? .sent)
            }
        }
    }

    /// Keeps the list short by dropping "I'm OK" calls and acknowledged ones, oldest first.
    /// A call nobody has acknowledged is never dropped: it keeps being sent.
    private func trimOutgoing() {
        while activity.outgoing.count > 50, let i = activity.outgoing.indices.dropLast().first(where: { i in
            let r = activity.outgoing[i]
            if case .seen = r.status { return true }
            return r.colour == .green || r.number == 0
        }) {
            activity.outgoing.remove(at: i)
        }
    }

    private func updateOutgoing(_ r: OutgoingRequest, _ route: Route, _ state: RouteState) {
        guard let i = activity.outgoing.firstIndex(where: { $0.number == r.number && $0.unit == r.unit }) else { return }
        activity.outgoing[i].update(route, state)
    }

    public func add(_ category: CallCategory) {
        guard var r = activity.outgoing.popLast() else { return }
        let frame = r.add(category)
        activity.outgoing.append(r)
        spawn { _ = await self.sendOptional(frame) }
    }

    /// Takes back a category pressed by mistake.
    public func withdraw(_ category: CallCategory) {
        guard var r = activity.outgoing.popLast() else { return }
        let frame = r.withdraw(category)
        activity.outgoing.append(r)
        if let frame { spawn { _ = await self.sendOptional(frame) } }
    }

    /// Typed text and position go only to responders (decision 12), sealed once for all of them;
    /// in a group made before responders had their own key, over the internet sealed with the
    /// group key, or else as direct messages to each responder's box.
    public var canSendPersonal: Bool { relay.isConfigured || mesh.isReady }

    public func addNote(_ text: String) -> String? {
        guard canSendPersonal else { return "Typed messages need the internet or your box." }
        guard var r = activity.outgoing.popLast() else { return nil }
        // Sealed and signed for responders, long text goes as several notes that each fit the radio.
        let frames = group?.secrets.responderPublicKey == nil ? [r.addNote(text)] : r.addNotes(text, pieceBytes: ForResponders.maxNoteBytes)
        activity.outgoing.append(r)
        spawn { for f in frames { await self.sendPersonal(f) } }
        return nil
    }

    public func sharePosition(latitude: Double, longitude: Double, accuracy: Double) {
        guard canSendPersonal, let r = current else { return }
        let frame = HelpFrame.position(unit: r.unit, request: r.number, latitudeE7: Int32(latitude * 1e7),
                                       longitudeE7: Int32(longitude * 1e7), accuracy: UInt16(clamping: Int(accuracy)))
        spawn { await self.sendPersonal(frame) }
    }

    /// Sealed once for all responders (decision 12) and sent once, over the internet or else on the
    /// group channel. A group made before responders had their own key falls back to a direct
    /// message to each responder's box.
    private func sendPersonal(_ frame: HelpFrame) async {
        if let g = group, let me = saved?.me, g.secrets.responderPublicKey != nil {
            for sealed in ForResponders.seal(frame, from: identity, as: me, in: g, at: now()) {
                if relay.isConfigured, await relay.send(sealed, wake: nil) == nil { continue }
                _ = await sendOnMesh(sealed, kind: .optional)
            }
            return
        }
        if relay.isConfigured, await relay.send(frame, wake: nil) == nil { return }
        await sendDirect(frame, to: nil)
    }

    /// Personal content as MeshCore direct messages to each responder's box (or one member's),
    /// which MeshCore encrypts to that box alone. Within the optional half of the airtime.
    private func sendDirect(_ frame: HelpFrame, to only: UInt16?) async {
        guard mesh.isReady, let text = MeshText.encode(frame), let radio = mesh.radio, radio.band != nil, budget != nil else { return }
        let seconds = radio.airtime(bytes: meshPacketBytes(payload: text.utf8.count + 8))
        for m in group?.members ?? [] where m.canRespond && m.number != saved?.me && (only == nil || m.number == only) {
            guard let key = activity.boardKeys[m.number], budget!.allows(seconds, kind: .optional, at: now()) else { continue }
            let reservation = budget!.record(seconds, at: now())
            if case .refused = await mesh.sendText(text, to: key) { budget?.cancel(reservation) }
        }
    }

    private func send(_ frame: HelpFrame, on route: Route, kind: AirtimeBudget.Kind) async -> String? {
        switch route {
        case .mesh: return await sendOnMesh(frame, kind: kind)
        case .internet: return await relay.send(frame, wake: nil)
        case .sms: return "Needs you to send it"
        }
    }

    /// Follow-ups, availability and notice acknowledgements use the internet when it works and the
    /// mesh only when it does not, to keep radio time for calls.
    private func sendOptional(_ frame: HelpFrame) async -> String? {
        if relay.isConfigured, await relay.send(frame, wake: nil) == nil { return nil }
        return await sendOnMesh(frame, kind: .optional)
    }

    /// Over the internet if it is set up, and over the mesh as well, so members without internet
    /// hear too. Optional airtime.
    private func sendToAll(_ frame: HelpFrame) async {
        if relay.isConfigured { _ = await relay.send(frame, wake: nil) }
        _ = await sendOnMesh(frame, kind: .optional)
    }

    private func sendOnMesh(_ frame: HelpFrame, kind: AirtimeBudget.Kind) async -> String? {
        // Personal content never goes on the shared group channel (decision 12).
        guard frame.mayGoOnGroupChannel else { return "Only goes over the internet" }
        guard mesh.isReady, let radio = mesh.radio else { return mesh.unavailableReason }
        guard radio.band != nil, budget != nil else { return "Box is on a frequency Help&I will not use" }
        let seconds = radio.airtime(bytes: meshPacketBytes(payload: frame.encoded().count)) * Double(mesh.channelsPerSend)
        guard budget!.allows(seconds, kind: kind, at: now()) else { return "Radio time used up for now" }
        // Reserve before sending, so overlapping sends cannot each see the same allowance. Give it
        // back only when the box certainly did not transmit.
        let reservation = budget!.record(seconds, at: now())
        let result = await mesh.send(frame, urgent: kind == .call)
        if case .refused = result { budget?.cancel(reservation) }
        return result.failure
    }

    // MARK: The box

    private func answerNewBoxesIfDue() async {
        guard !boxesToAnswer.isEmpty, now().timeIntervalSince(lastBoxAnswer ?? .distantPast) > 60,
              let mine = mesh.boxPublicKey, let me = saved?.me else { return }
        let members = boxesToAnswer
        boxesToAnswer = []
        answeredBoxes.formUnion(members)
        lastBoxAnswer = now()
        await sendToAll(.signedBoard(member: me, publicKey: mine, identity: identity, group: groupID))
        for m in members.sorted() { await shareCheckIns(to: m) }
    }

    /// Tells the group which box is this phone's, and adds the other members' boxes as contacts.
    public func boxReady() async {
        guard let myNumber = saved?.me, let key = mesh.boxPublicKey else { return }
        activity.boardKeys[myNumber] = key
        for (member, k) in activity.boardKeys where member != myNumber { await mesh.addContact(k, name: "Help&I \(member)") }
        await sendToAll(.signedBoard(member: myNumber, publicKey: key, identity: identity, group: groupID))
        await repeatMembershipIfDue()
    }

    // MARK: Time passing

    /// Runs every 15 seconds while the app runs, and whenever the box or relay wakes it.
    /// How long a phone waits to hear the first coordinator list it before saying so: the first
    /// coordinator repeats the member list daily, so two days covers a day away from the radio.
    public static let confirmationWait: TimeInterval = 2 * 86_400

    public func tick() {
        if !companion, let s = saved, !s.confirmed, let at = s.joinedAt, now().timeIntervalSince(at) > Self.confirmationWait { raise(.unconfirmed) }
        if actsAsCoordinator { spawn { await self.repeatMembershipIfDue() } }
        pruneInbox()
        publishMembersIfDue()
        if !boxesToAnswer.isEmpty { spawn { await self.answerNewBoxesIfDue() } }
        checkResends()
        // Repeat this caller's check-ins once a day, for responders who missed them.
        if !companion, var s = saved, s.checkInSince != nil, now().timeIntervalSince(s.checkInSharedAt ?? .distantPast) > 86_400 {
            s.checkInSharedAt = now()
            saved = s
            store.save(s)
            spawn { await self.shareCheckIns(to: nil) }
        }
        if !companion {
            checkMissedCheckIn()
            watchOthersCheckIns()
        }
        topUpAlerts()
        // Stop listening on the old channel once the changeover after a removal is over.
        let listening = group?.listening(at: now()).map(\.channelSecret) ?? []
        if mesh.secrets != listening { mesh.secrets = listening }
    }

    /// A coordinator's phone keeps the relay's member list current. A changed list goes at once,
    /// whatever else is happening, so a removal never waits. An unchanged one is repeated daily. If
    /// the relay cannot be reached, it tries again after a growing pause; if it refuses a list, that
    /// list is not tried again until it changes, so a refusal cannot use up the free allowance.
    private func publishMembersIfDue() {
        guard actsAsCoordinator, relay.isConfigured, let g = group else { return }
        let list = RelayProtocol.memberList(g)
        let t = now()
        let changed = list != publishedList
        if list == refusedList { return }
        let due = changed ? t.timeIntervalSince(lastPublishTry ?? .distantPast) >= publishBackoff || lastTriedList != list
            : t.timeIntervalSince(publishedAt ?? .distantPast) > 86_400
        guard due else { return }
        lastPublishTry = t
        lastTriedList = list
        spawn {
            switch await self.relay.publishMembers() {
            case .accepted:
                // Only the list that was sent counts as published; a change made meanwhile still goes.
                self.publishedList = list; self.publishedAt = self.now(); self.publishBackoff = 60
                self.publishMembersIfDue()
            case .refused:
                self.refusedList = list
            case .unreachable:
                self.publishBackoff = min(self.publishBackoff * 2, 1800)
            }
        }
    }

    private var lastTriedList: RelayProtocol.MemberList?

    /// A coordinator repeats who is in the group, at most once a day, for members who missed it; and
    /// the first coordinator's repeat is what confirms people other coordinators invited. Runs from
    /// the box connecting and from every tick, so it happens with no box too.
    private func repeatMembershipIfDue() async {
        guard actsAsCoordinator, let myNumber = saved?.me, let g = group,
              now().timeIntervalSince(lastMembershipRepeat ?? .distantPast) > 86_400, mesh.isReady || relay.isConfigured else { return }
        lastMembershipRepeat = now()
        // The settings too, for members who missed them.
        if g.settingsVersion > 0, let f = g.settingsFrame(as: myNumber, identity: identity) { _ = await sendOptional(f) }
        for m in g.members where m.number != myNumber {
            if let f = g.addedFrame(m.number) { await sendToAll(.signing(f, as: myNumber, identity: identity, group: groupID)) }
            if m.role == .coordinator, let f = g.roleFrame(m.number) { await sendToAll(.signing(f, as: myNumber, identity: identity, group: groupID)) }
        }
        // Removals too, so a phone that missed one stops counting that member's acknowledgements.
        if myNumber == g.primaryCoordinator {
            for n in g.removedMembers.sorted() {
                await sendToAll(.signing(.memberRemoved(member: n, version: g.membershipVersion), as: myNumber, identity: identity, group: groupID))
            }
        }
    }

    /// Drops "I'm OK" calls and acknowledged requests after a week. A request nobody has
    /// acknowledged stays, however old.
    private func pruneInbox() {
        let cutoff = now().addingTimeInterval(-7 * 86_400)
        let stale = activity.inbox.requests.values.filter { r in
            (r.isAcknowledged || r.colour == .green) && r.firstHeardAt < cutoff
        }.map(\.key)
        guard !stale.isEmpty else { return }
        activity.inbox.remove(stale)
        for k in stale { activity.alertedGreens.remove(k) }
    }

    /// Sends every call nobody has acknowledged yet again (see `Resend`), not only the latest, so a
    /// later press never strands an earlier one. A route that failed before is tried again, so a
    /// box that comes back in range still gets the call out.
    private func checkResends() {
        let t = now()
        for i in activity.outgoing.indices where activity.outgoing[i].unit != 0 && activity.outgoing[i].resendDue(at: t) {
            activity.outgoing[i].markResent(at: t)
            let r = activity.outgoing[i]
            for route in RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false) {
                // The first time a call reaches the relay, ask it to wake the others, even if that is
                // on a resend because the internet came back.
                let firstOnInternet = route == .internet && r.routes[.internet] != .sent
                spawn {
                    // Resends count as optional airtime, so they never use up what a new press needs.
                    let failure = firstOnInternet ? await self.relay.send(r.callFrame, wake: .call)
                        : await self.send(r.callFrame, on: route, kind: .optional)
                    if failure == nil { self.updateOutgoing(r, route, .sent) }
                }
            }
        }
    }

    // MARK: Receiving

    /// A direct message counts only if it came from the box of the member whose unit it names.
    public func receiveText(from prefix: Data, _ text: String) {
        if case let .checkIns(unit, _, _, _)? = MeshText.decode(text) {
            guard let sender = group?.member(unit: unit), unit != me?.unit, let key = activity.boardKeys[sender.number],
                  key.prefix(6) == prefix else { return }
            activity.checkInWatch.apply(MeshText.decode(text)!)
            return
        }
        guard let frame = MeshText.decode(text) else { return }
        let unit: UInt32
        switch frame {
        case let .note(u, _, _, _), let .position(u, _, _, _, _), let .checkIns(u, _, _, _): unit = u
        default: return
        }
        guard let sender = group?.member(unit: unit), let key = activity.boardKeys[sender.number], key.prefix(6) == prefix else { return }
        receive(frame, via: .mesh)
    }

    public func receive(_ frame: HelpFrame, via route: Route) {
        switch frame {
        case let .ack(unit, request, who, at, _):
            // Only a current responder's own signature counts (decision 6, AGENTS.md).
            guard group?.acceptsAck(frame) == true else { return }
            activity.lastAnswered[who] = max(activity.lastAnswered[who] ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(at)))
            if let i = activity.outgoing.firstIndex(where: { $0.unit == unit && $0.number == request }) {
                activity.outgoing[i].receive(frame)
            }
        case .availability, .noticeAck, .memberAdded, .memberRemoved, .memberName, .memberRole, .memberPhone:
            // Counted only when signed (below), so a removed phone cannot fake them.
            return
        case let .signed(signer, _, _):
            guard let sender = group?.member(signer), let inner = frame.verifiedInner(signedBy: sender.signingKey, group: groupID) else { return }
            switch inner {
            case let .noticeAck(notice, by, at):
                // An old acknowledgement, replayed, must not clear a newer notice.
                if sender.role == .coordinator, let raised = activity.notices[notice]?.raisedAt,
                   TimeInterval(at) >= raised.timeIntervalSince1970 - OutgoingRequest.clockAllowance {
                    activity.notices[notice]?.acknowledge(by: by)
                }
            case .availability:
                if sender.canRespond { activity.rota.apply(inner); checkGaps() }
            case let .checkIns(unit, _, _, _):
                if sender.unit == unit, unit != me?.unit { activity.checkInWatch.apply(inner) }
            case let .memberAdded(n, _, _, _, _, _) where n == saved?.me && signer == group?.primaryCoordinator:
                // The first coordinator lists this phone: the whole group knows it is in.
                if var s = saved, !s.confirmed { s.confirmed = true; saved = s; store.save(s); activity.notices[.unconfirmed] = nil }
            case .memberAdded, .memberRemoved, .memberName, .memberRole, .memberPhone:
                // Any coordinator can add people; only the first can remove people or change roles,
                // so the group can never be split onto different keys or numbers.
                let allowed: Bool
                switch inner {
                case .memberRemoved, .memberRole: allowed = signer == group?.primaryCoordinator
                // Members keep their own number up to date.
                case let .memberPhone(n, _, _): allowed = signer == n || sender.role == .coordinator
                default: allowed = sender.role == .coordinator
                }
                // Nothing changes, nothing is redone.
                if allowed, signer != saved?.me, var s = saved {
                    let before = s.group
                    s.group.apply(membership: inner, at: now())
                    if s.group != before { setState(s) }
                    // The coordinator who invited this phone has gone before it was confirmed.
                    if case let .memberRemoved(n, _) = inner, n == s.invitedBy, !s.confirmed { raise(.inviterLeft) }
                    // The first coordinator lists at once anyone it hears another coordinator add, so
                    // they are confirmed without waiting for the daily repeat.
                    if case let .memberAdded(n, _, _, _, _, _) = inner, isPrimaryCoordinator, !companion, let f = group?.addedFrame(n), let me = saved?.me {
                        let signed = HelpFrame.signing(f, as: me, identity: identity, group: groupID)
                        spawn { await self.sendToAll(signed) }
                    }
                }
            default: break
            }
            return
        case .groupSettings:
            guard var s = saved, s.group.apply(settings: frame) else { return }
            setState(s)
            return
        case .forResponders:
            // Only a responder can open it; what is inside is handled as if it came plainly.
            guard me?.canRespond == true, let g = group, let inner = ForResponders.open(frame, in: g, at: now()) else { return }
            receive(inner, via: route)
            return
        case let .board(member, key, _):
            // A watch has no box: other members' boxes are the phone's business.
            guard !companion, member != saved?.me, frame.isValidBoard(signedBy: group?.member(member)?.signingKey, group: groupID),
                  activity.boardKeys[member] != key else { return }
            activity.boardKeys[member] = key
            spawn {
                await self.mesh.addContact(key, name: "Help&I \(member)")
                // A box this phone has not heard before may not know this phone's box either (it
                // joined later): answer with ours, then tell it our check-ins. One answer a minute
                // covers every new box, so an answer due inside the minute waits for it, not lost.
                if !self.answeredBoxes.contains(member) { self.boxesToAnswer.insert(member) }
                await self.answerNewBoxesIfDue()
            }
            return
        case .checkIns:
            // Counted only signed by the caller (below) or as a direct message from their box.
            return
        case let .call(unit, _, _, _), let .followUp(unit, _, _, _), let .note(unit, _, _, _), let .position(unit, _, _, _, _):
            // A phone never alerts for its own calls, however they come back to it.
            if unit == me?.unit { return }
            activity.checkInWatch.apply(frame)
            if case .followUp(_, _, _, .missedCheckIn) = frame { activity.checkInWatch.heardRaised(unit: unit, at: now(), calendar: calendar) }
        }
        guard me?.canRespond == true else { return }
        switch activity.inbox.receive(frame, via: route, at: now()) {
        case let .new(key): scheduleAlerts(for: key)
        case let .updated(key) where activity.inbox.requests[key]?.isAcknowledged == true: alerts.cancel(key)
        case .duplicate:
            // The caller is still sending, so it has not heard an acknowledgement. Pass on the
            // signed acknowledgements this phone has, its own or another responder's.
            if case let .call(unit, request, _, _) = frame { reAck(IncomingRequest.Key(unit: unit, request: request)) }
        default: break
        }
        tick()
    }

    /// The phone that acknowledged repeats its ack at most every 25 seconds; others pass one on
    /// at most every five minutes, so a crowd of phones does not fill the radio.
    private func reAck(_ key: IncomingRequest.Key) {
        guard let me = saved?.me, let r = activity.inbox.requests[key], let any = r.acks.values.first else { return }
        let mine = r.acks[me]
        guard now().timeIntervalSince(lastReAck[key] ?? .distantPast) >= (mine != nil ? 25 : 300) else { return }
        lastReAck[key] = now()
        let frame = mine ?? any
        spawn { await self.sendToAll(frame) }
    }

    // MARK: Responding

    /// Returns whether an acknowledgement was made.
    @discardableResult
    public func acknowledge(_ key: IncomingRequest.Key) -> Bool {
        guard me?.canRespond == true, let me = saved?.me,
              let frame = activity.inbox.acknowledge(key, by: me, at: now(), identity: identity, group: groupID) else { return false }
        activity.lastAnswered[me] = now()
        alerts.cancel(key)
        sendAck(frame, for: key)
        return true
    }

    public func retryAck(_ key: IncomingRequest.Key) {
        guard let me = saved?.me else { return }
        sendAck(.signedAck(unit: key.unit, request: key.request, responder: me, at: now(), identity: identity, group: groupID), for: key)
    }

    private func sendAck(_ frame: HelpFrame, for key: IncomingRequest.Key) {
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        ackSends[key] = Dictionary(uniqueKeysWithValues: routes.map { ($0, RouteState.sending) })
        if routes.isEmpty { ackSends[key] = [.mesh: .failed(mesh.unavailableReason)] }
        // Results from an earlier attempt must not overwrite this one's.
        let attempt = UUID()
        ackAttempt[key] = attempt
        for route in routes {
            spawn {
                let failure = route == .internet ? await self.relay.send(frame, wake: .quiet) : await self.send(frame, on: route, kind: .call)
                guard self.ackAttempt[key] == attempt else { return }
                self.ackSends[key]?[route] = failure.map(RouteState.failed) ?? .sent
            }
        }
    }

    /// What the responder is told about their own acknowledgement.
    public func ackSendStatus(_ key: IncomingRequest.Key) -> CallerStatus? {
        guard let s = ackSends[key] else { return nil }
        if s.values.contains(.sent) { return .waitingForResponder }
        if s.values.contains(.sending) { return .sending }
        return .notSent
    }

    public func escalation(for r: IncomingRequest) -> Escalation? {
        guard let group else { return nil }
        let at = r.sentAt ?? r.firstHeardAt
        let responders = group.members.filter { $0.canRespond && $0.unit != r.key.unit }.map {
            ResponderInfo(member: $0.number, availableNow: activity.rota.isAvailable($0.number, at: at), lastAnsweredAt: activity.lastAnswered[$0.number])
        }
        return Escalation(colour: r.colour ?? .red, responders: responders, policy: group.escalationPolicy)
    }

    /// Every phone works out the order from the same group, rota and record of who answered, and
    /// alerts its own person from their turn, counted from when the caller pressed, until someone
    /// acknowledges.
    private func scheduleAlerts(for key: IncomingRequest.Key) {
        guard let r = activity.inbox.requests[key], !r.isAcknowledged, let e = escalation(for: r), let me = saved?.me else { return }
        let turn = TimeInterval(e.order.firstIndex(of: me) ?? e.order.count) * e.interval
        let turnAt = (r.sentAt ?? r.firstHeardAt).addingTimeInterval(turn)
        // "I'm OK" asks for no one: tell them once, calmly, and never again.
        if r.colour == .green {
            guard !activity.alertedGreens.contains(key) else { return }
            activity.alertedGreens.insert(key)
        }
        // iOS keeps at most 64 pending notifications per app: up to four go to check-in reminders,
        // the rest are shared between open requests. A long tail keeps alerting with the app asleep.
        let open = max(activity.inbox.requests.values.filter { !$0.isAcknowledged && $0.colour != .green }.count, 1)
        let count = max(3, 58 / open)
        let t = now()
        let times: [Date]
        switch r.colour {
        case .green?: times = [max(turnAt, t)]
        case .amber?: times = alertTimes(turnAt: turnAt, every: 300, quick: 6, later: 1800, from: t, count: count)
        default: times = alertTimes(turnAt: turnAt, every: 60, quick: 10, later: 600, from: t, count: count)
        }
        let who = name(ofUnit: key.unit)
        var title = "\(who): \(ButtonWords.words(r.colour ?? .red, in: group))"
        if key.request == 0 { title = "\(who) missed a check-in" }
        alerts.schedule(Alert(key: key, title: title, body: "Open Help&I to acknowledge.", calm: r.colour == .green, times: times))
    }

    /// Re-schedules each open request's alerts from now, so they keep coming however long it takes.
    private func topUpAlerts() {
        for r in activity.inbox.requests.values where !r.isAcknowledged && r.colour != .green {
            guard now().timeIntervalSince(lastTopUp[r.key] ?? .distantPast) > 120 else { continue }
            lastTopUp[r.key] = now()
            scheduleAlerts(for: r.key)
        }
    }

    // MARK: Rota and notices

    public func setAvailable(_ available: Bool, hours: Double = 12) {
        guard let me = saved?.me else { return }
        let from = now(), until = from.addingTimeInterval(hours * 3600)
        activity.rota.add(responder: me, from: from, until: until, available: available)
        checkGaps()
        let frame = HelpFrame.availability(responder: me, from: UInt32(from.timeIntervalSince1970),
                                           until: UInt32(until.timeIntervalSince1970), available: available)
        let signed = HelpFrame.signing(frame, as: me, identity: identity, group: groupID)
        spawn { _ = await self.sendOptional(signed) }
    }

    public var gaps: [DateInterval] { activity.rota.gaps(from: now()) }

    /// Every phone works out gaps for itself, so the coordinator hears with no network at all.
    private func checkGaps() {
        guard !companion else { return }
        if group != nil, !gaps.isEmpty { raise(.rotaGap) } else if activity.notices[.rotaGap] != nil { activity.notices[.rotaGap] = nil }
    }

    public func raise(_ notice: Notice) {
        guard activity.notices[notice] == nil else { return }
        activity.notices[notice] = CoordinatorAlert(raisedAt: now())
    }

    /// Whether this phone should be showing the notice now.
    public func showing(_ notice: Notice) -> Bool {
        guard let a = notices[notice], let me else { return false }
        if notice == .unconfirmed || notice == .inviterLeft { return a.acknowledgedBy == nil }
        switch a.audience(at: now()) {
        case .firstCoordinator?: return me.role == .coordinator && group?.members.first(where: { $0.role == .coordinator })?.number == me.number
        case .allCoordinators?: return me.role == .coordinator
        case .wholeGroup?: return true
        case nil: return false
        }
    }

    public func acknowledge(_ notice: Notice) {
        guard let me = saved?.me else { return }
        activity.notices[notice]?.acknowledge(by: me)
        let frame = HelpFrame.signing(.noticeAck(notice: notice, by: me, at: UInt32(now().timeIntervalSince1970)), as: me,
                                      identity: identity, group: groupID)
        spawn { _ = await self.sendOptional(frame) }
    }

    /// Makes a member a coordinator too, so the group does not depend on one person.
    /// Takes in a key update from the first coordinator. The keys come from the update; who is in
    /// the group is merged, so a member another coordinator added that the first had not yet heard
    /// of is kept, unless the update says they were removed.
    public func applyKeyUpdate(_ update: GroupState) {
        guard let current = group else { return }
        var merged = update
        for m in current.members where merged.member(m.number) == nil && !update.removedMembers.contains(m.number) {
            merged.members.append(m)
        }
        merged.removedMembers.formUnion(current.removedMembers)
        merged.members.removeAll { merged.removedMembers.contains($0.number) }
        merged.membershipVersion = max(update.membershipVersion, current.membershipVersion)
        merged.highestMember = max(update.highestMember, current.highestMember)
        for (n, v) in current.roleVersions where v > (merged.roleVersions[n] ?? 0) {
            merged.roleVersions[n] = v
            if let i = merged.members.firstIndex(where: { $0.number == n }), let mine = current.member(n) {
                merged.members[i].role = mine.role
                merged.members[i].block = mine.block
            }
        }
        if merged.relayURL == nil { merged.relayURL = current.relayURL }
        updateGroup { $0 = merged }
    }

    /// Only the first coordinator makes new coordinators.
    public func promote(_ number: UInt16) {
        guard saved?.me == group?.primaryCoordinator else { return }
        updateGroup { _ = $0.promote(number) }
    }

    /// Only the first coordinator removes people: a removal changes the group's keys.
    public func removeMember(_ number: UInt16) {
        guard saved?.me == group?.primaryCoordinator, number != saved?.me else { return }
        previousBlocks[number] = group?.member(number)?.block
        updateGroup { $0.remove(number, at: now()) }
    }

    public var isPrimaryCoordinator: Bool { saved?.me != nil && saved?.me == group?.primaryCoordinator }

    /// A watch never speaks for the group as its coordinator: the phone does.
    private var actsAsCoordinator: Bool { !companion && me?.role == .coordinator }

    public func setRelay(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        updateGroup { $0.relayURL = trimmed.isEmpty ? nil : trimmed }
    }

    // MARK: Check-ins (decision 16)

    public var checkIn: CheckInSchedule? { saved?.checkIn }

    /// Off unless the caller turns it on. Reminders come as notifications at each time.
    public func setCheckIn(_ schedule: CheckInSchedule?) {
        guard var s = saved else { return }
        s.checkIn = schedule
        s.checkInSince = schedule == nil ? nil : now()
        saved = s
        store.save(s)
        alerts.setCheckInReminders(schedule?.times ?? [])
        s.checkInSharedAt = now()
        saved = s
        store.save(s)
        spawn { await self.shareCheckIns(to: nil, evenIfOff: true) }
    }

    /// Tells responders this caller's check-ins, so their phones notice a missed one even if this
    /// phone is flat. A routine is personal: over the internet sealed with the group key, and as
    /// direct messages to each responder's box, never on the group channel.
    private func shareCheckIns(to only: UInt16?, evenIfOff: Bool = false) async {
        guard let unit = me?.unit, let s = saved, s.checkInSince != nil || evenIfOff else { return }
        let frame = HelpFrame.checkIns(unit: unit, since: UInt32((s.checkInSince ?? now()).timeIntervalSince1970),
                                       grace: UInt16((s.checkIn?.grace ?? 1800) / 60), times: (s.checkIn?.times ?? []).map { UInt16($0) })
        // Signed over the internet, where anyone with the group key could otherwise set or clear
        // someone else's check-ins; the direct message is tied to this phone's box instead.
        if only == nil, relay.isConfigured, let me = saved?.me {
            _ = await relay.send(.signing(frame, as: me, identity: identity, group: groupID), wake: nil)
        }
        await sendDirect(frame, to: only)
    }

    /// A missed check-in raises an amber request, once per missed time, unless a red or amber call
    /// is already waiting for a responder: that one matters more and must stay on screen.
    private func checkMissedCheckIn() {
        guard var s = saved, let schedule = s.checkIn, let since = s.checkInSince, me?.canCall == true else { return }
        let t = now()
        let waiting = activity.outgoing.contains { r in
            if case .seen = r.status { return false }
            return r.colour != .green && t.timeIntervalSince(r.createdAt) < 86_400
        }
        guard !waiting, let missed = schedule.missed(greens: activity.greens, since: since, now: t, calendar: calendar),
              (s.checkInRaised ?? .distantPast) < missed else { return }
        s.checkInRaised = missed
        saved = s
        store.save(s)
        press(.amber)
        add(.missedCheckIn)
    }

    /// Raises another caller's missed check-in on this phone, if their own phone has not. The
    /// request is numbered 0, which callers never use, and needs a person to acknowledge it.
    private func watchOthersCheckIns() {
        guard me?.canRespond == true else { return }
        for (unit, missed) in activity.checkInWatch.due(at: now(), calendar: calendar) {
            let at = UInt32(missed.timeIntervalSince1970)
            if case let .new(key) = activity.inbox.receive(.call(unit: unit, request: 0, colour: .amber, sentAt: at), via: .internet, at: now()) {
                activity.inbox.receive(.followUp(unit: unit, request: 0, part: 1, category: .missedCheckIn), via: .internet, at: now())
                scheduleAlerts(for: key)
            }
        }
    }
}

extension SavedState {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decode(GroupState.self, forKey: .group)
        me = try c.decode(UInt16.self, forKey: .me)
        lastRequest = try c.value(.lastRequest, or: 0)
        checkIn = try c.decodeIfPresent(CheckInSchedule.self, forKey: .checkIn)
        checkInSince = try c.decodeIfPresent(Date.self, forKey: .checkInSince)
        checkInRaised = try c.decodeIfPresent(Date.self, forKey: .checkInRaised)
        checkInSharedAt = try c.decodeIfPresent(Date.self, forKey: .checkInSharedAt)
        invitedBy = try c.decodeIfPresent(UInt16.self, forKey: .invitedBy)
        confirmed = try c.value(.confirmed, or: true)
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
    }
}

extension Activity {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outgoing = try c.value(.outgoing, or: [])
        inbox = try c.value(.inbox, or: ResponderInbox())
        rota = try c.value(.rota, or: Rota())
        lastAnswered = try c.value(.lastAnswered, or: [:])
        greens = try c.value(.greens, or: [])
        airtime = try c.decodeIfPresent(AirtimeBudget.self, forKey: .airtime)
        checkInWatch = try c.value(.checkInWatch, or: CheckInWatch())
        boardKeys = try c.value(.boardKeys, or: [:])
        notices = try c.value(.notices, or: [:])
        alertedGreens = try c.value(.alertedGreens, or: [])
    }
}
