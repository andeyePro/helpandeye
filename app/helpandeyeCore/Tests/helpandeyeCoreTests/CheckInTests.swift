import XCTest
@testable import helpandeyeCore

final class CheckInTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    func testGreenInsideTheWindowCounts() {
        let s = CheckInSchedule(times: [9 * 60], grace: 1800)
        XCTAssertNil(s.missed(greens: [at(27, 9, 20)], since: at(27, 0), now: at(27, 12), calendar: cal))
        XCTAssertNil(s.missed(greens: [at(27, 8, 45)], since: at(27, 0), now: at(27, 12), calendar: cal))
    }

    func testMissedOnlyOnceTheGraceHasRunOut() {
        let s = CheckInSchedule(times: [9 * 60], grace: 1800)
        XCTAssertNil(s.missed(greens: [], since: at(27, 0), now: at(27, 9, 29), calendar: cal))
        XCTAssertEqual(s.missed(greens: [], since: at(27, 0), now: at(27, 9, 30), calendar: cal), at(27, 9))
    }

    func testAnEarlierGreenDoesNotCover() {
        let s = CheckInSchedule(times: [9 * 60, 21 * 60], grace: 1800)
        XCTAssertEqual(s.missed(greens: [at(27, 9)], since: at(27, 0), now: at(27, 22), calendar: cal), at(27, 21))
    }

    func testOffWhenNoTimesAndAcrossTheClockChange() {
        XCTAssertNil(CheckInSchedule(times: []).missed(greens: [], since: at(24, 0), now: at(27, 0), calendar: cal))
        // British Summer Time ended on 25 October 2026; 09:00 is still 09:00 local.
        let s = CheckInSchedule(times: [9 * 60])
        XCTAssertEqual(s.moments(from: at(24, 0), until: at(27, 0), calendar: cal), [at(24, 9), at(25, 9), at(26, 9)])
    }

    func testCheckInsBeforeTheScheduleStartedAreNotMissed() {
        let s = CheckInSchedule(times: [9 * 60])
        XCTAssertNil(s.missed(greens: [], since: at(27, 10), now: at(27, 12), calendar: cal))
    }
}

final class CheckInWatchTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()
    func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: h, minute: m))! }
    func t(_ d: Date) -> UInt32 { UInt32(d.timeIntervalSince1970) }

    func schedule(_ w: inout CheckInWatch) {
        w.apply(.checkIns(unit: 7, since: t(at(0)), grace: 30, times: [540]))
    }

    func testRaisesAMissedCheckInOnceAfterTheWait() {
        var w = CheckInWatch(); schedule(&w)
        XCTAssertTrue(w.due(at: at(9, 34), calendar: cal).isEmpty, "still waiting for the caller's phone")
        XCTAssertEqual(w.due(at: at(9, 35), calendar: cal).map(\.missed), [at(9)])
        XCTAssertTrue(w.due(at: at(10), calendar: cal).isEmpty, "only once")
    }

    func testAGreenHeardInTimeCovers() {
        var w = CheckInWatch(); schedule(&w)
        w.apply(.call(unit: 7, request: 4, colour: .green, sentAt: t(at(9, 10))))
        XCTAssertTrue(w.due(at: at(12), calendar: cal).isEmpty)
    }

    func testTheCallersOwnRaiseCovers() {
        var w = CheckInWatch(); schedule(&w)
        w.heardRaised(unit: 7, at: at(9, 31), calendar: cal)
        XCTAssertTrue(w.due(at: at(12), calendar: cal).isEmpty)
    }

    func testTurningCheckInsOffStopsWatching() {
        var w = CheckInWatch(); schedule(&w)
        w.apply(.checkIns(unit: 7, since: t(at(0)), grace: 30, times: []))
        XCTAssertTrue(w.due(at: at(12), calendar: cal).isEmpty)
    }

    func testScheduleFrameRoundTripsAndStaysOffTheGroupChannel() {
        let f = HelpFrame.checkIns(unit: 7, since: 100, grace: 30, times: [540, 1260])
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertFalse(f.mayGoOnGroupChannel)
        var bad = f.encoded(); bad[bad.count - 1] = 0xFF; bad[bad.count - 2] = 0xFF
        XCTAssertNil(HelpFrame(bad))
    }
}
