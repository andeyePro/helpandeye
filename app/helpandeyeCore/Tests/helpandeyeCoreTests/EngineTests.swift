import XCTest
@testable import helpandeyeCore

// Several phones, each a HelpEngine, over a fake radio and a fake relay, with one clock.

@MainActor final class Clock { var now = Date(timeIntervalSince1970: 1_793_000_000) }

@MainActor final class Air {
    var phones: [Phone] = []
    var queue: [(from: Phone, to: Phone, deliver: () -> Void)] = []
    /// Return false to lose a packet.
    var keep: (HelpFrame, Phone, Phone) -> Bool = { _, _, _ in true }
    var groupSends: [HelpFrame] = []
    var directSends: [String] = []
    var violations: [String] = []
    let relay = RelayModel()
    var relayLog: [(String, RelayProtocol.MemberList, Int, Data)] = []

    func run() async {
        for _ in 0..<50 {
            for p in phones { await p.engine.settle() }
            guard !queue.isEmpty else { return }
            let batch = queue
            queue = []
            for q in batch { q.deliver() }
        }
    }
}

@MainActor final class FakeMesh: MeshLink {
    weak var air: Air?
    weak var phone: Phone?
    var isReady = true
    var radio: RadioSettings? = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8)
    let boxPublicKey: Data? = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    var channelsPerSend: Int { max(secrets.count, 1) }
    var unavailableReason = "No box connected"
    var secrets: [Data] = []

    func send(_ frame: HelpFrame, urgent: Bool) async -> MeshSendResult {
        guard isReady, let air, let me = phone else { return .refused("No box connected") }
        air.groupSends.append(frame)
        for p in air.phones where p !== me && p.mesh.isReady && !Set(p.mesh.secrets).isDisjoint(with: secrets) {
            guard air.keep(frame, me, p) else { continue }
            air.queue.append((me, p, { p.engine.receive(frame, via: .mesh) }))
        }
        return .sent
    }

    func sendText(_ text: String, to key: Data) async -> MeshSendResult {
        guard isReady, let air, let me = phone, let mine = boxPublicKey else { return .refused("No box connected") }
        air.directSends.append(text)
        if !(phone?.engine.activity.boardKeys.values.contains(key) ?? false) { air.violations.append("direct message to a box this phone does not list") }
        for p in air.phones where p.mesh.boxPublicKey == key {
            air.queue.append((me, p, { p.engine.receiveText(from: mine.prefix(6), text) }))
        }
        return .sent
    }

    func addContact(_ key: Data, name: String) async {}
}

/// The relay's membership rules (relay/src/relay.js, `setMembers` and `requireMember`), so the
/// fakes refuse what the real relay refuses. RelayModelVectorTests checks it against the real one.
final class RelayModel {
    struct Entry: Equatable { let key: String; let role: String }
    var owner: String?
    var removed: Set<String> = []
    var generation: UInt32 = 0
    var ownerGeneration: Int64 = -1
    var members: [Entry] = []
    var addedBy: [String: String] = [:]
    private var started = false
    static let maxMembers = 256

    /// 200, or the status the relay would refuse with.
    func setMembers(signer: String, generation g: UInt32, members list: [Entry], removed named: [String], primary: String?, groupID: Data?) -> Int {
        let isKey: (String) -> Bool = { $0.range(of: #"^[A-Za-z0-9+/]{43}=$"#, options: .regularExpression) != nil }
        if !named.allSatisfy(isKey) { return 400 }
        if !list.allSatisfy({ isKey($0.key) && ["coordinator", "member"].contains($0.role) }) { return 400 }
        if list.count > Self.maxMembers || named.count > 1024 { return 413 }
        if Set(list.map(\.key)).count != list.count { return 400 }
        var owner = self.owner
        if !started {
            guard let primary, list.contains(where: { $0.key == primary && $0.role == "coordinator" }) else { return 400 }
            if let groupID, let key = Data(base64Encoded: primary), !GroupSecrets(groupID: groupID, channelSecret: Data(), groupKey: Data(), generation: 0).isOwned(by: key) { return 403 }
            if !list.contains(where: { $0.key == signer && $0.role == "coordinator" }) { return 400 }
            owner = primary
        } else {
            if !members.contains(where: { $0.key == signer && $0.role == "coordinator" }) { return 403 }
            if let primary, primary != owner { return 409 }
        }
        var removed = self.removed
        if signer != owner && named.contains(where: { !removed.contains($0) }) { return 403 }
        if let owner, named.contains(owner) { return 409 }
        let ownerFresh = signer == owner && Int64(g) >= ownerGeneration
        var order = members.map(\.key)
        var roles = Dictionary(members.map { ($0.key, $0.role) }, uniquingKeysWith: { a, _ in a })
        var addedBy = self.addedBy
        for m in list where !removed.contains(m.key) {
            if roles[m.key] == nil {
                let asListed = ownerFresh || (!started && (m.key == owner || m.key == signer))
                roles[m.key] = asListed ? m.role : "member"
                order.append(m.key)
                addedBy[m.key] = signer
            } else if ownerFresh {
                roles[m.key] = m.role
            }
        }
        if signer == owner {
            let listed = Set(list.map(\.key))
            for k in named where !removed.contains(k) {
                removed.insert(k)
                if members.contains(where: { $0.key == k && $0.role == "coordinator" }) {
                    for (key, by) in addedBy where by == k && !listed.contains(key) { roles[key] = nil }
                }
            }
        }
        for k in removed { roles[k] = nil; addedBy[k] = nil }
        if roles.count > Self.maxMembers || removed.count > 1024 { return 413 }
        self.owner = owner; self.removed = removed; started = true
        self.addedBy = addedBy.filter { roles[$0.key] != nil }
        if ownerFresh { ownerGeneration = Int64(g) }
        generation = max(generation, g)
        members = order.compactMap { k in roles[k].map { Entry(key: k, role: $0) } }
        return 200
    }

    func isMember(_ key: String) -> Bool { members.contains { $0.key == key } }
}

@MainActor final class FakeRelay: RelayLink {
    weak var air: Air?
    weak var phone: Phone?
    var isConfigured = false
    var lastProblem: String?
    var sent: [(HelpFrame, RelayWake?)] = []
    /// The relay address this phone was using when it sent each frame.
    var sentVia: [String?] = []
    var configured = 0
    private var group: GroupState?
    private var identity: DeviceIdentity?
    var key: String? { identity?.signingPublicKey.base64EncodedString() }

    func configure(group: GroupState?, identity: DeviceIdentity) { configured += 1; self.group = group; self.identity = identity }

    var publishes = 0
    func publishMembers() async -> PublishResult {
        guard isConfigured, let air, let group, let key else { return .unreachable }
        publishes += 1
        let list = RelayProtocol.memberList(group)
        let status = air.relay.setMembers(signer: key, generation: list.generation, members: list.members.map { .init(key: $0.key, role: $0.role) },
                                          removed: list.removed, primary: list.primary, groupID: group.secrets.groupID)
        air.relayLog.append((key, list, status, group.secrets.groupID))
        return status == 200 ? .accepted : .refused
    }

    func send(_ frame: HelpFrame, wake: RelayWake?) async -> String? {
        guard isConfigured, let air, let me = phone, let key else { return "No internet" }
        guard air.relay.isMember(key) else { return "Relay refused it (403)" }
        sent.append((frame, wake))
        sentVia.append(group?.relayURL)
        for p in air.phones where p !== me && p.relay.isConfigured && p.relay.key.map(air.relay.isMember) == true {
            air.queue.append((me, p, { p.engine.receive(frame, via: .internet) }))
        }
        return nil
    }
}

/// Home Wi-Fi: phones given the same `network` reach each other directly.
@MainActor final class FakeLocal: LocalLink {
    weak var air: Air?
    weak var phone: Phone?
    var network: String?
    var sent: [HelpFrame] = []
    private var groupID: Data?
    var isEnabled: Bool { network != nil }
    var unavailableReason: String { network == nil ? "Not on Wi-Fi" : "No other phones of the group on this Wi-Fi" }
    func configure(group: GroupState?, me: UInt16?, identity: DeviceIdentity) { groupID = group?.secrets.groupID }
    var peers: [Phone] {
        guard let air, let network, let me = phone else { return [] }
        return air.phones.filter { $0 !== me && $0.wifi.network == network && $0.wifi.groupID == groupID && groupID != nil }
    }
    var hasPeers: Bool { !peers.isEmpty }
    func send(_ frame: HelpFrame) async -> String? {
        guard let air, let me = phone, !peers.isEmpty else { return unavailableReason }
        sent.append(frame)
        for p in peers where air.keep(frame, me, p) { air.queue.append((me, p, { p.engine.receive(frame, via: .wifi) })) }
        return nil
    }
}

@MainActor final class FakeAlerts: AlertScheduler {
    var scheduled: [IncomingRequest.Key: Alert] = [:]
    var cancelled: Set<IncomingRequest.Key> = []
    func schedule(_ alert: Alert) { scheduled[alert.key] = alert; cancelled.remove(alert.key) }
    func cancel(_ key: IncomingRequest.Key) { scheduled[key] = nil; cancelled.insert(key) }
    func cancelAll() { scheduled = [:] }
    func setCheckInReminders(_ minutes: [Int]) {}
    var toldCaller: [String] = []
    func tellCaller(title: String, body: String) { toldCaller.append(title) }
}

@MainActor final class NoStore: EngineStore {
    func save(_ state: SavedState?) {}
    func save(_ activity: Activity) {}
}

@MainActor final class Phone {
    let identity: DeviceIdentity
    /// Replaced when a test closes and reopens the app.
    let mesh = FakeMesh()
    let relay = FakeRelay()
    let wifi = FakeLocal()
    let alerts = FakeAlerts()
    var engine: HelpEngine!

    /// `watchOf` makes this the paired watch of that phone, acting as the same member.
    init(air: Air, clock: Clock, watchOf owner: Phone? = nil) {
        identity = owner?.identity ?? DeviceIdentity()
        mesh.air = air; relay.air = air
        engine = HelpEngine(identity: identity, mesh: mesh, relay: relay, alerts: alerts, store: NoStore(),
                            saved: nil, activity: Activity(), calendar: Calendar(identifier: .gregorian), now: { clock.now },
                            companion: owner != nil, homeWiFi: wifi)
        mesh.phone = self; relay.phone = self; wifi.phone = self; wifi.air = air
        engine.bandChanged(mesh.radio?.band)
        air.phones.append(self)
    }

    var request: OutgoingRequest? { engine.current }
}

@MainActor final class EngineTests: XCTestCase {
    var air: Air!
    var clock: Clock!
    var coordinator: Phone!   // responds too
    var caller: Phone!
    var responder: Phone!

    override func setUp() async throws {
        air = Air(); clock = Clock()
        coordinator = Phone(air: air, clock: clock)
        caller = Phone(air: air, clock: clock)
        responder = Phone(air: air, clock: clock)
        coordinator.engine.createGroup(name: "Mill Lane", myName: "Sam", call: false)
        join(caller, call: true, respond: false)
        join(responder, call: false, respond: true)
        await air.run()
        for p in air.phones { await p.engine.boxReady() }
        await air.run()
        // Start each test with an empty record of what went out.
        air.groupSends = []; air.directSends = []
    }

    func join(_ p: Phone, call: Bool, respond: Bool) {
        let c = coordinator.engine!
        let invite = Joining.invitation(for: c.group!, coordinator: coordinator.identity)
        let request = Joining.request(invite, name: call ? "Caller" : "Responder", call: call, respond: respond, me: p.identity)
        var welcome: Joining.Welcome?
        c.updateGroup { g in welcome = try! Joining.admit(request, to: &g, invite: invite, coordinator: coordinator.identity) }
        p.engine.joined(try! Joining.open(welcome!, invite: invite, me: p.identity), as: welcome!.memberNumber)
    }

    /// What happens when the coordinator enters the relay's address: the member list is published.
    func relaySetUp() async {
        coordinator.engine.tick()
        await air.run()
    }

    func advance(_ seconds: TimeInterval) async {
        clock.now = clock.now.addingTimeInterval(seconds)
        for p in air.phones { p.engine.tick() }
        await air.run()
    }

    var gid: Data { caller.engine.group!.secrets.groupID }
    var key: IncomingRequest.Key { IncomingRequest.Key(unit: caller.request!.unit, request: caller.request!.number) }

    func testAPressReachesRespondersAndOnlyAHumanAckShowsSeen() async {
        caller.engine.press(.red)
        await air.run()
        XCTAssertEqual(caller.request?.status, .waitingForResponder)
        XCTAssertNotNil(responder.alerts.scheduled[key], "the responder is alerted")
        XCTAssertNotNil(coordinator.alerts.scheduled[key], "so is the coordinator, at their turn")
        await advance(3600)
        XCTAssertEqual(caller.request?.status, .waitingForResponder, "an hour later, still waiting: nothing acknowledges by itself")
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(caller.request?.status, .seen(responder: responder.engine.saved!.me))
        XCTAssertNil(coordinator.alerts.scheduled[key], "the ack cancels alerts on every responder's phone")
        XCTAssertTrue(coordinator.alerts.cancelled.contains(key))
    }

    func testALostFirstPacketIsRepairedByAResend() async {
        var losing = true
        air.keep = { frame, _, _ in
            if case .call = frame, losing { return false }
            return true
        }
        caller.engine.press(.red)
        await air.run()
        XCTAssertNil(responder.alerts.scheduled[key], "the first packet was lost")
        losing = false
        await advance(30)
        XCTAssertNotNil(responder.alerts.scheduled[key], "the resend got through")
    }

    func testForgedAndRemovedAcksNeverReassure() async {
        caller.engine.press(.red)
        await air.run()
        let responderNumber = responder.engine.saved!.me
        let stranger = DeviceIdentity()
        caller.engine.receive(.signedAck(unit: key.unit, request: key.request, responder: responderNumber, at: clock.now, identity: stranger, group: gid), via: .mesh)
        XCTAssertEqual(caller.request?.status, .waitingForResponder, "a forged signature does not count")
        coordinator.engine.updateGroup { $0.remove(responderNumber, at: clock.now) }
        await air.run()
        XCTAssertNil(caller.engine.group?.member(responderNumber), "the caller heard of the removal")
        caller.engine.receive(.signedAck(unit: key.unit, request: key.request, responder: responderNumber, at: clock.now, identity: responder.identity, group: gid), via: .mesh)
        XCTAssertEqual(caller.request?.status, .waitingForResponder, "a removed responder's ack does not count")
    }

    func testTheInternetRouteAloneWorksAndAsksForAPush() async {
        for p in air.phones { p.mesh.isReady = false; p.relay.isConfigured = true }
        await relaySetUp()
        caller.engine.press(.red)
        await air.run()
        XCTAssertEqual(caller.request?.routes[.internet], .sent)
        XCTAssertEqual(caller.request?.routes[.mesh], .failed("No box connected"))
        XCTAssertEqual(caller.relay.sent.first?.1, .call, "the first send asks the relay to wake the others")
        XCTAssertNotNil(responder.alerts.scheduled[key])
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(responder.relay.sent.last?.1, .quiet, "an ack only wakes the caller's app")
        XCTAssertEqual(caller.request?.status, .seen(responder: responder.engine.saved!.me))
        await advance(30)
        XCTAssertFalse(caller.relay.sent.dropFirst().contains { $0.1 == .call }, "resends do not push")
    }

    func testTheCoordinatorsNumberReachesMembersWhoJoin() async {
        let other = Phone(air: air, clock: clock)
        coordinator.engine.setMyPhone("+44 7700 900111")
        join(other, call: true, respond: false)
        XCTAssertEqual(other.engine.group?.member(1)?.phone, "+447700900111")
        XCTAssertEqual(RoutePlan.smsRecipients(in: other.engine.group, me: other.engine.saved?.me), ["+447700900111"])
    }

    func testAMembersOwnNumberReachesTheGroupOverTheInternetOnly() async {
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        let n = responder.engine.saved!.me
        responder.engine.setMyPhone("07700 900222")
        await air.run()
        XCTAssertEqual(caller.engine.group?.member(n)?.phone, "07700900222")
        XCTAssertEqual(coordinator.engine.group?.member(n)?.phone, "07700900222")
        XCTAssertFalse(air.groupSends.contains { $0.encoded().contains(Data("07700900222".utf8)) }, "a number never goes on the radio")
        await advance(60)
        responder.engine.setMyPhone("")
        await air.run()
        XCTAssertNil(caller.engine.group?.member(n)?.phone, "clearing it clears it everywhere")
    }

    func testOnlyTheMemberOrACoordinatorCanChangeTheirNumber() async {
        let n = responder.engine.saved!.me
        let callerNumber = caller.engine.saved!.me
        let forged = HelpFrame.signing(.memberPhone(member: n, phone: "+449999", at: UInt32(clock.now.timeIntervalSince1970) + 10),
                                       as: callerNumber, identity: caller.identity, group: gid)
        coordinator.engine.receive(forged, via: .internet)
        XCTAssertNil(coordinator.engine.group?.member(n)?.phone, "another member cannot redirect someone's texts")
        let old = HelpFrame.signing(.memberPhone(member: n, phone: "+441111", at: 5), as: n, identity: responder.identity, group: gid)
        let new = HelpFrame.signing(.memberPhone(member: n, phone: "+442222", at: 6), as: n, identity: responder.identity, group: gid)
        coordinator.engine.receive(new, via: .internet)
        coordinator.engine.receive(old, via: .internet)
        XCTAssertEqual(coordinator.engine.group?.member(n)?.phone, "+442222", "an older change heard late does not win")
    }

    func testNoRouteGivesTheCrossAtOnce() async {
        caller.mesh.isReady = false
        caller.engine.press(.amber)
        XCTAssertEqual(caller.request?.status, .notSent)
        await air.run()
        XCTAssertEqual(caller.request?.status, .notSent)
    }

    func testARequestNeverClosesAndItsAlertsNeverStopWithoutAHuman() async {
        caller.engine.press(.red)
        await air.run()
        for _ in 0..<(30 * 24) { await advance(3600) }
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.isAcknowledged, false)
        XCTAssertFalse(responder.alerts.scheduled[key]?.times.isEmpty ?? true, "alerts still scheduled thirty days on")
        XCTAssertTrue(responder.alerts.scheduled[key]!.times.allSatisfy { $0 >= clock.now.addingTimeInterval(-1) })
        XCTAssertNotNil(caller.request?.nextResend, "and the caller is still sending")
    }

    func testReAcksAreRateLimited() async {
        caller.engine.press(.red)
        await air.run()
        air.keep = { frame, from, _ in
            if case .ack = frame, from === self.responder { return false }  // the caller never hears the first ack
            return true
        }
        responder.engine.acknowledge(key)
        await air.run()
        let acks = { self.air.groupSends.filter { if case .ack = $0 { return true }; return false }.count }
        let first = acks()
        for p in air.phones where p !== caller { p.engine.receive(caller.request!.callFrame, via: .mesh) }
        for p in air.phones where p !== caller { p.engine.receive(caller.request!.callFrame, via: .mesh) }
        await air.run()
        XCTAssertGreaterThanOrEqual(acks() - first, 1, "the ack was repeated")
        XCTAssertLessThanOrEqual(acks() - first, 2, "once by the responder and at most once passed on by the coordinator, not once per repeat")
        air.keep = { _, _, _ in true }
        await advance(30)
        XCTAssertEqual(caller.request?.status, .seen(responder: responder.engine.saved!.me), "the repeated ack got through")
    }

    func testPersonalContentNeverGoesOnTheGroupChannel() async {
        caller.engine.press(.red)
        await air.run()
        XCTAssertNil(caller.engine.addNote("Back door is open"))
        caller.engine.add(.fallen)
        var sent: Bool?
        caller.engine.sharePosition(latitude: 55.4, longitude: -4.5, accuracy: 10) { sent = $0 }
        await air.run()
        XCTAssertEqual(sent, true, "the caller is told only once a route took it")
        XCTAssertFalse(air.groupSends.contains { !$0.mayGoOnGroupChannel })
        let sealed = air.groupSends.filter { if case .forResponders = $0 { return true }; return false }
        XCTAssertEqual(sealed.count, 3, "each went once for all responders, sealed: what was typed, what was chosen, where")
        XCTAssertFalse(air.groupSends.contains { if case .followUp(_, _, _, .fallen) = $0 { return true }; return false },
                       "a caller in the group cannot read that someone has fallen")
        XCTAssertTrue(air.directSends.isEmpty, "not one copy per responder")
        XCTAssertFalse(air.groupSends.contains { $0.encoded().range(of: Data("Back door".utf8)) != nil })
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.orderedNotes, ["Back door is open"])
        XCTAssertNotNil(responder.engine.activity.inbox.requests[key]?.position)
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.orderedCategories, [.fallen])
        XCTAssertEqual(coordinator.engine.activity.inbox.requests[key]?.orderedNotes, ["Back door is open"], "every responder reads it")
        XCTAssertNil(caller.engine.group?.secrets.responderPrivateKey, "a caller holds no responders' key")
        for f in sealed { XCTAssertNil(ForResponders.open(f, in: caller.engine.group!, at: clock.now), "so another caller cannot read it") }
    }

    func testSealedForRespondersIsSmallSignedAndTamperProof() throws {
        let g = caller.engine.group!, me = caller.engine.saved!.me, unit = caller.engine.me!.unit!
        let note = HelpFrame.note(unit: unit, request: 1, part: 1, typed: "Back door")
        let sealed = try XCTUnwrap(ForResponders.seal(note, from: caller.identity, as: me, in: g, at: clock.now).first)
        XCTAssertEqual(sealed.encoded().count, note.encoded().count + (1 + 4 + 2 + 1) + 5 + 16 + (1 + 2 + 1 + 64),
                       "the clear header, salt, tag and the caller's signature: nothing else")
        XCTAssertEqual(ForResponders.open(sealed, in: responder.engine.group!, at: clock.now), note)
        guard case let .forResponders(u, r, p, box) = sealed else { return XCTFail() }
        var bad = box; bad[bad.startIndex + 8] ^= 1
        XCTAssertNil(ForResponders.open(.forResponders(unit: u, request: r, part: p, sealed: bad), in: responder.engine.group!, at: clock.now))
        XCTAssertNil(ForResponders.open(.forResponders(unit: u, request: r &+ 1, part: p, sealed: box), in: responder.engine.group!, at: clock.now),
                     "its outside cannot be moved to another call")
        XCTAssertEqual(HelpFrame(sealed.encoded()), sealed)
        let longest = HelpFrame.note(unit: unit, request: 1, part: 1, text: String(repeating: "x", count: ForResponders.maxNoteBytes))
        let big = try XCTUnwrap(ForResponders.seal(longest, from: caller.identity, as: me, in: g, at: clock.now).first)
        XCTAssertLessThanOrEqual(big.encoded().count, 165, "the longest piece still fits one MeshCore channel datagram")
    }

    func testAResponderCannotWriteAsACaller() throws {
        // A responder can work out the sealing key, but cannot sign as the caller.
        let g = responder.engine.group!, unit = caller.engine.me!.unit!
        let fake = HelpFrame.position(unit: unit, request: 1, latitudeE7: 1, longitudeE7: 1, accuracy: 5)
        let forged = try XCTUnwrap(ForResponders.seal(fake, from: responder.identity, as: responder.engine.saved!.me, in: g, at: clock.now).first)
        XCTAssertNil(ForResponders.open(forged, in: coordinator.engine.group!, at: clock.now))
        let claimed = try XCTUnwrap(ForResponders.seal(fake, from: responder.identity, as: caller.engine.saved!.me, in: g, at: clock.now).first)
        XCTAssertNil(ForResponders.open(claimed, in: coordinator.engine.group!, at: clock.now), "nor by naming the caller")
    }

    func testDuringAChangeoverOnlyTheNewKeyReadsWhatIsTyped() throws {
        // A removed responder keeps the old key, so nothing new is sealed with it.
        let old = responder.engine.group!
        var updated = caller.engine.group!
        updated.previousSecrets = updated.secrets
        updated.previousUntil = clock.now.addingTimeInterval(86_400)
        updated.secrets = updated.secrets.rotated()
        let note = HelpFrame.note(unit: caller.engine.me!.unit!, request: 1, part: 1, typed: "Back door")
        let sealed = ForResponders.seal(note, from: caller.identity, as: caller.engine.saved!.me, in: updated.copy(for: .caller), at: clock.now)
        XCTAssertEqual(sealed.count, 1)
        XCTAssertTrue(sealed.compactMap { ForResponders.open($0, in: old, at: self.clock.now) }.isEmpty, "the old key reads nothing")
        XCTAssertEqual(sealed.compactMap { ForResponders.open($0, in: updated, at: self.clock.now) }, [note], "an updated responder does")
    }

    func testACoordinatorsSettingsReachEveryoneAtOnce() async {
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        coordinator.engine.updateGroup { ButtonWords.set("Please come", for: ButtonWords.key(.red), in: &$0.policy.profiles[0]) }
        await air.run()
        XCTAssertEqual(ButtonWords.words(.red, in: caller.engine.profile), "Please come")
        XCTAssertEqual(ButtonWords.words(.red, in: responder.engine.group?.profile(ofUnit: caller.engine.me?.unit)), "Please come")
        XCTAssertEqual(caller.engine.group?.settingsVersion, 1)
        // An old copy heard late changes nothing back.
        let old = coordinator.engine.group!.settingsFrame(as: coordinator.engine.saved!.me, identity: coordinator.identity)!
        coordinator.engine.updateGroup { ButtonWords.set("", for: ButtonWords.key(.red), in: &$0.policy.profiles[0]) }
        await air.run()
        caller.engine.receive(old, via: .internet)
        XCTAssertEqual(ButtonWords.words(.red, in: caller.engine.profile), "Help")
    }

    func testSettingsTooBigToSendAreNotKept() {
        let before = coordinator.engine.group!.settingsVersion
        coordinator.engine.updateGroup { g in
            for i in 1...40 {
                var p = Profile(id: UInt8(i), name: UUID().uuidString)
                p.okWords = (0..<6).map { _ in UUID().uuidString }.joined()
                g.policy.profiles.append(p)
            }
        }
        XCTAssertEqual(coordinator.engine.group!.policy.profiles.count, 1)
        XCTAssertEqual(coordinator.engine.group!.settingsVersion, before)
        XCTAssertNotNil(coordinator.engine.settingsProblem)
        coordinator.engine.updateGroup { ButtonWords.set("Please come", for: ButtonWords.key(.red), in: &$0.policy.profiles[0]) }
        XCTAssertNil(coordinator.engine.settingsProblem)
    }

    func testANewRelayAddressGoesOverTheOldOneFirst() async {
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        coordinator.engine.setRelay("https://old.example")
        await air.run()
        let publishes = coordinator.relay.publishes, before = coordinator.relay.sent.count
        coordinator.engine.setRelay("https://new.example")
        await air.run()
        XCTAssertEqual(coordinator.relay.sentVia.dropFirst(before).first, "https://old.example", "members still looking there hear of the move")
        XCTAssertEqual(caller.engine.group?.relayURL, "https://new.example")
        XCTAssertGreaterThan(coordinator.relay.publishes, publishes, "the group is registered afresh at the new address")
    }

    func testAProfilesLockedSettingsReachTheCaller() async {
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        let callerNumber = caller.engine.saved!.me
        caller.engine.setOwn { $0.soundsAndSpeech = false; $0.callerMayClose = true }
        coordinator.engine.updateGroup { g in
            var p = Profile(id: 1, name: "Living alone")
            p.checkIns = CheckInSchedule(times: [600])
            p.personMayChange = [.sounds]
            g.policy.profiles.append(p)
            g.policy.profileOf[callerNumber] = 1
        }
        await air.run()
        XCTAssertEqual(caller.engine.profile.name, "Living alone")
        XCTAssertFalse(caller.engine.profile.soundsAndSpeech, "their own choice, which they may change")
        XCTAssertFalse(caller.engine.profile.callerMayClose, "not theirs to change")
        XCTAssertEqual(caller.engine.checkIn?.times, [600], "the profile's check-ins, which they may not change")
    }

    func testOnlyACoordinatorCanChangeTheGroupsSettings() {
        var g = caller.engine.group!
        g.settingsVersion = 9
        ButtonWords.set("Ignore me", for: ButtonWords.key(.red), in: &g.policy.profiles[0])
        let fromCaller = g.settingsFrame(as: caller.engine.saved!.me, identity: caller.identity)!
        responder.engine.receive(fromCaller, via: .internet)
        XCTAssertEqual(ButtonWords.words(.red, in: responder.engine.group?.profile(ofUnit: caller.engine.me?.unit)), "Help")
        let forged = g.settingsFrame(as: coordinator.engine.saved!.me, identity: caller.identity)!
        responder.engine.receive(forged, via: .internet)
        XCTAssertEqual(ButtonWords.words(.red, in: responder.engine.group?.profile(ofUnit: caller.engine.me?.unit)), "Help", "a coordinator's number without their signature")
        XCTAssertEqual(HelpFrame(fromCaller.encoded()), fromCaller)
    }

    func testLongTypedTextGoesInPiecesThatEachFit() async {
        caller.mesh.isReady = true
        caller.engine.press(.red)
        await air.run()
        let text = "The back door is open and the key is under the blue pot by the step, please come round the side"
        XCTAssertNil(caller.engine.addNote(text))
        await air.run()
        let pieces = responder.engine.activity.inbox.requests[key]?.orderedNotes ?? []
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(separator: " "), text, "broken between words, nothing lost")
        XCTAssertTrue(air.groupSends.allSatisfy { $0.encoded().count <= 165 })
        XCTAssertEqual(caller.request?.notes, [text], "the caller's own record keeps it whole")
    }

    func testADirectMessageFromTheWrongBoxIsIgnored() async {
        caller.engine.press(.red)
        await air.run()
        let note = HelpFrame.note(unit: key.unit, request: key.request, part: 9, text: "forged")
        responder.engine.receiveText(from: Data(repeating: 1, count: 6), MeshText.encode(note)!)
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.orderedNotes, [])
    }

    func testResendsNeverUseTheAirtimeANewPressNeeds() async {
        caller.engine.press(.red)
        await air.run()
        // Use up the optional half of this hour's allowance (10% band: 180 of 360 seconds).
        var budget = caller.engine.activity.airtime!
        _ = budget.record(180, at: clock.now)
        caller.engine.setAirtimeForTesting(budget)
        let before = air.groupSends.count
        await advance(30)
        XCTAssertEqual(air.groupSends.count, before, "the resend waited for radio time")
        caller.engine.press(.red)
        await air.run()
        XCTAssertEqual(caller.request?.routes[.mesh], .sent, "a new press still went out")
    }

    func testMembersWhoHaveNotUpdatedStillHearDuringAChangeover() async {
        let extra = Phone(air: air, clock: clock)
        join(extra, call: false, respond: true)
        await air.run()
        coordinator.engine.updateGroup { $0.remove(extra.engine.saved!.me, at: clock.now) }
        XCTAssertEqual(coordinator.mesh.channelsPerSend, 2, "sends go on the old and new channels")
        // The caller and responder have not scanned their update codes, so still have only the old
        // channel; the coordinator is on both.
        caller.engine.press(.red)
        await air.run()
        coordinator.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(caller.request?.status, .seen(responder: 1))
        await advance(GroupState.changeoverPeriod + 1)
        XCTAssertEqual(coordinator.mesh.secrets.count, 1, "the old channel is dropped after the changeover")
    }

    func testASecondCoordinatorCanAddAndRemoveAndEveryoneFollows() async {
        let second = Phone(air: air, clock: clock)
        join(second, call: false, respond: true)
        await air.run()
        let n2 = second.engine.saved!.me
        coordinator.engine.promote(n2)
        await air.run()
        XCTAssertEqual(caller.engine.group?.member(n2)?.role, .coordinator, "everyone heard the promotion")
        XCTAssertEqual(second.engine.me?.role, .coordinator, "so did the new coordinator's own phone")
        // The second coordinator adds someone; their number comes from the second coordinator's block.
        let late = Phone(air: air, clock: clock)
        let invite = Joining.invitation(for: second.engine.group!, coordinator: second.identity)
        let request = Joining.request(invite, name: "Late", call: false, respond: true, me: late.identity)
        var welcome: Joining.Welcome?
        second.engine.updateGroup { g in welcome = try! Joining.admit(request, to: &g, invite: invite, coordinator: second.identity) }
        late.engine.joined(try! Joining.open(welcome!, invite: invite, me: late.identity), as: welcome!.memberNumber)
        await air.run()
        let n3 = welcome!.memberNumber
        XCTAssertGreaterThan(n3, 1000, "from the second coordinator's own block, so it cannot clash")
        XCTAssertNotNil(caller.engine.group?.member(n3), "the caller accepts the second coordinator's change")
        XCTAssertNotNil(coordinator.engine.group?.member(n3), "and so does the first coordinator")
        XCTAssertEqual(coordinator.engine.group?.membershipVersion, second.engine.group?.membershipVersion,
                       "versions agree, so either coordinator's member list is accepted by the relay")
        // Only the first coordinator removes people or makes coordinators, so the keys and numbers
        // can never split. The second coordinator's attempts change nothing anywhere.
        let r = responder.engine.saved!.me
        second.engine.removeMember(r)
        second.engine.promote(r)
        await air.run()
        XCTAssertNotNil(caller.engine.group?.member(r))
        XCTAssertEqual(caller.engine.group?.member(r)?.role, .responder)
        // A forged removal signed by the second coordinator is refused by other phones too.
        caller.engine.receive(.signing(.memberRemoved(member: r, version: 999), as: n2, identity: second.identity, group: gid), via: .mesh)
        XCTAssertNotNil(caller.engine.group?.member(r))
        // Nor can the second coordinator add a coordinator numbered below the first, or anyone
        // outside their own block, to become or choose the first coordinator.
        for (n, role) in [(UInt16(0), Member.Role.coordinator), (UInt16(5), .responder)] {
            let forged = HelpFrame.memberAdded(member: n, role: role, unit: 0, signingKey: Data(repeating: 7, count: 32),
                                               sealKey: Data(repeating: 8, count: 32), version: 999)
            caller.engine.receive(.signing(forged, as: n2, identity: second.identity, group: gid), via: .mesh)
            XCTAssertNil(caller.engine.group?.member(n))
        }
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
        coordinator.engine.removeMember(r)
        await air.run()
        XCTAssertNil(caller.engine.group?.member(r), "the first coordinator's removal is followed")
        // An old role change, replayed, does not undo a newer one.
        let demote = HelpFrame.memberRole(member: n2, role: .responder, block: 0, version: 1)
        caller.engine.receive(.signing(demote, as: 1, identity: coordinator.identity, group: gid), via: .mesh)
        XCTAssertEqual(caller.engine.group?.member(n2)?.role, .coordinator)
    }

    func testAnInviteeWhoseCoordinatorLeftBeforeBeingConfirmedIsTold() async {
        let second = Phone(air: air, clock: clock)
        join(second, call: false, respond: true)
        await air.run()
        coordinator.engine.promote(second.engine.saved!.me)
        await air.run()
        // The second coordinator invites someone while the first is out of touch.
        coordinator.mesh.isReady = false
        let late = Phone(air: air, clock: clock)
        let invite = Joining.invitation(for: second.engine.group!, coordinator: second.identity)
        var welcome: Joining.Welcome?
        second.engine.updateGroup { g in welcome = try! Joining.admit(Joining.request(invite, name: "L", call: true, respond: false, me: late.identity), to: &g, invite: invite, coordinator: second.identity) }
        late.engine.joined(try! Joining.open(welcome!, invite: invite, me: late.identity), as: welcome!.memberNumber, invitedBy: second.engine.saved!.me)
        await air.run()
        XCTAssertFalse(late.engine.saved!.confirmed)
        coordinator.mesh.isReady = true
        coordinator.engine.removeMember(second.engine.saved!.me)
        await air.run()
        XCTAssertTrue(late.engine.showing(.inviterLeft), "told plainly, not left believing it is in")
    }

    func testNoFalseAlarmWhenTheFirstCoordinatorKnowsTheInvitee() async {
        let second = Phone(air: air, clock: clock)
        join(second, call: false, respond: true)
        await air.run()
        coordinator.engine.promote(second.engine.saved!.me)
        await air.run()
        let late = Phone(air: air, clock: clock)
        let invite = Joining.invitation(for: second.engine.group!, coordinator: second.identity)
        var welcome: Joining.Welcome?
        second.engine.updateGroup { g in welcome = try! Joining.admit(Joining.request(invite, name: "L", call: true, respond: false, me: late.identity), to: &g, invite: invite, coordinator: second.identity) }
        late.engine.joined(try! Joining.open(welcome!, invite: invite, me: late.identity), as: welcome!.memberNumber, invitedBy: second.engine.saved!.me)
        await air.run()
        XCTAssertTrue(late.engine.saved!.confirmed, "the first coordinator listed them as soon as it heard")
        coordinator.engine.removeMember(second.engine.saved!.me)
        await air.run()
        XCTAssertFalse(late.engine.showing(.inviterLeft))
        XCTAssertFalse(late.engine.showing(.unconfirmed))
    }

    func testConfirmationWorksOverTheInternetWithNoBox() async {
        for p in air.phones { p.mesh.isReady = false; p.relay.isConfigured = true }
        await relaySetUp()
        let second = Phone(air: air, clock: clock)
        second.mesh.isReady = false; second.relay.isConfigured = true
        join(second, call: false, respond: true)
        await relaySetUp()
        coordinator.engine.promote(second.engine.saved!.me)
        await relaySetUp()
        let late = Phone(air: air, clock: clock)
        late.mesh.isReady = false; late.relay.isConfigured = true
        let invite = Joining.invitation(for: second.engine.group!, coordinator: second.identity)
        var welcome: Joining.Welcome?
        second.engine.updateGroup { g in welcome = try! Joining.admit(Joining.request(invite, name: "L", call: true, respond: false, me: late.identity), to: &g, invite: invite, coordinator: second.identity) }
        late.engine.joined(try! Joining.open(welcome!, invite: invite, me: late.identity), as: welcome!.memberNumber, invitedBy: second.engine.saved!.me)
        await advance(60)
        await advance(3 * 86_400)
        XCTAssertTrue(late.engine.saved!.confirmed)
        XCTAssertFalse(late.engine.showing(.unconfirmed))
    }

    func testARemovalReachesTheRelayAtOnceEvenJustAfterAnotherPublish() async {
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        let r = responder.engine.saved!.me
        let rKey = responder.relay.key!
        XCTAssertTrue(air.relay.isMember(rKey))
        clock.now = clock.now.addingTimeInterval(5)
        coordinator.engine.removeMember(r)
        await air.run()
        XCTAssertFalse(air.relay.isMember(rKey), "not a day later")
    }

    func testARefusedListIsNotRetriedOverAndOver() async {
        for p in air.phones { p.relay.isConfigured = true }
        // Someone else registered this group on the relay first, so this coordinator is refused.
        let other = DeviceIdentity()
        _ = air.relay.setMembers(signer: other.signingPublicKey.base64EncodedString(), generation: 1,
                                 members: [.init(key: other.signingPublicKey.base64EncodedString(), role: "coordinator")],
                                 removed: [], primary: other.signingPublicKey.base64EncodedString(), groupID: nil)
        let before = coordinator.relay.publishes
        for _ in 0..<60 { await advance(60) }
        XCTAssertLessThanOrEqual(coordinator.relay.publishes - before, 2, "a refusal is not retried every minute")
    }

    func testAnInviteeIsConfirmedWhenTheFirstCoordinatorListsIt() async {
        let second = Phone(air: air, clock: clock)
        join(second, call: false, respond: true)
        await air.run()
        coordinator.engine.promote(second.engine.saved!.me)
        await air.run()
        let late = Phone(air: air, clock: clock)
        let invite = Joining.invitation(for: second.engine.group!, coordinator: second.identity)
        var welcome: Joining.Welcome?
        second.engine.updateGroup { g in welcome = try! Joining.admit(Joining.request(invite, name: "L", call: true, respond: false, me: late.identity), to: &g, invite: invite, coordinator: second.identity) }
        late.engine.joined(try! Joining.open(welcome!, invite: invite, me: late.identity), as: welcome!.memberNumber, invitedBy: second.engine.saved!.me)
        await air.run()
        coordinator.engine.resetMembershipRepeatForTesting()
        await coordinator.engine.boxReady()
        await air.run()
        XCTAssertTrue(late.engine.saved!.confirmed)
    }

    func testAReplayedMemberAddedCannotLetARemovedPhoneBackIn() async {
        let lost = Phone(air: air, clock: clock)
        join(lost, call: false, respond: true)
        await air.run()
        let n = lost.engine.saved!.me
        // The lost phone kept the signed "member added" it heard when it joined.
        let replay = HelpFrame.signing(coordinator.engine.group!.addedFrame(n)!, as: 1, identity: coordinator.identity, group: gid)
        coordinator.engine.updateGroup { $0.remove(n, at: clock.now) }
        await air.run()
        caller.engine.press(.red)
        await air.run()
        for p in air.phones where p !== lost { p.engine.receive(replay, via: .mesh) }
        XCTAssertNil(caller.engine.group?.member(n))
        caller.engine.receive(.signedAck(unit: key.unit, request: key.request, responder: n, at: clock.now, identity: lost.identity, group: gid), via: .mesh)
        XCTAssertEqual(caller.request?.status, .waitingForResponder)
    }

    func testRemovedMembersNumbersAndBoxesAreNeverReused() async {
        let old = Phone(air: air, clock: clock)
        join(old, call: false, respond: true)
        await air.run()
        await old.engine.boxReady()
        await air.run()
        let n = old.engine.saved!.me
        XCTAssertNotNil(caller.engine.activity.boardKeys[n])
        coordinator.engine.updateGroup { $0.remove(n, at: clock.now) }
        await air.run()
        XCTAssertNil(caller.engine.activity.boardKeys[n], "the removed box is forgotten")
        let new = Phone(air: air, clock: clock)
        join(new, call: false, respond: true)
        XCTAssertNotEqual(new.engine.saved!.me, n)
        caller.engine.press(.red)
        await air.run()
        air.directSends = []
        _ = caller.engine.addNote("private")
        await air.run()
        XCTAssertFalse(air.phones.contains { $0 === old && $0.engine.activity.inbox.requests[key]?.orderedNotes.isEmpty == false })
    }

    func testIAmOKAlertsOnceAndNeverCrowdsOutARedCall() async {
        for _ in 0..<20 {
            caller.engine.press(.green)
            await air.run()
            await advance(600)
        }
        let greenKeys = responder.engine.activity.inbox.requests.values.filter { $0.colour == .green }.map(\.key)
        XCTAssertEqual(greenKeys.count, 20)
        let first = greenKeys.min { $0.request < $1.request }!
        XCTAssertNil(responder.alerts.scheduled[first].map { a in a.times.filter { $0 > clock.now } }.flatMap { $0.isEmpty ? nil : $0 },
                     "an old green is not alerted again")
        caller.engine.press(.red)
        await air.run()
        XCTAssertEqual(responder.alerts.scheduled[key]?.times.count, 58, "a red call gets its full set of alerts")
    }

    func testACallFirstReachingTheRelayOnAResendStillWakesPhones() async {
        for p in air.phones { p.mesh.isReady = false }
        caller.engine.press(.red)
        await air.run()
        XCTAssertEqual(caller.request?.status, .notSent)
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        await advance(30)
        XCTAssertEqual(caller.relay.sent.first?.1, .call, "the first post to the relay asks for a push")
        XCTAssertNotNil(responder.alerts.scheduled[key])
    }

    func testRepeatedMembershipFromABoxReconnectChangesNothingElsewhere() async {
        let before = air.phones.map { $0.relay.configured }
        coordinator.engine.resetMembershipRepeatForTesting()
        await coordinator.engine.boxReady()
        await air.run()
        XCTAssertEqual(air.phones.map { $0.relay.configured }, before, "no phone reconfigured its relay for a change that changed nothing")
    }

    func testAfterLeavingAndJoiningTheMeshStillWorks() async {
        caller.engine.leave()
        join(caller, call: true, respond: false)
        await air.run()
        caller.engine.press(.red)
        await air.run()
        XCTAssertEqual(caller.request?.routes[.mesh], .sent)
    }

    func testDirectMessagesStayOffAFrequencyTheAppWillNotUse() async {
        caller.engine.press(.red)
        await air.run()
        caller.mesh.radio = RadioSettings(frequencyMHz: 870.0, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8)
        air.directSends = []
        _ = caller.engine.addNote("hello")
        await air.run()
        XCTAssertTrue(air.directSends.isEmpty)
    }

    func testARemovedCallerGetsTheCrossNotNothing() async {
        coordinator.engine.updateGroup { $0.remove(self.caller.engine.saved!.me, at: self.clock.now) }
        await air.run()
        caller.engine.press(.red)
        XCTAssertEqual(caller.request?.status, .notSent)
        await advance(3600)
        XCTAssertFalse(air.groupSends.contains { if case .call(0, _, _, _) = $0 { return true }; return false })
    }

    func testAnUnacknowledgedRedSurvivesTheListCap() async {
        caller.engine.press(.red)
        await air.run()
        let red = caller.request!
        for _ in 0..<60 { caller.engine.press(.green) }
        XCTAssertTrue(caller.engine.activity.outgoing.contains { $0.number == red.number }, "the red call is still being sent")
    }

    func testAMeshOnlyResponderNoticesAMissedCheckInWithTheCallersPhoneOff() async {
        let hour = Calendar(identifier: .gregorian).component(.hour, from: clock.now)
        caller.engine.setCheckIn(CheckInSchedule(times: [(hour * 60 + 120) % 1440]))
        await air.run()
        XCTAssertNotNil(responder.engine.activity.checkInWatch.callers[caller.engine.me!.unit!], "the schedule reached the responder over the mesh")
        XCTAssertTrue(air.directSends.contains { if case .checkIns? = MeshText.decode($0) { return true }; return false }, "sent as direct messages")
        XCTAssertFalse(air.groupSends.contains { !$0.mayGoOnGroupChannel }, "never on the group channel")
        caller.mesh.isReady = false  // the caller's phone goes flat
        await advance(2 * 3600 + 36 * 60)
        XCTAssertTrue(responder.engine.activity.inbox.requests.values.contains { $0.key.request == 0 && $0.orderedCategories.contains(.missedCheckIn) })
    }

    func testACheckInScheduleFromTheWrongBoxIsIgnored() async {
        let unit = caller.engine.me!.unit!
        let forged = HelpFrame.checkIns(unit: unit, since: 0, grace: 30, times: [0])
        responder.engine.receiveText(from: Data(repeating: 7, count: 6), MeshText.encode(forged)!)
        XCTAssertNil(responder.engine.activity.checkInWatch.callers[unit])
    }

    func testAnAckFromSomeoneLaterRemovedStopsReassuring() async {
        caller.engine.press(.red)
        await air.run()
        let r = responder.engine.saved!.me
        coordinator.mesh.isReady = false  // the caller will hear of the removal late
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(caller.request?.status, .seen(responder: r))
        coordinator.mesh.isReady = true
        coordinator.engine.removeMember(r)
        await air.run()
        XCTAssertEqual(caller.request?.status, .waitingForResponder, "the removed person's ack no longer counts")
        XCTAssertNotNil(caller.request?.nextResend, "so the call goes out again")
        XCTAssertNotNil(coordinator.alerts.scheduled[key], "and the coordinator is alerted again")
        XCTAssertEqual(caller.alerts.toldCaller, ["Your call is going out again"], "and the caller is told")
    }

    func testAPhoneThatMissedARemovalCatchesUp() async {
        let r = responder.engine.saved!.me
        caller.mesh.isReady = false
        coordinator.engine.removeMember(r)
        await air.run()
        XCTAssertNotNil(caller.engine.group?.member(r), "the caller's box was off")
        caller.mesh.isReady = true
        coordinator.engine.resetMembershipRepeatForTesting()
        await coordinator.engine.boxReady()
        await air.run()
        XCTAssertNil(caller.engine.group?.member(r), "the repeated removal reached it")
    }

    func testARemovedCallersCheckInsAreNoLongerWatched() async {
        let hour = Calendar(identifier: .gregorian).component(.hour, from: clock.now)
        caller.engine.setCheckIn(CheckInSchedule(times: [(hour * 60 + 120) % 1440]))
        await air.run()
        let unit = caller.engine.me!.unit!
        XCTAssertNotNil(responder.engine.activity.checkInWatch.callers[unit])
        coordinator.engine.removeMember(caller.engine.saved!.me)
        await air.run()
        XCTAssertNil(responder.engine.activity.checkInWatch.callers[unit])
        await advance(4 * 3600)
        XCTAssertFalse(responder.engine.activity.inbox.requests.values.contains { $0.key.unit == unit })
    }

    func testCheckInsOverTheInternetCountOnlyFromTheCaller() async {
        for p in air.phones { p.mesh.isReady = false; p.relay.isConfigured = true }
        await relaySetUp()
        let unit = caller.engine.me!.unit!
        caller.engine.setCheckIn(CheckInSchedule(times: [600]))
        await air.run()
        XCTAssertEqual(responder.engine.activity.checkInWatch.callers[unit]?.schedule.times, [600])
        // Another member tries to clear it.
        let clear = HelpFrame.checkIns(unit: unit, since: 0, grace: 30, times: [])
        responder.engine.receive(.signing(clear, as: coordinator.engine.saved!.me, identity: coordinator.identity, group: gid), via: .internet)
        responder.engine.receive(clear, via: .internet)
        XCTAssertEqual(responder.engine.activity.checkInWatch.callers[unit]?.schedule.times, [600])
    }

    func testANewBoxHearsTheCallersCheckIns() async {
        caller.engine.setCheckIn(CheckInSchedule(times: [600]))
        await air.run()
        let late = Phone(air: air, clock: clock)
        join(late, call: false, respond: true)
        await air.run()
        air.directSends = []
        await advance(120)  // a held-back answer goes once the minute is up
        XCTAssertTrue(air.directSends.contains { if case .checkIns? = MeshText.decode($0) { return true }; return false })
        XCTAssertNotNil(late.engine.activity.checkInWatch.callers[caller.engine.me!.unit!])
    }

    func testANewcomerHearingManyBoxesAnswersOnce() async {
        var phones: [Phone] = []
        for _ in 0..<3 { let p = Phone(air: air, clock: clock); join(p, call: false, respond: true); phones.append(p) }
        await air.run()
        clock.now = clock.now.addingTimeInterval(120)
        let late = Phone(air: air, clock: clock)
        join(late, call: false, respond: true)
        await air.run()
        air.groupSends = []
        await late.engine.boxReady()
        await air.run()
        let fromLate = air.groupSends.filter { if case let .board(m, _, _) = $0 { return m == late.engine.saved!.me }; return false }
        XCTAssertLessThanOrEqual(fromLate.count, 2, "its own announcement and at most one answer, not one per box")
    }

    func testABoxAlreadyConnectedIsAnnouncedOnJoining() async {
        let late = Phone(air: air, clock: clock)
        air.groupSends = []
        join(late, call: false, respond: true)
        await air.run()
        XCTAssertTrue(air.groupSends.contains { if case let .board(m, _, _) = $0 { return m == late.engine.saved!.me }; return false })
        XCTAssertNotNil(caller.engine.activity.boardKeys[late.engine.saved!.me])
    }

    func testOnlyRespondersCanBePromoted() async {
        let callerNumber = caller.engine.saved!.me
        coordinator.engine.promote(callerNumber)
        await air.run()
        XCTAssertEqual(coordinator.engine.group?.member(callerNumber)?.role, .caller, "a caller who cannot come out is not given alerts")
    }

    func testAMissedCheckInIsRaisedEndToEnd() async {
        caller.engine.setCheckIn(CheckInSchedule(times: [Calendar(identifier: .gregorian).component(.hour, from: clock.now) * 60 + 60]))
        await advance(3600 + 31 * 60)
        XCTAssertTrue(responder.engine.activity.inbox.requests.values.contains { $0.orderedCategories.contains(.missedCheckIn) })
    }
}
