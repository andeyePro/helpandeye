import XCTest
@testable import helpandeyeCore

/// Decision 6: only a person closes a call, and nothing closes one on its own.
@MainActor final class ClosingTests: XCTestCase {
    var t: EngineTests!

    override func setUp() async throws {
        t = EngineTests()
        try await t.setUp()
    }

    private var caller: Phone { t.caller }
    private var responder: Phone { t.responder }
    private var coordinator: Phone { t.coordinator }

    private func callerProfile(_ change: @escaping (inout Profile) -> Void) async {
        coordinator.engine.updateGroup { change(&$0.policy.profiles[0]) }
        await t.air.run()
    }

    func testImOKAfterHelpStopsTheRepeatsButAResponderStillChecks() async {
        caller.engine.press(.red)
        await t.air.run()
        let red = t.key
        XCTAssertFalse(caller.engine.settledByOK.isEmpty)
        caller.engine.press(.green)
        await t.air.run()
        let call = caller.engine.activity.outgoing.first { $0.number == red.request }!
        XCTAssertNotNil(call.nextResend, "still sent, with the news, for a responder who missed both")
        XCTAssertEqual(call.status, .waitingForResponder, "still not seen by anyone")
        let heard = responder.engine.activity.inbox.requests[red]!
        XCTAssertTrue(heard.callerIsOK)
        XCTAssertTrue(heard.isOpen, "a responder still checks")
        XCTAssertEqual(responder.alerts.scheduled[red]?.calm, true)
        let times = responder.alerts.scheduled[red]?.times ?? []
        XCTAssertGreaterThanOrEqual(zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.min() ?? 0, 1800, "calm reminders, not urgent ones")
        XCTAssertTrue(responder.engine.acknowledge(red))
        await t.air.run()
        XCTAssertFalse(responder.engine.activity.inbox.requests[red]!.isOpen)
    }

    func testAResponderWhoMissedImOKHearsItWithTheNextResend() async {
        caller.engine.press(.red)
        let red = t.key
        t.air.keep = { _, _, to in to !== self.responder }
        await t.air.run()
        caller.engine.press(.green)
        await t.air.run()
        t.air.keep = { _, _, _ in true }
        await t.advance(31)
        XCTAssertEqual(responder.engine.activity.inbox.requests[red]?.callerIsOK, true)
        XCTAssertEqual(responder.alerts.scheduled[red]?.calm, true)
    }

    func testImOKCanCloseTheCallWhenTheProfileSaysSo() async {
        await callerProfile { $0.afterOK = .closesCall }
        caller.engine.press(.amber)
        await t.air.run()
        let amber = t.key
        caller.engine.press(.green)
        await t.air.run()
        let me = caller.engine.saved!.me
        XCTAssertEqual(caller.engine.activity.outgoing.first { $0.number == amber.request }?.status, .closed(by: me))
        XCTAssertTrue(responder.engine.activity.inbox.requests[amber]!.isClosed)
        XCTAssertNil(responder.alerts.scheduled[amber])
        XCTAssertTrue(caller.engine.settledByOK.isEmpty)
    }

    func testACallerClosesTheirOwnCallOnlyWhereAllowed() async {
        caller.engine.press(.red)
        await t.air.run()
        caller.engine.closeMyCall()
        await t.air.run()
        XCTAssertEqual(caller.request?.status, .waitingForResponder, "not allowed by the standard profile")
        await callerProfile { $0.callerMayClose = true }
        caller.engine.closeMyCall()
        await t.air.run()
        XCTAssertEqual(caller.request?.status, .closed(by: caller.engine.saved!.me))
        XCTAssertFalse(responder.engine.activity.inbox.requests[t.key]!.isOpen)
    }

    func testACoordinatorClosesWithConsentOrAReason() async {
        for p in t.air.phones { p.relay.isConfigured = true }
        await t.relaySetUp()
        caller.engine.press(.red)
        await t.air.run()
        let key = t.key
        XCTAssertFalse(coordinator.engine.close(key, consent: false, reason: "  "), "a reason or consent is needed")
        XCTAssertFalse(responder.engine.close(key, consent: true), "only a coordinator")
        XCTAssertTrue(coordinator.engine.close(key, consent: false, reason: "Spoke to them on the phone, all well"))
        await t.air.run()
        let coord = coordinator.engine.saved!.me
        XCTAssertEqual(caller.request?.status, .closed(by: coord))
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.settled?.reason, "Spoke to them on the phone, all well")
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.settled?.state, .closedWithReason)
        XCTAssertFalse(t.air.groupSends.contains { if case let .signed(_, inner, _) = $0, case let .callState(_, _, _, _, r)? = HelpFrame(inner) { return !r.isEmpty }; return false },
                       "the reason never goes on the radio")
    }

    func testOnlyTheCallerOrACoordinatorCanSettleACall() async {
        caller.engine.press(.red)
        await t.air.run()
        let key = t.key
        let gid = t.gid
        let forged = HelpFrame.signing(.callState(unit: key.unit, request: key.request, state: .closedByCaller, at: UInt32(t.clock.now.timeIntervalSince1970), reason: ""),
                                       as: responder.engine.saved!.me, identity: responder.identity, group: gid)
        coordinator.engine.receive(forged, via: .mesh)
        caller.engine.receive(forged, via: .mesh)
        XCTAssertTrue(coordinator.engine.activity.inbox.requests[key]!.isOpen, "a responder cannot close it as the caller")
        XCTAssertEqual(caller.request?.status, .waitingForResponder)
        let byCaller = HelpFrame.signing(.callState(unit: key.unit, request: key.request, state: .closedWithReason, at: 0, reason: "x"),
                                         as: caller.engine.saved!.me, identity: caller.identity, group: gid)
        responder.engine.receive(byCaller, via: .internet)
        XCTAssertTrue(responder.engine.activity.inbox.requests[key]!.isOpen, "a caller cannot close as a coordinator")
    }

    func testNothingClosesACallOnItsOwn() async {
        caller.engine.press(.red)
        await t.air.run()
        await t.advance(30 * 86_400)
        XCTAssertNotNil(caller.request?.nextResend)
        XCTAssertTrue(responder.engine.activity.inbox.requests[t.key]!.isOpen)
    }

    func testTheCallStateFrame() {
        let f = HelpFrame.callState(unit: 70001, request: 3, state: .closedWithReason, at: 1_793_000_000, reason: "Spoke to them")
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertFalse(f.mayGoOnGroupChannel)
        XCTAssertTrue(HelpFrame.callState(unit: 70001, request: 3, state: .callerOK, at: 0, reason: "").mayGoOnGroupChannel)
        XCTAssertLessThanOrEqual(HelpFrame.signing(f, as: 1, identity: DeviceIdentity(), group: Data(count: 16)).encoded().count, HelpFrame.maxPayload)
    }
}
