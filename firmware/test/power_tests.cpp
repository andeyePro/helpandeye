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
