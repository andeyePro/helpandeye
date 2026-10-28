import XCTest
@testable import helpandeyeCore

/// A caller's watch, out of reach of their phone, calling over the internet as the same member.
@MainActor final class WatchCompanionTests: XCTestCase {
    var air: Air!
    var clock: Clock!
    var coordinator: Phone!
    var caller: Phone!
    var responder: Phone!
    var watch: Phone!

    func join(_ p: Phone, call: Bool, respond: Bool) {
        let c = coordinator.engine!
        let invite = Joining.invitation(for: c.group!, coordinator: coordinator.identity)
        let request = Joining.request(invite, name: "Member", call: call, respond: respond, me: p.identity)
        var welcome: Joining.Welcome?
        c.updateGroup { g in welcome = try! Joining.admit(request, to: &g, invite: invite, coordinator: coordinator.identity) }
        p.engine.joined(try! Joining.open(welcome!, invite: invite, me: p.identity), as: welcome!.memberNumber)
    }

    func relaySetUp() async {
        coordinator.engine.tick()
        await air.run()
    }

    func advance(_ seconds: TimeInterval) async {
        clock.now = clock.now.addingTimeInterval(seconds)
        for p in air.phones { p.engine.tick() }
        await air.run()
    }

    override func setUp() async throws {
        air = Air(); clock = Clock()
        coordinator = Phone(air: air, clock: clock)
        caller = Phone(air: air, clock: clock)
        responder = Phone(air: air, clock: clock)
        coordinator.engine.createGroup(name: "Mill Lane", myName: "Sam", call: false)
        join(caller, call: true, respond: false)
        join(responder, call: false, respond: true)
        await air.run()
        watch = Phone(air: air, clock: clock, watchOf: caller)
        XCTAssertTrue(watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: caller.identity)))
        watch.mesh.isReady = false
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        await air.run()
    }

    func testTheWatchCallsAloneAndOnlyAHumanAckShowsSeen() async {
        caller.relay.isConfigured = false; caller.mesh.isReady = false
        watch.engine.press(.red)
        await air.run()
        let r = watch.request!
        XCTAssertGreaterThanOrEqual(r.number, 0x8000, "the watch numbers its calls apart from the phone's")
        XCTAssertEqual(r.routes[.internet], .sent)
        let key = IncomingRequest.Key(unit: r.unit, request: r.number)
        XCTAssertNotNil(responder.alerts.scheduled[key], "the responder is alerted")
        await advance(3600)
        XCTAssertEqual(watch.request?.status, .waitingForResponder, "nothing acknowledges by itself")
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(watch.request?.status, .seen(responder: responder.engine.saved!.me))
    }

    func testPhoneAndWatchNeverReuseANumber() async {
        caller.engine.press(.amber)
        watch.engine.press(.amber)
        await air.run()
        XCTAssertLessThan(caller.request!.number, 0x8000)
        XCTAssertNotEqual(caller.request!.number, watch.request!.number)
        // A newer handover from the phone keeps the watch's own numbering.
        let before = watch.engine.saved!.lastRequest
        watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: caller.identity))
        XCTAssertEqual(watch.engine.saved!.lastRequest, before)
    }

    func testAWatchCallSentByBothWatchAndPhoneIsOneCall() async {
        watch.engine.press(.red)
        XCTAssertTrue(caller.engine.adopt(watch.request!.callFrame), "the phone takes its watch's call")
        XCTAssertTrue(caller.engine.adopt(watch.request!.callFrame), "and taking it twice changes nothing")
        await air.run()
        let key = IncomingRequest.Key(unit: watch.request!.unit, request: watch.request!.number)
        XCTAssertEqual(caller.request?.number, key.request, "under the watch's number, not a second call")
        XCTAssertEqual(caller.engine.activity.outgoing.filter { $0.number == key.request }.count, 1)
        XCTAssertEqual(responder.engine.activity.inbox.requests.count, 1, "responders hear one call")
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(watch.request?.status, .seen(responder: responder.engine.saved!.me))
        XCTAssertEqual(caller.request?.status, .seen(responder: responder.engine.saved!.me))
        XCTAssertFalse(responder.engine.adopt(watch.request!.callFrame), "only the caller's own phone takes it")
        XCTAssertFalse(caller.engine.adopt(.call(unit: key.unit, request: 5, colour: .red, sentAt: 0)), "only watch-numbered calls")
    }

    func testHeldAlertsLetGoLateBuzzOnceNotInABurst() {
        let t = clock.now
        let a = Alert(key: .init(unit: 1, request: 1), title: "t", body: "b", calm: false,
                      times: [t.addingTimeInterval(-300), t.addingTimeInterval(-120), t.addingTimeInterval(60)])
        XCTAssertEqual(a.fromNow(t).times, [t, t.addingTimeInterval(60)])
        XCTAssertEqual(Alert(key: a.key, title: "t", body: "b", calm: false, times: [t.addingTimeInterval(60)]).fromNow(t).times, [t.addingTimeInterval(60)])
    }

    func testAHandoverCarriesEveryGroupTheOwnerRespondsIn() throws {
        let other = coordinator.engine.saved!
        let h = WatchHandover(saved: responder.engine.saved!, identity: responder.identity, others: [other])
        let back = try JSONDecoder().decode(WatchHandover.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.each.map(\.group.name), [responder.engine.group!.name, other.group.name])
        XCTAssertTrue(back.each.allSatisfy { $0.keys == responder.identity.rawRepresentation })
        // One from a phone before several groups still opens.
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        plain["others"] = nil
        let old = try JSONDecoder().decode(WatchHandover.self, from: JSONSerialization.data(withJSONObject: plain))
        XCTAssertEqual(old.each.count, 1)
    }

    func testAHandoverWithOtherKeysIsRefused() {
        XCTAssertFalse(watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: DeviceIdentity())))
        XCTAssertFalse(responder.engine.take(WatchHandover(saved: responder.engine.saved!, identity: responder.identity)),
                       "a phone never takes a handover")
    }

    func testAResponderWatchAcknowledgesForItsOwner() async {
        let rw = Phone(air: air, clock: clock, watchOf: responder)
        rw.engine.take(WatchHandover(saved: responder.engine.saved!, identity: responder.identity))
        rw.mesh.isReady = false; rw.relay.isConfigured = true
        responder.relay.isConfigured = false; responder.mesh.isReady = false
        caller.engine.press(.red)
        await air.run()
        let key = IncomingRequest.Key(unit: caller.request!.unit, request: caller.request!.number)
        XCTAssertNotNil(rw.alerts.scheduled[key], "the watch alerts its wearer")
        rw.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(caller.request?.status, .seen(responder: responder.engine.saved!.me), "signed as its owner, it counts")
    }

    func testACoordinatorsWatchLeavesTheMemberListToThePhone() async {
        let cw = Phone(air: air, clock: clock, watchOf: coordinator)
        cw.engine.take(WatchHandover(saved: coordinator.engine.saved!, identity: coordinator.identity))
        cw.mesh.isReady = false; cw.relay.isConfigured = true
        await advance(2 * 86_400)
        XCTAssertEqual(cw.relay.publishes, 0, "only the phone publishes the member list")
        XCTAssertTrue(cw.engine.activity.notices.isEmpty, "rota gaps are the phone's to raise")
    }
}
