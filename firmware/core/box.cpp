#include "box.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <type_traits>

namespace helpandi {

const char* statusWords(CallerStatus s) {
    switch (s) {
    case CallerStatus::sending: return "Sending...";
    case CallerStatus::waitingForResponder: return "Sent. Waiting for someone to see it.";
    case CallerStatus::seen: return "A responder has seen your call.";
    case CallerStatus::notSent: return "Not sent. Nobody may know you need help. If you need help now, call 999.";
    case CallerStatus::closed: return "Your call is closed.";
    }
    return "";
}

BatteryModel batteryModel(const BatteryDraw& draw) {
    double awakeShare = double(kAwakePerWakeMs) / (double(kSleepS) * 1000 + kAwakePerWakeMs);
    double averageUA = draw.asleepUA + (draw.awakeMA * 1000.0 - draw.asleepUA) * awakeShare;
    return BatteryModel{draw.capacityMAh, uint32_t(std::ceil(averageUA / 1000))};
}

namespace {
// The call schedule runs in whole seconds of the monotonic clock (call.hpp).
uint64_t seconds(uint64_t nowMs) { return nowMs / 1000; }

// FNV-1a, enough to tell a copy this build wrote from whatever a cold start leaves in RTC memory.
uint32_t checksum(const void* bytes, size_t length) {
    const uint8_t* p = static_cast<const uint8_t*>(bytes);
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < length; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
}  // namespace

BoxEngine::BoxEngine(BoxPort& port, const RadioSettings& radio, const BatteryModel& battery, uint16_t nextRequest)
    : port_(port),
      radio_(radio),
      budget_(radio.band() ? radio.band()->dutyCycle : 0),
      monitor_(battery) {
    setNextRequest(nextRequest);
}

void BoxEngine::provision(const GroupSettings& group, const MemberList& members) {
    group_ = group;
    members_ = members;
    provisioned_ = true;
    revokeAcks();
    canSeal_ = false;
    uint8_t shared[32];
    if (group_.hasRespondersKey() && port_.sharedSecret(shared, group_.respondersKey)) {
        respondersKey(shared, group_.groupID, kGroupIDBytes, sealKey_);
        canSeal_ = true;
    }
}

void BoxEngine::forget() {
    provisioned_ = false;
    canSeal_ = false;
    std::memset(&group_, 0, sizeof group_);
    members_.count = 0;
    callCount_ = 0;
    reportRequest_ = 0;
    for (ReportPart& p : parts_) p.repeating = false;
}

void BoxEngine::setRadio(const RadioSettings& radio) {
    radio_ = radio;
    budget_.setDutyCycle(radio_.band() ? radio_.band()->dutyCycle : 0);
}

void BoxEngine::coldStart(uint64_t nowMs) {
    const Band* band = radio_.band();
    if (band) budget_.record(uint32_t(band->dutyCycle * AirtimeBudget::kWindowMs * 0.5), nowMs);
}

BoxEngine::Retained BoxEngine::snapshot() const {
    Retained r{kRetainedLayout, 0, budget_, monitor_, {}, callCount_, reportRequest_, reportParts_, reportAcknowledged_};
    for (size_t i = 0; i < callCount_; i++) r.slots[i] = slots_[i];
    return r;
}

void BoxEngine::retain(uint8_t* out) const {
    static_assert(std::is_trivially_copyable<Retained>::value, "the copy is the struct's own bytes");
    Retained r = snapshot();
    r.sum = checksum(&r, sizeof r);
    std::memcpy(out, &r, sizeof r);
}

bool BoxEngine::resume(const uint8_t* in) {
    Retained r = snapshot();
    std::memcpy(&r, in, sizeof r);
    uint32_t sum = r.sum;
    r.sum = 0;
    if (r.version != kRetainedLayout || checksum(&r, sizeof r) != sum) return false;
    budget_ = r.budget;
    monitor_ = r.monitor;
    for (size_t i = 0; i < kMaxCalls; i++) slots_[i] = r.slots[i];
    callCount_ = r.callCount;
    reportRequest_ = r.reportRequest;
    reportParts_ = r.reportParts;
    reportAcknowledged_ = r.reportAcknowledged;
    return true;
}

bool BoxEngine::canSleep(bool phoneConnected) const {
    if (phoneConnected || monitor_.mains() != PowerMonitor::Mains::off) return false;
    for (size_t i = 0; i < callCount_; i++) {
        uint64_t at;
        if (slots_[i].repeating || slots_[i].call.nextResend(at)) return false;
    }
    for (const ReportPart& p : parts_)
        if (p.repeating) return false;
    return true;
}

bool BoxEngine::powerCap(double amplifierGainDB, int boardMin, int boardMax, int& setting) const {
    const Band* band = radio_.band();
    return band && maxRadioPowerSetting(*band, antennaGainDBi(group_.antenna), amplifierGainDB, boardMin, boardMax, setting);
}

void BoxEngine::sound(Sound s) {
    if (soundCount_ == kSounds) return;
    sounds_[(soundHead_ + soundCount_++) % kSounds] = s;
}

Sound BoxEngine::takeSound() {
    if (!soundCount_) return Sound::none;
    Sound s = sounds_[soundHead_];
    soundHead_ = (soundHead_ + 1) % kSounds;
    soundCount_--;
    return s;
}

bool BoxEngine::send(const uint8_t* payload, size_t length, AirtimeBudget::Kind kind, uint64_t nowMs, uint32_t wallNow) {
    if (!radio_.band()) return false;
    bool both = inChangeover(wallNow);
    uint32_t ms = port_.airtimeMs(length);
    if (!budget_.allows(both ? ms * 2 : ms, kind, nowMs)) return false;
    uint32_t id = budget_.record(ms, nowMs);
    bool took = port_.sendGroup(group_.channelSecret, payload, length);
    if (!took) budget_.cancel(id);
    if (both) {
        uint32_t old = budget_.record(ms, nowMs);
        if (port_.sendGroup(group_.oldChannelSecret, payload, length)) {
            took = true;
        } else {
            budget_.cancel(old);
        }
    }
    return took;
}

uint16_t BoxEngine::takeRequest() {
    uint16_t n = nextRequest_;
    nextRequest_ = n == kMaxRequest ? 1 : n + 1;
    port_.saveNextRequest(nextRequest_);
    return n;
}

BoxEngine::Slot& BoxEngine::newSlot() {
    if (callCount_ == kMaxCalls) {
        for (size_t i = 1; i < kMaxCalls; i++) slots_[i - 1] = slots_[i];
        callCount_--;
    }
    Slot& s = slots_[callCount_++];
    s = Slot();
    return s;
}

size_t BoxEngine::signFrame(const uint8_t* inner, size_t innerLength, uint8_t* out, size_t cap) {
    uint8_t input[kMaxSignedInner + 64];
    size_t n = signedSignatureInput(group_.member, inner, innerLength, group_.groupID, kGroupIDBytes, input, sizeof input);
    SignedFrame f;
    f.signer = group_.member;
    f.innerLength = uint8_t(innerLength);
    std::memcpy(f.inner, inner, innerLength);
    port_.sign(f.signature, input, n);
    return encode(f, out, cap);
}

void BoxEngine::revokeAcks() {
    for (size_t i = 0; i < callCount_; i++)
        slots_[i].call.revoke([&](uint16_t who) {
            const Member* m = members_.find(who);
            return m && canRespond(m->role);
        });
}

void BoxEngine::settleSlot(Slot& s, CallState state, uint64_t nowMs, uint32_t wallNow) {
    s.call.settle(state, group_.member, wallNow);
    CallStateFrame cs{s.call.unit, s.call.number, state, wallNow, 0, {}};
    uint8_t inner[16];
    size_t n = encode(cs, inner, sizeof inner);
    s.stateLength = signFrame(inner, n, s.state, sizeof s.state);
    send(s.state, s.stateLength, AirtimeBudget::Kind::optional, nowMs, wallNow);
    port_.toPhone(s.state, s.stateLength);
    // A close is repeated on its own; I'm OK goes with each resend of the call instead.
    s.repeating = closes(state);
    s.repeat = CloseRepeat(seconds(nowMs));
}

void BoxEngine::press(Colour colour, uint64_t nowMs, uint32_t wallNow, bool phoneConnected) {
    if (!provisioned_) {
        sound(Sound::notSent);
        return;
    }
    if (colour == Colour::green) {
        OutgoingCall calls[kMaxCalls];
        for (size_t i = 0; i < callCount_; i++) calls[i] = slots_[i].call;
        size_t settled[kMaxCalls];
        size_t n = settledByOK(calls, callCount_, group_.okClosesCall, seconds(nowMs), settled, kMaxCalls);
        CallState state = group_.okClosesCall ? CallState::closedByCaller : CallState::callerOK;
        for (size_t i = 0; i < n; i++) settleSlot(slots_[settled[i]], state, nowMs, wallNow);
    }
    Slot& s = newSlot();
    s.call = OutgoingCall(group_.unit, takeRequest(), colour, wallNow, seconds(nowMs));
    uint8_t frame[kCallBytes];
    encode(s.call.callFrame(), frame, sizeof frame);
    s.call.mesh = send(frame, sizeof frame, AirtimeBudget::Kind::call, nowMs, wallNow) ? RouteState::sent : RouteState::failed;
    s.call.phone = phoneConnected ? RouteState::sending : RouteState::failed;
    port_.toPhone(frame, sizeof frame);
    if (s.call.status() == CallerStatus::notSent) {
        sound(Sound::notSent);
    } else {
        sound(colour == Colour::green ? Sound::ok : Sound::press);
    }
}

void BoxEngine::tick(uint64_t nowMs, uint32_t wallNow) {
    for (size_t i = 0; i < callCount_; i++) {
        Slot& s = slots_[i];
        // A phone asked to carry the call and still silent at its first resend did not take it
        // (gone out of range, or an app that cannot answer yet): the cross, not "Sending..." for
        // ever.
        if (s.call.phone == RouteState::sending && seconds(nowMs) >= s.call.pressedMono + resend::kGaps[0])
            phoneRoute(s.call.number, false);
        if (s.call.resendDue(seconds(nowMs))) {
            uint8_t frame[kCallBytes];
            encode(s.call.callFrame(), frame, sizeof frame);
            bool took = send(frame, sizeof frame, s.call.resendKind(), nowMs, wallNow);
            if (took) s.call.mesh = RouteState::sent;
            s.call.markResent(seconds(nowMs));
            // While a call stands at I'm OK, the signed I'm OK goes with it (section 7).
            if (took && s.call.settled && !closes(s.call.settledState))
                send(s.state, s.stateLength, AirtimeBudget::Kind::optional, nowMs, wallNow);
        }
        bool finished;
        if (s.repeating && s.repeat.tick(seconds(nowMs), finished)) {
            send(s.state, s.stateLength, AirtimeBudget::Kind::optional, nowMs, wallNow);
            if (finished) s.repeating = false;
        }
    }
    for (ReportPart& p : parts_) {
        bool finished;
        if (!p.repeating || !p.repeat.tick(seconds(nowMs), finished)) continue;
        if (!reportAcknowledged_ || p.lastWarning) send(p.sealed, p.length, AirtimeBudget::Kind::optional, nowMs, wallNow);
        if (finished) p.repeating = false;
    }
}

void BoxEngine::phoneRoute(uint16_t request, bool sent) {
    for (size_t i = 0; i < callCount_; i++) {
        OutgoingCall& c = slots_[i].call;
        if (c.number != request) continue;
        bool wasSent = c.status() != CallerStatus::notSent;
        c.phone = sent ? RouteState::sent : RouteState::failed;
        if (wasSent && c.status() == CallerStatus::notSent) sound(Sound::notSent);
    }
}

void BoxEngine::onAck(const AckFrame& ack) {
    if (ack.unit != group_.unit) return;
    const Member* m = members_.find(ack.responder);
    if (!m || !canRespond(m->role)) return;
    uint8_t input[64];
    size_t n = ackSignatureInput(ack, group_.groupID, kGroupIDBytes, input, sizeof input);
    if (!port_.verify(m->signingKey, ack.signature, input, n)) return;
    if (ack.request == reportRequest_ && !reportAcknowledged_) {
        reportAcknowledged_ = true;
        monitor_.acknowledged();
        return;
    }
    for (size_t i = 0; i < callCount_; i++) {
        OutgoingCall& c = slots_[i].call;
        if (c.number != ack.request) continue;
        bool seen = c.status() == CallerStatus::seen;
        c.receive(ack);
        if (!seen && c.status() == CallerStatus::seen) sound(Sound::seen);
    }
}

void BoxEngine::onSigned(const SignedFrame& s) {
    const Member* signer = members_.find(s.signer);
    if (!signer) return;
    uint8_t input[kMaxSignedInner + 64];
    size_t n = signedSignatureInput(s.signer, s.inner, s.innerLength, group_.groupID, kGroupIDBytes, input, sizeof input);
    if (!port_.verify(signer->signingKey, s.signature, input, n)) return;
    Frame inner = decode(s.inner, s.innerLength);
    if (inner.kind == FrameKind::memberRemoved && s.signer == group_.firstCoordinator) {
        if (members_.remove(inner.memberRemoved.member, inner.memberRemoved.version)) revokeAcks();
        return;
    }
    // A coordinator closes with the caller's consent or a reason (decision 6); the caller's own
    // states come only from the caller's key, which is this box's.
    if (inner.kind == FrameKind::callState && signer->role == Role::coordinator && inner.callState.unit == group_.unit &&
        (inner.callState.state == CallState::closedWithConsent || inner.callState.state == CallState::closedWithReason)) {
        for (size_t i = 0; i < callCount_; i++) {
            OutgoingCall& c = slots_[i].call;
            if (c.number == inner.callState.request) c.settle(inner.callState.state, s.signer, inner.callState.at);
        }
    }
}

void BoxEngine::heard(const uint8_t* data, size_t length) {
    if (!provisioned_) return;
    Frame f = decode(data, length);
    if (f.kind == FrameKind::ack) onAck(f.ack);
    if (f.kind == FrameKind::signedFrame) onSigned(f.signedFrame);
}

void BoxEngine::addReportPart(const uint8_t* inner, size_t innerLength, bool lastWarning, uint64_t nowMs, uint32_t wallNow) {
    uint8_t signedFrame[kMaxSignedInner + 68];
    size_t n = signFrame(inner, innerLength, signedFrame, sizeof signedFrame);
    ReportPart* slot = nullptr;
    for (ReportPart& p : parts_)
        if (!p.repeating) {
            slot = &p;
            break;
        }
    if (!slot) slot = &parts_[0];
    uint8_t salt[kSealSaltBytes];
    port_.randomBytes(salt, sizeof salt);
    slot->length = sealForResponders(sealKey_, group_.groupID, kGroupIDBytes, group_.unit, reportRequest_, ++reportParts_, salt,
                                     signedFrame, n, slot->sealed, sizeof slot->sealed);
    slot->repeat = CloseRepeat(seconds(nowMs));
    slot->repeating = true;
    slot->lastWarning = lastWarning;
    send(slot->sealed, slot->length, AirtimeBudget::Kind::optional, nowMs, wallNow);
    port_.toPhone(slot->sealed, slot->length);
}

void BoxEngine::power(uint64_t nowMs, uint32_t wallNow, bool mainsPresent, uint16_t millivolts) {
    PowerMonitor::Event e = monitor_.update(nowMs, mainsPresent, millivolts);
    if (e.report == PowerMonitor::Report::none) return;
    if (!provisioned_ || !group_.reportPowerCut || !canSeal_) return;
    if (e.report == PowerMonitor::Report::mainsLost) {
        reportRequest_ = takeRequest();
        reportParts_ = 0;
        reportAcknowledged_ = false;
        FollowUpFrame f{group_.unit, reportRequest_, 1, Category::powerCut};
        uint8_t inner[kFollowUpBytes];
        size_t n = encode(f, inner, sizeof inner);
        addReportPart(inner, n, false, nowMs, wallNow);
        return;
    }
    if (!reportRequest_) return;
    NoteFrame note{group_.unit, reportRequest_, 0, 0, {}};
    if (e.report == PowerMonitor::Report::mainsBack) {
        std::strcpy(reinterpret_cast<char*>(note.text), "Power is back.");
    } else if (e.hours == 0) {
        std::strcpy(reinterpret_cast<char*>(note.text), "Less than an hour of battery left.");
    } else {
        std::snprintf(reinterpret_cast<char*>(note.text), sizeof note.text, "About %u hour%s of battery left.", unsigned(e.hours),
                      e.hours == 1 ? "" : "s");
    }
    note.length = uint8_t(std::strlen(reinterpret_cast<const char*>(note.text)));
    note.part = uint8_t(reportParts_ + 1);
    uint8_t inner[9 + kMaxNoteBytes];
    size_t n = encode(note, inner, sizeof inner);
    bool lastWarning = e.report == PowerMonitor::Report::hoursLeft && e.hours <= 1;
    addReportPart(inner, n, lastWarning, nowMs, wallNow);
    if (e.report == PowerMonitor::Report::mainsBack) reportRequest_ = 0;
}

Screen BoxEngine::screen() const {
    Screen s{provisioned_, callCount_ > 0, Colour::red, CallerStatus::notSent, monitor_.mains(), monitor_.hours()};
    if (callCount_) {
        const OutgoingCall& c = slots_[callCount_ - 1].call;
        s.colour = c.colour;
        s.status = c.status();
    }
    return s;
}

}  // namespace helpandi
