// The whole box against a fake board: real Ed25519 and X25519 from TweetNaCl, a radio that
// records what it sent, a phone link that records what it was given.
#include <cstring>
#include <vector>

#include "../core/box.hpp"
#include "test.hpp"

extern "C" {
#include "tweetnacl.h"
}

using namespace helpandi;

namespace {

struct Sent {
    uint8_t secret[16];
    std::vector<uint8_t> payload;
};

// A phone: an Ed25519 key for signing and, for the responders as a whole, an X25519 pair.
struct Phone {
    uint8_t pk[32], sk[64];
    Phone() { crypto_sign_keypair(pk, sk); }
    void sign(uint8_t sig[64], const uint8_t* m, size_t n) const {
        std::vector<uint8_t> sm(n + 64);
        unsigned long long len;
        crypto_sign(sm.data(), &len, m, n, sk);
        std::memcpy(sig, sm.data(), 64);
    }
};

bool verifies(const uint8_t pk[32], const uint8_t sig[64], const uint8_t* m, size_t n) {
    std::vector<uint8_t> sm(n + 64), out(n + 64);
    std::memcpy(sm.data(), sig, 64);
    std::memcpy(sm.data() + 64, m, n);
    unsigned long long len;
    return crypto_sign_open(out.data(), &len, sm.data(), sm.size(), pk) == 0;
}

// The board: MeshCore's identity is an Ed25519 key whose private half is SHA-512 of a seed,
// clamped; the first 32 bytes of that are an X25519 scalar, which gives the box its seal key
// without a second key (section 6).
class FakePort : public BoxPort {
public:
    uint8_t pk[32], sk[64], scalar[32], x25519Public[32];
    std::vector<Sent> sent;
    std::vector<std::vector<uint8_t>> phone;
    uint16_t savedNext = 0;
    bool radioWorks = true;
    uint32_t airtime = 400;

    FakePort() {
        crypto_sign_keypair(pk, sk);
        uint8_t h[64];
        crypto_hash(h, sk, 32);
        std::memcpy(scalar, h, 32);
        scalar[0] &= 248;
        scalar[31] &= 127;
        scalar[31] |= 64;
        crypto_scalarmult_base(x25519Public, scalar);
    }
    bool verify(const uint8_t key[32], const uint8_t sig[64], const uint8_t* m, size_t n) override {
        return verifies(key, sig, m, n);
    }
    void sign(uint8_t sig[64], const uint8_t* m, size_t n) override {
        std::vector<uint8_t> sm(n + 64);
        unsigned long long len;
        crypto_sign(sm.data(), &len, m, n, sk);
        std::memcpy(sig, sm.data(), 64);
    }
    bool sharedSecret(uint8_t out[32], const uint8_t theirs[32]) override {
        crypto_scalarmult(out, scalar, theirs);
        return true;
    }
    void randomBytes(uint8_t* out, size_t n) override {
        for (size_t i = 0; i < n; i++) out[i] = uint8_t(0xA0 + i);
    }
    bool sendGroup(const uint8_t secret[16], const uint8_t* payload, size_t n) override {
        if (!radioWorks) return false;
        Sent s;
        std::memcpy(s.secret, secret, 16);
        s.payload.assign(payload, payload + n);
        sent.push_back(s);
        return true;
    }
    uint32_t airtimeMs(size_t) override { return airtime; }
    void toPhone(const uint8_t* frame, size_t n) override { phone.emplace_back(frame, frame + n); }
    void saveNextRequest(uint16_t next) override { savedNext = next; }
};

const RadioSettings kUK(869.618, 62.5, 8, 5);
const BatteryModel kCell{3000, 100};
// The V4: about 12 dB of amplifier after the SX1262's -9 to 22 dBm.
const Transmitter kV4{12.0, -9, 22};

struct World {
    FakePort port;
    Phone coordinator, responder, caller;
    uint8_t respondersPrivate[32], respondersPublic[32];
    GroupSettings group{};
    MemberList members;
    BoxEngine box;

    explicit World(bool okCloses = true, bool reportPowerCut = true, const BatteryModel& battery = kCell)
        : box(port, kUK, kV4, battery, 1) {
        for (int i = 0; i < 32; i++) respondersPrivate[i] = uint8_t(0x30 + i);
        respondersPrivate[0] &= 248;
        respondersPrivate[31] &= 127;
        respondersPrivate[31] |= 64;
        crypto_scalarmult_base(respondersPublic, respondersPrivate);
        for (int i = 0; i < 16; i++) group.groupID[i] = uint8_t(i);
        group.member = 4;
        group.unit = 70004;
        group.okClosesCall = okCloses;
        group.reportPowerCut = reportPowerCut;
        group.antenna = Antenna::whip;
        std::memcpy(group.respondersKey, respondersPublic, 32);
        for (int i = 0; i < 16; i++) group.channelSecret[i] = uint8_t(0x50 + i);
        group.firstCoordinator = 1;
        members.version = 1;
        members.count = 4;
        members.members[0] = Member{1, Role::coordinator, {}};
        std::memcpy(members.members[0].signingKey, coordinator.pk, 32);
        members.members[1] = Member{2, Role::responder, {}};
        std::memcpy(members.members[1].signingKey, responder.pk, 32);
        members.members[2] = Member{3, Role::caller, {}};
        std::memcpy(members.members[2].signingKey, caller.pk, 32);
        members.members[3] = Member{4, Role::caller, {}};
        std::memcpy(members.members[3].signingKey, port.pk, 32);
        box.provision(group, members);
    }

    std::vector<uint8_t> ack(const Phone& who, uint16_t member, uint16_t request, uint32_t at, const uint8_t* gid = nullptr) {
        return ackFor(group.unit, who, member, request, at, gid);
    }

    std::vector<uint8_t> ackFor(uint32_t unit, const Phone& who, uint16_t member, uint16_t request, uint32_t at,
                                const uint8_t* gid = nullptr) {
        AckFrame a{unit, request, member, at, {}};
        uint8_t input[64];
        size_t n = ackSignatureInput(a, gid ? gid : group.groupID, 16, input, sizeof input);
        who.sign(a.signature, input, n);
        std::vector<uint8_t> out(kAckBytes);
        encode(a, out.data(), out.size());
        return out;
    }

    std::vector<uint8_t> signedBy(const Phone& who, uint16_t member, const uint8_t* inner, size_t n) {
        SignedFrame s{member, uint8_t(n), {}, {}};
        std::memcpy(s.inner, inner, n);
        uint8_t input[160];
        size_t m = signedSignatureInput(member, inner, n, group.groupID, 16, input, sizeof input);
        who.sign(s.signature, input, m);
        std::vector<uint8_t> out(4 + n + 64);
        encode(s, out.data(), out.size());
        return out;
    }

    // What a responder's phone does with a sealed report: opens it with the responders' key and
    // the box's X25519 public key, checks the signature inside, and returns the inner frame.
    Frame open(const std::vector<uint8_t>& sealed) {
        Frame none;
        none.kind = FrameKind::none;
        if (sealed.size() < 1 + kSealOverhead || sealed[0] != 0x10) return none;
        uint8_t shared[32], key[32];
        crypto_scalarmult(shared, respondersPrivate, port.x25519Public);
        respondersKey(shared, group.groupID, 16, key);
        uint32_t unit = uint32_t(sealed[1]) | uint32_t(sealed[2]) << 8 | uint32_t(sealed[3]) << 16 | uint32_t(sealed[4]) << 24;
        uint16_t request = uint16_t(sealed[5] | sealed[6] << 8);
        uint8_t part = sealed[7];
        uint8_t nonce[12];
        respondersNonce(unit, request, part, &sealed[8], nonce);
        size_t n = sealed.size() - 1 - kSealOverhead;
        std::vector<uint8_t> plain(n), again(n);
        uint8_t block[64], tag[16];
        for (size_t i = 0; i < n; i++) {
            if (i % 64 == 0) chacha20Block(key, uint32_t(i / 64) + 1, nonce, block);
            plain[i] = sealed[13 + i] ^ block[i % 64];
        }
        chacha20Poly1305Seal(key, nonce, group.groupID, 16, plain.data(), n, again.data(), tag);
        if (std::memcmp(tag, &sealed[13 + n], 16) != 0) return none;
        Frame s = decode(plain.data(), n);
        if (s.kind != FrameKind::signedFrame || s.signedFrame.signer != group.member) return none;
        uint8_t input[160];
        size_t m = signedSignatureInput(s.signedFrame.signer, s.signedFrame.inner, s.signedFrame.innerLength, group.groupID, 16,
                                        input, sizeof input);
        if (!verifies(port.pk, s.signedFrame.signature, input, m)) return none;
        Frame inner = decode(s.signedFrame.inner, s.signedFrame.innerLength);
        uint32_t iu = 0;
        uint16_t ir = 0;
        uint8_t ip = 0;
        if (inner.kind == FrameKind::followUp) iu = inner.followUp.unit, ir = inner.followUp.request, ip = inner.followUp.part;
        if (inner.kind == FrameKind::note) iu = inner.note.unit, ir = inner.note.request, ip = inner.note.part;
        if (iu != unit || ir != request || ip != part) return none;
        return inner;
    }
};

bool resumeFrom(BoxEngine& box, const uint8_t* rtc) {
    uint64_t monoMs;
    int64_t wallUs;
    return box.resume(rtc, monoMs, wallUs);
}

const uint8_t kFirstRed[] = {0x11, 0x74, 0x11, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00};

}  // namespace

TEST(nothingGoesOutBeforeTheBoxIsProvisioned) {
    FakePort port;
    BoxEngine box(port, kUK, kV4, kCell, 1);
    box.press(Colour::red, 1000, 1000, false);
    CHECK(port.sent.empty() && port.phone.empty());
    CHECK(box.takeSound() == Sound::notSent);
    CHECK(!box.screen().provisioned && !box.screen().hasCall);
}

TEST(aRedPressSendsTheCallFrameAtOnceAndTellsThePhone) {
    World w;
    w.box.press(Colour::red, 5000, 0, true);
    CHECK(w.port.sent.size() == 1);
    CHECK(w.port.sent[0].payload.size() == 12);
    CHECK(std::memcmp(w.port.sent[0].payload.data(), kFirstRed, 12) == 0);
    CHECK(std::memcmp(w.port.sent[0].secret, w.group.channelSecret, 16) == 0);
    CHECK(w.port.phone.size() == 1 && w.port.phone[0] == w.port.sent[0].payload);
    CHECK(w.port.savedNext == 2 && w.box.nextRequest() == 2);
    CHECK(w.box.takeSound() == Sound::press);
    Screen s = w.box.screen();
    CHECK(s.hasCall && s.colour == Colour::red && s.status == CallerStatus::waitingForResponder);
    CHECK(std::strcmp(statusWords(s.status), "Sent. Waiting for someone to see it.") == 0);
}

TEST(resendsFollowTheScheduleAndASecondPressIsANewCall) {
    World w;
    w.box.press(Colour::red, 0, 100, false);
    w.box.tick(29000, 129);
    CHECK(w.port.sent.size() == 1);
    w.box.tick(30000, 130);
    CHECK(w.port.sent.size() == 2 && w.port.sent[1].payload == w.port.sent[0].payload);
    w.box.tick(90000, 190);
    w.box.tick(210000, 310);
    w.box.tick(450000, 550);
    w.box.tick(1050000, 1150);
    CHECK(w.port.sent.size() == 6);
    w.box.press(Colour::red, 1060000, 1160, false);
    CHECK(w.port.sent.size() == 7 && w.port.sent[6].payload[5] == 2);
    CHECK(w.box.callCount() == 2);
    w.box.tick(3700000, 3800);
    CHECK(w.port.sent.size() == 9);
}

TEST(onlyACurrentRespondersValidAcknowledgementCounts) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    auto bad = w.ack(w.caller, 3, 1, 1001);
    w.box.heard(bad.data(), bad.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    uint8_t otherGroup[16] = {9, 9, 9};
    auto wrongGroup = w.ack(w.responder, 2, 1, 1001, otherGroup);
    w.box.heard(wrongGroup.data(), wrongGroup.size(), 0);
    auto forged = w.ack(w.caller, 2, 1, 1001);
    w.box.heard(forged.data(), forged.size(), 0);
    auto unknown = w.ack(w.responder, 7, 1, 1001);
    w.box.heard(unknown.data(), unknown.size(), 0);
    auto otherCall = w.ack(w.responder, 2, 2, 1001);
    w.box.heard(otherCall.data(), otherCall.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    CHECK(w.box.takeSound() == Sound::press && w.box.takeSound() == Sound::none);
    auto good = w.ack(w.responder, 2, 1, 1001);
    w.box.heard(good.data(), good.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::seen);
    CHECK(w.box.takeSound() == Sound::seen);
    CHECK(std::strcmp(statusWords(CallerStatus::seen), "A responder has seen your call.") == 0);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.size() == 1);
    auto coordinatorsToo = w.ack(w.coordinator, 1, 1, 1002);
    w.box.heard(coordinatorsToo.data(), coordinatorsToo.size(), 0);
    CHECK(w.box.takeSound() == Sound::none);
}

TEST(aRemovalSignedByTheFirstCoordinatorTakesBackTheAcknowledgement) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    auto good = w.ack(w.responder, 2, 1, 1001);
    w.box.heard(good.data(), good.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::seen);
    uint8_t removed[8];
    size_t n = encode(MemberRemovedFrame{2, 2}, removed, sizeof removed);
    auto byResponder = w.signedBy(w.responder, 2, removed, n);
    w.box.heard(byResponder.data(), byResponder.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::seen);
    auto stale = w.signedBy(w.coordinator, 1, removed, n);
    w.members.version = 2;
    w.box.provision(w.group, w.members);
    w.box.press(Colour::red, 1000, 1001, false);
    auto second = w.ack(w.responder, 2, 2, 1002);
    w.box.heard(second.data(), second.size(), 0);
    w.box.heard(stale.data(), stale.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::seen);
    size_t m = encode(MemberRemovedFrame{2, 3}, removed, sizeof removed);
    auto real = w.signedBy(w.coordinator, 1, removed, m);
    w.box.heard(real.data(), real.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    CHECK(w.box.members().find(2) == nullptr);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.back().payload[0] == 0x11);
}

TEST(aNewMemberListFromThePhoneTakesBackADroppedRespondersAcknowledgement) {
    // The phone sends the list again after every change (0x72): a responder no longer on it, or
    // now a caller, must not go on reassuring the person at the box.
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    auto good = w.ack(w.responder, 2, 1, 1001);
    w.box.heard(good.data(), good.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::seen);
    w.members.members[1].role = Role::caller;
    w.members.version = 2;
    w.box.provision(w.group, w.members);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.size() == 2);
}

TEST(imOKClosesTheCallWhereTheProfileSaysAndSendsASignedCloseThatRepeats) {
    World w(true);
    w.box.press(Colour::red, 0, 1000, false);
    w.box.press(Colour::green, 5000, 1005, false);
    CHECK(w.box.takeSound() == Sound::press && w.box.takeSound() == Sound::ok);
    CHECK(w.port.sent.size() == 3);
    const std::vector<uint8_t>& state = w.port.sent[1].payload;
    CHECK(state[0] == 0x1A && state[1] == 4 && state[2] == 0 && state[3] == 13);
    const uint8_t closed[13] = {0x22, 0x74, 0x11, 0x01, 0x00, 0x01, 0x00, 0x02, 0xED, 0x03, 0x00, 0x00, 0x00};
    CHECK(std::memcmp(&state[4], closed, 13) == 0);
    uint8_t input[160];
    size_t n = signedSignatureInput(4, closed, 13, w.group.groupID, 16, input, sizeof input);
    CHECK(verifies(w.port.pk, &state[17], input, n));
    CHECK(w.port.sent[2].payload[7] == 3);  // the green call itself
    CHECK(w.port.phone.size() == 3 && w.port.phone[1] == state);
    CHECK(w.box.call(0).status() == CallerStatus::closed);
    CHECK(w.box.screen().colour == Colour::green);
    w.box.tick(35000, 1035);
    CHECK(w.port.sent.size() == 5);  // the close repeated, and the green resent
    w.box.tick(95000, 1095);
    w.box.tick(215000, 1215);
    w.box.tick(455000, 1455);
    CHECK(w.port.sent.size() == 11);  // four repeats of each
    w.box.tick(1055000, 2055);
    w.box.tick(4000000, 5000);
    CHECK(w.port.sent.size() == 11);  // then nothing: the red is closed, the green was left
}

TEST(imOKThatOnlyStopsTheRepeatsGoesWithEachResend) {
    World w(false);
    w.box.press(Colour::amber, 0, 1000, false);
    w.box.press(Colour::green, 5000, 1005, false);
    CHECK(w.port.sent.size() == 3);
    CHECK(w.port.sent[1].payload[4 + 7] == 1);  // callerOK
    CHECK(w.box.call(0).status() == CallerStatus::waitingForResponder);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.size() == 5);  // the amber again, with the I'm OK
    CHECK(w.port.sent[3].payload[7] == 2 && w.port.sent[4].payload[0] == 0x1A);
    w.box.tick(35000, 1035);
    CHECK(w.port.sent.size() == 6);  // the green's own resend
    auto good = w.ack(w.responder, 2, 1, 1040);
    w.box.heard(good.data(), good.size(), 0);
    w.box.tick(95000, 1095);
    CHECK(w.port.sent.size() == 7);  // the green only; the amber is seen
}

TEST(imOKNeverGoesForACallMadeAtTheSameMoment) {
    World w(true);
    w.box.press(Colour::red, 1000, 1001, false);
    w.box.press(Colour::green, 1000, 1001, false);
    CHECK(w.box.call(0).status() == CallerStatus::waitingForResponder);
}

TEST(theCrossWhenNeitherTheRadioNorAPhoneTookIt) {
    World w;
    w.port.radioWorks = false;
    w.box.press(Colour::red, 0, 1000, false);
    CHECK(w.box.screen().status == CallerStatus::notSent);
    CHECK(w.box.takeSound() == Sound::notSent);
    CHECK(std::strcmp(statusWords(CallerStatus::notSent),
                      "Not sent. Nobody may know you need help. If you need help now, call 999.") == 0);
    w.port.radioWorks = true;
    w.box.tick(30000, 1030);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    w.port.radioWorks = false;
    w.box.press(Colour::red, 40000, 1040, true);
    CHECK(w.box.screen().status == CallerStatus::sending);
    w.box.phoneRoute(2, false);
    CHECK(w.box.screen().status == CallerStatus::notSent);
    CHECK(w.box.takeSound() == Sound::press && w.box.takeSound() == Sound::notSent);
    w.box.press(Colour::red, 50000, 1050, true);
    w.box.phoneRoute(3, true);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
}

TEST(aPhoneThatNeverAnswersIsNotSendingForEver) {
    // The phone was connected when red was pressed, then went out of range (or its app cannot
    // answer 0x74 yet) and the radio refused the packet: by the first resend the box must show
    // the cross, not "Sending...".
    World w;
    w.port.radioWorks = false;
    w.box.press(Colour::red, 0, 1000, true);
    CHECK(w.box.screen().status == CallerStatus::sending);
    CHECK(w.box.takeSound() == Sound::press);
    w.box.tick(29000, 1029);
    CHECK(w.box.screen().status == CallerStatus::sending && w.box.takeSound() == Sound::none);
    w.box.tick(30000, 1030);
    CHECK(w.box.screen().status == CallerStatus::notSent);
    CHECK(w.box.takeSound() == Sound::notSent);
    // A late answer from the phone still counts, and the radio coming back is retried as before.
    w.box.phoneRoute(1, true);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
}

TEST(nothingIsSentOutsideTheUKBandsAndAColdStartKeepsRoomForCalls) {
    World w(false);
    w.box.setRadio(RadioSettings(915.0, 250, 10, 5));
    w.box.press(Colour::red, 0, 1000, false);
    CHECK(w.port.sent.empty() && w.box.screen().status == CallerStatus::notSent);
    w.box.setRadio(kUK);
    // The 10% band allows 360 s an hour. After a cold start half counts as used, so at 400 ms a
    // packet the optional share (50%) is full, while calls (90%) and resends (70%) still go.
    w.box.coldStart(1000);
    w.box.press(Colour::amber, 2000, 1002, false);
    CHECK(w.port.sent.size() == 1);
    w.box.tick(32000, 1032);
    CHECK(w.port.sent.size() == 3);  // the red that never went, and the amber, resent
    w.box.press(Colour::green, 40000, 1040, false);
    CHECK(w.port.sent.size() == 4);  // the green call went; the two signed I'm OKs could not
    w.box.tick(70000, 1070);
    CHECK(w.port.sent.size() == 4);  // the green's resend is optional too
    w.box.tick(3700000, 4700);
    CHECK(w.port.sent.size() > 4);  // an hour on, the room is back
}

TEST(airtimeUsedInOneBandStillCountsInTheOther) {
    // A frequency change from the app or the console must not hand the box a fresh hour: what
    // went on air in the 10% band still counts against the 1% band's 36 s (32.4 s for calls).
    World w;
    w.port.airtime = 30000;
    w.box.press(Colour::red, 0, 1000, false);
    w.box.press(Colour::red, 1000, 1001, false);
    CHECK(w.port.sent.size() == 2);
    w.box.setRadio(RadioSettings(868.3, 62.5, 8, 5));
    w.box.press(Colour::red, 2000, 1002, false);
    CHECK(w.port.sent.size() == 2 && w.box.screen().status == CallerStatus::notSent);
    w.box.setRadio(kUK);
    w.box.setRadio(RadioSettings(868.3, 62.5, 8, 5));
    w.box.press(Colour::red, 3000, 1003, false);
    CHECK(w.port.sent.size() == 2);
    w.box.setRadio(kUK);
    w.box.tick(3700000, 4700);
    CHECK(w.port.sent.size() == 6);  // an hour on, the four calls go out again
}

TEST(thePowerCapFollowsTheBandAndTheAntenna) {
    World w;
    int setting = 0;
    CHECK(w.box.powerCap(setting) && setting == 15);
    w.box.setRadio(RadioSettings(868.3, 62.5, 8, 5));
    CHECK(w.box.powerCap(setting) && setting == 2);
    w.group.antenna = Antenna::external5dBi;
    w.box.provision(w.group, w.members);
    CHECK(w.box.powerCap(setting) && setting == -1);
    FakePort port;
    BoxEngine noLowerThanZero(port, RadioSettings(868.3, 62.5, 8, 5), Transmitter{12.0, 0, 22}, kCell, 1);
    noLowerThanZero.provision(w.group, w.members);
    CHECK(!noLowerThanZero.powerCap(setting));
    w.box.setRadio(RadioSettings(915.0, 250, 10, 5));
    CHECK(!w.box.powerCap(setting));
}

// The same table as the app's HelpBoxTests.testTheBoxAndTheAppAgreeOnTheCapForAnyGain: gain in
// dBi, then the cap at 869.4-869.65 MHz and at 868.0-868.6 MHz, -128 where the box must not send.
TEST(thePowerCapFollowsAnyAntennaGain) {
    const struct { double gain; int ten, one; } rows[] = {
        {0, 17, 4}, {2, 15, 2}, {3, 14, 1}, {5, 12, -1}, {7.5, 9, -4}, {8, 9, -4},
        {12, 5, -8}, {13, 4, -9}, {14, 3, -128}, {26, -9, -128}, {26.5, -128, -128}, {63.5, -128, -128},
    };
    for (const auto& r : rows) {
        World w;
        w.group.antenna = Antenna(kAntennaByGain | uint8_t(r.gain * 2));
        w.box.provision(w.group, w.members);
        int setting = -128;
        CHECK(w.box.powerCap(setting) ? setting == r.ten : r.ten == -128);
        w.box.setRadio(RadioSettings(868.3, 62.5, 8, 5));
        setting = -128;
        CHECK(w.box.powerCap(setting) ? setting == r.one : r.one == -128);
    }
}

TEST(aBoxThatMustNotSendSendsNothingAndShowsTheCross) {
    // At 27 dBi even the lowest setting is over 500 mW ERP (section 8): nothing of the box's own
    // goes on air, however much airtime is free, and the person sees the cross.
    World w;
    w.group.antenna = Antenna(kAntennaByGain | 54);
    w.box.provision(w.group, w.members);
    int setting;
    CHECK(!w.box.powerCap(setting));
    w.box.press(Colour::red, 0, 1000, false);
    CHECK(w.port.sent.empty());
    CHECK(w.box.screen().status == CallerStatus::notSent && w.box.takeSound() == Sound::notSent);
    w.box.tick(30000, 1030);
    w.box.press(Colour::green, 40000, 1040, false);
    w.box.tick(70000, 1070);
    CHECK(w.port.sent.empty());
    // Its phone can still carry a call.
    w.box.press(Colour::amber, 80000, 1080, true);
    w.box.phoneRoute(w.box.call(w.box.callCount() - 1).number, true);
    CHECK(w.port.sent.empty() && w.box.screen().status == CallerStatus::waitingForResponder);
}

TEST(aBoxWhoseAntennaIsNotAllowedSaysSoAndLetsNothingOnAir) {
    // The board stops MeshCore's own packets too when this is true (UITask::applyRadio), so a
    // phone's traffic through the box never goes out over the limit either.
    World w;
    CHECK(!w.box.antennaNotAllowed() && !w.box.screen().antennaNotAllowed);
    w.group.antenna = Antenna(kAntennaByGain | 54);
    w.box.provision(w.group, w.members);
    CHECK(w.box.antennaNotAllowed() && w.box.screen().antennaNotAllowed);
    // 14 dBi is allowed in the 10% band and not in the 1% band.
    w.group.antenna = Antenna(kAntennaByGain | 28);
    w.box.provision(w.group, w.members);
    CHECK(!w.box.antennaNotAllowed());
    w.box.setRadio(RadioSettings(868.3, 62.5, 8, 5));
    CHECK(w.box.antennaNotAllowed());
    // Outside the UK bands the antenna is not what stops the box (section 8).
    w.box.setRadio(RadioSettings(915.0, 250, 10, 5));
    CHECK(!w.box.antennaNotAllowed());
    CHECK(std::strstr(kAntennaNotAllowedWords, "antenna is not allowed"));
    CHECK(std::strstr(kNotSentAntennaWords, "antenna is not allowed") && std::strstr(kNotSentAntennaWords, "call 999"));
}

TEST(aPowerCutIsSealedForRespondersAndTheHoursFollow) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    w.box.power(0, 1000, true, 4200, false);
    w.box.power(10000, 1010, true, 4200, false);
    w.box.power(20000, 1020, false, 4200, false);
    w.box.power(30000, 1030, false, 4200, false);
    CHECK(w.port.sent.size() == 2);
    CHECK(w.box.reportRequest() == 2 && w.port.savedNext == 3);
    const std::vector<uint8_t>& sealed = w.port.sent[1].payload;
    CHECK(sealed[0] == 0x10 && sealed[5] == 2 && sealed[7] == 1);
    CHECK(sealed.size() == 1 + kSealOverhead + 4 + 9 + 64);
    CHECK(sealed.size() <= kMaxPayload);
    Frame inner = w.open(sealed);
    CHECK(inner.kind == FrameKind::followUp && inner.followUp.category == Category::powerCut);
    CHECK(inner.followUp.unit == 70004 && inner.followUp.request == 2 && inner.followUp.part == 1);
    CHECK(w.port.phone.size() == 2 && w.port.phone[1] == sealed);
    Screen s = w.box.screen();
    CHECK(s.mains == PowerMonitor::Mains::off && s.hoursLeft == 0);

    w.box.power(31000, 1031, false, 4000, false);
    CHECK(w.port.sent.size() == 3);
    Frame note = w.open(w.port.sent[2].payload);
    CHECK(note.kind == FrameKind::note && note.note.part == 2);
    CHECK(note.note.length == 31 && std::memcmp(note.note.text, "About 24 hours of battery left.", 31) == 0);
    CHECK(w.port.sent[2].payload.size() <= kMaxPayload);
    CHECK(w.box.screen().hoursLeft == 24);

    // Repeated on the resend times until a responder acknowledges the report.
    w.box.tick(60000, 1060);
    CHECK(w.port.sent.size() == 5);  // both parts
    auto seen = w.ack(w.responder, 2, 2, 1061);
    w.box.heard(seen.data(), seen.size(), 0);
    CHECK(w.box.reportAcknowledged());
    w.box.tick(90000, 1090);
    CHECK(w.port.sent.size() == 6);  // the red's resend only
    w.box.power(91000, 1091, false, 3700, false);  // 9 hours: quiet now
    CHECK(w.port.sent.size() == 6);
    w.box.power(92000, 1092, false, 3450, false);  // under an hour: the final warning still goes
    CHECK(w.port.sent.size() == 7);
    Frame last = w.open(w.port.sent[6].payload);
    CHECK(last.kind == FrameKind::note && last.note.part == 3);
    CHECK(std::memcmp(last.note.text, "Less than an hour of battery left.", last.note.length) == 0);
    w.box.tick(122000, 1122);
    CHECK(w.port.sent.size() == 8 && w.port.sent[7].payload == w.port.sent[6].payload);

    w.box.power(130000, 1130, true, 3450, false);
    w.box.power(140000, 1140, true, 3450, false);
    Frame back = w.open(w.port.sent.back().payload);
    CHECK(back.kind == FrameKind::note && back.note.part == 4);
    CHECK(std::memcmp(back.note.text, "Power is back.", 14) == 0);
    CHECK(w.box.screen().mains == PowerMonitor::Mains::on);
}

TEST(aReportsAcknowledgementIsNoOlderThanTheCut) {
    World w;
    w.box.power(0, 2000, true, 4200, false);
    w.box.power(10000, 2010, true, 4200, false);
    w.box.power(20000, 2020, false, 4200, false);
    w.box.power(30000, 2030, false, 4200, false);
    CHECK(w.box.reportRequest() == 1 && w.port.sent.size() == 1);
    uint8_t rtc[BoxEngine::kRetainedBytes] = {};
    w.box.retain(rtc, 0, 0);
    // An acknowledgement of an earlier request 1, made long before this cut, is not for it.
    auto old = w.ack(w.responder, 2, 1, 1600);
    w.box.heard(old.data(), old.size(), 2040);
    CHECK(!w.box.reportAcknowledged());
    auto fresh = w.ack(w.responder, 2, 1, 2025);
    w.box.heard(fresh.data(), fresh.size(), 2040);
    CHECK(w.box.reportAcknowledged());
    // The cut's time survives a reset with the report.
    World after;
    CHECK(resumeFrom(after.box, rtc));
    old = after.ack(after.responder, 2, 1, 1600);
    after.box.heard(old.data(), old.size(), 2040);
    CHECK(!after.box.reportAcknowledged());
    fresh = after.ack(after.responder, 2, 1, 2025);
    after.box.heard(fresh.data(), fresh.size(), 2040);
    CHECK(after.box.reportAcknowledged());
}

TEST(theClockIsRaisedOnlyFromTimesACurrentMemberSigned) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    // Unsigned traffic carries no weight, however late its time.
    CallFrame call{70009, 5, Colour::red, 5000};
    uint8_t frame[kCallBytes];
    encode(call, frame, sizeof frame);
    CHECK(w.box.heard(frame, sizeof frame, 1000) == 0);
    auto forged = w.ackFor(70009, w.caller, 2, 5, 5000);
    CHECK(w.box.heard(forged.data(), forged.size(), 1000) == 0);
    auto stranger = w.ackFor(70009, w.responder, 7, 5, 5000);
    CHECK(w.box.heard(stranger.data(), stranger.size(), 1000) == 0);
    uint8_t otherGroup[16] = {9, 9, 9};
    auto elsewhere = w.ackFor(70009, w.responder, 2, 5, 5000, otherGroup);
    CHECK(w.box.heard(elsewhere.data(), elsewhere.size(), 1000) == 0);
    // A responder's acknowledgement of another unit's call: its time, only if it is later.
    auto other = w.ackFor(70009, w.responder, 2, 5, 5000);
    CHECK(w.box.heard(other.data(), other.size(), 1000) == 5000);
    CHECK(w.box.heard(other.data(), other.size(), 5000) == 0);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    // An acknowledgement of this box's call counts as before, and never lowers the clock.
    auto mine = w.ack(w.responder, 2, 1, 900);
    CHECK(w.box.heard(mine.data(), mine.size(), 1000) == 0);
    CHECK(w.box.screen().status == CallerStatus::seen);
    // A signed call state, from any current member.
    CallStateFrame ok{70009, 5, CallState::callerOK, 6000, 0, {}};
    uint8_t inner[16];
    size_t n = encode(ok, inner, sizeof inner);
    auto byCaller = w.signedBy(w.caller, 3, inner, n);
    CHECK(w.box.heard(byCaller.data(), byCaller.size(), 5000) == 6000);
    auto misnamed = w.signedBy(w.caller, 2, inner, n);
    CHECK(w.box.heard(misnamed.data(), misnamed.size(), 5000) == 0);
}

TEST(aTimeMoreThanADayAheadNeedsASecondMemberToAgree) {
    // A phone whose clock is set days ahead moves the box's clock only if another member's phone
    // says much the same; within a day, one member's word is enough, as before (section 9).
    World w;
    const uint32_t now = 1000000, day = kMaxClockStep;
    auto near = w.ackFor(70009, w.responder, 2, 5, now + day);
    CHECK(w.box.heard(near.data(), near.size(), now) == now + day);
    auto far = w.ackFor(70009, w.responder, 2, 5, now + 3 * day);
    CHECK(w.box.heard(far.data(), far.size(), now) == 0);
    auto again = w.ackFor(70009, w.responder, 2, 6, now + 3 * day + 60);
    CHECK(w.box.heard(again.data(), again.size(), now) == 0);
    // Another member a week ahead does not agree with three days.
    CallStateFrame week{70009, 7, CallState::callerOK, now + 7 * day, 0, {}};
    uint8_t inner[16];
    size_t n = encode(week, inner, sizeof inner);
    auto byCaller = w.signedBy(w.caller, 3, inner, n);
    CHECK(w.box.heard(byCaller.data(), byCaller.size(), now) == 0);
    // The coordinator's phone agrees with the caller's to within the day: the earlier of the two.
    CallStateFrame close{70009, 7, CallState::callerOK, now + 7 * day + 600, 0, {}};
    n = encode(close, inner, sizeof inner);
    auto byCoordinator = w.signedBy(w.coordinator, 1, inner, n);
    CHECK(w.box.heard(byCoordinator.data(), byCoordinator.size(), now) == now + 7 * day);
}

TEST(aPowerCutIsNotReportedWithoutOptInOrARespondersKey) {
    World quiet(true, false);
    quiet.box.power(0, 1000, false, 4200, false);
    quiet.box.power(10000, 1010, false, 4200, false);
    CHECK(quiet.port.sent.empty());
    CHECK(quiet.box.screen().mains == PowerMonitor::Mains::off);
    World noKey;
    std::memset(noKey.group.respondersKey, 0, 32);
    noKey.box.provision(noKey.group, noKey.members);
    noKey.box.power(0, 1000, false, 4200, false);
    noKey.box.power(10000, 1010, false, 4200, false);
    CHECK(noKey.port.sent.empty());
}

TEST(aCoordinatorsSignedCloseClosesTheCall) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    CallStateFrame close{70004, 1, CallState::closedWithReason, 1100, 0, {}};
    uint8_t inner[16];
    size_t n = encode(close, inner, sizeof inner);
    auto byResponder = w.signedBy(w.responder, 2, inner, n);
    w.box.heard(byResponder.data(), byResponder.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    auto byCoordinator = w.signedBy(w.coordinator, 1, inner, n);
    w.box.heard(byCoordinator.data(), byCoordinator.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::closed);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.size() == 1);
}

TEST(aCoordinatorCannotSpeakForTheCaller) {
    // Engine.swift takes callerOK and closedByCaller only from the member whose unit it is, and a
    // coordinator's close only with consent or a reason.
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    uint8_t inner[16];
    CallStateFrame byCaller{70004, 1, CallState::closedByCaller, 1100, 0, {}};
    size_t n = encode(byCaller, inner, sizeof inner);
    auto fake = w.signedBy(w.coordinator, 1, inner, n);
    w.box.heard(fake.data(), fake.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder && !w.box.call(0).settled);
    CallStateFrame ok{70004, 1, CallState::callerOK, 1100, 0, {}};
    n = encode(ok, inner, sizeof inner);
    auto fakeOK = w.signedBy(w.coordinator, 1, inner, n);
    w.box.heard(fakeOK.data(), fakeOK.size(), 0);
    CHECK(!w.box.call(0).settled);
    CallStateFrame consent{70004, 1, CallState::closedWithConsent, 1100, 0, {}};
    n = encode(consent, inner, sizeof inner);
    auto real = w.signedBy(w.coordinator, 1, inner, n);
    w.box.heard(real.data(), real.size(), 0);
    CHECK(w.box.screen().status == CallerStatus::closed && w.box.call(0).settledBy == 1);
}

TEST(duringAChangeoverEveryFrameGoesOnBothChannels) {
    World w;
    for (int i = 0; i < 16; i++) w.group.oldChannelSecret[i] = uint8_t(0x60 + i);
    w.group.oldSecretEndsAt = 2000;
    w.box.provision(w.group, w.members);
    CHECK(w.box.inChangeover(1999) && !w.box.inChangeover(2000));
    w.box.press(Colour::red, 0, 1000, false);
    CHECK(w.port.sent.size() == 2);
    CHECK(std::memcmp(w.port.sent[0].secret, w.group.channelSecret, 16) == 0);
    CHECK(std::memcmp(w.port.sent[1].secret, w.group.oldChannelSecret, 16) == 0);
    w.box.tick(30000, 2000);
    CHECK(w.port.sent.size() == 3);
}

TEST(requestNumbersWrapBefore32768AndAreSavedBeforeUse) {
    FakePort port;
    BoxEngine box(port, kUK, kV4, kCell, 32767);
    World w;
    box.provision(w.group, w.members);
    box.press(Colour::red, 0, 1000, false);
    CHECK(port.sent[0].payload[5] == 0xFF && port.sent[0].payload[6] == 0x7F);
    CHECK(port.savedNext == 1);
    BoxEngine fresh(port, kUK, kV4, kCell, 0);
    CHECK(fresh.nextRequest() == 1);
    fresh.setNextRequest(40000);
    CHECK(fresh.nextRequest() == 1);
    fresh.setNextRequest(500);
    CHECK(fresh.nextRequest() == 500);
}

TEST(theOldestCallMakesRoomForTheNinth) {
    World w;
    for (int i = 0; i < 9; i++) w.box.press(Colour::amber, uint64_t(i) * 1000, 1000 + i, false);
    CHECK(w.box.callCount() == 8);
    CHECK(w.box.call(0).number == 2 && w.box.call(7).number == 9);
}

TEST(forgettingTheGroupStopsEverything) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    w.box.forget();
    CHECK(!w.box.provisioned());
    w.box.tick(30000, 1030);
    w.box.press(Colour::red, 31000, 1031, false);
    CHECK(w.port.sent.size() == 1);
    CHECK(w.box.takeSound() == Sound::press && w.box.takeSound() == Sound::notSent);
}

TEST(theHoursAirtimeAndThePowerCutSurviveAResetThroughRTCMemory) {
    World w(false);
    w.box.coldStart(1000);
    w.box.press(Colour::amber, 2000, 1002, false);
    w.box.power(2000, 1002, false, 4200, false);
    w.box.power(12000, 1012, false, 4200, false);
    CHECK(w.port.sent.size() == 1 && w.port.phone.size() == 2);  // the power-cut report reached only the phone
    uint8_t rtc[BoxEngine::kRetainedBytes] = {};
    w.box.retain(rtc, 0, 0);

    World after(false);
    CHECK(resumeFrom(after.box, rtc));
    // The same call, still waiting.
    CHECK(after.box.callCount() == 1 && after.box.call(0).number == 1);
    CHECK(after.box.screen().status == CallerStatus::waitingForResponder);
    // The same power cut: no second report, and the next note carries on the part numbers. The
    // hour's record came too, half of it counted as used at the cold start, so the optional
    // share is still full and the note reaches only the phone.
    CHECK(after.box.screen().mains == PowerMonitor::Mains::off);
    CHECK(after.box.reportRequest() == w.box.reportRequest());
    after.box.power(14000, 1014, false, 4200, false);
    CHECK(after.port.phone.empty());
    after.box.power(15000, 1015, false, 4000, false);
    CHECK(after.port.sent.empty() && after.port.phone.size() == 1 && after.port.phone[0][7] == 2);
    CHECK(after.open(after.port.phone[0]).kind == FrameKind::note);
    after.box.press(Colour::green, 16000, 1016, false);
    CHECK(after.port.sent.size() == 1);  // the call went; the signed I'm OK could not
    // An hour on, the record has cleared.
    after.box.tick(3700000, 4700);
    CHECK(after.port.sent.size() > 1);

    // Anything else in the memory is a cold start.
    World cold(false);
    uint8_t broken[BoxEngine::kRetainedBytes];
    std::memcpy(broken, rtc, sizeof broken);
    broken[sizeof broken / 2] ^= 1;
    CHECK(!resumeFrom(cold.box, broken));
    std::memset(broken, 0, sizeof broken);
    CHECK(!resumeFrom(cold.box, broken));
    CHECK(cold.box.callCount() == 0 && cold.box.screen().mains == PowerMonitor::Mains::unknown);
}

TEST(aResetInTheMiddleOfAWriteResumesFromTheOtherCopy) {
    World w(false);
    uint8_t rtc[BoxEngine::kRetainedBytes] = {};
    w.box.press(Colour::amber, 1000, 1001, false);
    w.box.retain(rtc, 1000, 1001000000);
    w.box.press(Colour::red, 2000, 1002, false);
    w.box.retain(rtc, 2000, 1002000000);
    uint8_t whole[sizeof rtc];
    std::memcpy(whole, rtc, sizeof rtc);
    // The next write, cut off a third of the way through the copy it was overwriting.
    w.box.press(Colour::red, 3000, 1003, false);
    w.box.retain(rtc, 3000, 1003000000);
    const size_t half = sizeof rtc / 2;
    size_t written = std::memcmp(rtc, whole, half) != 0 ? 0 : half, resumedFrom = half - written;
    uint8_t torn[sizeof rtc];
    std::memcpy(torn, whole, sizeof torn);
    std::memcpy(torn + written, rtc + written, half / 3);

    World after(false);
    uint64_t monoMs = 0;
    int64_t wallUs = 0;
    CHECK(after.box.resume(torn, monoMs, wallUs));
    // The copy before: both calls open, and the clocks it was taken at.
    CHECK(after.box.callCount() == 2 && after.box.call(1).colour == Colour::red);
    CHECK(monoMs == 2000 && wallUs == 1002000000);
    // The next write goes over the torn copy, never the one just resumed from.
    uint8_t kept[sizeof rtc];
    std::memcpy(kept, torn, sizeof kept);
    after.box.retain(torn, 4000, 1004000000);
    CHECK(std::memcmp(torn + resumedFrom, kept + resumedFrom, half) == 0);
    World later(false);
    CHECK(later.box.resume(torn, monoMs, wallUs) && monoMs == 4000);

    // With both copies whole, the newest.
    World whole3(false);
    CHECK(whole3.box.resume(rtc, monoMs, wallUs) && whole3.box.callCount() == 3 && monoMs == 3000);
}

TEST(aResetKeepsTheBandItStartsInNotTheOneInTheCopy) {
    // The copy was taken in the 10% band and the box starts again in the 1% band, as when the
    // radio's settings changed in the second before a reset. The 60 s already sent this hour is
    // over the 1% band's 32.4 s for calls, so nothing more goes.
    World w;
    w.port.airtime = 30000;
    w.box.press(Colour::red, 0, 1000, false);
    w.box.press(Colour::red, 1000, 1001, false);
    CHECK(w.port.sent.size() == 2);
    uint8_t rtc[BoxEngine::kRetainedBytes] = {};
    w.box.retain(rtc, 0, 0);
    World after;
    after.port.airtime = 30000;
    after.box.setRadio(RadioSettings(868.3, 62.5, 8, 5));
    CHECK(resumeFrom(after.box, rtc));
    after.box.press(Colour::red, 2000, 1002, false);
    CHECK(after.port.sent.empty() && after.box.screen().status == CallerStatus::notSent);
}

TEST(aCopyFromAnotherBuildRunsOnThisBuildsBattery) {
    // A build with the mains wire and a 3000 mAh cell left the copy; this one has no wire and a
    // 6000 mAh cell. The power cut carries on, counted and worded as this build's.
    World w;
    w.box.power(0, 1000, false, 4200, false);
    w.box.power(10000, 1010, false, 4200, false);
    uint8_t rtc[BoxEngine::kRetainedBytes] = {};
    w.box.retain(rtc, 0, 0);
    World after(true, true, BatteryModel{6000, 100, false});
    CHECK(resumeFrom(after.box, rtc));
    CHECK(after.box.screen().mains == Mains::off && after.box.screen().mainsEstimated);
    after.box.power(11000, 1011, false, 4200, false);
    CHECK(after.box.screen().hoursLeft == 60);
}

TEST(theClockCarriesOnThroughSleepAndNeverWraps) {
    // Ten minutes asleep by the system clock.
    CHECK(resumedMonoMs(5000000, 1000000000, 1600000000, true) == 5600000);
    // A plain reset: the copy is at most a second old, and the clock carries on from it.
    CHECK(resumedMonoMs(5000000, 1000000000, 1600000000, false) == 5000000);
    // A system clock behind the copy's (set back before it was read) adds nothing: never a wrap
    // round to thousands of years on, which would empty the hour's airtime record.
    CHECK(resumedMonoMs(5000000, 1000000000, 400000000, true) == 5000000);
}

TEST(theBoxSleepsOnlyOnBatteryWithNothingToSendAgainAndNoPhone) {
    World w;
    CHECK(!w.box.canSleep(false));  // mains not yet known
    w.box.power(0, 1000, true, 4200, false);
    w.box.power(10000, 1010, true, 4200, false);
    CHECK(!w.box.canSleep(false));  // on mains it never sleeps
    w.box.power(20000, 1020, false, 4200, false);
    CHECK(!w.box.canSleep(false));  // a flicker is not a power cut yet
    w.box.power(30000, 1030, false, 4200, false);
    CHECK(!w.box.canSleep(false));  // the power-cut report is being repeated
    for (uint64_t t = 60000; t <= 500000; t += 30000) w.box.tick(t, 1000 + t / 1000);
    CHECK(w.box.canSleep(false));  // its four repeats are done
    CHECK(!w.box.canSleep(true));  // a phone is using the box as its radio

    w.box.press(Colour::red, 510000, 1510, false);
    CHECK(!w.box.canSleep(false));  // an open call is resent until a person settles it
    auto seen = w.ack(w.responder, 2, 2, 1511);  // request 1 was the power-cut report
    w.box.heard(seen.data(), seen.size(), 0);
    CHECK(w.box.canSleep(false));

    w.box.press(Colour::green, 520000, 1520, false);
    CHECK(!w.box.canSleep(false));  // the I'm OK call's own repeats, and the close's
    for (uint64_t t = 550000; t <= 1100000; t += 30000) w.box.tick(t, 1000 + t / 1000);
    CHECK(w.box.canSleep(false));

    w.box.power(1110000, 2110, true, 4200, false);
    w.box.power(1120000, 2120, true, 4200, false);
    CHECK(!w.box.canSleep(false));

    FakePort port;
    BoxEngine bare(port, kUK, kV4, kCell, 1);
    bare.power(0, 1000, false, 4200, false);
    bare.power(10000, 1010, false, 4200, false);
    CHECK(bare.canSleep(false));  // a box not yet set up has nothing to stay awake for
}

TEST(theHoursLeftAssumeTheBoxSleepsBetweenPolls) {
    // Awake 100 mA, asleep 0.5 mA, awake about 3 s in every 600: just under 1 mA, so 3000 hours.
    BatteryModel sleeping = batteryModel(BatteryDraw{3000, 100, 500}, true);
    CHECK(sleeping.capacityMAh == 3000 && sleeping.drawMA == 1);
    CHECK(hoursLeft(4200, sleeping) == 3000);
    // Rounded up to the next milliamp, never down: 1.99 mA counts as 2.
    CHECK(batteryModel(BatteryDraw{3000, 100, 1500}, true).drawMA == 2);
    // A box that never sleeps is the 30 hours the power tests assume.
    CHECK(hoursLeft(4200, batteryModel(BatteryDraw{3000, 100, 100000}, true)) == 30);
}

TEST(withoutTheWireTheReportAndTheScreenSayProbably) {
    World w(true, true, BatteryModel{3000, 100, false});
    // An hour held at full by the charger, then the cell falling as it does when the mains goes.
    uint64_t minute = 0;
    for (; minute < 60; minute++) w.box.power(minute * 60000, uint32_t(1000 + minute * 60), true, uint16_t(minute % 2 ? 4196 : 4184), false);
    CHECK(w.box.screen().mains == Mains::on && w.box.screen().mainsEstimated);
    CHECK(w.port.sent.empty());
    for (int i = 0; i < 30 && w.port.sent.empty(); i++, minute++)
        w.box.power(minute * 60000, uint32_t(1000 + minute * 60), true, uint16_t(4160 - i), false);
    CHECK(w.port.sent.size() == 2);
    CHECK(w.open(w.port.sent[0].payload).kind == FrameKind::followUp);
    Frame note = w.open(w.port.sent[1].payload);
    const char kProbably[] = "Power probably cut: the battery is falling.";
    CHECK(note.kind == FrameKind::note && note.note.part == 2);
    CHECK(note.note.length == sizeof kProbably - 1 && std::memcmp(note.note.text, kProbably, sizeof kProbably - 1) == 0);
    CHECK(w.port.sent[1].payload.size() <= kMaxPayload);
    Screen s = w.box.screen();
    CHECK(s.mains == Mains::off && s.mainsEstimated);
    // The charger lifts the cell: "probably back".
    size_t before = w.port.sent.size();
    for (int i = 0; i < 20 && w.box.screen().mains != Mains::on; i++, minute++)
        w.box.power(minute * 60000, uint32_t(1000 + minute * 60), false, uint16_t(4150 + 3 * i), false);
    CHECK(w.box.screen().mains == Mains::on);
    CHECK(w.port.sent.size() > before);
    Frame back = w.open(w.port.sent.back().payload);
    CHECK(back.kind == FrameKind::note && back.note.length == 20 && std::memcmp(back.note.text, "Power probably back.", 20) == 0);
}

TEST(withTheWireTheReportAndTheScreenSayNothingOfProbably) {
    World w;
    w.box.power(0, 1000, false, 4200, false);
    w.box.power(10000, 1010, false, 4200, false);
    CHECK(w.port.sent.size() == 1);
    CHECK(!w.box.screen().mainsEstimated);
}

TEST(theHoursAreCountedAtTheAwakeDrawWhileACallOrAPhoneKeepsTheBoxUp) {
    World w(true, true, batteryModel(BatteryDraw{3000, 100, 500}, true));
    w.box.power(0, 1000, false, 4200, false);
    w.box.power(10000, 1010, false, 4200, false);
    // The report's own repeats do not count: left alone, the box sleeps through the cut.
    w.box.power(11000, 1011, false, 4200, false);
    CHECK(w.box.screen().hoursLeft == 3000);
    // A phone connected keeps it up.
    w.box.power(12000, 1012, false, 4200, true);
    CHECK(w.box.screen().hoursLeft == 30);
    w.box.power(13000, 1013, false, 4200, false);
    CHECK(w.box.screen().hoursLeft == 3000);
    // A Help call is sent again until a person sees it, awake all the while.
    w.box.press(Colour::red, 14000, 1014, false);
    w.box.power(15000, 1015, false, 4200, false);
    CHECK(w.box.screen().hoursLeft == 30);
    uint16_t request = w.box.call(w.box.callCount() - 1).number;
    auto seen = w.ack(w.responder, 2, request, 1016);
    w.box.heard(seen.data(), seen.size(), 0);
    w.box.power(17000, 1017, false, 4200, false);
    CHECK(w.box.screen().hoursLeft == 3000);
}

TEST(aBoxWithoutAWorkingScreenStartsNoBluetooth) {
    CHECK(pairingAtStart(false) == Pairing::off);
    CHECK(pairingAtStart(true) == Pairing::shownCode);
}

TEST(theLEDSaysBluetoothIsOffOnlyWhenNoCallIsOpen) {
    Screen idle{};
    idle.provisioned = true;
    // Two short flashes every two seconds while awake.
    for (uint64_t t : {0, 100, 300, 449, 2000, 2350}) CHECK(ledLit(idle, Pairing::off, true, t));
    for (uint64_t t : {150, 299, 450, 1000, 1999, 2500}) CHECK(!ledLit(idle, Pairing::off, true, t));
    // Dark while asleep or waking only to read the battery, and with Bluetooth on.
    CHECK(!ledLit(idle, Pairing::off, false, 0));
    CHECK(!ledLit(idle, Pairing::shownCode, true, 0));
    // The same before the box is set up, which is when someone is most likely to look.
    Screen fresh{};
    CHECK(ledLit(fresh, Pairing::off, true, 0) && !ledLit(fresh, Pairing::off, true, 1000));

    // An open call keeps its own light whatever Bluetooth is doing.
    Screen call{};
    call.provisioned = call.hasCall = true;
    for (CallerStatus st : {CallerStatus::sending, CallerStatus::waitingForResponder}) {
        call.status = st;
        for (Pairing p : {Pairing::off, Pairing::shownCode})
            for (uint64_t t : {0, 200, 1000, 1999}) CHECK(ledLit(call, p, true, t));
    }
    call.status = CallerStatus::notSent;
    for (Pairing p : {Pairing::off, Pairing::shownCode}) {
        CHECK(!ledLit(call, p, true, 0) && !ledLit(call, p, true, 200));
        CHECK(ledLit(call, p, true, 500) && ledLit(call, p, true, 999));
    }
    // A call that is seen or closed is not open: the flashes come back.
    for (CallerStatus st : {CallerStatus::seen, CallerStatus::closed}) {
        call.status = st;
        CHECK(ledLit(call, Pairing::off, true, 0) && !ledLit(call, Pairing::off, true, 200));
        CHECK(!ledLit(call, Pairing::shownCode, true, 0));
    }
}
