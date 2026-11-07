#include "call.hpp"

namespace helpandi {

uint64_t resend::due(uint64_t n) {
    uint64_t early = 0;
    for (size_t i = 0; i < kGapCount && i < n; i++) early += kGaps[i];
    uint64_t later = n > kGapCount ? (n - kGapCount) * kSteady : 0;
    return early + later;
}

void OutgoingCall::receive(const AckFrame& ack) {
    if (ack.unit != unit || ack.request != number) return;
    for (size_t i = 0; i < ackCount; i++)
        if (acknowledgedBy[i] == ack.responder) return;
    // Past the first few, more names change nothing the box shows.
    if (ackCount < kMaxAcks) acknowledgedBy[ackCount++] = ack.responder;
}

void OutgoingCall::settle(CallState state, uint16_t by, uint32_t at) {
    if (settled && (closes(settledState) || !closes(state))) return;
    settled = true;
    settledState = state;
    settledBy = by;
    settledAt = at;
}

CallerStatus OutgoingCall::status() const {
    if (settled && closes(settledState)) return CallerStatus::closed;
    if (ackCount > 0) return CallerStatus::seen;
    if (mesh == RouteState::sent || phone == RouteState::sent) return CallerStatus::waitingForResponder;
    if (mesh == RouteState::sending || phone == RouteState::sending) return CallerStatus::sending;
    // Nothing attempted is nothing sent: the cross, not "Sending" for ever.
    return CallerStatus::notSent;
}

bool OutgoingCall::nextResend(uint64_t& at) const {
    CallerStatus s = status();
    if (s == CallerStatus::seen || s == CallerStatus::closed) return false;
    if (colour == Colour::green && resends >= resend::kGapCount) return false;
    at = pressedMono + resend::due(resends + 1);
    return true;
}

bool OutgoingCall::resendDue(uint64_t nowMono) const {
    uint64_t at;
    return nextResend(at) && nowMono >= at;
}

void OutgoingCall::markResent(uint64_t nowMono) {
    resends++;
    while (nowMono >= pressedMono + resend::due(resends + 1)) resends++;
}

size_t settledByOK(const OutgoingCall* calls, size_t count, bool okClosesCall, uint64_t okPressedMono, size_t* out,
                   size_t cap) {
    size_t n = 0;
    for (size_t i = 0; i < count && n < cap; i++) {
        const OutgoingCall& c = calls[i];
        if (!c.isUnsettled() || c.pressedMono >= okPressedMono) continue;
        if (!okClosesCall && (c.status() == CallerStatus::seen || c.settled)) continue;
        out[n++] = i;
    }
    return n;
}

bool CloseRepeat::tick(uint64_t nowMono, bool& finished) {
    finished = false;
    if (nowMono < atMono + resend::due(resends + 1)) return false;
    do resends++;
    while (nowMono >= atMono + resend::due(resends + 1));
    finished = resends >= resend::kGapCount;
    return true;
}

}  // namespace helpandi
