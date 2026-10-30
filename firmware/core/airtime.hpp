// Keeps the box's own sending inside Ofcom IR 2030 at 868 MHz: time on air per packet, the
// licence-exempt sub-bands, the hourly duty-cycle budget and the transmit power cap. Follows
// Airtime.swift.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

namespace helpandi {

struct Band {
    const char* name;
    double lowMHz;
    double highMHz;
    double dutyCycle;
    double maxERPmW;
};

// The IR 2030 short-range-device bands MeshCore uses in the UK. A radio outside these has no
// allowance, so the box sends nothing on it.
extern const Band kBands[2];

struct RadioSettings {
    double frequencyMHz;
    double bandwidthKHz;
    int spreadingFactor;
    // The coding rate denominator, 5 to 8 for 4/5 to 4/8, as MeshCore reports it.
    int codingRate;
    int preambleSymbols;

    RadioSettings(double frequencyMHz, double bandwidthKHz, int spreadingFactor, int codingRate, int preambleSymbols)
        : frequencyMHz(frequencyMHz),
          bandwidthKHz(bandwidthKHz),
          spreadingFactor(spreadingFactor),
          codingRate(codingRate),
          preambleSymbols(preambleSymbols) {}
    // MeshCore sends a 32-symbol preamble at SF8 and below and 16 above
    // (RadioLibWrapper::preambleLengthForSF), as Airtime.swift assumes when none is given.
    RadioSettings(double frequencyMHz, double bandwidthKHz, int spreadingFactor, int codingRate)
        : RadioSettings(frequencyMHz, bandwidthKHz, spreadingFactor, codingRate, spreadingFactor <= 8 ? 32 : 16) {}

    // Seconds on air for one LoRa packet of `bytes` (Semtech AN1200.13), explicit header, CRC on.
    double airtime(int bytes) const;
    // Milliseconds on air, rounded up, for the budget.
    uint32_t airtimeMs(int bytes) const;
    const Band* band() const;
};

// Bytes on air for a MeshCore group datagram carrying `payload` bytes: header and path length,
// any path, the channel hash, a 2-byte MAC, then AES blocks of the data type, length and payload.
int meshPacketBytes(int payload, int pathBytes = 0);

// The highest SX1262 power setting (dBm) that keeps the box inside the band's ERP limit, given
// the antenna's gain (dBi) and the gain of the board's power amplifier after the SX1262 (dB).
// False when even the board's lowest setting would be over the limit: then the box must not send.
bool maxRadioPowerSetting(const Band& band, double antennaGainDBi, double amplifierGainDB, int boardMin, int boardMax,
                          int& setting);

class AirtimeBudget {
public:
    // A new press; a resend of a Help or Need a hand nobody has answered; anything else.
    enum class Kind : uint8_t { call, resend, optional };
    static constexpr uint64_t kWindowMs = 3600000;
    static constexpr size_t kCapacity = 128;

    explicit AirtimeBudget(double dutyCycle) : dutyCycle_(dutyCycle > 0 ? dutyCycle : 0) {}

    uint64_t usedMs(uint64_t nowMs) const;

    // Calls may use up to 90% of the legal allowance, leaving a margin for what MeshCore sends
    // itself (adverts, direct-message acknowledgements). Resends of unanswered calls may use up to
    // 70%, so routine traffic, which keeps half free for other people's calls (decision 12), never
    // leaves them none.
    bool allows(uint32_t ms, Kind kind, uint64_t nowMs) const;

    // Reserves airtime before sending, so overlapping sends cannot each see the same allowance.
    // Returns an id to give it back with if the radio refused the packet.
    uint32_t record(uint32_t ms, uint64_t nowMs);
    void cancel(uint32_t id);

private:
    struct Entry {
        uint32_t id;
        uint64_t atMs;
        uint32_t ms;
    };
    double dutyCycle_;
    Entry log_[kCapacity] = {};
    size_t count_ = 0;
    uint32_t nextId_ = 1;
};

}  // namespace helpandi
