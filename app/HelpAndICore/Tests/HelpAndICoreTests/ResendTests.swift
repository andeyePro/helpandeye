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
        r.markResent()
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
