import XCTest
@testable import helpandeyeCore

final class HelpCountdownTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_793_000_000)

    func testItTapsEveryTenSecondsWarnsAtThirtyAndSendsAtTheEnd() {
        let c = HelpCountdown(startedAt: start)
        var events: [HelpCountdown.Event] = []
        for s in 0..<70 { events += c.events(from: start.addingTimeInterval(TimeInterval(s)), to: start.addingTimeInterval(TimeInterval(s + 1))) }
        XCTAssertEqual(events, [.vibrate, .vibrate, .vibrate, .warn, .vibrate, .vibrate, .send])
        XCTAssertEqual(c.remaining(at: start), 60)
        XCTAssertEqual(c.remaining(at: start.addingTimeInterval(30.5)), 30)
        XCTAssertEqual(c.remaining(at: start.addingTimeInterval(99)), 0)
    }

    func testALateWakeStillSendsOnce() {
        let c = HelpCountdown(startedAt: start)
        let late = c.events(from: start.addingTimeInterval(25), to: start.addingTimeInterval(200))
        XCTAssertEqual(late.last, .send)
        XCTAssertEqual(late.filter { $0 == .send }.count, 1)
        XCTAssertEqual(c.events(from: start.addingTimeInterval(200), to: start.addingTimeInterval(300)), [])
    }

    func testTheWarningUsesTheWearersWords() {
        XCTAssertEqual(HelpCountdown.warning(in: .standard),
                       "Calling for help in 30 seconds. Press I'm OK to stop, or Help to ask for help now.")
    }
}
