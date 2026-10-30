// Mains and battery (decisions 3 and 4): a power cut is mains gone for ten seconds, so a flicker
// is not one; hours left come from the cell's resting voltage and the box's average draw; the
// hours are reported at 24, 12, 6, 3, 2 and 1, and a responder's acknowledgement silences all but
// the last.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

namespace helpandi {

struct BatteryModel {
    uint32_t capacityMAh;
    uint32_t drawMA;
};

// The share of a lithium cell's charge left at a resting voltage, 0 to 1, by a piecewise-linear
// curve. Rough, which is why the reports say "about".
double batteryFraction(uint16_t millivolts);

// Whole hours left, rounded down.
uint32_t hoursLeft(uint16_t millivolts, const BatteryModel& model);

class PowerMonitor {
public:
    static constexpr uint64_t kSettleMs = 10000;
    static constexpr uint32_t kReportHours[6] = {24, 12, 6, 3, 2, 1};

    enum class Mains : uint8_t { unknown, on, off };
    enum class Report : uint8_t { none, mainsLost, hoursLeft, mainsBack };

    // `hours` is the estimate when a report is due, not the mark it passed.
    struct Event {
        Report report;
        uint32_t hours;
    };

    explicit PowerMonitor(const BatteryModel& model) : model_(model) {}

    // Fed the mains level and the battery voltage whenever the board has them. At most one
    // report per call; the next call gives the next.
    Event update(uint64_t nowMs, bool mainsPresent, uint16_t millivolts);

    Mains mains() const { return mains_; }
    uint32_t hours() const { return hours_; }

    // A responder has seen the power cut: only the final warning still goes.
    void acknowledged() { acknowledged_ = true; }

private:
    BatteryModel model_;
    Mains mains_ = Mains::unknown;
    bool rawMains_ = false;
    uint64_t rawSince_ = 0;
    bool rawSeen_ = false;
    uint32_t hours_ = 0;
    uint8_t reported_ = 0;
    bool acknowledged_ = false;
};

}  // namespace helpandi
