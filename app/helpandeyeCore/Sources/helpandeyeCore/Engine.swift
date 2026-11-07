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
    /// Tells a Help&I box taken out of the group to leave it and clear what it holds (0x75).
    func tellBoxToForget() async
}

extension MeshLink {
    public var sharedAirtime: AirtimeLedger? { nil }
    public func tellBoxToForget() async {}
}

public enum RelayWake: String, Sendable { case call, quiet }

public enum PublishResult: Equatable, Sendable {
    case accepted
    /// The relay said no; trying the same list again will not help.
    case refused
    /// Not yet: the group's first coordinator has not registered it, so another coordinator's list
    /// is turned away for now. Worth trying again later, unchanged.
    case notYet
    /// No answer; worth trying again later.
    case unreachable
}

/// The internet route.
@MainActor public protocol RelayLink: AnyObject {
    var isConfigured: Bool { get }
    var lastProblem: String? { get }
    func configure(group: GroupState?, identity: DeviceIdentity)
    func publishMembers() async -> PublishResult
    /// Sends this member list in place of the group's own, as a coordinator taking over asks the
    /// relay before they do (decision 20).
    func publish(_ list: RelayProtocol.MemberList) async -> PublishResult
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
    /// On the phone: the highest number of a call its watch made, handed to the watch so a new or
    /// erased one carries on above it rather than reuse a number.
    public var lastWatchRequest: UInt16 = 0
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
    /// This person's own choices for the settings their profile lets them change, and which
    /// settings they have chosen for themselves.
    public var own: Profile?
    public var ownChosen: Set<Profile.Setting> = []
    /// When this phone last had something signed by the first coordinator (decision 20): the
    /// member list they repeat daily, an acknowledgement, their box. Seven days without, and one
    /// other coordinator alone may take over.
    public var primaryHeardAt: Date?

    public init(group: GroupState, me: UInt16) { self.group = group; self.me = me }

    /// The settings that apply to this person now: their profile, with their own choices where
    /// it lets them choose.
    public var profile: Profile { group.profile(of: me).applying(own, chosen: ownChosen) }
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
    /// On a coordinator's phone: the group's log, and the latest settings change, which is shown
    /// to them even with the log off.
    public var log = GroupLog()
    public var lastSettingsChange: GroupLog.Entry?
    /// On a coordinator's phone: people's requests to change their settings, until dealt with.
    public var changeRequests: [ChangeRequest] = []
    /// Closes this phone sent, repeated a few times like I'm OK, so a phone that missed one does
    /// not go on alerting.
    public var closeRepeats: [CloseRepeat] = []
    /// When the first coordinator last repeated the member list, kept so a relaunch does not
    /// repeat it again within the day and use up radio time.
    public var lastMembershipRepeat: Date?
    /// On a coordinator's phone: other coordinators' signed agreement that this phone may take
    /// over from the first coordinator, by signer (decision 20); and whom this phone has agreed to.
    public var takeoverConsents: [UInt16: Data] = [:]
    public var takeoverAgreed: Set<UInt16> = []
    /// The signing key the relay last said owns the group, and takeovers heard that this phone
    /// does not follow, or not yet: a rival to the one it follows, or one the relay may yet take.
    /// Two coordinators taking over at once settle on one by these (`GroupState.prefers`).
    public var relayOwner: Data?
    public var heardTakeovers: [Takeover] = []
    /// The coordinator whose takeover was followed in place of this phone's own, until this phone
    /// has their update code.
    public var tookOverFirst: UInt16?
    /// The household's Help&I box when this phone left the group it is set up for, told to
    /// forget that group once this phone is in another that does not have it.
    public var leftGroupBox: Data?

    public init() {}
}

public struct CloseRepeat: Codable, Equatable, Sendable {
    public let call: IncomingRequest.Key
    /// Off the air: a coordinator's reason, sealed for responders, or the close with its reason in
    /// a group made before responders had their own key; otherwise the close itself. On the air:
    /// the close without a reason.
    public let full: HelpFrame
    public let onAir: HelpFrame
    public let at: Date
    public internal(set) var resends = 0
}

@MainActor
public final class HelpEngine: ObservableObject {
    @Published public private(set) var saved: SavedState?
    @Published public private(set) var activity: Activity { didSet { store.save(activity) } }
    /// Notices a coordinator must acknowledge. Each phone widens its own copy until it hears an
    /// acknowledgement (app spec, "The relay's daily allowance" and "Rota gaps").
    public var notices: [Notice: CoordinatorAlert] { activity.notices }
    /// Whether this responder's own acknowledgements went out.
    @Published public private(set) var ackSends: [IncomingRequest.Key: [Route: RouteState]] = [:]
    /// Why a coordinator's last change to the group's settings was not made.
    @Published public private(set) var settingsProblem: String?
    /// While a coordinator taking over alone asks the relay first, and why it did not happen.
    @Published public private(set) var askingRelayToTakeOver = false
    @Published public private(set) var takeoverProblem: String?

    public let identity: DeviceIdentity
    public let mesh: MeshLink
    public let relay: RelayLink
    public let homeWiFi: LocalLink
    let alerts: AlertScheduler
    let store: EngineStore
    let now: () -> Date
    let calendar: Calendar

    private var lastReAck: [IncomingRequest.Key: Date] = [:]
    private var lastTopUp: [IncomingRequest.Key: Date] = [:]
    private var ackAttempt: [IncomingRequest.Key: UUID] = [:]
    private var lastMembershipRepeat: Date? {
        get { activity.lastMembershipRepeat }
        set { activity.lastMembershipRepeat = newValue }
    }
    private var answeredBoxes: Set<UInt16> = []
    /// The removed Help&I box this phone last told to forget the group, so a group change does not
    /// tell it again; connecting to it again does.
    private var forgottenBox: Data?
    private var boxesToAnswer: Set<UInt16> = []
    /// Number blocks of coordinators just removed, to re-list the people they added.
    private var previousBlocks: [UInt16: UInt16] = [:]
    /// The member list the relay last took from this phone, and when; and the last attempt.
    private var publishedList: RelayProtocol.MemberList?
    private var publishedAt: Date?
    private var refusedList: RelayProtocol.MemberList?
    /// The pass the refused list was sent with: a new pass is reason to send the list again.
    private var refusedPass: String?
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
                companion: Bool = false, homeWiFi: LocalLink? = nil) {
        self.identity = identity; self.mesh = mesh; self.relay = relay; self.alerts = alerts; self.store = store
        self.homeWiFi = homeWiFi ?? NoLocalLink()
        self.saved = saved; self.activity = activity; self.calendar = calendar; self.now = now; self.companion = companion
        applyGroup()
    }

    public var group: GroupState? { saved?.group }
    private var groupID: Data { group?.secrets.groupID ?? Data() }
    public var me: Member? { saved.flatMap { $0.group.member($0.me) } }
    /// This phone's own latest call; the household's box's calls are kept apart (`fromBox`).
    public var current: OutgoingRequest? { activity.outgoing.last { !$0.fromBox } }

    public func name(ofUnit unit: UInt32) -> String { group?.member(unit: unit)?.name ?? "Unit \(unit)" }
    public func name(ofMember n: UInt16) -> String { n == saved?.me ? "You" : (group?.member(n)?.name ?? "Responder \(n)") }

    /// The unit of the Help&I box this phone is connected to, when the box is in this member's
    /// home: the household's own, so its calls are never alerted for here and the phone carries
    /// them (firmware/DESIGN.md, section 4). Nil for anyone else's box, even one this phone added
    /// or set up: a coordinator who responds must still be alerted for its calls.
    public var householdBoxUnit: UInt32? {
        guard let g = group, let me, let box = g.boxMember(key: mesh.boxPublicKey), g.box(box, isHomeOf: me) else { return nil }
        return box.unit
    }
    private func isHousehold(_ unit: UInt32) -> Bool {
        guard let me else { return false }
        // A watch is never connected to the box: its owner's phone carries the box's calls, and
        // the escalation order leaves them out, so the watch goes by the group alone.
        return unit == me.unit || unit == householdBoxUnit || (companion && group?.isHousehold(me, ofUnit: unit) == true)
    }

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

    public func createGroup(name: String, myName: String, call: Bool, phone: String? = nil, relay: String? = nil) {
        var g = GroupState(name: name, secrets: .forOwner(signingKey: identity.signingPublicKey), members: [])
        g.relayURL = relay
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
        s.primaryHeardAt = now()
        setState(s)
        followProfileCheckIns()
    }

    /// Changes the group. On a coordinator's phone, everyone is told who joined or left, signed,
    /// so their acknowledgements count (or stop counting) on every phone at once.
    public func updateGroup(_ change: (inout GroupState) -> Void) { changeGroup(edit: true, change) }

    /// `edit` is false for settings taken in from elsewhere (a key update), which are not this
    /// coordinator's own change, so are not sent out again as a newer version.
    private func changeGroup(edit: Bool, _ change: (inout GroupState) -> Void) {
        guard var s = saved else { return }
        let old = s.group
        let before = Set(s.group.members.map(\.number))
        change(&s.group)
        // Changed settings go to every member at once, under a newer version.
        let settingsChanged = edit && actsAsCoordinator && s.group.settings != old.settings
        if settingsChanged { s.group.settingsVersion = old.settingsVersion + 1; s.group.settingsSigner = s.me }
        if settingsChanged {
            // Settings that cannot go to every member are not kept, so no one is told they went.
            guard s.group.settingsFrame(as: s.me, identity: identity) != nil else {
                settingsProblem = "That is too much to send to everyone. Use shorter words, or fewer profiles."
                return
            }
            settingsProblem = nil
        }
        let relayMoved = settingsChanged && s.group.relayURL != old.relayURL
        if relayMoved {
            // Members still look at the old relay address, so the new one goes there first; only
            // then does this phone move, and register the group afresh at the new address.
            saved = s
            store.save(s)
            publishedList = nil; publishedAt = nil; refusedList = nil; lastTriedList = nil; publishBackoff = 60
            publishRound += 1
        } else {
            setState(s)
        }
        followProfileCheckIns()
        guard actsAsCoordinator else { return }
        if settingsChanged { logSettings(by: s.me, s.group.settings.changes(from: old.settings), old: old.settings) }
        let frame = settingsChanged ? s.group.settingsFrame(as: s.me, identity: identity) : nil
        let gid = groupID
        if relayMoved {
            spawn {
                if let frame { _ = await self.sendOnInternet(frame, in: gid) }
                self.applyGroup()
                if let frame { _ = await self.sendOptional(frame, in: gid) }
            }
        } else if let frame {
            spawn { _ = await self.sendOptional(frame, in: gid) }
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
            + (removed.isEmpty ? [] : [g.changeoverFrame(at: now())].compactMap { $0 })
            + roles.sorted().compactMap { g.roleFrame($0) }
        for f in frames {
            let signed = HelpFrame.signing(f, as: me, identity: identity, group: gid)
            spawn { await self.sendToAll(signed, in: gid) }
        }
        // Names are personal, so they go over the internet and home Wi-Fi only.
        for n in added.sorted() {
            guard let m = g.member(n) else { continue }
            let signed = HelpFrame.signing(.memberName(member: n, name: m.name), as: me, identity: identity, group: gid)
            spawn { _ = await self.sendOffAir(signed, in: gid) }
            if let phone = m.phone {
                let at = g.phoneVersions[n] ?? UInt32(now().timeIntervalSince1970)
                let signed = HelpFrame.signing(.memberPhone(member: n, phone: phone, at: at), as: me, identity: identity, group: gid)
                spawn { _ = await self.sendOffAir(signed, in: gid) }
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
        let gid = groupID
        let signed = HelpFrame.signing(.memberPhone(member: s.me, phone: number, at: at), as: s.me, identity: identity, group: gid)
        spawn { _ = await self.sendOffAir(signed, in: gid) }
    }

    public func leave() {
        let box = householdBoxUnit != nil ? mesh.boxPublicKey : activity.leftGroupBox
        setState(nil)
        // The radio's record of the last hour belongs to the box, not the group: keep it.
        var fresh = Activity()
        fresh.airtime = activity.airtime
        fresh.leftGroupBox = box
        activity = fresh
        // What this phone remembers of the group's boxes, member lists and acknowledgements is by
        // member number and call, which mean other people in the next group.
        answeredBoxes = []; boxesToAnswer = []; lastBoxAnswer = nil; previousBlocks = [:]; forgottenBox = nil
        publishedList = nil; publishedAt = nil; refusedList = nil; refusedPass = nil; lastPublishTry = nil; publishBackoff = 60
        lastReAck = [:]; lastTopUp = [:]; ackAttempt = [:]; ackSends = [:]
        settingsProblem = nil; takeoverProblem = nil
        alerts.cancelAll()
    }

    /// Takes over a group this person responded in through another engine, after they left the
    /// group they called in (`leave`): it becomes their call group, with its open calls,
    /// acknowledgements, rota and log, and this engine's alerts take over from the other's.
    public func adopt(_ s: SavedState, activity a: Activity) {
        var a = a
        // The radio's record of the last hour, and the box set up for the group left, belong to
        // the box, not the group.
        a.airtime = activity.airtime
        a.leftGroupBox = activity.leftGroupBox
        activity = a
        setState(s)
        for r in activity.inbox.requests.values where r.isOpen { scheduleAlerts(for: r.key) }
        followProfileCheckIns()
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
                    alerts.tellCaller(title: "Your call is being sent again",
                                      body: "The person who saw it is no longer in your group. Nobody else has seen it yet. If you need help now, call 999.")
                }
            }
            if activity.inbox.requests.values.contains(where: { $0.acknowledgedBy.contains { !current.contains($0) } }) {
                for k in activity.inbox.revoke(keeping: current) { scheduleAlerts(for: k) }
            }
            // Removed, or a caller only, however this phone learnt it (a removal heard, a key
            // update, a watch handover, a takeover): it can acknowledge nothing, so nothing should
            // keep alerting it.
            if me?.canRespond != true { for k in activity.inbox.requests.keys { alerts.cancel(k) } }
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
        } else {
            forgetRemovedBox()
        }
        relay.configure(group: group, identity: identity)
        homeWiFi.configure(group: group, me: saved?.me, identity: identity)
        publishMembersIfDue()
        checkGaps()
    }

    /// The box's radio band changed (or a box was paired): start a budget only if its limit
    /// differs, so re-pairing or relaunching never gives a fresh allowance within the hour.
    public func bandChanged(_ band: Band?) {
        guard let band, budget?.dutyCycle != band.dutyCycle else { return }
        budget = budget?.moved(to: band.dutyCycle) ?? AirtimeBudget(dutyCycle: band.dutyCycle)
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

    /// When this phone's keys stop reaching the group, if it has not scanned its update by then.
    public var keysEndAt: Date? {
        guard let g = group, let heard = g.keysOutdatedSince else { return nil }
        let guess = heard.addingTimeInterval(GroupState.changeoverPeriod)
        return g.keysEndAt.map { min($0, guess) } ?? guess
    }
    /// Past that, only a text the caller sends reaches anyone, so every other route shows the cross.
    public var keysExpired: Bool { keysEndAt.map { now() >= $0 } ?? false }
    public static let keysExpiredReason = "Scan the new code from your coordinator, under Group"

    public var availableRoutes: Set<Route> {
        var s: Set<Route> = [.sms]
        guard !keysExpired else { return s }
        if mesh.isReady { s.insert(.mesh) }
        if relay.isConfigured { s.insert(.internet) }
        if homeWiFi.hasPeers { s.insert(.wifi) }
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
        if colour == .green { settleOnOK() }
        launch(OutgoingRequest(unit: unit, number: nextRequestNumber(), colour: colour, createdAt: now()))
    }

    /// On the phone: sends a call its watch made, under the watch's number, on the phone's own
    /// routes too. Responders hear one call however many ways it comes, and both devices hear its
    /// acknowledgement. Returns false if it is not this phone's caller's call.
    @discardableResult
    public func adopt(_ call: HelpFrame) -> Bool {
        guard !companion, case let .call(unit, number, colour, sentAt) = call, unit == me?.unit, number >= 0x8000 else { return false }
        let pressed = Date(timeIntervalSince1970: TimeInterval(sentAt))
        if let i = activity.outgoing.firstIndex(where: { $0.unit == unit && $0.number == number }) {
            // The same call again. A different press under the same number is a new watch that
            // started its numbering afresh: the old entry goes, so the new call is sent.
            if abs(activity.outgoing[i].createdAt.timeIntervalSince(pressed)) <= OutgoingRequest.clockAllowance { return true }
            activity.outgoing.remove(at: i)
        }
        if var s = saved, number > s.lastWatchRequest {
            s.lastWatchRequest = number
            saved = s
            store.save(s)
        }
        // The watch's I'm OK settles only what was open when it was pressed: never a call made on
        // the phone while it was on its way.
        if colour == .green { settleOnOK(pressedAt: pressed) }
        launch(OutgoingRequest(unit: unit, number: number, colour: colour, createdAt: pressed))
        return true
    }

    private func launch(_ request: OutgoingRequest) {
        var r = request
        let colour = r.colour
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        let expired = keysExpired ? Self.keysExpiredReason : nil
        if !routes.contains(.mesh) { r.update(.mesh, .failed(expired ?? mesh.unavailableReason)) }
        if !routes.contains(.internet) { r.update(.internet, .failed(expired ?? relay.lastProblem ?? "Internet route not set up")) }
        if homeWiFi.isEnabled, !routes.contains(.wifi) { r.update(.wifi, .failed(expired ?? homeWiFi.unavailableReason)) }
        for route in routes { r.update(route, .sending) }
        activity.outgoing.append(r)
        trimOutgoing()
        log("\(describe(r.unit, r.number, colour)) pressed")
        if colour == .green { activity.greens.append(r.createdAt) }
        let frame = r.callFrame
        let gid = groupID
        for route in routes {
            spawn {
                let failure = route == .internet ? await self.sendOnInternet(frame, wake: .call, in: gid) : await self.send(frame, on: route, kind: .call, in: gid)
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
        let before = activity.outgoing[i].routes[route]
        activity.outgoing[i].update(route, state)
        guard before != state else { return }
        let how = route.words
        switch state {
        case .sent: log("\(describe(r.unit, r.number, r.colour)) sent over \(how)")
        case let .failed(why): log("\(describe(r.unit, r.number, r.colour)) not sent over \(how): \(why)")
        case .sending: break
        }
    }

    /// Returns why it could not go, if it could not.
    @discardableResult
    public func add(_ category: CallCategory) -> String? {
        guard current?.partsLeft ?? 0 > 0 else { return "This call cannot take any more messages. If you need help now, call 999." }
        if category != .missedCheckIn, let keyProblem { return keyProblem }
        guard let i = activity.outgoing.lastIndex(where: { !$0.fromBox }) else { return nil }
        let frame = activity.outgoing[i].add(category)
        let gid = groupID
        // A missed check-in is not the caller's choice, so it goes plainly, like the call.
        if frame.personalPart == nil {
            spawn { _ = await self.sendOptional(frame, in: gid) }
        } else {
            spawn { await self.sendPersonal(frame, in: gid) }
        }
        return nil
    }

    /// Takes back a category pressed by mistake.
    @discardableResult
    public func withdraw(_ category: CallCategory) -> String? {
        // Taken back here but not there would leave responders acting on it.
        if let keyProblem { return keyProblem }
        guard let i = activity.outgoing.lastIndex(where: { !$0.fromBox }) else { return nil }
        let frame = activity.outgoing[i].withdraw(category)
        let gid = groupID
        if let frame { spawn { await self.sendPersonal(frame, in: gid) } }
        return nil
    }

    // MARK: Settling a call (decision 6)

    /// The calls I'm OK would settle now: every open Help or Need a hand when it closes them, or
    /// those still waiting for a responder when it only stops the urgent repeats.
    public var settledByOK: [OutgoingRequest] {
        activity.outgoing.filter { r in
            guard r.isUnsettled, !r.fromBox else { return false }
            if profile.afterOK == .closesCall { return true }
            if case .seen = r.status { return false }
            return r.settled == nil
        }
    }

    /// `pressedAt` is when I'm OK was pressed on the watch, to the second. A call made in that
    /// second or later stays as it is, so the doubt always leaves a call urgent.
    private func settleOnOK(pressedAt: Date? = nil) {
        guard let n = saved?.me else { return }
        let state: CallState = profile.afterOK == .closesCall ? .closedByCaller : .callerOK
        for r in settledByOK where pressedAt.map({ r.createdAt < $0 }) ?? true {
            settleCall(r.unit, r.number, Settled(state: state, by: n, at: pressedAt ?? now()))
        }
    }

    /// The caller closes their latest open call, where their profile lets them.
    public func closeMyCall() {
        guard profile.callerMayClose, let n = saved?.me, let r = activity.outgoing.last(where: { $0.isUnsettled && !$0.fromBox }) else { return }
        settleCall(r.unit, r.number, Settled(state: .closedByCaller, by: n, at: now()))
    }

    /// A reason for closing goes sealed for responders over the internet or home Wi-Fi only, never
    /// the radio, so needs one of them.
    public var canSendReason: Bool { canSendOffAir }

    /// A coordinator closes someone's call, recording the caller's consent or a reason.
    @discardableResult
    public func close(_ key: IncomingRequest.Key, consent: Bool, reason: String = "") -> Bool {
        let reason = MeshText.fit(reason.trimmingCharacters(in: .whitespacesAndNewlines), bytes: HelpFrame.maxReasonBytes)
        // A reason never goes on the radio; without the internet or home Wi-Fi it would reach nobody.
        guard me?.role == .coordinator, let n = saved?.me, activity.inbox.requests[key] != nil,
              consent || (!reason.isEmpty && canSendOffAir) else { return false }
        settleCall(key.unit, key.request, Settled(state: consent ? .closedWithConsent : .closedWithReason, by: n, at: now(), reason: consent ? "" : reason))
        return true
    }

    /// The caller's signed "I'm OK" for a call still being sent, so it goes with each resend.
    private func okFrame(_ r: OutgoingRequest) -> HelpFrame? {
        guard let s = r.settled, s.state == .callerOK, let n = saved?.me else { return nil }
        return .signing(.callState(unit: r.unit, request: r.number, state: .callerOK, at: UInt32(s.at.timeIntervalSince1970), reason: ""),
                        as: n, identity: identity, group: groupID)
    }

    /// Settles a call here and tells everyone, signed. A reason is for responders only: it goes
    /// sealed for them, over the internet and home Wi-Fi only, and the radio carries the close
    /// without it. In a group made before responders had their own key it goes as before, inside
    /// the signed close, sealed with the group key every member holds.
    private func settleCall(_ unit: UInt32, _ request: UInt16, _ s: Settled) {
        let key = IncomingRequest.Key(unit: unit, request: request)
        settleCall(key, s, via: nil)
        guard let n = saved?.me, let g = group else { return }
        let at = UInt32(s.at.timeIntervalSince1970)
        let onAir = HelpFrame.signing(.callState(unit: unit, request: request, state: s.state, at: at, reason: ""), as: n, identity: identity, group: groupID)
        var full = onAir
        if !s.reason.isEmpty {
            let withReason = HelpFrame.callState(unit: unit, request: request, state: s.state, at: at, reason: s.reason)
            full = ForResponders.seal(withReason, from: identity, as: n, in: g, at: now()).first
                ?? HelpFrame.signing(withReason, as: n, identity: identity, group: groupID)
        }
        if s.state.closes {
            activity.closeRepeats.removeAll { $0.call == key }
            activity.closeRepeats.append(CloseRepeat(call: key, full: full, onAir: onAir, at: now()))
        }
        sendClose(full, onAir)
    }

    private func sendClose(_ full: HelpFrame, _ onAir: HelpFrame) {
        let gid = groupID
        spawn {
            _ = await self.sendOffAir(full, in: gid)
            // Only responders can open the sealed reason: the close itself goes to every member too.
            if case .forResponders = full { _ = await self.sendOffAir(onAir, in: gid) }
            _ = await self.sendOnMesh(onAir, kind: .optional, in: gid)
        }
    }

    /// Records a settled call on the caller's own list and on a responder's, where calm or
    /// closed it stops alerting urgently.
    private func settleCall(_ key: IncomingRequest.Key, _ s: Settled, via route: Route?) {
        let mine = activity.outgoing.firstIndex { $0.unit == key.unit && $0.number == key.request }
        let before = mine.map { activity.outgoing[$0].settled } ?? activity.inbox.requests[key]?.settled
        if let i = mine { activity.outgoing[i].settle(s) }
        if me?.canRespond == true, key.unit != me?.unit, case .updated = activity.inbox.settle(key, s, via: route, at: now()) {
            alerts.cancel(key)
            scheduleAlerts(for: key)
        }
        let after = mine.map { activity.outgoing[$0].settled } ?? activity.inbox.requests[key]?.settled
        guard let a = after, a != before else { return }
        let call = describe(key.unit, key.request, mine.map { activity.outgoing[$0].colour } ?? activity.inbox.requests[key]?.colour)
        let who = name(ofMember: a.by)
        switch a.state {
        case .callerOK: log("\(who) said they are OK after \(call)")
        case .closedByCaller: log("\(who) closed \(call)")
        case .closedWithConsent: log("\(who) closed \(call), with the caller's agreement")
        case .closedWithReason: log("\(who) closed \(call)" + (a.reason.isEmpty ? ", with a reason sealed for responders" : ": \(a.reason)"))
        }
    }

    // MARK: The log

    /// Adds to the group's log on a coordinator's phone, while the group keeps one.
    private func log(_ text: String) {
        guard actsAsCoordinator, group?.policy.keepsLog == true else { return }
        activity.log.add(text, at: now())
    }

    /// A settings change is logged (also the one that switches the log off) and kept to show the
    /// coordinators, even with the log off.
    private func logSettings(by signer: UInt16, _ changes: [String], old: GroupSettings) {
        guard actsAsCoordinator, !changes.isEmpty else { return }
        let entry = GroupLog.Entry(at: now(), text: "\(name(ofMember: signer)) \(changes.joined(separator: ", "))")
        activity.lastSettingsChange = entry
        if old.policy.keepsLog || group?.policy.keepsLog == true { activity.log.add(entry.text, at: entry.at) }
    }

    /// "Pat's Help call 3", in the caller's own words for the button.
    private func describe(_ unit: UInt32, _ request: UInt16, _ colour: Colour?) -> String {
        let words = colour.map { ButtonWords.words($0, in: group?.profile(ofUnit: unit)) } ?? "call"
        return "\(name(ofUnit: unit))'s \(words) call \(request)"
    }

    /// Typed text and position go only to responders (decision 12), sealed once for all of them;
    /// in a group made before responders had their own key, over the internet sealed with the
    /// group key, or else as direct messages to each responder's box.
    /// Whether this phone acts on a frame, so may confirm it on home Wi-Fi: a call or a sealed
    /// message for responders only if this member responds and it is not their own.
    public func takes(_ frame: HelpFrame) -> Bool {
        switch frame {
        case let .call(unit, _, _, _): me?.canRespond == true && !isHousehold(unit)
        // Sealed for responders: only one that can open it holds it.
        case .forResponders: me?.canRespond == true && group.flatMap { ForResponders.open(frame, in: $0, at: now()) } != nil
        // Personal detail sent plainly (an older group) is for responders only, too.
        default: frame.personalPart != nil ? me?.canRespond == true : me != nil
        }
    }

    public var canSendPersonal: Bool { keyProblem == nil && (relay.isConfigured || mesh.isReady || homeWiFi.hasPeers) }

    /// After a removal this phone has no new keys for, the removed phone could still open what it
    /// seals for responders, so choices, messages and where the caller is wait for the update code.
    public var keyProblem: String? { group?.needsKeyUpdate == true && me != nil ? Self.keysNeeded : nil }
    public static let keysNeeded = "Your buttons still work. Your coordinator has a new code for you to scan, under Group. Until then, anything you type, choose or share is not sent."
    public static let cannotSendPersonal = "Messages and where you are cannot be sent just now. Your buttons still work. If you need help now, call 999."

    public func addNote(_ text: String) -> String? {
        if let keyProblem { return keyProblem }
        guard canSendPersonal else { return Self.cannotSendPersonal }
        guard let i = activity.outgoing.lastIndex(where: { !$0.fromBox }) else { return nil }
        // Sealed and signed for responders, long text goes as several notes that each fit the radio.
        let frames = group?.secrets.responderPublicKey == nil ? [activity.outgoing[i].addNote(text)].compactMap { $0 }
            : activity.outgoing[i].addNotes(text, pieceBytes: ForResponders.maxNoteBytes)
        if frames.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "This call cannot take any more messages. If you need help now, call 999."
        }
        let gid = groupID
        spawn { for f in frames { await self.sendPersonal(f, in: gid) } }
        return nil
    }

    /// `sent` hears whether any route took it: not whether anyone has read it. `call` is the call
    /// it was asked for, as a fix can come after another call was made; nil for the latest.
    public func sharePosition(latitude: Double, longitude: Double, accuracy: Double, call: UInt16? = nil, sent: ((Bool) -> Void)? = nil) {
        guard canSendPersonal, let r = call == nil ? current : activity.outgoing.last(where: { $0.number == call }) else { sent?(false); return }
        let frame = HelpFrame.position(unit: r.unit, request: r.number, latitudeE7: Int32(latitude * 1e7),
                                       longitudeE7: Int32(longitude * 1e7), accuracy: UInt16(clamping: Int(accuracy)))
        let gid = groupID
        spawn { let ok = await self.sendPersonal(frame, in: gid); sent?(ok) }
    }

    /// Sealed once for all responders (decision 12) and sent once, over the internet or else on the
    /// group channel. A group made before responders had their own key falls back to a direct
    /// message to each responder's box. Only into the group it was typed in: never one this phone
    /// joined while an earlier piece was still going. True if any route took it.
    @discardableResult private func sendPersonal(_ frame: HelpFrame, in gid: Data) async -> Bool {
        guard let g = group, g.secrets.groupID == gid, !g.needsKeyUpdate else { return false }
        if let me = saved?.me, g.secrets.responderPublicKey != nil {
            var took = false
            for sealed in ForResponders.seal(frame, from: identity, as: me, in: g, at: now()) {
                if await sendOnWiFi(sealed, in: gid) == nil { took = true }
                if await sendOnInternet(sealed, in: gid) == nil { took = true; continue }
                if await sendOnMesh(sealed, kind: .optional, in: gid) == nil { took = true }
            }
            return took
        }
        var took = false
        if await sendOnWiFi(frame, in: gid) == nil { took = true }
        if await sendOnInternet(frame, in: gid) == nil { return true }
        return await sendDirect(frame, to: nil, in: gid) || took
    }

    /// Personal content as MeshCore direct messages to each responder's box (or one member's),
    /// which MeshCore encrypts to that box alone. Within the optional half of the airtime. True if
    /// the box took at least one.
    @discardableResult private func sendDirect(_ frame: HelpFrame, to only: UInt16?, in gid: Data) async -> Bool {
        guard mesh.isReady, let text = MeshText.encode(frame), let radio = mesh.radio, radio.band != nil, budget != nil else { return false }
        let seconds = radio.airtime(bytes: meshPacketBytes(payload: text.utf8.count + 8))
        var took = false
        for m in group?.members ?? [] where m.canRespond && m.number != saved?.me && (only == nil || m.number == only) {
            guard groupID == gid else { return took }
            guard let key = activity.boardKeys[m.number], budget!.allows(seconds, kind: .optional, at: now()) else { continue }
            let reservation = budget!.record(seconds, at: now())
            switch await mesh.sendText(text, to: key) {
            case .sent: took = true
            case .refused: budget?.cancel(reservation)
            case .unknown: break
            }
        }
        return took
    }

    private func send(_ frame: HelpFrame, on route: Route, kind: AirtimeBudget.Kind, in gid: Data) async -> String? {
        switch route {
        case .mesh: return await sendOnMesh(frame, kind: kind, in: gid)
        case .internet: return await sendOnInternet(frame, in: gid)
        case .wifi: return await sendOnWiFi(frame, in: gid)
        case .sms: return "Press Send as a text"
        }
    }

    /// Every send names the group it was made in, and each route is tried only while this phone is
    /// still in that group: a send waiting on one route must never go out sealed with the keys of a
    /// group joined meanwhile.
    private static let groupChanged = "This call was made in your old group"

    private func sendOnWiFi(_ frame: HelpFrame, to only: Set<UInt16>? = nil, in gid: Data) async -> String? {
        guard groupID == gid else { return Self.groupChanged }
        return homeWiFi.hasPeers ? await homeWiFi.send(frame, to: only) : homeWiFi.unavailableReason
    }

    private func sendOnInternet(_ frame: HelpFrame, wake: RelayWake? = nil, in gid: Data) async -> String? {
        guard groupID == gid else { return Self.groupChanged }
        return relay.isConfigured ? await relay.send(frame, wake: wake) : "Internet route not set up"
    }

    /// Follow-ups, availability and notice acknowledgements use the internet when it works and the
    /// mesh only when it does not, to keep radio time for calls.
    /// Home Wi-Fi is free and uses no radio time, so it is always tried as well.
    private func sendOptional(_ frame: HelpFrame, in gid: Data) async -> String? {
        let viaWiFi = await sendOnWiFi(frame, in: gid)
        if await sendOnInternet(frame, in: gid) == nil { return nil }
        let viaMesh = await sendOnMesh(frame, kind: .optional, in: gid)
        return viaWiFi == nil ? nil : viaMesh
    }

    /// Over the internet if it is set up, and over the mesh as well, so members without internet
    /// hear too. Optional airtime.
    private func sendToAll(_ frame: HelpFrame, in gid: Data) async {
        _ = await sendOnWiFi(frame, in: gid)
        _ = await sendOnInternet(frame, in: gid)
        _ = await sendOnMesh(frame, kind: .optional, in: gid)
    }

    /// What is too personal for the radio goes over the internet and home Wi-Fi: on the Wi-Fi it
    /// never leaves the house. `only` is who must have it, when it is for them alone.
    private func sendOffAir(_ frame: HelpFrame, to only: Set<UInt16>? = nil, in gid: Data) async -> String? {
        let viaWiFi = await sendOnWiFi(frame, to: only, in: gid)
        guard relay.isConfigured else { return viaWiFi }
        // With the internet route set up, its answer counts: the one it was meant for, such as a
        // coordinator, may not be on this Wi-Fi.
        return await sendOnInternet(frame, in: gid)
    }

    private var canSendOffAir: Bool { relay.isConfigured || homeWiFi.hasPeers }

    private func sendOnMesh(_ frame: HelpFrame, kind: AirtimeBudget.Kind, in gid: Data) async -> String? {
        guard groupID == gid else { return Self.groupChanged }
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
        let gid = groupID
        await sendToAll(.signedBoard(member: me, publicKey: mine, identity: identity, group: gid), in: gid)
        for m in members.sorted() { await shareCheckIns(to: m) }
    }

    // MARK: A Help&I box of its own

    /// A coordinator adds the Help&I box with this MeshCore key and sealing key (from its info
    /// reply) as a member of its own, a caller with its own unit (decision 8), told to everyone
    /// like any member, in the home of member `home`. Returns why it could not be, if it could not.
    @discardableResult
    public func addBox(key: Data, sealKey: Data, name: String, home: UInt16) -> String? {
        guard actsAsCoordinator, let g = group else { return "Only a coordinator can add a box to the group" }
        guard g.boxMember(key: key) == nil else { return "This box is already in the group" }
        guard let person = g.member(home), !g.isBox(person) else { return "Choose whose home the box is in" }
        let me = saved?.me
        var added: UInt16?
        updateGroup { added = $0.addBox(key: key, sealKey: sealKey, name: name, home: home, by: me) }
        guard added != nil else { return "This box could not be added" }
        // Its home is a setting: settings too big to send to everyone are not kept, nor the box.
        guard group?.boxMember(key: key) != nil else { return settingsProblem ?? "This box could not be added" }
        log("You added the box \(name)")
        return nil
    }

    /// A coordinator chooses whose home a Help&I box is in: a person's, never another box's.
    /// Returns why it could not be, if it could not.
    @discardableResult
    public func setHome(ofBox box: UInt16, to home: UInt16) -> String? {
        guard actsAsCoordinator, let g = group else { return "Only a coordinator can choose a box's home" }
        guard g.member(box) != nil, home != box, let person = g.member(home), !g.isBox(person) else { return "Choose whose home the box is in" }
        updateGroup { $0.policy.boxHome[box] = home }
        return group?.policy.boxHome[box] == home ? nil : settingsProblem
    }

    /// A frame the connected Help&I box made (push 0xA3): its call, its signed I'm OK or close, or
    /// a sealed power-cut report. The box has sent it on the radio itself. The phone of the box's
    /// home takes it in as if heard there and carries it on its other routes, like its own: a call
    /// is kept as the household's own, never alerted for here, and what comes back for it
    /// (acknowledgements, closes) reaches its record like the phone's own calls'. Any other phone
    /// connected to it, such as a coordinator's setting it up, only hears it, as on the radio, so
    /// a responder there is alerted from their turn like everyone else; but a box in no one's home
    /// would then be heard on the radio only, so that phone carries its calls on its other routes
    /// too, still alerted for them. Returns whether any route took a call, for the box (0x74); nil
    /// for anything else.
    public func receiveFromBox(_ frame: HelpFrame) async -> Bool? {
        guard !companion, let g = group, let box = g.boxMember(key: mesh.boxPublicKey) else { return nil }
        let gid = g.secrets.groupID
        guard let unit = householdBoxUnit else {
            receive(frame, via: .mesh)
            guard !g.hasHome(box) else { return nil }
            switch frame {
            case let .call(u, _, _, _) where u == box.unit:
                var took = false
                for route in RoutePlan.firstAttempt(available: availableRoutes.subtracting([.mesh]), smsIsAutomatic: false) {
                    let failure = route == .internet ? await sendOnInternet(frame, wake: .call, in: gid) : await send(frame, on: route, kind: .call, in: gid)
                    if failure == nil { took = true }
                }
                return took
            case .signed, .forResponders:
                _ = await sendOffAir(frame, in: gid)
                return nil
            default:
                return nil
            }
        }
        switch frame {
        case let .call(u, number, colour, sentAt) where u == unit:
            let pressed = Date(timeIntervalSince1970: TimeInterval(sentAt))
            if let i = activity.outgoing.firstIndex(where: { $0.unit == u && $0.number == number }) {
                // The same call again: nothing more to do. A different press under the same number
                // is a box that started its numbering afresh: the old record goes.
                if abs(activity.outgoing[i].createdAt.timeIntervalSince(pressed)) <= OutgoingRequest.clockAllowance {
                    return activity.outgoing[i].routes.values.contains(.sent)
                }
                activity.outgoing.remove(at: i)
            }
            var r = OutgoingRequest(unit: u, number: number, colour: colour, createdAt: pressed, fromBox: true)
            let routes = RoutePlan.firstAttempt(available: availableRoutes.subtracting([.mesh]), smsIsAutomatic: false)
            let expired = keysExpired ? Self.keysExpiredReason : nil
            if !routes.contains(.internet) { r.update(.internet, .failed(expired ?? relay.lastProblem ?? "Internet route not set up")) }
            if homeWiFi.isEnabled, !routes.contains(.wifi) { r.update(.wifi, .failed(expired ?? homeWiFi.unavailableReason)) }
            for route in routes { r.update(route, .sending) }
            activity.outgoing.append(r)
            trimOutgoing()
            log("\(describe(u, number, colour)) pressed on the box")
            var took = false
            for route in routes {
                let failure = route == .internet ? await sendOnInternet(frame, wake: .call, in: gid) : await send(frame, on: route, kind: .call, in: gid)
                updateOutgoing(r, route, failure.map(RouteState.failed) ?? .sent)
                if failure == nil { took = true }
            }
            return took
        case .signed, .forResponders:
            receive(frame, via: .mesh)
            _ = await sendOffAir(frame, in: gid)
            return nil
        default:
            return nil
        }
    }

    /// The household's box's own list of its calls (0x73), read when the phone connects to it
    /// again: a call made while the phone was away and still waiting for a responder is carried
    /// now on the phone's routes, as if the box had pushed it then. Calls the phone already has,
    /// and those seen or closed, are left alone. Returns each call taken on with whether a route
    /// took it, for the box (0x74).
    public func adoptBoxCalls(_ calls: [MeshCore.BoxCall]) async -> [(request: UInt16, sent: Bool)] {
        guard let unit = householdBoxUnit else { return [] }
        var adopted: [(request: UInt16, sent: Bool)] = []
        for c in calls {
            if case .seen = c.status { continue }
            if case .closed = c.status { continue }
            let pressed = Date(timeIntervalSince1970: TimeInterval(c.pressedAt))
            if activity.outgoing.contains(where: { $0.unit == unit && $0.number == c.request
                && abs($0.createdAt.timeIntervalSince(pressed)) <= OutgoingRequest.clockAllowance }) { continue }
            if let took = await receiveFromBox(.call(unit: unit, request: c.request, colour: c.colour, sentAt: c.pressedAt)) {
                adopted.append((c.request, took))
            }
        }
        return adopted
    }

    /// A Help&I box taken out of the group is told to forget it (0x75) by the phone connected to
    /// it, when it is removed and whenever that phone connects to it again, so it stops calling
    /// on the group's channel as a member the others no longer accept. So is the household's box
    /// once its phone has left the group for one that does not have it; one the new group has is
    /// set up for it instead.
    private func forgetRemovedBox() {
        guard let key = mesh.boxPublicKey, mesh.isReady, let g = group, g.boxMember(key: key) == nil,
              g.removedKeys.contains(key) || activity.leftGroupBox == key, forgottenBox != key else { return }
        forgottenBox = key
        spawn { await self.mesh.tellBoxToForget() }
    }

    /// A stock box's battery suggests a power cut (`BatteryWatch`) and the caller chose to tell
    /// responders: as a note on their open call, or on a new Need a hand. Returns why it could not
    /// go, if it could not.
    @discardableResult
    public func tellRespondersOfProbablePowerCut() -> String? {
        if let keyProblem { return keyProblem }
        guard canSendPersonal else { return Self.cannotSendPersonal }
        if current?.isUnsettled != true { press(.amber) }
        return addNote(HelpBox.probablePowerCutNote)
    }

    /// Tells the group which box is this phone's, and adds the other members' boxes as contacts.
    public func boxReady() async {
        forgottenBox = nil
        forgetRemovedBox()
        guard let myNumber = saved?.me, let key = mesh.boxPublicKey else { return }
        activity.boardKeys[myNumber] = key
        for (member, k) in activity.boardKeys where member != myNumber { await mesh.addContact(k, name: "Help&I \(member)") }
        let gid = groupID
        await sendToAll(.signedBoard(member: myNumber, publicKey: key, identity: identity, group: gid), in: gid)
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
        if list == refusedList, g.relayPass == refusedPass { return }
        let due = changed ? t.timeIntervalSince(lastPublishTry ?? .distantPast) >= publishBackoff || lastTriedList != list
            : t.timeIntervalSince(publishedAt ?? .distantPast) > 86_400
        guard due else { return }
        lastPublishTry = t
        lastTriedList = list
        let round = publishRound
        spawn {
            let result = await self.relay.publishMembers()
            // The relay's address changed while this was going: it says nothing about the new one.
            guard self.publishRound == round else { return }
            switch result {
            case .accepted:
                // Only the list that was sent counts as published; a change made meanwhile still goes.
                self.publishedList = list; self.publishedAt = self.now(); self.publishBackoff = 60
                if list.primary == self.identity.signingPublicKey.base64EncodedString() { self.relayOwner(is: self.identity.signingPublicKey) }
                self.publishMembersIfDue()
            case .refused:
                self.refusedList = list; self.refusedPass = g.relayPass
            case .unreachable, .notYet:
                self.publishBackoff = min(self.publishBackoff * 2, 1800)
            }
        }
    }

    private var lastTriedList: RelayProtocol.MemberList?
    /// Moves on when the relay's address changes, so an answer from the old address is not kept.
    private var publishRound = 0

    /// A coordinator repeats who is in the group, at most once a day, for members who missed it; and
    /// the first coordinator's repeat is what confirms people other coordinators invited. Runs from
    /// the box connecting and from every tick, so it happens with no box too.
    private func repeatMembershipIfDue() async {
        guard actsAsCoordinator, let myNumber = saved?.me, let g = group,
              now().timeIntervalSince(lastMembershipRepeat ?? .distantPast) > 86_400, mesh.isReady || relay.isConfigured || homeWiFi.hasPeers else { return }
        lastMembershipRepeat = now()
        let gid = g.secrets.groupID
        // The settings too, for members who missed them.
        if g.settingsVersion > 0, let f = g.settingsFrame(as: myNumber, identity: identity) { _ = await sendOptional(f, in: gid) }
        for m in g.members where m.number != myNumber {
            if let f = g.addedFrame(m.number) { await sendToAll(.signing(f, as: myNumber, identity: identity, group: gid), in: gid) }
            if m.role == .coordinator, let f = g.roleFrame(m.number) { await sendToAll(.signing(f, as: myNumber, identity: identity, group: gid), in: gid) }
        }
        // Removals too, so a phone that missed one stops counting that member's acknowledgements.
        if myNumber == g.primaryCoordinator {
            for n in g.removedMembers.sorted() {
                await sendToAll(.signing(.memberRemoved(member: n, version: g.membershipVersion), as: myNumber, identity: identity, group: gid), in: gid)
            }
            if let f = g.changeoverFrame(at: now()) { await sendToAll(.signing(f, as: myNumber, identity: identity, group: gid), in: gid) }
            if let f = g.deputyFrame() { await sendToAll(f, in: gid) }
            // How this phone came to be first coordinator, for phones that missed it, while they
            // can still hear: after the changeover they need an update code, which carries it.
            if let t = g.takeover, g.changeoverFrame(at: now()) != nil { await sendToAll(.takeover(t), in: gid) }
        }
    }

    /// Drops "I'm OK" calls and acknowledged requests after a week. A request nobody has
    /// acknowledged stays, however old.
    private func pruneInbox() {
        let cutoff = now().addingTimeInterval(-7 * 86_400)
        let stale = activity.inbox.requests.values.filter { r in
            (!r.isOpen || r.colour == .green) && r.firstHeardAt < cutoff
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
            let gid = groupID
            // The box sends its own calls on the radio; the phone carries them on its other routes.
            let available = r.fromBox ? availableRoutes.subtracting([.mesh]) : availableRoutes
            for route in RoutePlan.firstAttempt(available: available, smsIsAutomatic: false) {
                // The first time a call reaches the relay, ask it to wake the others, even if that is
                // on a resend because the internet came back.
                let firstOnInternet = route == .internet && r.routes[.internet] != .sent
                spawn {
                    // Resends count as optional airtime, so they never use up what a new press needs.
                    let failure = firstOnInternet ? await self.sendOnInternet(r.callFrame, wake: .call, in: gid)
                        : await self.send(r.callFrame, on: route, kind: r.colour == .green ? .optional : .resend, in: gid)
                    if failure == nil { self.updateOutgoing(r, route, .sent) }
                    if !r.fromBox, let ok = self.okFrame(r) { _ = await self.send(ok, on: route, kind: .optional, in: gid) }
                }
            }
        }
        for i in activity.closeRepeats.indices.reversed() where t >= Resend.due(activity.closeRepeats[i].resends + 1, after: activity.closeRepeats[i].at) {
            var c = activity.closeRepeats[i]
            // After a long sleep, missed slots are skipped rather than sent back to back.
            repeat { c.resends += 1 } while t >= Resend.due(c.resends + 1, after: c.at)
            activity.closeRepeats[i] = c
            if c.resends >= Resend.gaps.count { activity.closeRepeats.remove(at: i) }
            sendClose(c.full, c.onAir)
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

    public func receive(_ frame: HelpFrame, via route: Route) { receive(frame, via: route, opened: false) }

    /// `opened` is true for what came sealed for responders. Where responders have their own key,
    /// callers seal and sign everything personal, so a plain note, position or choice is someone
    /// else writing as the caller (any member holds the channel secret) and counts for nothing.
    private func receive(_ frame: HelpFrame, via route: Route, opened: Bool) {
        if frame.personalPart != nil, !opened, group?.secrets.responderPublicKey != nil { return }
        switch frame {
        case let .ack(unit, request, who, at, _):
            // Only a current responder's own signature counts (decision 6, AGENTS.md).
            guard group?.acceptsAck(frame) == true else { return }
            // Other phones pass on acknowledgements they hold, so one may be days old: it says when.
            if who == group?.primaryCoordinator { heardPrimary(at: Date(timeIntervalSince1970: TimeInterval(at))) }
            let k = IncomingRequest.Key(unit: unit, request: request)
            let heard = activity.inbox.requests[k]?.sentAt != nil || activity.outgoing.contains { $0.unit == unit && $0.number == request }
            // Logged only when it will count: for a call heard, and not from this responder already.
            if heard, activity.inbox.requests[k]?.acknowledgedBy.contains(who) != true,
               activity.outgoing.first(where: { $0.unit == unit && $0.number == request })?.acknowledgedBy.contains(who) != true {
                log("\(name(ofMember: who)) acknowledged \(describe(unit, request, activity.inbox.requests[k]?.colour))")
            }
            activity.lastAnswered[who] = max(activity.lastAnswered[who] ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(at)))
            if let i = activity.outgoing.firstIndex(where: { $0.unit == unit && $0.number == request }) {
                let before = activity.outgoing[i].acknowledgedBy
                activity.outgoing[i].receive(frame)
                // The box hears only the radio: an acknowledgement of its call that came another
                // way goes on the radio for it, so it can show that someone has seen the call.
                if activity.outgoing[i].fromBox, route != .mesh, activity.outgoing[i].acknowledgedBy != before {
                    let gid = groupID
                    spawn { _ = await self.sendOnMesh(frame, kind: .optional, in: gid) }
                }
            }
        case .availability, .noticeAck, .memberAdded, .memberRemoved, .memberName, .memberRole, .memberPhone, .callState, .changeRequest, .changeoverEnds:
            // Counted only when signed (below), so a removed phone cannot fake them.
            return
        case .deputy:
            guard var s = saved, s.group.apply(deputy: frame) else { return }
            let first = s.group.primaryCoordinator
            setState(s)
            heardPrimary()
            log(s.group.deputy.map { "\(name(ofMember: first ?? 0)) named \(name(ofMember: $0)) as deputy" } ?? "\(name(ofMember: first ?? 0)) named no deputy")
            return
        case let .takeover(t):
            guard !activity.heardTakeovers.contains(t), let g = group, t.from == g.primaryCoordinator || t.from == g.takeover?.from else { return }
            keepHeard(t)
            settleTakeovers()
            return
        case let .takeoverConsent(from, to, signer, sig):
            guard to == saved?.me, let g = group, from == g.primaryCoordinator, signer != to, signer != from,
                  let by = g.member(signer), by.role == .coordinator, let fromKey = g.member(from)?.signingKey,
                  HelpFrame.isValidTakeoverSignature(sig, by: by.signingKey, fromKey: fromKey, toKey: identity.signingPublicKey, group: groupID),
                  activity.takeoverConsents[signer] != sig else { return }
            activity.takeoverConsents[signer] = sig
            log("\(name(ofMember: signer)) agreed that you may take over as first coordinator")
            return
        case let .signed(signer, _, _):
            guard let sender = group?.member(signer), let inner = frame.verifiedInner(signedBy: sender.signingKey, group: groupID) else { return }
            if signer == group?.primaryCoordinator { heardPrimary() }
            switch inner {
            case let .noticeAck(notice, by, at):
                // An old acknowledgement, replayed, must not clear a newer notice.
                if notice.isShared, sender.role == .coordinator, let raised = activity.notices[notice]?.raisedAt,
                   TimeInterval(at) >= raised.timeIntervalSince1970 - OutgoingRequest.clockAllowance {
                    activity.notices[notice]?.acknowledge(by: by)
                }
            case .availability:
                if sender.canRespond { activity.rota.apply(inner); checkGaps() }
            case let .checkIns(unit, _, _, _):
                if sender.unit == unit, unit != me?.unit { activity.checkInWatch.apply(inner) }
            case let .changeRequest(member, setting, at, text):
                guard actsAsCoordinator else { break }
                let r = ChangeRequest(member: member, setting: setting, at: Date(timeIntervalSince1970: TimeInterval(at)), text: text)
                guard !activity.changeRequests.contains(r) else { break }
                activity.changeRequests.append(r)
                log("\(name(ofMember: member)) asked to change \(setting?.words ?? "a setting")" + (text.isEmpty ? "" : ": \(text)"))
            case let .callState(unit, request, state, at, reason):
                // The caller says they are OK, and closes their own call where their coordinator
                // allows it; a coordinator may close anyone's (decision 6).
                let allowed = switch state {
                case .callerOK: sender.unit == unit
                case .closedByCaller: sender.unit == unit && group?.profile(ofUnit: unit).callerMayEnd == true
                default: sender.role == .coordinator
                }
                if allowed {
                    settleCall(IncomingRequest.Key(unit: unit, request: request),
                           Settled(state: state, by: signer, at: Date(timeIntervalSince1970: TimeInterval(at)), reason: reason), via: route)
                    // A coordinator's close of the household's box's call, heard off the air, goes on
                    // the radio for the box.
                    if unit == householdBoxUnit, route != .mesh, sender.unit != unit {
                        let gid = groupID
                        spawn { _ = await self.sendOnMesh(frame, kind: .optional, in: gid) }
                    }
                }
            case let .memberAdded(n, _, _, _, _, _) where n == saved?.me && signer == group?.primaryCoordinator:
                // The first coordinator lists this phone: the whole group knows it is in.
                if var s = saved, !s.confirmed { s.confirmed = true; saved = s; store.save(s); activity.notices[.unconfirmed] = nil }
            case .memberAdded, .memberRemoved, .memberName, .memberRole, .memberPhone, .changeoverEnds:
                // Any coordinator can add people; only the first can remove people or change roles,
                // so the group can never be split onto different keys or numbers.
                let allowed: Bool
                switch inner {
                case .memberRemoved, .memberRole, .changeoverEnds: allowed = signer == group?.primaryCoordinator
                // Members keep their own number up to date.
                case let .memberPhone(n, _, _): allowed = signer == n || sender.role == .coordinator
                // Another coordinator adds only callers and responders, from their own block of
                // numbers, so they cannot make someone else the first coordinator.
                case let .memberAdded(n, role, _, _, _, _):
                    let base = group?.block(of: signer) ?? 0
                    allowed = sender.role == .coordinator && (signer == group?.primaryCoordinator || (role != .coordinator && n > base && n <= base + 999))
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
                        let gid = groupID
                        let signed = HelpFrame.signing(f, as: me, identity: identity, group: gid)
                        spawn { await self.sendToAll(signed, in: gid) }
                    }
                }
            default: break
            }
            return
        case .groupSettings:
            guard var s = saved else { return }
            let old = s.group.settings
            guard s.group.apply(settings: frame) else { return }
            setState(s)
            if case let .groupSettings(signer, _, _, _) = frame { logSettings(by: signer, s.group.settings.changes(from: old), old: old) }
            followProfileCheckIns()
            return
        case .forResponders:
            // Only a responder can open it; what is inside is handled as if it came plainly (a
            // close with its reason still signed, so the rules for who may close apply).
            guard me?.canRespond == true, let g = group, let inner = ForResponders.open(frame, in: g, at: now()) else { return }
            receive(inner, via: route, opened: true)
            return
        case let .board(member, key, _):
            // A watch has no box: other members' boxes are the phone's business.
            guard !companion, member != saved?.me, frame.isValidBoard(signedBy: group?.member(member)?.signingKey, group: groupID) else { return }
            if member == group?.primaryCoordinator { heardPrimary() }
            guard activity.boardKeys[member] != key else { return }
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
            // A phone never alerts for its own calls, nor its household's box's, however they come
            // back to it.
            if isHousehold(unit) { return }
            activity.checkInWatch.apply(frame)
            if case .followUp(_, _, _, .missedCheckIn) = frame { activity.checkInWatch.heardRaised(unit: unit, at: now(), calendar: calendar) }
        }
        guard me?.canRespond == true else { return }
        switch activity.inbox.receive(frame, via: route, at: now()) {
        case let .new(key):
            log("\(describe(key.unit, key.request, activity.inbox.requests[key]?.colour)) heard over \(route.words)")
            scheduleAlerts(for: key)
        case let .updated(key) where activity.inbox.requests[key]?.isOpen == false: alerts.cancel(key)
        // A box's power-cut report: a later part (its "probably") can change what the alert says.
        case let .updated(key) where activity.inbox.requests[key]?.isPowerReport == true: scheduleAlerts(for: key)
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
        let gid = groupID
        spawn { await self.sendToAll(frame, in: gid) }
    }

    // MARK: Responding

    /// Returns whether an acknowledgement was made.
    @discardableResult
    public func acknowledge(_ key: IncomingRequest.Key) -> Bool {
        guard me?.canRespond == true, let me = saved?.me,
              let frame = activity.inbox.acknowledge(key, by: me, at: ackTime(key), identity: identity, group: groupID) else { return false }
        activity.lastAnswered[me] = now()
        alerts.cancel(key)
        log("You acknowledged \(describe(key.unit, key.request, activity.inbox.requests[key]?.colour))")
        sendAck(frame, for: key)
        return true
    }

    public func retryAck(_ key: IncomingRequest.Key) {
        guard let me = saved?.me else { return }
        sendAck(.signedAck(unit: key.unit, request: key.request, responder: me, at: ackTime(key), identity: identity, group: groupID), for: key)
    }

    /// Never before the call was pressed, so a responder whose clock is slow is still counted by
    /// a caller on a build from before 2026-11-07, which took only acknowledgements made after
    /// the press.
    private func ackTime(_ key: IncomingRequest.Key) -> Date {
        // A call frame anyone in the group could forge cannot push an acknowledgement into the future.
        min(max(now(), activity.inbox.requests[key]?.sentAt ?? .distantPast), now().addingTimeInterval(OutgoingRequest.clockAllowance))
    }

    private func sendAck(_ frame: HelpFrame, for key: IncomingRequest.Key) {
        let routes = RoutePlan.firstAttempt(available: availableRoutes, smsIsAutomatic: false)
        ackSends[key] = Dictionary(uniqueKeysWithValues: routes.map { ($0, RouteState.sending) })
        if routes.isEmpty { ackSends[key] = [.mesh: .failed(mesh.unavailableReason)] }
        // Results from an earlier attempt must not overwrite this one's.
        let attempt = UUID()
        ackAttempt[key] = attempt
        let gid = groupID
        for route in routes {
            spawn {
                let failure = route == .internet ? await self.sendOnInternet(frame, wake: .quiet, in: gid) : await self.send(frame, on: route, kind: .call, in: gid)
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
        let at = r.escalatesFrom
        let responders = group.members.filter { $0.canRespond && !group.isHousehold($0, ofUnit: r.key.unit) }.map {
            ResponderInfo(member: $0.number, availableNow: activity.rota.isAvailable($0.number, at: at), lastAnsweredAt: activity.lastAnswered[$0.number])
        }
        return Escalation(colour: r.colour ?? .red, responders: responders, policy: group.escalationPolicy(forUnit: r.key.unit))
    }

    /// Every phone works out the order from the same group, rota and record of who answered, and
    /// alerts its own person from their turn, counted from when the caller pressed, until someone
    /// acknowledges.
    private func scheduleAlerts(for key: IncomingRequest.Key) {
        guard let r = activity.inbox.requests[key], r.isOpen, let e = escalation(for: r), let me = self.me?.number, self.me?.canRespond == true else { return }
        let calm = r.colour == .green || r.callerIsOK || r.isPowerReport
        let turn = TimeInterval(e.order.firstIndex(of: me) ?? e.order.count) * e.interval
        let turnAt = r.escalatesFrom.addingTimeInterval(turn)
        // "I'm OK" asks for no one: tell them once, calmly, and never again.
        if r.colour == .green {
            guard !activity.alertedGreens.contains(key) else { return }
            activity.alertedGreens.insert(key)
        }
        // iOS keeps at most 64 pending notifications per app: up to four go to check-in reminders,
        // the rest are shared between open requests. A long tail keeps alerting with the app asleep.
        let open = max(activity.inbox.requests.values.filter { $0.isOpen && $0.colour != .green }.count, 1)
        let count = max(3, 58 / open)
        let t = now()
        let times: [Date]
        switch r.colour {
        case .green?: times = [max(turnAt, t)]
        // A box's power cut at someone's home: nobody pressed, so calm reminders, spaced out.
        case nil where r.isPowerReport: times = alertTimes(turnAt: turnAt, every: 1800, quick: 2, later: 7200, from: t, count: count)
        // The caller said they are OK after it: calm reminders, as often and as many as their
        // coordinator chose, until a responder has checked.
        case _ where r.callerIsOK:
            let p = group?.profile(ofUnit: key.unit) ?? .standard
            // From when they said so, but never before this phone heard the call or after now,
            // whatever the caller's clock says.
            let start = max(turnAt, min(max(r.settled?.at ?? t, r.firstHeardAt), t))
            if let limit = p.calmReminders {
                // Counted from when they said so, so topping up never adds more.
                times = Array(alertTimes(turnAt: start, every: p.calmEvery, from: start, count: max(limit, 1))
                    .filter { $0 >= t.addingTimeInterval(-1) }.prefix(count))
            } else {
                times = alertTimes(turnAt: start, every: p.calmEvery, from: t, count: count)
            }
        case .amber?: times = alertTimes(turnAt: turnAt, every: 300, quick: 6, later: 1800, from: t, count: count)
        default: times = alertTimes(turnAt: turnAt, every: 60, quick: 10, later: 600, from: t, count: count)
        }
        let who = name(ofUnit: key.unit)
        var title = "\(who): \(ButtonWords.words(r.colour ?? .red, in: group?.profile(ofUnit: key.unit)))"
        if key.request == 0 { title = "\(who) missed a check-in" }
        if r.callerIsOK { title = "\(who) says they're OK now" }
        if r.isPowerReport { title = r.powerCutIsProbable ? "\(who): probably a power cut at home" : "\(who): power cut at home" }
        let body = r.isPowerReport ? "Their box is on its battery. Please check on them when you can, then acknowledge in Help&I."
            : r.callerIsOK ? "Please check on them, then acknowledge in Help&I." : "Open Help&I to acknowledge."
        alerts.schedule(Alert(key: key, title: title, body: body, calm: calm, times: times))
    }

    /// Re-schedules each open request's alerts from now, so they keep coming however long it takes.
    private func topUpAlerts() {
        for r in activity.inbox.requests.values where r.isOpen && r.colour != .green {
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
        let gid = groupID
        let signed = HelpFrame.signing(frame, as: me, identity: identity, group: gid)
        spawn { _ = await self.sendOptional(signed, in: gid) }
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
        guard notice.isShared else { return }
        let frame = HelpFrame.signing(.noticeAck(notice: notice, by: me, at: UInt32(now().timeIntervalSince1970)), as: me,
                                      identity: identity, group: groupID)
        let gid = groupID
        spawn { _ = await self.sendOptional(frame, in: gid) }
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
        merged.removalsWithoutKeys = current.removalsWithoutKeys.subtracting(update.removedMembers)
        merged.keysOutdatedSince = current.removedMembers.isSubset(of: update.removedMembers) ? nil : current.keysOutdatedSince
        merged.keysEndAt = merged.keysOutdatedSince == nil ? nil : current.keysEndAt
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
        // The newer settings stay, by version and then signer, as if heard in a settings frame.
        let updateIsNewer = update.settingsVersion > current.settingsVersion
            || (update.settingsVersion == current.settingsVersion && update.settingsSigner != 0 && update.settingsSigner < current.settingsSigner)
        if !updateIsNewer {
            merged.policy = current.policy
            merged.relayURL = current.relayURL
            merged.relayPass = current.relayPass
            merged.settingsVersion = current.settingsVersion
            merged.settingsSigner = current.settingsSigner
        }
        // An update made before the relay address was first set has none: keep this phone's.
        if !updateIsNewer || update.settingsVersion == 0, merged.relayURL == nil { merged.relayURL = current.relayURL }
        // A pass is only ever replaced, never taken away, so an update without one keeps this phone's.
        if merged.relayPass == nil { merged.relayPass = current.relayPass }
        changeGroup(edit: false) { $0 = merged }
        activity.tookOverFirst = nil
        // Only the first coordinator could have sealed it.
        heardPrimary()
    }

    // MARK: If the first coordinator's phone is lost (decision 20)

    /// What the relay said owns the group, from its answer to a poll or to this phone's own
    /// takeover: a takeover to them is the one every phone follows.
    public func relayOwner(is key: Data) {
        guard activity.relayOwner != key else { return }
        activity.relayOwner = key
        settleTakeovers()
    }

    /// Follows the takeover every phone settles on (`GroupState.prefers`) of those heard: one from
    /// the first coordinator this phone accepts, or a rival preferred to the one it follows.
    private func settleTakeovers() {
        guard var s = saved else { return }
        let owner = activity.relayOwner
        let best = { (ts: [Takeover]) in ts.min { s.group.prefers($0, over: $1, relayOwner: owner) } }
        if let held = s.group.takeover,
           let rival = best(activity.heardTakeovers.filter { s.group.acceptsRival($0, relayOwner: owner) && s.group.prefers($0, over: held, relayOwner: owner) }) {
            let mine = held.to == s.me
            s.group.follow(rival, me: s.me, at: now())
            // The one let go stays heard, should the relay turn out to have taken it.
            activity.heardTakeovers.removeAll { $0 == rival }
            keepHeard(heard(held))
            activity.tookOverFirst = mine ? rival.to : nil
            setState(s)
            if rival.to == s.me {
                log("You are first coordinator after all: the relay took your takeover")
                let gid = groupID
                spawn { await self.sendToAll(.takeover(rival), in: gid) }
            } else if mine {
                log("\(name(ofMember: rival.to)) also took over as first coordinator, and the group follows them rather than you")
            } else {
                log("\(name(ofMember: rival.to)) took over as first coordinator, in place of \(name(ofMember: held.to))")
            }
        } else if let t = best(activity.heardTakeovers.filter { s.group.accepts($0, silent: primaryIsSilent, relayOwner: owner) }) {
            let words = "\(name(ofMember: t.to)) took over as first coordinator from \(t.from == s.me ? "you" : name(ofMember: t.from)), \(how(t))"
            s.group.apply(takeover: t, at: now())
            s.primaryHeardAt = now()
            activity.heardTakeovers.removeAll { $0 == t }
            setState(s)
            activity.takeoverConsents = [:]
            activity.takeoverAgreed = []
            log(words)
        }
    }

    /// The latest heard of each coordinator's takeover of each lost phone, a few at most.
    private func keepHeard(_ t: Takeover) {
        activity.heardTakeovers = (activity.heardTakeovers.filter { $0.from != t.from || $0.to != t.to } + [t]).suffix(8)
    }

    /// A takeover as heard on air, without what a phone keeps with the one it follows.
    private func heard(_ t: Takeover) -> Takeover {
        var t = t
        t.fromKey = Data(); t.deputyVersionBefore = nil; t.keysGeneration = nil
        return t
    }

    /// `at` is when the first coordinator's phone made what was heard, where it says.
    private func heardPrimary(at made: Date? = nil) {
        let at = min(made ?? now(), now())
        guard var s = saved, at.timeIntervalSince(s.primaryHeardAt ?? .distantPast) > 60 else { return }
        s.primaryHeardAt = at
        saved = s
        store.save(s)
    }

    /// When one other coordinator alone may take over: seven days after the first coordinator
    /// was last heard from. Nil on the first coordinator's own phone.
    public var takeoverOpensAt: Date? {
        guard !isPrimaryCoordinator else { return nil }
        return saved?.primaryHeardAt.map { $0.addingTimeInterval(GroupState.takeoverSilence) }
    }

    public var primaryIsSilent: Bool { takeoverOpensAt.map { now() >= $0 } ?? false }

    public enum TakeoverPath: Equatable, Sendable { case deputy, agreed(by: UInt16), silence }

    /// How this coordinator may take over now, if at all (decision 20): as the deputy the first
    /// coordinator named, with another coordinator's agreement, or alone after seven days' silence.
    /// Alone only with a relay, which has the last word on the silence: without one, a phone that
    /// alone heard nothing could not tell, so a second coordinator must agree.
    public var takeoverPath: TakeoverPath? {
        guard let g = group, let me = saved?.me, actsAsCoordinator, !isPrimaryCoordinator else { return nil }
        if g.currentDeputy == me, g.deputySignature != nil { return .deputy }
        if let by = activity.takeoverConsents.keys.sorted().first(where: { g.member($0)?.role == .coordinator }) { return .agreed(by: by) }
        return primaryIsSilent && relay.isConfigured ? .silence : nil
    }

    /// The first coordinator names a coordinator to take over if their phone is lost, or no one.
    public func nameDeputy(_ number: UInt16?) {
        guard isPrimaryCoordinator, !companion, let g = group, let me = saved?.me, number != me else { return }
        let key: Data
        if let number {
            guard let m = g.member(number), m.role == .coordinator, let k = m.signingKey else { return }
            key = k
        } else {
            key = Data(count: 32)
        }
        let frame = HelpFrame.signedDeputy(member: number ?? 0, key: key, version: g.deputyVersion + 1, identity: identity, group: groupID)
        guard case let .deputy(_, _, version, sig) = frame else { return }
        updateGroup { $0.deputy = number; $0.deputyVersion = version; $0.deputySignature = sig }
        log(number.map { "You named \(name(ofMember: $0)) as deputy" } ?? "You named no deputy")
        let gid = groupID
        spawn { await self.sendToAll(frame, in: gid) }
    }

    /// A coordinator agrees that another may take over from the first coordinator: with two
    /// coordinators behind it, a takeover needs no waiting.
    public func agreeToTakeover(by number: UInt16) {
        guard let g = group, let me = saved?.me, actsAsCoordinator, let from = g.primaryCoordinator, number != me, number != from,
              let to = g.member(number), to.role == .coordinator, let fromKey = g.member(from)?.signingKey, let toKey = to.signingKey else { return }
        let sig = HelpFrame.takeoverSignature(fromKey: fromKey, toKey: toKey, identity: identity, group: groupID)
        activity.takeoverAgreed.insert(number)
        log("You agreed that \(to.name) may take over as first coordinator")
        let gid = groupID
        spawn { await self.sendToAll(.takeoverConsent(from: from, to: number, signer: me, signature: sig), in: gid) }
    }

    /// Takes over as first coordinator, by whichever path is open. The lost phone is removed and
    /// the group gets new keys, which this phone then hands out as after any removal. Returns
    /// whether it happened now; alone after seven days, it happens only once the relay agrees.
    @discardableResult
    public func takeOver() -> Bool {
        guard let g = group, let me = saved?.me, let path = takeoverPath, let from = g.primaryCoordinator, let fromKey = g.member(from)?.signingKey else { return false }
        let mine = Takeover.Signature(signer: me, signature: HelpFrame.takeoverSignature(fromKey: fromKey, toKey: identity.signingPublicKey, identity: identity, group: groupID))
        var t = Takeover(from: from, to: me, version: g.membershipVersion + 1, signatures: [mine])
        switch path {
        case .deputy: t.deputyVersion = g.deputyVersion; t.deputySignature = g.deputySignature
        case let .agreed(by): if let sig = activity.takeoverConsents[by] { t.signatures.append(.init(signer: by, signature: sig)) }
        case .silence: break
        }
        guard g.accepts(t, silent: primaryIsSilent) else { return false }
        if path == .silence {
            askRelay(toTakeOver: t)
            return false
        }
        becomeFirstCoordinator(t)
        return true
    }

    /// Only the relay hears every request the first coordinator's phone makes, so alone after
    /// seven days the takeover goes to the relay first and is made only once it is taken: a
    /// phone that alone heard nothing (abroad, say) does not split off with keys of its own.
    private func askRelay(toTakeOver t: Takeover) {
        guard let g = group, !askingRelayToTakeOver else { return }
        var after = g
        after.takeOver(t, at: now())
        let list = RelayProtocol.memberList(after)
        let first = name(ofMember: t.from)
        askingRelayToTakeOver = true
        takeoverProblem = nil
        spawn {
            let result = await self.relay.publish(list)
            self.askingRelayToTakeOver = false
            switch result {
            case .accepted:
                // Taken by the relay, it is the one every phone follows, even where this phone
                // followed another coordinator's takeover meanwhile.
                if self.group?.primaryCoordinator == t.from { self.becomeFirstCoordinator(t) } else { self.keepHeard(t) }
                self.relayOwner(is: self.identity.signingPublicKey)
            case .notYet: self.takeoverProblem = "\(first)'s phone has been in touch in the last week, so it cannot be taken over yet."
            case .refused: self.takeoverProblem = "The relay did not take it, so nothing has changed."
            case .unreachable: self.takeoverProblem = "The relay could not be reached, so nothing has changed. Try again with internet."
            }
        }
    }

    private func becomeFirstCoordinator(_ t: Takeover) {
        let words = "You took over as first coordinator from \(name(ofMember: t.from)), \(how(t))"
        updateGroup { $0.takeOver(t, at: self.now()) }
        activity.takeoverConsents = [:]
        activity.takeoverAgreed = []
        log(words)
        let gid = groupID
        spawn { await self.sendToAll(.takeover(t), in: gid) }
    }

    /// The path a takeover came by, for the log; from the group before it is applied.
    private func how(_ t: Takeover) -> String {
        guard let g = group, let fromKey = g.member(t.from)?.signingKey, let toKey = g.member(t.to)?.signingKey else { return "" }
        if t.namedDeputy(fromKey: fromKey, toKey: toKey, group: groupID) { return "as the deputy they named" }
        if let other = t.signatures.first(where: { $0.signer != t.to }) {
            return other.signer == saved?.me ? "with your agreement" : "with \(name(ofMember: other.signer))'s agreement"
        }
        return "after seven days without word from them"
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

    /// Takes a pasted relay pass, if it reads as one for this group. Returns whether it was kept:
    /// not when it does not read as one, nor when it takes the settings past what can be sent to
    /// everyone (`settingsProblem` says so).
    @discardableResult
    public func setRelayPass(_ token: String) -> Bool {
        guard let group, let pass = RelayPass(token), pass.isFor(group.secrets) else { return false }
        updateGroup { $0.relayPass = pass.token }
        return self.group?.relayPass == pass.token
    }

    // MARK: Profiles

    /// The settings that apply to this person now (`SavedState.profile`).
    public var profile: Profile { saved?.profile ?? .standard }

    /// Changes this person's own choices. Only the settings their profile lets them change count.
    public func setOwn(_ change: (inout Profile) -> Void) {
        guard var s = saved else { return }
        let before = s.profile
        var own = before
        change(&own)
        s.ownChosen.formUnion(own.differences(from: before))
        s.own = own
        setState(s)
    }

    /// Asks the group's coordinators to change one of this person's settings. Over the internet
    /// and home Wi-Fi only, as what they write is personal. Returns why it could not go, if it could not.
    public func askCoordinator(about setting: Profile.Setting?, _ text: String) async -> String? {
        guard let n = saved?.me else { return "Not in a group" }
        guard canSendOffAir else { return "Needs the internet route, or another of the group's phones on this Wi-Fi" }
        let words = MeshText.fit(text.trimmingCharacters(in: .whitespacesAndNewlines), bytes: HelpFrame.maxRequestBytes)
        let frame = HelpFrame.changeRequest(member: n, setting: setting, at: UInt32(now().timeIntervalSince1970), text: words)
        // Only a coordinator's phone takes it in, so only theirs counts on home Wi-Fi.
        let coordinators = Set(group?.members.filter { $0.role == .coordinator }.map(\.number) ?? [])
        return await sendOffAir(.signing(frame, as: n, identity: identity, group: groupID), to: coordinators, in: groupID)
    }

    public func dismiss(_ request: ChangeRequest) { activity.changeRequests.removeAll { $0 == request } }

    /// Check-ins set by a profile the person may not change replace their own.
    private func followProfileCheckIns() {
        guard !companion, let s = saved, me?.canCall == true else { return }
        let p = s.group.profile(of: s.me)
        guard !p.mayChange(.checkIns), s.checkIn != p.checkIns else { return }
        setCheckIn(p.checkIns)
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
        let gid = groupID
        if only == nil, canSendOffAir, let me = saved?.me {
            _ = await sendOffAir(.signing(frame, as: me, identity: identity, group: gid), in: gid)
        }
        await sendDirect(frame, to: only, in: gid)
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
                log("\(name(ofUnit: unit)) missed a check-in")
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
        lastWatchRequest = try c.value(.lastWatchRequest, or: 0)
        checkIn = try c.decodeIfPresent(CheckInSchedule.self, forKey: .checkIn)
        checkInSince = try c.decodeIfPresent(Date.self, forKey: .checkInSince)
        checkInRaised = try c.decodeIfPresent(Date.self, forKey: .checkInRaised)
        checkInSharedAt = try c.decodeIfPresent(Date.self, forKey: .checkInSharedAt)
        invitedBy = try c.decodeIfPresent(UInt16.self, forKey: .invitedBy)
        confirmed = try c.value(.confirmed, or: true)
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
        own = try c.decodeIfPresent(Profile.self, forKey: .own)
        ownChosen = try c.value(.ownChosen, or: [])
        // Saved before decision 20: the seven days start when this version first opens it.
        primaryHeardAt = try c.decodeIfPresent(Date.self, forKey: .primaryHeardAt) ?? Date()
    }
}

extension Activity {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outgoing = c.values(.outgoing)
        inbox = try c.value(.inbox, or: ResponderInbox())
        rota = try c.value(.rota, or: Rota())
        lastAnswered = try c.value(.lastAnswered, or: [:])
        greens = try c.value(.greens, or: [])
        airtime = try c.decodeIfPresent(AirtimeBudget.self, forKey: .airtime)
        checkInWatch = try c.value(.checkInWatch, or: CheckInWatch())
        boardKeys = try c.value(.boardKeys, or: [:])
        notices = try c.value(.notices, or: [:])
        alertedGreens = try c.value(.alertedGreens, or: [])
        log = try c.value(.log, or: GroupLog())
        lastSettingsChange = try c.decodeIfPresent(GroupLog.Entry.self, forKey: .lastSettingsChange)
        changeRequests = c.values(.changeRequests)
        closeRepeats = c.values(.closeRepeats)
        lastMembershipRepeat = try? c.decodeIfPresent(Date.self, forKey: .lastMembershipRepeat)
        takeoverConsents = try c.value(.takeoverConsents, or: [:])
        takeoverAgreed = try c.value(.takeoverAgreed, or: [])
        relayOwner = try c.decodeIfPresent(Data.self, forKey: .relayOwner)
        heardTakeovers = c.values(.heardTakeovers)
        tookOverFirst = try c.decodeIfPresent(UInt16.self, forKey: .tookOverFirst)
    }
}
