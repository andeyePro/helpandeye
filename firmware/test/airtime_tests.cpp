// Mirrors AirtimeTests and the airtime parts of ResendTests in the Swift package. Airtime figures
// other than Semtech's 41.216 ms were worked out from the same formula outside this code.
#include <cmath>

#include "../core/airtime.hpp"
#include "test.hpp"

using namespace helpandi;

namespace {
const RadioSettings ukNarrow{869.618, 62.5, 8, 8, 32};

bool near(double a, double b) { return std::fabs(a - b) < 1e-6; }
}  // namespace

TEST(airtimeMatchesSemtechsCalculator) {
    // SF7, 125 kHz, CR 4/5, 8-symbol preamble, 10 bytes: 41.216 ms in Semtech's calculator.
    RadioSettings r{868.1, 125, 7, 5, 8};
    CHECK(near(r.airtime(10), 0.041216));
    CHECK(r.airtimeMs(10) == 42);
    CHECK(ukNarrow.airtime(40) > ukNarrow.airtime(20));
}

TEST(airtimeCountsMeshCoresLongerPreambleAtLowSpreadingFactors) {
    RadioSettings swiftDefault{869.618, 62.5, 8, 8, 16};
    CHECK(near(swiftDefault.airtime(21), 0.31232));
    CHECK(near(ukNarrow.airtime(21), 0.377856));
}

TEST(airtimeUsesLowDataRateOptimisationWhenSymbolsAreLong) {
    RadioSettings sf12{869.5, 125, 12, 5, 16};
    CHECK(near(sf12.airtime(21), 1.744896));
}

TEST(onlyTheUKBandsHaveAnAllowance) {
    CHECK(ukNarrow.band() && ukNarrow.band()->dutyCycle == 0.10);
    RadioSettings low{868.1, 125, 7, 5, 32};
    CHECK(low.band() && low.band()->dutyCycle == 0.01);
    RadioSettings us{915, 125, 7, 5, 32};
    CHECK(us.band() == nullptr);
}

TEST(packetSizeIncludesMeshCoresLengthByte) {
    CHECK(meshPacketBytes(12) == 21);  // a call
    CHECK(meshPacketBytes(77) == 85);  // an acknowledgement
    CHECK(meshPacketBytes(13) == 21);
    CHECK(meshPacketBytes(14) == 37);  // Airtime.swift says 21 here: it leaves the length byte out
    CHECK(meshPacketBytes(12, 2) == 23);
}

TEST(optionalTrafficKeepsHalfTheAllowanceFree) {
    AirtimeBudget b(0.01);  // 36 s an hour; optional traffic may use 18 s
    b.record(17000, 0);
    CHECK(b.allows(1000, AirtimeBudget::Kind::optional, 0));
    CHECK(!b.allows(1500, AirtimeBudget::Kind::optional, 0));
    CHECK(b.allows(15000, AirtimeBudget::Kind::call, 0));  // calls may use up to 90%: 32.4 s
    CHECK(!b.allows(16000, AirtimeBudget::Kind::call, 0));
    CHECK(b.allows(18000, AirtimeBudget::Kind::optional, AirtimeBudget::kWindowMs));
}

TEST(resendsUseTheShareThatLeavesRoomForANewPress) {
    AirtimeBudget b(0.01);
    b.record(18000, 0);
    CHECK(!b.allows(500, AirtimeBudget::Kind::optional, 0));
    CHECK(b.allows(500, AirtimeBudget::Kind::call, 0));
}

TEST(reservationsCountAtOnceAndCanBeGivenBack) {
    AirtimeBudget b(0.01);
    uint32_t first = b.record(18000, 0);
    CHECK(!b.allows(1, AirtimeBudget::Kind::optional, 0));  // a send still in flight already counts
    b.cancel(first);
    CHECK(b.allows(18000, AirtimeBudget::Kind::optional, 0));
}

TEST(aFullLogStillCountsEverything) {
    AirtimeBudget b(0.10);
    uint32_t last = 0;
    for (uint64_t i = 0; i < 3 * AirtimeBudget::kCapacity; i++) last = b.record(10, i);
    uint64_t now = 3 * AirtimeBudget::kCapacity;
    CHECK(b.usedMs(now) == 30 * AirtimeBudget::kCapacity);
    b.cancel(last);
    CHECK(b.usedMs(now) == 30 * AirtimeBudget::kCapacity - 10);
    // The first entry, at 0 ms, was folded into a later one, so it is still counted an hour on.
    CHECK(b.usedMs(AirtimeBudget::kWindowMs) == 30 * AirtimeBudget::kCapacity - 10);
}

TEST(transmitPowerStaysInsideTheBandsERPLimit) {
    int s = 0;
    // 869.4-869.65 MHz, 500 mW ERP: 26.99 dBm + 2.15 - 3 dBi antenna - 12 dB amplifier = 14.1.
    CHECK(maxRadioPowerSetting(kBands[1], 3, 12, -9, 22, s) && s == 14);
    // 868.0-868.6 MHz, 25 mW ERP: 13.98 + 2.15 - 3 - 12 = 1.1.
    CHECK(maxRadioPowerSetting(kBands[0], 3, 12, -9, 22, s) && s == 1);
    // Never above the board's own limit.
    CHECK(maxRadioPowerSetting(kBands[1], 0, 0, -9, 22, s) && s == 22);
    // Too much gain for the board's lowest setting: do not send at all.
    CHECK(!maxRadioPowerSetting(kBands[0], 3, 25, -9, 22, s));
}
