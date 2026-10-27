import XCTest
@testable import HelpAndICore

final class ResendTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    let sig = Data(repeating: 1, count: 64)

    func testBacksOffThenEveryTenMinutes() {
        XCTAssertEqual(Resend.due(1, after: t0), t0.addingTimeInterval(30))
        XCTAssertEqual(Resend.due(2, after: t0), t0.addingTimeInterval(90))
        XCTAssertEqual(Resend.due(4, after: t0), t0.addingTimeInterval(450))
        XCTAssertEqual(Resend.due(5, after: t0), t0.addingTimeInterval(1050))
        XCTAssertEqual(Resend.due(6, after: t0), t0.addingTimeInterval(1650))
    }

    func testResendsUntilAcknowledgedAndNeverStopsOnATimer() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: t0)
        r.update(.mesh, .sent)
        XCTAssertFalse(r.resendDue(at: t0.addingTimeInterval(29)))
        XCTAssertTrue(r.resendDue(at: t0.addingTimeInterval(30)))
        r.markResent(at: t0.addingTimeInterval(30))
        XCTAssertFalse(r.resendDue(at: t0.addingTimeInterval(31)))
        XCTAssertTrue(r.resendDue(at: t0.addingTimeInterval(86_400 * 7)), "a week later it is still going out")
        r.receive(.ack(unit: 5, request: 1, responder: 2, ackedAt: UInt32(t0.timeIntervalSince1970), signature: sig))
        XCTAssertFalse(r.resendDue(at: t0.addingTimeInterval(86_400 * 7)))
        XCTAssertNil(r.nextResend)
    }

    func testCrossedCallsAreRetriedToo() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .amber, createdAt: t0)
        r.update(.mesh, .failed("no box"))
        XCTAssertTrue(r.resendDue(at: t0.addingTimeInterval(30)), "a box that comes back gets the call")
    }

    func testResendsAreDuplicatesToResponders() {
        var inbox = ResponderInbox()
        let call = HelpFrame.call(unit: 5, request: 1, colour: .red, sentAt: 0)
        inbox.receive(call, via: .mesh, at: t0)
        XCTAssertEqual(inbox.receive(call, via: .mesh, at: t0.addingTimeInterval(30)), .duplicate)
        XCTAssertEqual(inbox.requests.count, 1)
    }

    func testResendsUseTheShareThatLeavesRoomForANewPress() {
        var b = AirtimeBudget(dutyCycle: 0.01)
        b.record(18, at: t0)
        XCTAssertFalse(b.allows(0.5, kind: .optional, at: t0), "resends go as optional and stop at half")
        XCTAssertTrue(b.allows(0.5, kind: .call, at: t0), "a new press still has room")
    }

    func testAlertTimesRepeatFromTheTurnAndSkipThePast() {
        let turn = t0.addingTimeInterval(120)
        XCTAssertEqual(alertTimes(turnAt: turn, every: 60, from: t0, count: 3), [turn, turn.addingTimeInterval(60), turn.addingTimeInterval(120)])
        XCTAssertEqual(alertTimes(turnAt: turn, every: 60, from: turn.addingTimeInterval(90), count: 2),
                       [turn.addingTimeInterval(120), turn.addingTimeInterval(180)])
        XCTAssertEqual(alertTimes(turnAt: turn, every: 60, from: t0, count: 0), [])
    }
}

final class SecondReviewTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    let sig = Data(repeating: 1, count: 64)
    var at0: UInt32 { UInt32(t0.timeIntervalSince1970) }

    func testAfterALongSleepMissedResendsAreSkipped() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: t0)
        r.update(.mesh, .sent)
        let later = t0.addingTimeInterval(5 * 3600)
        XCTAssertTrue(r.resendDue(at: later))
        r.markResent(at: later)
        XCTAssertFalse(r.resendDue(at: later), "one resend, not thirty back to back")
        XCTAssertFalse(r.resendDue(at: later.addingTimeInterval(15)))
    }

    func testGreenIsRepeatedOnlyAFewTimes() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .green, createdAt: t0)
        r.update(.mesh, .sent)
        for _ in 0..<4 { XCTAssertTrue(r.resendDue(at: t0.addingTimeInterval(86_400))); r.markResent(at: t0) }
        XCTAssertFalse(r.resendDue(at: t0.addingTimeInterval(86_400)))
    }

    func testAlertTailStretchesForHours() {
        let times = alertTimes(turnAt: t0, every: 60, quick: 10, later: 600, from: t0, count: 30)
        XCTAssertEqual(times.count, 30)
        XCTAssertEqual(times[9], t0.addingTimeInterval(540))
        XCTAssertEqual(times[10], t0.addingTimeInterval(600))
        XCTAssertEqual(times.last, t0.addingTimeInterval(600 + 19 * 600))
        XCTAssertEqual(alertTimes(turnAt: t0, every: 60, quick: 10, later: 600, from: t0.addingTimeInterval(3600), count: 5).first,
                       t0.addingTimeInterval(3600), "the tail continues past the end of the quick ones")
    }

    func testSameNumbersAtANewTimeAreANewCall() {
        var inbox = ResponderInbox()
        let key = IncomingRequest.Key(unit: 5, request: 1)
        inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: at0), via: .mesh, at: t0)
        inbox.receive(.ack(unit: 5, request: 1, responder: 2, ackedAt: at0 + 10, signature: sig), via: .mesh, at: t0)
        XCTAssertTrue(inbox.requests[key]!.isAcknowledged)
        XCTAssertEqual(inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: at0 + 86_400), via: .mesh, at: t0), .new(key))
        XCTAssertFalse(inbox.requests[key]!.isAcknowledged)
    }

    func testResponderIgnoresAnAckFromBeforeTheCallLikeTheCallerDoes() {
        var inbox = ResponderInbox()
        let key = IncomingRequest.Key(unit: 5, request: 1)
        inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: at0), via: .mesh, at: t0)
        XCTAssertEqual(inbox.receive(.ack(unit: 5, request: 1, responder: 2, ackedAt: at0 - 3600, signature: sig), via: .mesh, at: t0), .ignored)
        XCTAssertFalse(inbox.requests[key]!.isAcknowledged)
    }

    func testHeardAcksAreKeptForPassingOn() {
        var inbox = ResponderInbox()
        let key = IncomingRequest.Key(unit: 5, request: 1)
        let ack = HelpFrame.ack(unit: 5, request: 1, responder: 2, ackedAt: at0, signature: sig)
        inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: at0), via: .mesh, at: t0)
        inbox.receive(ack, via: .internet, at: t0)
        XCTAssertEqual(inbox.requests[key]?.acks[2], ack)
        let back = try! JSONDecoder().decode(ResponderInbox.self, from: JSONEncoder().encode(inbox))
        XCTAssertEqual(back.requests[key]?.acks[2], ack)
    }

    func testAirtimeLogSurvivesARelaunch() throws {
        var b = AirtimeBudget(dutyCycle: 0.01)
        b.record(18, at: t0)
        let back = try JSONDecoder().decode(AirtimeBudget.self, from: JSONEncoder().encode(b))
        XCTAssertFalse(back.allows(1, kind: .optional, at: t0))
    }

    func testAtMostFourCheckInsADay() {
        XCTAssertEqual(CheckInSchedule(times: [60, 120, 180, 240, 300]).times, [60, 120, 180, 240])
    }
}
