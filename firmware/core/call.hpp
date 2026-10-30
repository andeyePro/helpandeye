// A call as the box tracks it: when it goes out again, which acknowledgements count, and what
// the person at the box is shown. Follows Resend.swift and OutgoingRequest in Requests.swift.
//
// Two clocks. `pressedAt` and every frame time are wall-clock seconds, which the responders'
// phones compare against their own. The resend schedule runs on the board's monotonic clock in
// seconds, so a clock set from the phone mid-call never makes a resend early, late or skipped.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

#include "frame.hpp"

namespace helpandi {

// A call goes out again after 30 s, 1, 2 and 4 minutes, then every 10 minutes, and never stops on
// a timer: only a person ends resending.
namespace resend {
constexpr uint32_t kGaps[] = {30, 60, 120, 240};
constexpr size_t kGapCount = sizeof kGaps / sizeof kGaps[0];
constexpr uint32_t kSteady = 600;
// Seconds after the press that resend number `n` (1 for the first) is due.
uint64_t due(uint64_t n);
}  // namespace resend

// How far a responder's clock may be behind the caller's.
constexpr uint32_t kClockAllowance = 300;

enum class RouteState : uint8_t { untried, sending, sent, failed };

// There is deliberately no "delivered": a radio sending a packet is not a person reading it
// (decision 7). Only a responder's signed acknowledgement gives `seen`.
enum class CallerStatus : uint8_t { sending, waitingForResponder, seen, notSent, closed };

struct OutgoingCall {
    static constexpr size_t kMaxAcks = 8;

    uint32_t unit;
    uint16_t number;
    Colour colour;
    uint32_t pressedAt;
    uint64_t pressedMono;

    // The box's own radio, and whatever the paired phone reports for its routes.
    RouteState mesh = RouteState::untried;
    RouteState phone = RouteState::untried;
    uint32_t resends = 0;

    uint16_t acknowledgedBy[kMaxAcks] = {};
    size_t ackCount = 0;

    bool settled = false;
    CallState settledState = CallState::callerOK;
    uint16_t settledBy = 0;
    uint32_t settledAt = 0;

    OutgoingCall(uint32_t unit, uint16_t number, Colour colour, uint32_t pressedAt, uint64_t pressedMono)
        : unit(unit), number(number), colour(colour), pressedAt(pressedAt), pressedMono(pressedMono) {}

    CallFrame callFrame() const { return CallFrame{unit, number, colour, pressedAt}; }

    // Records an acknowledgement. Only one for this call, made after it was pressed, counts.
    // Check first that it carries a current responder's valid signature: this does not.
    void receive(const AckFrame& ack);

    // Takes back acknowledgements from people no longer able to respond.
    template <typename Keep>
    void revoke(Keep stillResponds) {
        size_t kept = 0;
        for (size_t i = 0; i < ackCount; i++)
            if (stillResponds(acknowledgedBy[i])) acknowledgedBy[kept++] = acknowledgedBy[i];
        ackCount = kept;
    }

    // A person settled the call. Only a settlement made after the press counts; a close is final,
    // and "I'm OK" never undoes one.
    void settle(CallState state, uint16_t by, uint32_t at);

    // A Help or Need a hand call nobody has closed, which I'm OK can settle.
    bool isUnsettled() const { return unit != 0 && colour != Colour::green && !(settled && closes(settledState)); }

    CallerStatus status() const;

    // Whether the call should go out again now. A call nobody could send is retried too, so a
    // radio that comes back still gets it out. "I'm OK" is repeated against lost packets, then left.
    bool resendDue(uint64_t nowMono) const;

    // When the next resend is due (monotonic seconds), or false when none will be.
    bool nextResend(uint64_t& at) const;

    // After a long sleep, missed slots are skipped rather than sent back to back.
    void markResent(uint64_t nowMono);
};

// The calls a press of I'm OK settles: every open Help or Need a hand when the caller's profile
// has I'm OK close them (A), or only those still waiting for a responder when it just stops the
// urgent repeats (B). Writes their indices to `out` and returns how many.
size_t settledByOK(const OutgoingCall* calls, size_t count, bool okClosesCall, size_t* out, size_t cap);

// A close this box sent, repeated on the call's resend times a few times, so a phone that missed
// it does not go on alerting.
struct CloseRepeat {
    uint64_t atMono;
    uint32_t resends = 0;

    explicit CloseRepeat(uint64_t atMono) : atMono(atMono) {}

    // True when the close should go out now. Sets `finished` when this is the last time.
    bool tick(uint64_t nowMono, bool& finished);
};

}  // namespace helpandi
