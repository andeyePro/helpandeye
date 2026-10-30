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

    func testTheCoordinatorChoosesHowManyCalmRemindersAndHowOften() async {
        await callerProfile { $0.calmEvery = 3600; $0.calmReminders = 3 }
        caller.engine.press(.red)
        await t.air.run()
        let red = t.key
        caller.engine.press(.green)
        await t.air.run()
        let times = responder.alerts.scheduled[red]?.times ?? []
        XCTAssertEqual(times.count, 3)
        XCTAssertEqual(zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }, [3600, 3600])
        await t.advance(4 * 3600)
        XCTAssertTrue(responder.alerts.scheduled[red]?.times.allSatisfy { $0 < self.t.clock.now } ?? true, "no more than three, however often topped up")
        XCTAssertTrue(responder.engine.activity.inbox.requests[red]!.isOpen, "still open: a responder still checks")
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

    /// Codex re-review: a close lost on the way is repeated, as I'm OK is, then left.
    func testAResponderWhoMissedACloseHearsItRepeated() async {
        await callerProfile { $0.callerMayClose = true }
        caller.engine.press(.red)
        await t.air.run()
        t.air.keep = { _, _, to in to !== self.responder }
        caller.engine.closeMyCall()
        await t.air.run()
        XCTAssertTrue(responder.engine.activity.inbox.requests[t.key]!.isOpen, "missed the close")
        t.air.keep = { _, _, _ in true }
        await t.advance(31)
        XCTAssertFalse(responder.engine.activity.inbox.requests[t.key]!.isOpen)
        XCTAssertNil(responder.alerts.scheduled[t.key])
        await t.advance(Resend.gaps.reduce(0, +))
        XCTAssertTrue(caller.engine.activity.closeRepeats.isEmpty, "repeated a few times, then left")
    }

    func testACoordinatorsCloseIsRepeatedToo() async {
        caller.engine.press(.red)
        await t.air.run()
        t.air.keep = { _, _, to in to !== self.responder }
        XCTAssertTrue(coordinator.engine.close(t.key, consent: true))
        await t.air.run()
        XCTAssertTrue(responder.engine.activity.inbox.requests[t.key]!.isOpen)
        t.air.keep = { _, _, _ in true }
        await t.advance(31)
        XCTAssertFalse(responder.engine.activity.inbox.requests[t.key]!.isOpen)
    }

    /// Codex NR19: a close the caller's profile does not allow, though signed by them (an old or
    /// altered app), closes nothing on other phones.
    func testACallersCloseTheirProfileDoesNotAllowCountsNowhere() async {
        caller.engine.press(.red)
        await t.air.run()
        let close = HelpFrame.signing(.callState(unit: t.key.unit, request: t.key.request, state: .closedByCaller, at: UInt32(t.clock.now.timeIntervalSince1970), reason: ""),
                                      as: caller.engine.saved!.me, identity: caller.identity, group: t.gid)
        responder.engine.receive(close, via: .internet)
        XCTAssertTrue(responder.engine.activity.inbox.requests[t.key]!.isOpen)
        await callerProfile { $0.callerMayClose = true }
        responder.engine.receive(close, via: .internet)
        XCTAssertFalse(responder.engine.activity.inbox.requests[t.key]!.isOpen, "allowed now, so the same close counts")
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

    /// Decision 12 (Martin, 2026-10-30): a coordinator's reason is read by responders, not by every
    /// member. It goes sealed for responders; the close itself goes plainly to everyone.
    func testACoordinatorsReasonIsReadByRespondersOnly() async {
        for p in t.air.phones { p.relay.isConfigured = true }
        await t.relaySetUp()
        caller.engine.press(.red)
        await t.air.run()
        let key = t.key
        let before = coordinator.relay.sent.count
        XCTAssertTrue(coordinator.engine.close(key, consent: false, reason: "Spoke to them, all well"))
        await t.air.run()
        let coord = coordinator.engine.saved!.me
        XCTAssertEqual(caller.request?.status, .closed(by: coord), "the caller still hears the close")
        XCTAssertEqual(caller.request?.settled?.reason, "", "but not the reason")
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.settled?.reason, "Spoke to them, all well")
        let sent = coordinator.relay.sent.dropFirst(before).map(\.0)
        let sealed = sent.filter { if case .forResponders = $0 { true } else { false } }
        XCTAssertEqual(sealed.count, 1, "one sealed frame for all responders")
        XCTAssertFalse(sent.contains { if case let .signed(_, inner, _) = $0, case let .callState(_, _, _, _, r)? = HelpFrame(inner) { return !r.isEmpty }; return false },
                       "the reason never goes where every member could read it")
        XCTAssertNil(ForResponders.open(sealed[0], in: caller.engine.group!, at: t.clock.now), "a caller's phone cannot open it")
        XCTAssertNotNil(ForResponders.open(sealed[0], in: responder.engine.group!, at: t.clock.now), "a responder's can")
        // A caller sealing a close as if a coordinator closes nothing.
        let forged = ForResponders.seal(.callState(unit: key.unit, request: key.request, state: .closedWithReason, at: UInt32(t.clock.now.timeIntervalSince1970), reason: "x"),
                                        from: caller.identity, as: caller.engine.saved!.me, in: caller.engine.group!, at: t.clock.now)
        XCTAssertEqual(forged.count, 1)
        XCTAssertNil(ForResponders.open(forged[0], in: responder.engine.group!, at: t.clock.now))
    }

    /// The sealed reason can arrive before the plain close, or after: the responder keeps it either way.
    func testTheReasonIsKeptWhicheverOrderTheCloseArrivesIn() async {
        for p in t.air.phones { p.relay.isConfigured = true }
        await t.relaySetUp()
        caller.engine.press(.red)
        await t.air.run()
        let key = t.key
        t.air.keep = { _, _, to in to !== self.responder }
        XCTAssertTrue(coordinator.engine.close(key, consent: false, reason: "All well"))
        await t.air.run()
        let sent = coordinator.relay.sent.map(\.0)
        let sealed = sent.last { if case .forResponders = $0 { true } else { false } }!
        let plain = sent.last { if case let .signed(_, inner, _) = $0, case .callState? = HelpFrame(inner) { true } else { false } }!
        responder.engine.receive(plain, via: .internet)
        responder.engine.receive(sealed, via: .internet)
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.settled?.reason, "All well")
        responder.engine.receive(plain, via: .internet)
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.settled?.reason, "All well", "a repeat of the close does not wipe it")
        XCTAssertFalse(responder.engine.activity.inbox.requests[key]!.isOpen)
    }

    /// A group made before responders had their own key cannot seal for them: the reason goes
    /// inside the signed close, sealed with the group key, as it always did.
    func testAnOlderGroupSendsTheReasonAsBefore() async {
        for p in t.air.phones {
            p.relay.isConfigured = true
            var g = p.engine.group!
            g.secrets.responderPublicKey = nil
            g.secrets.responderPrivateKey = nil
            p.engine.joined(g, as: p.engine.saved!.me)
        }
        await t.relaySetUp()
        caller.engine.press(.red)
        await t.air.run()
        let key = t.key
        XCTAssertTrue(coordinator.engine.close(key, consent: false, reason: "All well"))
        await t.air.run()
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.settled?.reason, "All well")
        XCTAssertFalse(responder.engine.activity.inbox.requests[key]!.isOpen)
        XCTAssertEqual(caller.request?.status, .closed(by: coordinator.engine.saved!.me))
        XCTAssertFalse(coordinator.relay.sent.contains { if case .forResponders = $0.0 { true } else { false } })
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

    func testAnOldCloseNeverClosesANewCall() async {
        caller.engine.press(.red)
        await t.air.run()
        let key = t.key
        let old = HelpFrame.signing(.callState(unit: key.unit, request: key.request, state: .closedWithConsent,
                                               at: UInt32(t.clock.now.timeIntervalSince1970 - 86_400), reason: ""),
                                    as: coordinator.engine.saved!.me, identity: coordinator.identity, group: t.gid)
        responder.engine.receive(old, via: .internet)
        caller.engine.receive(old, via: .internet)
        XCTAssertTrue(responder.engine.activity.inbox.requests[key]!.isOpen, "made a day before the call was pressed")
        XCTAssertEqual(caller.request?.status, .waitingForResponder)
        XCTAssertNotNil(caller.request?.nextResend)
    }

    func testACloseHeardBeforeItsCallDoesNotSilenceIt() async {
        let unit = caller.engine.me!.unit!
        let close = HelpFrame.signing(.callState(unit: unit, request: 1, state: .closedWithConsent, at: UInt32(t.clock.now.timeIntervalSince1970), reason: ""),
                                      as: coordinator.engine.saved!.me, identity: coordinator.identity, group: t.gid)
        responder.engine.receive(close, via: .internet)
        XCTAssertNil(responder.engine.activity.inbox.requests[IncomingRequest.Key(unit: unit, request: 1)])
        caller.engine.press(.red)
        await t.air.run()
        XCTAssertTrue(responder.engine.activity.inbox.requests[t.key]!.isOpen)
        XCTAssertNotNil(responder.alerts.scheduled[t.key])
    }

    func testAReasonNeedsTheInternet() async {
        caller.engine.press(.red)
        await t.air.run()
        XCTAssertFalse(coordinator.engine.canSendReason)
        XCTAssertFalse(coordinator.engine.close(t.key, consent: false, reason: "Spoke to them"), "it would reach nobody else")
        XCTAssertTrue(responder.engine.activity.inbox.requests[t.key]!.isOpen)
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
        XCTAssertEqual(f.forRespondersPart.map { [$0.0, UInt32($0.1), UInt32($0.2)] }, [70001, 3, 255])
        XCTAssertTrue(HelpFrame.callState(unit: 70001, request: 3, state: .callerOK, at: 0, reason: "").mayGoOnGroupChannel)
        XCTAssertNil(HelpFrame.callState(unit: 70001, request: 3, state: .callerOK, at: 0, reason: "").forRespondersPart)
        XCTAssertLessThanOrEqual(HelpFrame.signing(f, as: 1, identity: DeviceIdentity(), group: Data(count: 16)).encoded().count, HelpFrame.maxPayload)
    }
}
