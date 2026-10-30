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

struct World {
    FakePort port;
    Phone coordinator, responder, caller;
    uint8_t respondersPrivate[32], respondersPublic[32];
    GroupSettings group{};
    MemberList members;
    BoxEngine box;

    explicit World(bool okCloses = true, bool reportPowerCut = true) : box(port, kUK, kCell, 1) {
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
        AckFrame a{group.unit, request, member, at, {}};
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

const uint8_t kFirstRed[] = {0x11, 0x74, 0x11, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00};

}  // namespace

TEST(nothingGoesOutBeforeTheBoxIsProvisioned) {
    FakePort port;
    BoxEngine box(port, kUK, kCell, 1);
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
    w.box.heard(bad.data(), bad.size());
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    uint8_t otherGroup[16] = {9, 9, 9};
    auto wrongGroup = w.ack(w.responder, 2, 1, 1001, otherGroup);
    w.box.heard(wrongGroup.data(), wrongGroup.size());
    auto forged = w.ack(w.caller, 2, 1, 1001);
    w.box.heard(forged.data(), forged.size());
    auto unknown = w.ack(w.responder, 7, 1, 1001);
    w.box.heard(unknown.data(), unknown.size());
    auto otherCall = w.ack(w.responder, 2, 2, 1001);
    w.box.heard(otherCall.data(), otherCall.size());
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    CHECK(w.box.takeSound() == Sound::press && w.box.takeSound() == Sound::none);
    auto good = w.ack(w.responder, 2, 1, 1001);
    w.box.heard(good.data(), good.size());
    CHECK(w.box.screen().status == CallerStatus::seen);
    CHECK(w.box.takeSound() == Sound::seen);
    CHECK(std::strcmp(statusWords(CallerStatus::seen), "A responder has seen your call.") == 0);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.size() == 1);
    auto coordinatorsToo = w.ack(w.coordinator, 1, 1, 1002);
    w.box.heard(coordinatorsToo.data(), coordinatorsToo.size());
    CHECK(w.box.takeSound() == Sound::none);
}

TEST(aRemovalSignedByTheFirstCoordinatorTakesBackTheAcknowledgement) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    auto good = w.ack(w.responder, 2, 1, 1001);
    w.box.heard(good.data(), good.size());
    CHECK(w.box.screen().status == CallerStatus::seen);
    uint8_t removed[8];
    size_t n = encode(MemberRemovedFrame{2, 2}, removed, sizeof removed);
    auto byResponder = w.signedBy(w.responder, 2, removed, n);
    w.box.heard(byResponder.data(), byResponder.size());
    CHECK(w.box.screen().status == CallerStatus::seen);
    auto stale = w.signedBy(w.coordinator, 1, removed, n);
    w.members.version = 2;
    w.box.provision(w.group, w.members);
    w.box.press(Colour::red, 1000, 1001, false);
    auto second = w.ack(w.responder, 2, 2, 1002);
    w.box.heard(second.data(), second.size());
    w.box.heard(stale.data(), stale.size());
    CHECK(w.box.screen().status == CallerStatus::seen);
    size_t m = encode(MemberRemovedFrame{2, 3}, removed, sizeof removed);
    auto real = w.signedBy(w.coordinator, 1, removed, m);
    w.box.heard(real.data(), real.size());
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    CHECK(w.box.members().find(2) == nullptr);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.back().payload[0] == 0x11);
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
    w.box.heard(good.data(), good.size());
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

TEST(thePowerCapFollowsTheBandAndTheAntenna) {
    World w;
    int setting = 0;
    CHECK(w.box.powerCap(12.0, -9, 22, setting) && setting == 15);
    w.box.setRadio(RadioSettings(868.3, 62.5, 8, 5));
    CHECK(w.box.powerCap(12.0, -9, 22, setting) && setting == 2);
    w.group.antenna = Antenna::external5dBi;
    w.box.provision(w.group, w.members);
    CHECK(w.box.powerCap(12.0, -9, 22, setting) && setting == -1);
    CHECK(!w.box.powerCap(12.0, 0, 22, setting));
    w.box.setRadio(RadioSettings(915.0, 250, 10, 5));
    CHECK(!w.box.powerCap(12.0, -9, 22, setting));
}

TEST(aPowerCutIsSealedForRespondersAndTheHoursFollow) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    w.box.power(0, 1000, true, 4200);
    w.box.power(10000, 1010, true, 4200);
    w.box.power(20000, 1020, false, 4200);
    w.box.power(30000, 1030, false, 4200);
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

    w.box.power(31000, 1031, false, 4000);
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
    w.box.heard(seen.data(), seen.size());
    CHECK(w.box.reportAcknowledged());
    w.box.tick(90000, 1090);
    CHECK(w.port.sent.size() == 6);  // the red's resend only
    w.box.power(91000, 1091, false, 3700);  // 9 hours: quiet now
    CHECK(w.port.sent.size() == 6);
    w.box.power(92000, 1092, false, 3450);  // under an hour: the final warning still goes
    CHECK(w.port.sent.size() == 7);
    Frame last = w.open(w.port.sent[6].payload);
    CHECK(last.kind == FrameKind::note && last.note.part == 3);
    CHECK(std::memcmp(last.note.text, "Less than an hour of battery left.", last.note.length) == 0);
    w.box.tick(122000, 1122);
    CHECK(w.port.sent.size() == 8 && w.port.sent[7].payload == w.port.sent[6].payload);

    w.box.power(130000, 1130, true, 3450);
    w.box.power(140000, 1140, true, 3450);
    Frame back = w.open(w.port.sent.back().payload);
    CHECK(back.kind == FrameKind::note && back.note.part == 4);
    CHECK(std::memcmp(back.note.text, "Power is back.", 14) == 0);
    CHECK(w.box.screen().mains == PowerMonitor::Mains::on);
}

TEST(aPowerCutIsNotReportedWithoutOptInOrARespondersKey) {
    World quiet(true, false);
    quiet.box.power(0, 1000, false, 4200);
    quiet.box.power(10000, 1010, false, 4200);
    CHECK(quiet.port.sent.empty());
    CHECK(quiet.box.screen().mains == PowerMonitor::Mains::off);
    World noKey;
    std::memset(noKey.group.respondersKey, 0, 32);
    noKey.box.provision(noKey.group, noKey.members);
    noKey.box.power(0, 1000, false, 4200);
    noKey.box.power(10000, 1010, false, 4200);
    CHECK(noKey.port.sent.empty());
}

TEST(aCoordinatorsSignedCloseClosesTheCall) {
    World w;
    w.box.press(Colour::red, 0, 1000, false);
    CallStateFrame close{70004, 1, CallState::closedWithReason, 1100, 0, {}};
    uint8_t inner[16];
    size_t n = encode(close, inner, sizeof inner);
    auto byResponder = w.signedBy(w.responder, 2, inner, n);
    w.box.heard(byResponder.data(), byResponder.size());
    CHECK(w.box.screen().status == CallerStatus::waitingForResponder);
    auto byCoordinator = w.signedBy(w.coordinator, 1, inner, n);
    w.box.heard(byCoordinator.data(), byCoordinator.size());
    CHECK(w.box.screen().status == CallerStatus::closed);
    w.box.tick(30000, 1030);
    CHECK(w.port.sent.size() == 1);
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
    BoxEngine box(port, kUK, kCell, 32767);
    World w;
    box.provision(w.group, w.members);
    box.press(Colour::red, 0, 1000, false);
    CHECK(port.sent[0].payload[5] == 0xFF && port.sent[0].payload[6] == 0x7F);
    CHECK(port.savedNext == 1);
    BoxEngine fresh(port, kUK, kCell, 0);
    CHECK(fresh.nextRequest() == 1);
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
