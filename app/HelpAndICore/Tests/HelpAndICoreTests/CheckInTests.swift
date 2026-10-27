import XCTest
@testable import HelpAndICore

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
