import XCTest
@testable import helpandeyeCore

/// The power-cut guess from a stock MeshCore box's battery, against the firmware's own trends.
final class BatteryWatchTests: XCTestCase {
    /// The firmware's own trends for `MainsEstimate` (firmware/test/power_tests.cpp): a reading a
    /// minute, moving `tenths` of a millivolt each minute, with a small noise on each.
    struct Trend {
        var watch = BatteryWatch()
        var minute = 0
        var changes: [BatteryWatch.Mains] = []
        mutating func run(_ from: Int, _ tenths: Int, _ count: Int, noise: Int = 6) {
            for i in 0..<count {
                let before = watch.mains
                watch.add(from + tenths * i / 10 + (minute % 2 == 1 ? noise : -noise), at: Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 60))
                if watch.mains != before { changes.append(watch.mains) }
                minute += 1
            }
        }
    }

    func testAStockBoxsBatterySuggestsAPowerCutAsTheFirmwareWould() {
        var cut = Trend()
        cut.run(4190, 0, 60)
        XCTAssertEqual(cut.watch.mains, .on, "held by the charger")
        cut.run(4160, -10, 30)
        XCTAssertTrue(cut.watch.probablePowerCut, "the cell sags, then falls a millivolt a minute: within half an hour")
        cut.run(4130, -10, 210)
        cut.run(3980, 30, 15)
        XCTAssertEqual(cut.changes, [.on, .off, .on], "after four hours on battery the charger lifts it: power back")

        var charging = Trend()
        charging.run(3860, 10, 60)
        charging.run(3840, -5, 10)
        XCTAssertTrue(charging.watch.probablePowerCut, "charging from half, the lift is lost at once")

        var resting = Trend()
        resting.run(4190, 0, 240, noise: 8)
        resting.run(4190, -1, 300, noise: 8)
        resting.run(4160, 20, 5, noise: 8)
        resting.run(4200, 0, 60, noise: 8)
        resting.watch.add(4100, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(resting.minute) * 60))
        resting.minute += 1
        resting.run(4200, 0, 40, noise: 8)
        XCTAssertEqual(resting.changes, [.on], "a full cell resting, its top-up and one odd reading never show a cut")

        var finished = Trend()
        finished.run(3800, 30, 60)
        finished.run(4200, 0, 30)
        finished.run(4175, 0, 180)
        XCTAssertEqual(finished.changes, [.on], "the charger finishing steps down, then holds")

        var early = Trend()
        early.run(4190, 0, 20)
        early.run(4100, -10, 14)
        XCTAssertEqual(early.watch.mains, .unknown, "nothing is decided before 35 minutes of readings")
    }

    func testReadingsCloserThanAMinuteCountOnce() {
        var w = BatteryWatch()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<90 {
            w.add(4190, at: t.addingTimeInterval(Double(i) * 60))
            // The handshake's reading, or a reconnect's, within the same minute.
            w.add(3000, at: t.addingTimeInterval(Double(i) * 60 + 30))
        }
        XCTAssertEqual(w.mains, .on)
    }
}
