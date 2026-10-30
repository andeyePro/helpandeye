#include "../core/power.hpp"
#include "test.hpp"

using namespace helpandi;

namespace {
const BatteryModel kCell{3000, 100};  // 30 hours from full
}

TEST(hoursLeftFollowTheCellsCurve) {
    CHECK(hoursLeft(4200, kCell) == 30);
    CHECK(hoursLeft(3800, kCell) == 15);
    CHECK(hoursLeft(3400, kCell) == 0);
    CHECK(hoursLeft(3000, kCell) == 0);
    CHECK(hoursLeft(4200, BatteryModel{3000, 0}) == 0);
}

TEST(aFlickerIsNotAPowerCut) {
    PowerMonitor m(kCell);
    CHECK(m.update(0, true, 4200).report == PowerMonitor::Report::none);
    CHECK(m.update(10000, true, 4200).report == PowerMonitor::Report::none);
    CHECK(m.mains() == PowerMonitor::Mains::on);
    CHECK(m.update(20000, false, 4200).report == PowerMonitor::Report::none);
    CHECK(m.update(21000, true, 4200).report == PowerMonitor::Report::none);
    CHECK(m.update(40000, true, 4200).report == PowerMonitor::Report::none);
    CHECK(m.mains() == PowerMonitor::Mains::on);
}

TEST(aPowerCutIsReportedThenTheHoursThenThePowerBack) {
    PowerMonitor m(kCell);
    m.update(0, true, 4200);
    m.update(10000, true, 4200);
    m.update(20000, false, 4200);
    CHECK(m.update(29999, false, 4200).report == PowerMonitor::Report::none);
    PowerMonitor::Event e = m.update(30000, false, 4200);
    CHECK(e.report == PowerMonitor::Report::mainsLost);
    CHECK(m.mains() == PowerMonitor::Mains::off);
    // 30 hours: above every mark.
    CHECK(m.update(31000, false, 4200).report == PowerMonitor::Report::none);
    e = m.update(32000, false, 4050);  // 25.5 h, still above 24
    CHECK(e.report == PowerMonitor::Report::none);
    e = m.update(33000, false, 4000);  // 24 h
    CHECK(e.report == PowerMonitor::Report::hoursLeft && e.hours == 24);
    CHECK(m.update(34000, false, 4000).report == PowerMonitor::Report::none);
    e = m.update(35000, false, 3800);  // 15 h: the 12 mark is not passed yet
    CHECK(e.report == PowerMonitor::Report::none);
    e = m.update(36000, false, 3700);  // 9 h: passes 12
    CHECK(e.report == PowerMonitor::Report::hoursLeft && e.hours == 9);
    e = m.update(37000, false, 3500);  // 1 h: passes 6, 3, 2 and 1, reported one per call
    CHECK(e.report == PowerMonitor::Report::hoursLeft && e.hours == 1);
    CHECK(m.update(38000, false, 3500).report == PowerMonitor::Report::hoursLeft);
    CHECK(m.update(39000, false, 3500).report == PowerMonitor::Report::hoursLeft);
    CHECK(m.update(40000, false, 3500).report == PowerMonitor::Report::hoursLeft);
    CHECK(m.update(41000, false, 3500).report == PowerMonitor::Report::none);
    m.update(50000, true, 3500);
    CHECK(m.update(59999, true, 3500).report == PowerMonitor::Report::none);
    CHECK(m.update(60000, true, 3500).report == PowerMonitor::Report::mainsBack);
    CHECK(m.update(61000, true, 3500).report == PowerMonitor::Report::none);
}

TEST(anAcknowledgementSilencesAllButTheFinalWarning) {
    PowerMonitor m(kCell);
    m.update(0, false, 4200);
    CHECK(m.update(10000, false, 4200).report == PowerMonitor::Report::mainsLost);
    m.acknowledged();
    CHECK(m.update(11000, false, 3600).report == PowerMonitor::Report::none);  // 4.5 h: 24, 12 and 6 passed quietly
    PowerMonitor::Event e = m.update(12000, false, 3450);                      // 0.75 h: 3 and 2 quiet, 1 still goes
    CHECK(e.report == PowerMonitor::Report::hoursLeft && e.hours == 0);
    CHECK(m.update(13000, false, 3450).report == PowerMonitor::Report::none);
}

TEST(aBoxSwitchedOnDuringAPowerCutReportsItAndOnMainsSaysNothing) {
    PowerMonitor off(kCell);
    off.update(0, false, 4000);
    CHECK(off.update(10000, false, 4000).report == PowerMonitor::Report::mainsLost);
    PowerMonitor on(kCell);
    on.update(0, true, 4000);
    CHECK(on.update(10000, true, 4000).report == PowerMonitor::Report::none);
    CHECK(on.mains() == PowerMonitor::Mains::on);
}

TEST(thePowerBackResetsTheMarksForTheNextCut) {
    PowerMonitor m(kCell);
    m.update(0, false, 3700);
    CHECK(m.update(10000, false, 3700).report == PowerMonitor::Report::mainsLost);
    CHECK(m.update(11000, false, 3700).hours == 9);
    m.update(20000, true, 3700);
    CHECK(m.update(30000, true, 3700).report == PowerMonitor::Report::mainsBack);
    m.update(40000, false, 3700);
    CHECK(m.update(50000, false, 3700).report == PowerMonitor::Report::mainsLost);
    CHECK(m.update(51000, false, 3700).report == PowerMonitor::Report::hoursLeft);
}

// Without the mains wire: the battery's trend, one reading a minute, in the shapes a box's own
// readings take. The wire's level passed in is always false, to show it is ignored.
namespace {

const BatteryModel kNoWire{3000, 100, false};

struct Trend {
    PowerMonitor monitor{kNoWire};
    uint64_t minute = 0;
    PowerMonitor::Report first = PowerMonitor::Report::none, last = PowerMonitor::Report::none;
    int reports = 0;

    // Feeds `count` minutes from `from`, moving `perMinute` tenths of a millivolt each minute,
    // with a small alternating noise on every reading.
    void run(int from, int tenthsPerMinute, int count, int noise = 6) {
        for (int i = 0; i < count; i++, minute++) {
            int mv = from + tenthsPerMinute * i / 10 + (minute % 2 ? noise : -noise);
            PowerMonitor::Event e = monitor.update(minute * 60000, false, uint16_t(mv));
            if (e.report != PowerMonitor::Report::none) {
                if (!reports) first = e.report;
                last = e.report;
                reports++;
            }
        }
    }
    Mains mains() const { return monitor.mains(); }
};

}  // namespace

TEST(withoutTheWireAChargingCellSaysMainsIsOnAndTheChargerFinishingIsNotACut) {
    Trend t;
    t.run(3800, 30, 60);  // charging: 3.8 V rising 3 mV a minute
    CHECK(t.mains() == Mains::on && t.monitor.estimated());
    CHECK(t.reports == 0);  // switched on with the mains on: nothing to report
    t.run(4200, 0, 30);     // the top of the charge
    t.run(4175, 0, 180);    // the charger finishes: a step down, then held for hours
    CHECK(t.mains() == Mains::on);
    CHECK(t.reports == 0);
}

TEST(withoutTheWireAFullCellRestingNeverFires) {
    Trend t;
    t.run(4190, 0, 240, 8);  // four hours held by the charger
    CHECK(t.mains() == Mains::on);
    t.run(4190, -1, 300, 8);  // a day's self-discharge, 0.1 mV a minute, then the top-up
    t.run(4160, 20, 5, 8);
    t.run(4200, 0, 60, 8);
    CHECK(t.mains() == Mains::on);
    CHECK(t.reports == 0);
    // A transmit burst or a bad reading in one sample.
    t.monitor.update(t.minute * 60000, false, 4100);
    t.minute++;
    t.run(4200, 0, 40, 8);
    CHECK(t.mains() == Mains::on);
    CHECK(t.reports == 0);
}

TEST(withoutTheWireAPowerCutFromFullIsProbablyACutWithinHalfAnHour) {
    Trend t;
    t.run(4190, 0, 60);
    CHECK(t.mains() == Mains::on);
    // Mains goes: the cell sags under the box's load in the first minutes, then falls a
    // millivolt a minute.
    t.run(4160, -10, 30);
    CHECK(t.mains() == Mains::off);
    CHECK(t.last == PowerMonitor::Report::mainsLost && t.reports == 1);
    CHECK(t.monitor.estimated());
    // The hours follow as with the wire.
    t.run(4000, 0, 1, 0);
    CHECK(t.last == PowerMonitor::Report::hoursLeft && t.monitor.hours() == 24);
}

TEST(withoutTheWireAPowerCutWhileChargingFromHalfIsACutWithinTenMinutes) {
    Trend t;
    t.run(3860, 10, 60);  // charging from half, slowly
    CHECK(t.mains() == Mains::on);
    t.run(3840, -5, 10);  // mains goes: the charging lift is lost at once, then the cell falls
    CHECK(t.mains() == Mains::off);
    CHECK(t.first == PowerMonitor::Report::mainsLost && t.last == PowerMonitor::Report::hoursLeft);
}

TEST(withoutTheWireTheChargerLiftingTheCellIsMainsBack) {
    Trend t;
    t.run(4190, 0, 60);
    t.run(4160, -10, 240);  // four hours on battery
    CHECK(t.mains() == Mains::off);
    t.run(3980, 30, 15);  // the charger: a step up at once, then rising
    CHECK(t.mains() == Mains::on);
    CHECK(t.last == PowerMonitor::Report::mainsBack);
}

TEST(withoutTheWireACellHeldStillAboveItsRechargeLevelIsMainsBackToo) {
    Trend t;
    t.run(4190, 0, 60);
    t.run(4160, -10, 60);  // an hour on battery
    CHECK(t.mains() == Mains::off);
    t.run(4110, 0, 45);  // mains back, but the cell is too full for the charger to start
    CHECK(t.mains() == Mains::on);
    CHECK(t.last == PowerMonitor::Report::mainsBack);
}

TEST(withoutTheWireABoxStartedOnBatteryReportsTheCutOnceTheFallShows) {
    Trend full;
    full.run(4150, -10, 70);  // a full cell on its own: falling a millivolt a minute from the start
    CHECK(full.mains() == Mains::off);
    CHECK(full.last == PowerMonitor::Report::mainsLost);
    Trend half;
    half.run(3900, -5, 60);  // at half the fall is slower: not yet
    CHECK(half.mains() == Mains::unknown);
    half.run(3870, -5, 60);
    CHECK(half.mains() == Mains::off);
}

TEST(withTheWireTheBatteryTrendIsIgnored) {
    PowerMonitor m(kCell);
    CHECK(!m.estimated());
    // The cell falls as in a cut, but the wire says mains is on.
    for (uint64_t minute = 0; minute < 120; minute++) m.update(minute * 60000, true, uint16_t(4200 - minute));
    CHECK(m.mains() == Mains::on);
}

TEST(withoutTheWireASleepingBoxReadingEveryTenMinutesStillSeesMainsBack) {
    Trend t;
    t.run(4190, 0, 60);
    t.run(4160, -10, 60);
    CHECK(t.mains() == Mains::off);
    // Asleep on battery, the box reads the cell once each ten-minute wake (kSleepS).
    uint64_t ms = t.minute * 60000;
    int mv = 4100;
    for (int wake = 0; wake < 12; wake++, ms += 600000, mv -= 10) t.monitor.update(ms, false, uint16_t(mv));
    CHECK(t.mains() == Mains::off);
    // The charger lifts the cell; mains back shows within one and a half hours of it.
    int woken = 0;
    for (mv = 4060; woken < 9 && t.mains() != Mains::on; woken++, ms += 600000, mv += 15) t.monitor.update(ms, false, uint16_t(mv));
    CHECK(t.mains() == Mains::on);
    CHECK(woken <= 9);
}

TEST(theEstimateSurvivesBeingCopiedAsTheRetainedCopyDoes) {
    Trend t;
    t.run(4190, 0, 60);
    t.run(4160, -10, 25);
    PowerMonitor copy = t.monitor;
    t.run(4135, -10, 10);
    for (uint64_t m = 85; m < 95; m++) copy.update(m * 60000, false, uint16_t(4135 - (m - 85) + (m % 2 ? 6 : -6)));
    CHECK(copy.mains() == t.mains() && copy.mains() == Mains::off);
}
