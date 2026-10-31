// The box: what a press does, when a call goes out again, which acknowledgements count, what the
// person is shown and told, I'm OK, the sealed power-cut report, and what the paired phone is
// given to carry on its own routes. Everything the board does for it (signing, verifying, the
// radio, the phone link, flash) comes through BoxPort, so the whole of this runs in the host
// tests against fakes.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

#include "airtime.hpp"
#include "call.hpp"
#include "frame.hpp"
#include "power.hpp"
#include "provision.hpp"
#include "seal.hpp"

namespace helpandi {

class BoxPort {
public:
    virtual ~BoxPort() {}
    // Ed25519 over exactly the bytes HelpFrame.swift signs.
    virtual bool verify(const uint8_t key[32], const uint8_t sig[64], const uint8_t* message, size_t length) = 0;
    virtual void sign(uint8_t sig[64], const uint8_t* message, size_t length) = 0;
    // X25519 between the box's key and the responders' public key.
    virtual bool sharedSecret(uint8_t out[32], const uint8_t theirs[32]) = 0;
    virtual void randomBytes(uint8_t* out, size_t length) = 0;
    // A Help&I datagram on the group channel with this secret. True if the radio took it.
    virtual bool sendGroup(const uint8_t secret[16], const uint8_t* payload, size_t length) = 0;
    // Time on air of the packet MeshCore would send for this payload.
    virtual uint32_t airtimeMs(size_t payloadLength) = 0;
    virtual void toPhone(const uint8_t* frame, size_t length) = 0;
    // Before the number is used, so a restart never reuses it.
    virtual void saveNextRequest(uint16_t next) = 0;
};

enum class Sound : uint8_t { none, press, seen, notSent, ok };

struct Screen {
    bool provisioned;
    bool hasCall;
    Colour colour;
    CallerStatus status;
    PowerMonitor::Mains mains;
    // The mains state is the battery's trend, not the wire (section 10): the screen says "?".
    bool mainsEstimated;
    uint32_t hoursLeft;
    // The antenna the coordinator set puts even the lowest setting over the band's limit: the box
    // sends nothing at all, and says why (section 8).
    bool antennaNotAllowed;
};

// What the box shows for each state. No "delivered", and never that help is on its way
// (decision 7).
const char* statusWords(CallerStatus s);
constexpr const char* kNotSetUpWords = "Not set up yet. Add this box to a group in the Help&I app.";
constexpr const char* kSupplementWords = "Help&I does not replace 999 or telecare.";
// A box whose antenna is not allowed (section 8): with no call, and in place of "Not sent" for one.
constexpr const char* kAntennaNotAllowedWords = "This box cannot send: its antenna is not allowed. Ask your coordinator.";
constexpr const char* kNotSentAntennaWords = "Not sent: this box's antenna is not allowed. If you need help now, call 999.";

// Bluetooth pairing, decided at every start (section 6). The phone pairs with the random code
// MeshCore shows on the screen. Without a working screen MeshCore falls back to its fixed code
// 123456, which anyone in range could use to set up or wipe the box, so such a box starts no
// Bluetooth at all; its buttons, buzzer, LED and radio need none.
enum class Pairing : uint8_t { off, shownCode };
Pairing pairingAtStart(bool screenWorks);

// The state LED (section 5): lit while a call is open, blinking each second when it could not be
// sent. With no call open, a box whose Bluetooth is off for want of a screen gives two short
// flashes every two seconds while it is awake, so whoever is setting it up can tell why no phone
// finds it.
bool ledLit(const Screen& s, Pairing pairing, bool awake, uint64_t nowMs);

// On battery with nothing to send again, the box deep-sleeps between battery readings, and each
// reading keeps it awake for about this long (MeshCore's start-up and one poll). Section 10.
constexpr uint32_t kSleepS = 600;
constexpr uint32_t kAwakePerWakeMs = 3000;

// The box's draw as measured for the build flags: awake, and in deep sleep.
struct BatteryDraw {
    uint32_t capacityMAh;
    uint32_t awakeMA;
    uint32_t asleepUA;
};

// The hours-left model for a box left on battery: the sleeping draw plus the share of each poll
// it is awake, rounded up to a whole milliamp so the estimate never flatters the battery. A call
// that keeps the box awake draws more for as long as it stands; the estimate is for the box
// once it is left alone again: BoxEngine counts the hours at `awakeMA` while one does.
// `mainsSensed` says whether the build has the mains wire.
BatteryModel batteryModel(const BatteryDraw& draw, bool mainsSensed);

// The board's transmitter (section 8): the gain of its amplifier after the SX1262, and the
// SX1262's lowest and highest settings.
struct Transmitter {
    double amplifierGainDB;
    int minSetting;
    int maxSetting;
};

// The monotonic clock at a start (section 9): carried on from the retained copy, plus, after a
// wake from deep sleep, the time asleep by the system clock read before anything in this start
// set it. MeshCore's start sets that clock to just after its newest contact, often earlier than
// the copy's, and a clock behind the copy's adds nothing rather than wrapping round.
uint64_t resumedMonoMs(uint64_t retainedMonoMs, int64_t retainedWallUs, int64_t wallUsAtStart, bool slept);

// The most a signed time may raise the box's clock in one step on one member's word (section 9).
constexpr uint32_t kMaxClockStep = 86400;

class BoxEngine {
public:
    static constexpr size_t kMaxCalls = 8;
    // A power cut, the six hour marks and the power back.
    static constexpr size_t kMaxReportParts = 8;
    static constexpr uint16_t kMaxRequest = 32767;

private:
    struct Slot {
        OutgoingCall call;
        // The signed I'm OK or close, sent with each resend or repeated on its own.
        uint8_t state[96];
        size_t stateLength = 0;
        CloseRepeat repeat;
        bool repeating = false;
    };
    // What survives a reset or deep sleep in the board's RTC memory (section 10), with the clocks
    // it was taken at.
    struct Retained {
        uint32_t version;
        uint32_t sum;
        uint32_t sequence;
        uint64_t monoMs;
        int64_t wallUs;
        AirtimeBudget budget;
        PowerMonitor monitor;
        Slot slots[kMaxCalls];
        size_t callCount;
        uint16_t reportRequest;
        uint32_t reportAt;
        uint8_t reportParts;
        bool reportAcknowledged;
    };
    // The layout's size and a number to raise whenever one of the types above changes without
    // changing the size, so a copy another build wrote is never read as this one's.
    static constexpr uint32_t kRetainedLayout = uint32_t(sizeof(Retained)) << 8 | 3;

public:
    // Two copies, written in turn.
    static constexpr size_t kRetainedBytes = 2 * sizeof(Retained);

    BoxEngine(BoxPort& port, const RadioSettings& radio, const Transmitter& transmitter, const BatteryModel& battery,
              uint16_t nextRequest);

    void provision(const GroupSettings& group, const MemberList& members);
    void forget();
    bool provisioned() const { return provisioned_; }
    const GroupSettings& group() const { return group_; }
    const MemberList& members() const { return members_; }

    // The radio's settings changed: the band, so the budget, may have.
    void setRadio(const RadioSettings& radio);
    // After a cold start, with no record of the hour before, the optional half of the hour's
    // airtime counts as used (section 8).
    void coldStart(uint64_t nowMs);
    // The copy that survives a reset or deep sleep: the hour's airtime, the mains and battery
    // state, the calls and the open report, and the board's clocks as it was taken. `retain`
    // writes it over the older of two copies in kRetainedBytes, with a checksum and a sequence
    // number, so a reset in the middle of a write leaves the other copy whole. `resume` takes
    // back the newest whole copy, and is false when neither is one this build wrote (a cold
    // start, with nothing or something else in the memory). What the copy cannot say stays as
    // this start has it: the band's limit and this build's battery.
    void retain(uint8_t* out, uint64_t monoMs, int64_t wallUs);
    bool resume(const uint8_t* in, uint64_t& monoMs, int64_t& wallUs);
    // Whether the box may deep-sleep now (section 10): on battery, with nothing to send again
    // (a call's resends, a close's or a report's repeats) and no phone using it as its radio.
    // A sleeping box hears nothing, which is why nothing may be waiting for an answer.
    bool canSleep(bool phoneConnected) const;
    // The highest SX1262 setting the band allows with this box's antenna, or false when the box
    // must not send at all: then it sends nothing of its own, and shows the cross.
    bool powerCap(int& setting) const;
    // In a UK band, but the antenna puts even the lowest setting over its limit: the board then
    // lets nothing go on air, MeshCore's own packets included (section 8).
    bool antennaNotAllowed() const;

    // A button. `phoneConnected` says whether a phone can be asked to carry the call too.
    void press(Colour colour, uint64_t nowMs, uint32_t wallNow, bool phoneConnected);
    // Resends and repeats. Call it often.
    void tick(uint64_t nowMs, uint32_t wallNow);
    // A Help&I datagram heard on the group channel. Returns a wall-clock time later than
    // `wallNow` that a current member signed (an acknowledgement, a signed call state), for the
    // board to raise its clock to, or 0 (section 9). A time more than kMaxClockStep ahead counts
    // only once a second member's agrees with it to within kMaxClockStep.
    uint32_t heard(const uint8_t* data, size_t length, uint32_t wallNow);
    // The phone says whether its own routes took the call.
    void phoneRoute(uint16_t request, bool sent);
    // The mains level and battery voltage, as often as the board reads them. `phoneConnected`
    // says whether a phone is keeping the box awake.
    void power(uint64_t nowMs, uint32_t wallNow, bool mainsPresent, uint16_t millivolts, bool phoneConnected);

    Screen screen() const;
    Sound takeSound();
    uint16_t nextRequest() const { return nextRequest_; }
    // The number saved in flash, once the board has read it.
    void setNextRequest(uint16_t next) { nextRequest_ = next >= 1 && next <= kMaxRequest ? next : 1; }
    size_t callCount() const { return callCount_; }
    const OutgoingCall& call(size_t i) const { return slots_[i].call; }
    uint16_t reportRequest() const { return reportRequest_; }
    bool reportAcknowledged() const { return reportAcknowledged_; }
    // Whether the box sends on the old channel too, during a changeover.
    bool inChangeover(uint32_t wallNow) const { return group_.hasOldSecret() && wallNow < group_.oldSecretEndsAt; }

private:
    struct ReportPart {
        uint8_t sealed[kMaxPayload];
        size_t length = 0;
        CloseRepeat repeat;
        bool repeating = false;
        // The last battery warning goes even after an acknowledgement (decision 4).
        bool lastWarning = false;
    };

    bool send(const uint8_t* payload, size_t length, AirtimeBudget::Kind kind, uint64_t nowMs, uint32_t wallNow);
    // A phone, or a call still being sent again, keeps the box awake whatever the mains.
    bool keptAwake(bool phoneConnected) const;
    void addNote(const char* text, bool lastWarning, uint64_t nowMs, uint32_t wallNow);
    Retained snapshot() const;
    uint16_t takeRequest();
    Slot& newSlot();
    void sound(Sound s);
    size_t signFrame(const uint8_t* inner, size_t innerLength, uint8_t* out, size_t cap);
    void settleSlot(Slot& s, CallState state, uint64_t nowMs, uint32_t wallNow);
    // Takes back acknowledgements from anyone no longer a member who can respond.
    void revokeAcks();
    uint32_t onAck(const AckFrame& ack, uint32_t wallNow);
    uint32_t onSigned(const SignedFrame& s, uint32_t wallNow);
    void addReportPart(const uint8_t* inner, size_t innerLength, bool lastWarning, uint64_t nowMs, uint32_t wallNow);
    uint32_t raiseClock(uint32_t at, uint16_t member, uint32_t wallNow);

    BoxPort& port_;
    RadioSettings radio_;
    Transmitter transmitter_;
    AirtimeBudget budget_;
    BatteryModel battery_;
    PowerMonitor monitor_;
    GroupSettings group_{};
    MemberList members_;
    bool provisioned_ = false;
    uint8_t sealKey_[kSealKeyBytes] = {};
    bool canSeal_ = false;
    uint16_t nextRequest_;

    Slot slots_[kMaxCalls];
    size_t callCount_ = 0;

    uint16_t reportRequest_ = 0;
    // When the power cut was reported, by the box's clock: an acknowledgement must not be older.
    uint32_t reportAt_ = 0;
    uint8_t reportParts_ = 0;
    bool reportAcknowledged_ = false;
    ReportPart parts_[kMaxReportParts];

    uint32_t retainedSequence_ = 0;
    // A time too far ahead to take on one member's word, and whose it was.
    uint32_t farAt_ = 0;
    uint16_t farMember_ = 0;

    static constexpr size_t kSounds = 4;
    Sound sounds_[kSounds] = {};
    size_t soundHead_ = 0, soundCount_ = 0;
};

}  // namespace helpandi
