import XCTest
@testable import helpandeyeCore

final class EscalationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testOnlyAvailableRespondersLeastRecentFirst() {
        let rs = [
            ResponderInfo(member: 1, availableNow: true, lastAnsweredAt: t0),
            ResponderInfo(member: 2, availableNow: false),
            ResponderInfo(member: 3, availableNow: true, lastAnsweredAt: t0.addingTimeInterval(-3600)),
            ResponderInfo(member: 4, availableNow: true),
        ]
        XCTAssertEqual(EscalationPolicy.standard.order(rs), [4, 3, 1])
    }

    func testClosestFirstThenFairness() {
        let p = EscalationPolicy(useDistance: true, similarDistance: 500)
        let rs = [
            ResponderInfo(member: 1, availableNow: true, distance: 2000),
            ResponderInfo(member: 2, availableNow: true, distance: 100, lastAnsweredAt: t0),
            ResponderInfo(member: 3, availableNow: true, distance: 300),
            ResponderInfo(member: 4, availableNow: true, distance: nil),
        ]
        XCTAssertEqual(p.order(rs), [3, 2, 1, 4])
    }

    func testRedAddsSomeoneEveryTwoMinutesThenWholeGroup() {
        let e = Escalation(order: [7, 8, 9], interval: EscalationPolicy.standard.interval(for: .red))
        XCTAssertEqual(e.interval, 120)
        XCTAssertEqual(e.stage(after: 0), .init(alerted: [7], wholeGroup: false))
        XCTAssertEqual(e.stage(after: 119), .init(alerted: [7], wholeGroup: false))
        XCTAssertEqual(e.stage(after: 120), .init(alerted: [7, 8], wholeGroup: false))
        XCTAssertEqual(e.stage(after: 360), .init(alerted: [7, 8, 9], wholeGroup: true))
        XCTAssertEqual(e.nextStep(after: 130), 240)
        XCTAssertNil(e.nextStep(after: 360))
    }

    func testNeverWindsDown() {
        let e = Escalation(order: [1, 2], interval: 900)
        XCTAssertEqual(e.stage(after: 86_400 * 365), .init(alerted: [1, 2], wholeGroup: true))
    }

    func testNobodyAvailableAlertsEveryoneAtOnce() {
        let e = Escalation(colour: .amber, responders: [ResponderInfo(member: 1, availableNow: false)])
        XCTAssertEqual(e.stage(after: 0), .init(alerted: [], wholeGroup: true))
        XCTAssertEqual(EscalationPolicy.standard.interval(for: .amber), 900)
    }
}

final class RotaTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    func h(_ n: Double) -> Date { t0.addingTimeInterval(n * 3600) }

    func testGapsWhereNobodyIsAvailable() {
        var rota = Rota()
        rota.add(responder: 1, from: h(0), until: h(8), available: true)
        rota.add(responder: 2, from: h(6), until: h(12), available: true)
        rota.add(responder: 1, from: h(16), until: h(30), available: true)
        XCTAssertEqual(rota.gaps(from: h(0)), [DateInterval(start: h(12), end: h(16))])
    }

    func testLaterChangeOverridesAndComesOverTheMesh() {
        var rota = Rota()
        rota.add(responder: 1, from: h(0), until: h(24), available: true)
        XCTAssertTrue(rota.gaps(from: h(0)).isEmpty)
        rota.apply(.availability(responder: 1, from: UInt32(h(2).timeIntervalSince1970),
                                 until: UInt32(h(3).timeIntervalSince1970), available: false))
        XCTAssertEqual(rota.gaps(from: h(0)), [DateInterval(start: h(2), end: h(3))])
        XCTAssertEqual(rota.available(at: h(1)), [1])
        XCTAssertEqual(rota.available(at: h(2.5)), [])
    }

    func testDefaultAvailabilityCoversUnfilledTime() {
        var rota = Rota(responders: [1, 2], defaultAvailable: true)
        XCTAssertTrue(rota.gaps(from: h(0)).isEmpty)
        rota.add(responder: 1, from: h(1), until: h(2), available: false)
        XCTAssertTrue(rota.gaps(from: h(0)).isEmpty)
        rota.add(responder: 2, from: h(1.5), until: h(3), available: false)
        XCTAssertEqual(rota.gaps(from: h(0)), [DateInterval(start: h(1.5), end: h(2))])
    }

    func testEmptyRotaIsOneGap() {
        XCTAssertEqual(Rota().gaps(from: t0, horizon: 3600), [DateInterval(start: t0, end: h(1))])
    }

    func testCoordinatorAlertWidensUntilAcknowledged() {
        var a = CoordinatorAlert(raisedAt: t0)
        XCTAssertEqual(a.audience(at: t0), .firstCoordinator)
        XCTAssertEqual(a.audience(at: h(1)), .allCoordinators)
        XCTAssertEqual(a.audience(at: h(2)), .wholeGroup)
        XCTAssertEqual(a.audience(at: h(500)), .wholeGroup)
        a.acknowledge(by: 3)
        XCTAssertNil(a.audience(at: h(2)))
    }
}

final class AirtimeTests: XCTestCase {
    let ukNarrow = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8)

    func testUKNarrowIsInTheTenPercentBand() {
        XCTAssertEqual(ukNarrow.band?.dutyCycle, 0.10)
        XCTAssertEqual(RadioSettings(frequencyMHz: 868.1, bandwidthKHz: 125, spreadingFactor: 7, codingRate: 5).band?.dutyCycle, 0.01)
        XCTAssertNil(RadioSettings(frequencyMHz: 915, bandwidthKHz: 125, spreadingFactor: 7, codingRate: 5).band)
    }

    func testAirtimeMatchesSemtechCalculator() {
        // SF7, 125 kHz, CR 4/5, 8-symbol preamble, 10 bytes: 41.2 ms in Semtech's calculator.
        let r = RadioSettings(frequencyMHz: 868.1, bandwidthKHz: 125, spreadingFactor: 7, codingRate: 5, preambleSymbols: 8)
        XCTAssertEqual(r.airtime(bytes: 10), 0.041216, accuracy: 0.0005)
        XCTAssertGreaterThan(ukNarrow.airtime(bytes: 40), ukNarrow.airtime(bytes: 20))
    }

    func testOptionalTrafficKeepsHalfTheAllowanceFree() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = AirtimeBudget(dutyCycle: 0.01) // 36 s an hour; optional traffic may use 18 s
        b.record(17, at: t0)
        XCTAssertTrue(b.allows(1, kind: .optional, at: t0))
        XCTAssertFalse(b.allows(1.5, kind: .optional, at: t0))
        XCTAssertTrue(b.allows(15, kind: .call, at: t0), "calls may use up to 90%: 32.4 s")
        XCTAssertFalse(b.allows(16, kind: .call, at: t0))
        XCTAssertTrue(b.allows(18, kind: .optional, at: t0.addingTimeInterval(3600)))
    }

    func testReservationsCountAtOnceAndCanBeGivenBack() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = AirtimeBudget(dutyCycle: 0.01)
        let first = b.record(18, at: t0)
        XCTAssertFalse(b.allows(1, kind: .optional, at: t0), "a send still in flight already counts")
        b.cancel(first)
        XCTAssertTrue(b.allows(18, kind: .optional, at: t0))
    }
}

final class RoutePlanTests: XCTestCase {
    func testIPhoneLeavesSMSOutOfFirstAttempt() {
        XCTAssertEqual(RoutePlan.firstAttempt(available: [.internet, .sms, .mesh], smsIsAutomatic: false), [.internet, .mesh])
        XCTAssertEqual(RoutePlan.firstAttempt(available: [.internet, .sms, .mesh], smsIsAutomatic: true), [.internet, .sms, .mesh])
    }

    func testManualSMSOfferedOnlyAfterEverythingFailed() {
        var r = OutgoingRequest(unit: 70001, number: 3, colour: .red, createdAt: Date())
        r.update(.mesh, .failed("x")); r.update(.internet, .sending)
        XCTAssertFalse(RoutePlan.offerManualSMS(for: r, smsAvailable: true, smsIsAutomatic: false))
        r.update(.internet, .failed("x"))
        XCTAssertTrue(RoutePlan.offerManualSMS(for: r, smsAvailable: true, smsIsAutomatic: false))
        XCTAssertFalse(RoutePlan.offerManualSMS(for: r, smsAvailable: true, smsIsAutomatic: true))
        XCTAssertEqual(RoutePlan.smsBody(for: r), "Help&I Come now. Unit 70001, request 3. Reply in the Help&I app.")
    }
}
