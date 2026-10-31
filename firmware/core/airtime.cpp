#include "airtime.hpp"

#include <cmath>
#include <cstring>

namespace helpandi {

const Band kBands[2] = {
    {"868.0-868.6 MHz", 868.0, 868.6, 0.01, 25},
    {"869.4-869.65 MHz", 869.4, 869.65, 0.10, 500},
};

double RadioSettings::airtime(int bytes) const {
    double sf = spreadingFactor, bw = bandwidthKHz * 1000;
    double tSym = std::pow(2.0, sf) / bw;
    double de = tSym > 0.016 ? 1.0 : 0.0;
    int c = codingRate < 5 ? 5 : (codingRate > 8 ? 8 : codingRate);
    double cr = c - 4;
    double preamble = (preambleSymbols + 4.25) * tSym;
    double num = 8.0 * bytes - 4 * sf + 28 + 16;
    double payload = std::ceil(num / (4 * (sf - 2 * de))) * (cr + 4);
    double symbols = 8 + (payload > 0 ? payload : 0);
    return preamble + symbols * tSym;
}

uint32_t RadioSettings::airtimeMs(int bytes) const { return uint32_t(std::ceil(airtime(bytes) * 1000)); }

const Band* RadioSettings::band() const {
    for (const Band& b : kBands)
        if (frequencyMHz >= b.lowMHz && frequencyMHz <= b.highMHz) return &b;
    return nullptr;
}

int meshPacketBytes(int payload, int pathBytes) {
    // MeshCore's sendGroupData puts the data type (2) and the length (1) before the payload.
    int plaintext = 3 + payload;
    return 2 + pathBytes + 1 + 2 + (plaintext + 15) / 16 * 16;
}

bool maxRadioPowerSetting(const Band& band, double antennaGainDBi, double amplifierGainDB, int boardMin, int boardMax,
                          int& setting) {
    // ERP is measured against a dipole, 2.15 dBi.
    double conducted = 10 * std::log10(band.maxERPmW) + 2.15 - antennaGainDBi;
    int s = int(std::floor(conducted - amplifierGainDB));
    if (s < boardMin) return false;
    setting = s < boardMax ? s : boardMax;
    return true;
}

namespace {
// An entry stamped after `nowMs` (the clock went back) still counts, as in Airtime.swift: never
// under-count what went on air.
bool inWindow(uint64_t atMs, uint64_t nowMs) { return atMs > nowMs || nowMs - atMs < AirtimeBudget::kWindowMs; }
}  // namespace

uint64_t AirtimeBudget::usedMs(uint64_t nowMs) const {
    uint64_t used = 0;
    for (size_t i = 0; i < count_; i++)
        if (inWindow(log_[i].atMs, nowMs)) used += log_[i].ms;
    return used;
}

bool AirtimeBudget::allows(uint32_t ms, Kind kind, uint64_t nowMs) const {
    double share = kind == Kind::call ? 0.9 : kind == Kind::resend ? 0.7 : 0.5;
    // The small allowance absorbs rounding in the product, never a whole millisecond.
    uint64_t limit = uint64_t(std::floor(dutyCycle_ * kWindowMs * share + 1e-6));
    return usedMs(nowMs) + ms <= limit;
}

uint32_t AirtimeBudget::record(uint32_t ms, uint64_t nowMs) {
    size_t kept = 0;
    for (size_t i = 0; i < count_; i++)
        if (inWindow(log_[i].atMs, nowMs)) log_[kept++] = log_[i];
    count_ = kept;
    if (count_ == kCapacity) {
        // Folding the oldest into the next keeps it counted for longer, never shorter.
        log_[1].ms += log_[0].ms;
        std::memmove(&log_[0], &log_[1], (count_ - 1) * sizeof(Entry));
        count_--;
    }
    uint32_t id = nextId_++;
    log_[count_++] = Entry{nowMs, id, ms};
    return id;
}

void AirtimeBudget::cancel(uint32_t id) {
    for (size_t i = 0; i < count_; i++) {
        if (log_[i].id != id) continue;
        std::memmove(&log_[i], &log_[i + 1], (count_ - i - 1) * sizeof(Entry));
        count_--;
        return;
    }
}

}  // namespace helpandi
