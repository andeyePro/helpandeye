// Mains and battery (decisions 3 and 4): a power cut is mains gone for ten seconds, so a flicker
// is not one; hours left come from the cell's resting voltage and the box's average draw; the
// hours are reported at 24, 12, 6, 3, 2 and 1, and a responder's acknowledgement silences all but
// the last. A build without the mains wire estimates mains from the battery's trend instead,
// with less confidence (section 10).
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

namespace helpandi {

struct BatteryModel {
    uint32_t capacityMAh;
    // The box's average draw left alone, and while something keeps it awake (section 10).
    uint32_t drawMA;
    uint32_t awakeMA;
    // Whether the build has the mains wire (section 5). Without it the battery's trend decides.
    bool mainsSensed;

    // A constructor rather than an aggregate: the board compiles as C++11, where a default
    // member initialiser would stop brace initialisation.
    constexpr BatteryModel(uint32_t capacityMAh, uint32_t drawMA, bool mainsSensed = true)
        : capacityMAh(capacityMAh), drawMA(drawMA), awakeMA(drawMA), mainsSensed(mainsSensed) {}
};

enum class Mains : uint8_t { unknown, on, off };

// The share of a lithium cell's charge left at a resting voltage, 0 to 1, by a piecewise-linear
// curve. Rough, which is why the reports say "about".
double batteryFraction(uint16_t millivolts);

// Whole hours left, rounded down.
uint32_t hoursLeft(uint16_t millivolts, const BatteryModel& model);

// Mains from the battery alone. On mains the charger holds the cell near its charged level; when
// mains goes the cell sags under the box's load and keeps falling; when mains returns the charger
// lifts it, or holds a cell still too full to recharge. One reading a minute, kept for two hours
// and compared as five-minute means, so one noisy reading or a transmit burst cannot decide it:
// a cut is the newest mean well under the highest of the two hours and still falling against
// half an hour before, so a charger finishing (a step down, then held) and a full cell's slow
// self-discharge on mains are not. The thresholds are a guess at the Heltec V4's charger and the
// box's draw, to be set from a box's own recordings (MANUAL-TESTS 53); the fall must stay above
// the step the charger makes when it finishes.
class MainsEstimate {
public:
    static constexpr uint64_t kSampleMs = 60000;
    static constexpr size_t kBlock = 5;
    static constexpr size_t kBlocks = 24;
    static constexpr size_t kHistory = kBlock * kBlocks;
    // Decisions need this much history: the newest block, the one half an hour before it, and
    // something in between.
    static constexpr size_t kLeastBlocks = 7;
    // The newest block this far under the highest of the two hours is a cut, if it is still
    // falling against the block half an hour before.
    static constexpr int kFallMV = 40;
    static constexpr int kStillFallingMV = 8;
    // The newest block this far over the lowest of the two hours is the charger: mains is back.
    static constexpr int kRiseMV = 25;
    // Half an hour of blocks within this of each other, at the charged level, is a cell held by
    // its charger. A full cell on battery alone is not held: under the box's load it falls.
    static constexpr int kFlatMV = 6;
    static constexpr size_t kFlatBlocks = 6;
    static constexpr uint16_t kChargedMV = 4050;
    // How many minutes in a row the readings must say the same before it counts.
    static constexpr size_t kConfirm = 3;

    void sample(uint64_t nowMs, uint16_t millivolts);
    Mains mains() const { return mains_; }

private:
    Mains read() const;
    // The mean of block `j` back from now: 0 is the newest five minutes.
    int block(size_t j) const;

    uint16_t samples_[kHistory] = {};
    size_t head_ = 0, count_ = 0;
    uint64_t lastSampleMs_ = 0;
    Mains mains_ = Mains::unknown;
    Mains pending_ = Mains::unknown;
    size_t agreed_ = 0;
};

class PowerMonitor {
public:
    using Mains = helpandi::Mains;
    static constexpr uint64_t kSettleMs = 10000;
    static constexpr uint32_t kReportHours[6] = {24, 12, 6, 3, 2, 1};

    enum class Report : uint8_t { none, mainsLost, hoursLeft, mainsBack };

    // `hours` is the estimate when a report is due, not the mark it passed.
    struct Event {
        Report report;
        uint32_t hours;
    };

    explicit PowerMonitor(const BatteryModel& model) : model_(model) {}

    // Fed the mains level and the battery voltage whenever the board has them. At most one
    // report per call; the next call gives the next. Without the mains wire the level is ignored
    // and the battery's trend decides.
    Event update(uint64_t nowMs, bool mainsPresent, uint16_t millivolts);

    Mains mains() const { return mains_; }
    uint32_t hours() const { return hours_; }
    // The mains state is the battery's trend, not the wire: a report says "probably".
    bool estimated() const { return !model_.mainsSensed; }

    // A responder has seen the power cut: only the final warning still goes.
    void acknowledged() { acknowledged_ = true; }

    // The draw the hours are counted at from the next update: the box's, as it is now.
    void setDraw(uint32_t drawMA) { model_.drawMA = drawMA; }

private:
    BatteryModel model_;
    MainsEstimate estimate_;
    Mains mains_ = Mains::unknown;
    bool rawMains_ = false;
    uint64_t rawSince_ = 0;
    bool rawSeen_ = false;
    uint32_t hours_ = 0;
    uint8_t reported_ = 0;
    bool acknowledged_ = false;
};

}  // namespace helpandi
