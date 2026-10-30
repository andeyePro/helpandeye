#include "power.hpp"

namespace helpandi {

constexpr uint32_t PowerMonitor::kReportHours[6];

double batteryFraction(uint16_t millivolts) {
    // A single lithium cell at rest, from full to the board's 3.4 V shutdown.
    static const struct {
        uint16_t mV;
        double fraction;
    } curve[] = {{4200, 1.0}, {4100, 0.9}, {4000, 0.8}, {3900, 0.65}, {3800, 0.5},
                 {3700, 0.3}, {3600, 0.15}, {3500, 0.05}, {3400, 0.0}};
    if (millivolts >= curve[0].mV) return 1.0;
    for (size_t i = 1; i < sizeof curve / sizeof curve[0]; i++) {
        if (millivolts >= curve[i].mV) {
            double span = curve[i - 1].mV - curve[i].mV;
            double up = (millivolts - curve[i].mV) / span;
            return curve[i].fraction + up * (curve[i - 1].fraction - curve[i].fraction);
        }
    }
    return 0.0;
}

uint32_t hoursLeft(uint16_t millivolts, const BatteryModel& model) {
    if (model.drawMA == 0) return 0;
    return uint32_t(batteryFraction(millivolts) * model.capacityMAh / model.drawMA);
}

PowerMonitor::Event PowerMonitor::update(uint64_t nowMs, bool mainsPresent, uint16_t millivolts) {
    if (!rawSeen_ || mainsPresent != rawMains_) {
        rawSeen_ = true;
        rawMains_ = mainsPresent;
        rawSince_ = nowMs;
    }
    Mains steady = nowMs - rawSince_ >= kSettleMs ? (rawMains_ ? Mains::on : Mains::off) : Mains::unknown;
    if (steady != Mains::unknown && steady != mains_) {
        bool wasKnown = mains_ != Mains::unknown;
        mains_ = steady;
        reported_ = 0;
        acknowledged_ = false;
        if (mains_ == Mains::off) return Event{Report::mainsLost, 0};
        // A box switched on with the mains on has nothing to report.
        if (wasKnown) return Event{Report::mainsBack, 0};
    }
    if (mains_ != Mains::off) return Event{Report::none, 0};

    hours_ = hoursLeft(millivolts, model_);
    for (size_t i = 0; i < 6; i++) {
        if (reported_ & (1 << i) || hours_ > kReportHours[i]) continue;
        reported_ |= uint8_t(1 << i);
        bool last = i == 5;
        if (acknowledged_ && !last) continue;
        return Event{Report::hoursLeft, hours_};
    }
    return Event{Report::none, 0};
}

}  // namespace helpandi
