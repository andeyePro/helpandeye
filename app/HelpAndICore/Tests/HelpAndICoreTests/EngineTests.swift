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

    func configure(group: GroupState?, identity: DeviceIdentity) {}
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
        caller.engine.receive(.signedAck(unit: key.unit, request: key.request, responder: responderNumber, at: clock.now, identity: stranger), via: .mesh)
        XCTAssertEqual(caller.request?.status, .waitingForResponder, "a forged signature does not count")
        coordinator.engine.updateGroup { $0.remove(responderNumber, at: clock.now) }
        await air.run()
        XCTAssertNil(caller.engine.group?.member(responderNumber), "the caller heard of the removal")
        caller.engine.receive(.signedAck(unit: key.unit, request: key.request, responder: responderNumber, at: clock.now, identity: responder.identity), via: .mesh)
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
        XCTAssertLessThanOrEqual(acks() - first, 2, "one repeat from the responder and at most one passed on, not one per repeat")
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

    func testASecondCoordinatorTakesTheFirstOnesMembershipChanges() async {
        let second = Phone(air: air, clock: clock)
        join(second, call: false, respond: true)
        coordinator.engine.updateGroup { g in
            if let i = g.members.firstIndex(where: { $0.publicKey == second.identity.publicKey }) { g.members[i].role = .coordinator }
        }
        let welcome = try! Joining.update(coordinator.engine.group!, for: coordinator.engine.group!.members.last!, coordinator: coordinator.identity)
        _ = welcome
        await air.run()
        second.engine.joined(coordinator.engine.group!, as: second.engine.saved!.me)
        let late = Phone(air: air, clock: clock)
        join(late, call: false, respond: true)
        await air.run()
        XCTAssertNotNil(second.engine.group?.member(late.engine.saved!.me), "the second coordinator heard of the new member")
    }
}
