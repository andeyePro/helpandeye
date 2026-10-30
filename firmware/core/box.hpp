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
    uint32_t hoursLeft;
};

// What the box shows for each state. No "delivered", and never that help is on its way
// (decision 7).
const char* statusWords(CallerStatus s);
constexpr const char* kNotSetUpWords = "Not set up yet. Add this box to a group in the Help&I app.";
constexpr const char* kSupplementWords = "Help&I does not replace 999 or telecare.";

class BoxEngine {
public:
    static constexpr size_t kMaxCalls = 8;
    // A power cut, the six hour marks and the power back.
    static constexpr size_t kMaxReportParts = 8;
    static constexpr uint16_t kMaxRequest = 32767;

    BoxEngine(BoxPort& port, const RadioSettings& radio, const BatteryModel& battery, uint16_t nextRequest);

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
    // The highest SX1262 setting the band allows with this box's antenna, or false when the box
    // must not send at all.
    bool powerCap(double amplifierGainDB, int boardMin, int boardMax, int& setting) const;

    // A button. `phoneConnected` says whether a phone can be asked to carry the call too.
    void press(Colour colour, uint64_t nowMs, uint32_t wallNow, bool phoneConnected);
    // Resends and repeats. Call it often.
    void tick(uint64_t nowMs, uint32_t wallNow);
    // A Help&I datagram heard on the group channel.
    void heard(const uint8_t* data, size_t length);
    // The phone says whether its own routes took the call.
    void phoneRoute(uint16_t request, bool sent);
    // The mains level and battery voltage, as often as the board reads them.
    void power(uint64_t nowMs, uint32_t wallNow, bool mainsPresent, uint16_t millivolts);

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
    struct Slot {
        OutgoingCall call;
        // The signed I'm OK or close, sent with each resend or repeated on its own.
        uint8_t state[96];
        size_t stateLength = 0;
        CloseRepeat repeat;
        bool repeating = false;
    };
    struct ReportPart {
        uint8_t sealed[kMaxPayload];
        size_t length = 0;
        CloseRepeat repeat;
        bool repeating = false;
        // The last battery warning goes even after an acknowledgement (decision 4).
        bool lastWarning = false;
    };

    bool send(const uint8_t* payload, size_t length, AirtimeBudget::Kind kind, uint64_t nowMs, uint32_t wallNow);
    uint16_t takeRequest();
    Slot& newSlot();
    void sound(Sound s);
    size_t signFrame(const uint8_t* inner, size_t innerLength, uint8_t* out, size_t cap);
    void settleSlot(Slot& s, CallState state, uint64_t nowMs, uint32_t wallNow);
    void onAck(const AckFrame& ack);
    void onSigned(const SignedFrame& s);
    void addReportPart(const uint8_t* inner, size_t innerLength, bool lastWarning, uint64_t nowMs, uint32_t wallNow);

    BoxPort& port_;
    RadioSettings radio_;
    AirtimeBudget budget_;
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
    uint8_t reportParts_ = 0;
    bool reportAcknowledged_ = false;
    ReportPart parts_[kMaxReportParts];

    static constexpr size_t kSounds = 4;
    Sound sounds_[kSounds] = {};
    size_t soundHead_ = 0, soundCount_ = 0;
};

}  // namespace helpandi
