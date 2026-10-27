import XCTest
@testable import HelpAndICore

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

@MainActor final class FakeRelay: RelayLink {
    weak var air: Air?
    weak var phone: Phone?
    var isConfigured = false
    var lastProblem: String?
    var sent: [(HelpFrame, RelayWake?)] = []

    var configured = 0
    func configure(group: GroupState?, identity: DeviceIdentity) { configured += 1 }
    func publishMembers() async {}

    func send(_ frame: HelpFrame, wake: RelayWake?) async -> String? {
        guard isConfigured, let air, let me = phone else { return "No internet" }
        sent.append((frame, wake))
        for p in air.phones where p !== me && p.relay.isConfigured {
            air.queue.append((me, p, { p.engine.receive(frame, via: .internet) }))
        }
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
}

@MainActor final class NoStore: EngineStore {
    func save(_ state: SavedState?) {}
    func save(_ activity: Activity) {}
}

@MainActor final class Phone {
    let identity = DeviceIdentity()
    let mesh = FakeMesh()
    let relay = FakeRelay()
    let alerts = FakeAlerts()
    var engine: HelpEngine!

    init(air: Air, clock: Clock) {
        mesh.air = air; relay.air = air
        engine = HelpEngine(identity: identity, mesh: mesh, relay: relay, alerts: alerts, store: NoStore(),
                            saved: nil, activity: Activity(), calendar: Calendar(identifier: .gregorian), now: { clock.now })
        mesh.phone = self; relay.phone = self
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
        caller.engine.sharePosition(latitude: 55.4, longitude: -4.5, accuracy: 10)
        await air.run()
        XCTAssertFalse(air.groupSends.contains { !$0.mayGoOnGroupChannel })
        XCTAssertFalse(air.directSends.isEmpty, "they went as direct messages instead")
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.orderedNotes, ["Back door is open"])
        XCTAssertNotNil(responder.engine.activity.inbox.requests[key]?.position)
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
        coordinator.engine.removeMember(r)
        await air.run()
        XCTAssertNil(caller.engine.group?.member(r), "the first coordinator's removal is followed")
        // An old role change, replayed, does not undo a newer one.
        let demote = HelpFrame.memberRole(member: n2, role: .responder, block: 0, version: 1)
        caller.engine.receive(.signing(demote, as: 1, identity: coordinator.identity, group: gid), via: .mesh)
        XCTAssertEqual(caller.engine.group?.member(n2)?.role, .coordinator)
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

    func testDirectMessagesStayOffAFrequencyHelpAndIWillNotUse() async {
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
        await late.engine.boxReady()
        await air.run()
        XCTAssertTrue(air.directSends.contains { if case .checkIns? = MeshText.decode($0) { return true }; return false })
        XCTAssertNotNil(late.engine.activity.checkInWatch.callers[caller.engine.me!.unit!])
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
