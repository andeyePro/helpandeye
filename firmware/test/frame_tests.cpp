// Test vectors worked out by hand from HelpFrame.swift's encoder (Swift could not be run here):
// header byte, then little-endian fields in the order `encoded()` writes them. Values are the
// ones HelpFrameTests.swift uses, so the same frames can be checked from the Swift side.
#include <cstring>

#include "../core/frame.hpp"
#include "test.hpp"

using namespace helpandi;

namespace {

// .call(unit: 70001, request: 12, colour: .red, sentAt: 1_793_000_000)
const uint8_t kRedCall[] = {
    0x11,                    // version 1, kind 1
    0x71, 0x11, 0x01, 0x00,  // unit 70001
    0x0C, 0x00,              // request 12
    0x01,                    // red
    0x40, 0x02, 0xDF, 0x6A,  // 1_793_000_000
};

// .ack(unit: 70001, request: 12, responder: 3, ackedAt: 1_793_000_060, signature: 64 x 0x07)
const uint8_t kAckHead[] = {
    0x13,                    // version 1, kind 3
    0x71, 0x11, 0x01, 0x00,  // unit
    0x0C, 0x00,              // request
    0x03, 0x00,              // responder 3
    0x7C, 0x02, 0xDF, 0x6A,  // 1_793_000_060
};

// .callState(unit: 70001, request: 12, state: .callerOK, at: 1_793_000_100, reason: "")
const uint8_t kCallerOK[] = {
    0x22,                    // call state's own header byte
    0x71, 0x11, 0x01, 0x00,  // unit
    0x0C, 0x00,              // request
    0x01,                    // caller OK
    0xA4, 0x02, 0xDF, 0x6A,  // 1_793_000_100
    0x00,                    // no reason
};

// The same with state .closedWithReason and reason "Off".
const uint8_t kClosedWithReason[] = {
    0x22, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x04, 0xA4, 0x02, 0xDF, 0x6A, 0x03, 'O', 'f', 'f',
};

// HelpFrame.ackInput for the ack above, in a group whose ID is the bytes 0 to 15.
const uint8_t kAckInput[] = {
    'H', 'E', 'L', 'P', 'A', '-', 'A', 'C', 'K', '-', '2',
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x03, 0x00, 0x7C, 0x02, 0xDF, 0x6A,
};

// HelpFrame.signedInput for member 5 signing kCallerOK, same group.
const uint8_t kSignedInput[] = {
    'H', 'E', 'L', 'P', 'A', '-', 'S', 'I', 'G', 'N', 'E', 'D', '-', '2',
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x05, 0x00,
    0x22, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x01, 0xA4, 0x02, 0xDF, 0x6A, 0x00,
};

uint8_t group[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

AckFrame sampleAck() {
    AckFrame a{70001, 12, 3, 1793000060, {}};
    std::memset(a.signature, 7, sizeof a.signature);
    return a;
}

SignedFrame signedCallerOK() {
    SignedFrame s{};
    s.signer = 5;
    s.innerLength = sizeof kCallerOK;
    std::memcpy(s.inner, kCallerOK, sizeof kCallerOK);
    std::memset(s.signature, 9, sizeof s.signature);
    return s;
}

}  // namespace

TEST(callEncodesAsSwiftDoes) {
    uint8_t out[kMaxPayload];
    size_t n = encode(CallFrame{70001, 12, Colour::red, 1793000000}, out, sizeof out);
    CHECK_BYTES(out, n, kRedCall);
    Frame f = decode(kRedCall, sizeof kRedCall);
    CHECK(f.kind == FrameKind::call);
    CHECK(f.call.unit == 70001 && f.call.request == 12 && f.call.colour == Colour::red && f.call.sentAt == 1793000000);
}

TEST(callIsTwelveBytesAndStartsWith0x11) {
    uint8_t out[kMaxPayload];
    size_t n = encode(CallFrame{1, 1, Colour::amber, 0}, out, sizeof out);
    CHECK(n == kCallBytes);
    CHECK(out[0] == 0x11);
}

TEST(strayTrafficIsIgnored) {
    CHECK(decode(nullptr, 0).kind == FrameKind::none);
    const uint8_t hello[] = {'h', 'e', 'l', 'l', 'o'};
    CHECK(decode(hello, sizeof hello).kind == FrameKind::none);

    uint8_t b[sizeof kRedCall + 1];
    std::memcpy(b, kRedCall, sizeof kRedCall);
    b[sizeof kRedCall] = 0;
    CHECK(decode(b, sizeof kRedCall + 1).kind == FrameKind::none);  // trailing byte
    CHECK(decode(b, sizeof kRedCall - 1).kind == FrameKind::none);  // one short
    b[7] = 9;
    CHECK(decode(b, sizeof kRedCall).kind == FrameKind::none);  // no such colour
    b[7] = 1;
    b[0] = 0x31;
    CHECK(decode(b, sizeof kRedCall).kind == FrameKind::none);  // a format version not understood
    // HelpFrameTests' wrong-version case: 0x21 is group settings' header, so not a call. The box
    // passes such frames to the phone unread; the phone rejects this one.
    b[0] = 0x21;
    CHECK(decode(b, sizeof kRedCall).kind == FrameKind::other);
}

TEST(otherHelpFramesArePassedOnUnread) {
    const uint8_t followUp[] = {0x12, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x01, 0x05};
    CHECK(decode(followUp, sizeof followUp).kind == FrameKind::other);
    const uint8_t sealed[] = {0x10, 0x00};
    CHECK(decode(sealed, sizeof sealed).kind == FrameKind::other);
}

TEST(ackEncodesAsSwiftDoes) {
    uint8_t out[kMaxPayload];
    size_t n = encode(sampleAck(), out, sizeof out);
    CHECK(n == kAckBytes);
    CHECK(std::memcmp(out, kAckHead, sizeof kAckHead) == 0);
    for (size_t i = sizeof kAckHead; i < n; i++) CHECK(out[i] == 7);
    Frame f = decode(out, n);
    CHECK(f.kind == FrameKind::ack);
    CHECK(f.ack.responder == 3 && f.ack.ackedAt == 1793000060 && f.ack.signature[63] == 7);
    CHECK(decode(out, n - 1).kind == FrameKind::none);
}

TEST(callStateEncodesAsSwiftDoes) {
    uint8_t out[kMaxPayload];
    CallStateFrame ok{70001, 12, CallState::callerOK, 1793000100, 0, {}};
    CHECK_BYTES(out, encode(ok, out, sizeof out), kCallerOK);

    CallStateFrame off{70001, 12, CallState::closedWithReason, 1793000100, 3, {'O', 'f', 'f'}};
    CHECK_BYTES(out, encode(off, out, sizeof out), kClosedWithReason);
    Frame f = decode(kClosedWithReason, sizeof kClosedWithReason);
    CHECK(f.kind == FrameKind::callState);
    CHECK(f.callState.state == CallState::closedWithReason && f.callState.reasonLength == 3);
    CHECK(std::memcmp(f.callState.reason, "Off", 3) == 0);
}

TEST(callStateRefusesWhatSwiftWouldNotRead) {
    uint8_t out[kMaxPayload];
    CallStateFrame bad{70001, 12, CallState::callerOK, 0, 2, {0xC0, 0x80}};
    CHECK(encode(bad, out, sizeof out) == 0);  // not UTF-8
    CallStateFrame noState{70001, 12, CallState(9), 0, 0, {}};
    CHECK(encode(noState, out, sizeof out) == 0);

    uint8_t b[sizeof kCallerOK];
    std::memcpy(b, kCallerOK, sizeof b);
    b[7] = 0;
    CHECK(decode(b, sizeof b).kind == FrameKind::none);  // no such state
    b[7] = 1;
    b[12] = 57;
    CHECK(decode(b, sizeof b).kind == FrameKind::none);  // reason longer than allowed
}

TEST(signedFrameWrapsACallState) {
    uint8_t out[kMaxPayload];
    size_t n = encode(signedCallerOK(), out, sizeof out);
    CHECK(n == 1 + 2 + 1 + sizeof kCallerOK + kSignatureBytes);
    const uint8_t head[] = {0x1A, 0x05, 0x00, sizeof kCallerOK};
    CHECK(std::memcmp(out, head, sizeof head) == 0);
    CHECK(std::memcmp(out + sizeof head, kCallerOK, sizeof kCallerOK) == 0);
    Frame f = decode(out, n);
    CHECK(f.kind == FrameKind::signedFrame);
    CHECK(f.signedFrame.signer == 5 && f.signedFrame.innerLength == sizeof kCallerOK);
    CHECK(decode(f.signedFrame.inner, f.signedFrame.innerLength).kind == FrameKind::callState);

    SignedFrame tooLong = signedCallerOK();
    tooLong.innerLength = kMaxSignedInner + 1;
    CHECK(encode(tooLong, out, sizeof out) == 0);
}

TEST(nothingPersonalGoesOnTheGroupChannel) {
    CHECK(mayGoOnGroupChannel(decode(kRedCall, sizeof kRedCall)));
    CHECK(mayGoOnGroupChannel(decode(kCallerOK, sizeof kCallerOK)));
    CHECK(!mayGoOnGroupChannel(decode(kClosedWithReason, sizeof kClosedWithReason)));

    uint8_t out[kMaxPayload];
    CHECK(mayGoOnGroupChannel(decode(out, encode(signedCallerOK(), out, sizeof out))));

    SignedFrame withReason = signedCallerOK();
    withReason.innerLength = sizeof kClosedWithReason;
    std::memcpy(withReason.inner, kClosedWithReason, sizeof kClosedWithReason);
    CHECK(!mayGoOnGroupChannel(decode(out, encode(withReason, out, sizeof out))));

    // A typed note (kind 6) inside a signed frame: this core cannot read it, so it stays off.
    SignedFrame note = signedCallerOK();
    const uint8_t noteHead[] = {0x16, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x01, 0x00};
    note.innerLength = sizeof noteHead;
    std::memcpy(note.inner, noteHead, sizeof noteHead);
    CHECK(!mayGoOnGroupChannel(decode(out, encode(note, out, sizeof out))));
}

TEST(signatureInputsMatchSwift) {
    uint8_t out[128];
    CHECK_BYTES(out, ackSignatureInput(sampleAck(), group, sizeof group, out, sizeof out), kAckInput);
    CHECK_BYTES(out, signedSignatureInput(5, kCallerOK, sizeof kCallerOK, group, sizeof group, out, sizeof out),
                kSignedInput);
    CHECK(ackSignatureInput(sampleAck(), group, sizeof group, out, sizeof kAckInput - 1) == 0);
}

namespace {
// Encodes into a buffer of exactly `need` bytes, then one short of it: the first must fill it,
// the second must leave every byte as it was.
template <typename Encode>
bool fitsExactlyAndOneShortWritesNothing(size_t need, Encode encode) {
    uint8_t out[256];
    if (encode(out, need) != need) return false;
    std::memset(out, 0xEE, sizeof out);
    if (encode(out, need - 1) != 0) return false;
    for (uint8_t b : out)
        if (b != 0xEE) return false;
    return true;
}
}  // namespace

TEST(tooSmallABufferWritesNothing) {
    CHECK(fitsExactlyAndOneShortWritesNothing(kCallBytes, [](uint8_t* o, size_t c) {
        return encode(CallFrame{1, 1, Colour::red, 0}, o, c);
    }));
    CHECK(fitsExactlyAndOneShortWritesNothing(kAckBytes, [](uint8_t* o, size_t c) { return encode(sampleAck(), o, c); }));
    CHECK(fitsExactlyAndOneShortWritesNothing(sizeof kClosedWithReason, [](uint8_t* o, size_t c) {
        CallStateFrame f{70001, 12, CallState::closedWithReason, 1793000100, 3, {'O', 'f', 'f'}};
        return encode(f, o, c);
    }));
    CHECK(fitsExactlyAndOneShortWritesNothing(4 + sizeof kCallerOK + kSignatureBytes, [](uint8_t* o, size_t c) {
        return encode(signedCallerOK(), o, c);
    }));
    CHECK(fitsExactlyAndOneShortWritesNothing(sizeof kAckInput, [](uint8_t* o, size_t c) {
        return ackSignatureInput(sampleAck(), group, sizeof group, o, c);
    }));
    CHECK(fitsExactlyAndOneShortWritesNothing(sizeof kSignedInput, [](uint8_t* o, size_t c) {
        return signedSignatureInput(5, kCallerOK, sizeof kCallerOK, group, sizeof group, o, c);
    }));
}

TEST(anUnknownColourIsNotEncoded) {
    uint8_t out[kMaxPayload];
    CHECK(encode(CallFrame{1, 1, Colour(0), 0}, out, sizeof out) == 0);
    CHECK(encode(CallFrame{1, 1, Colour(4), 0}, out, sizeof out) == 0);
}

TEST(utf8IsCheckedStrictly) {
    const uint8_t e[] = {0xC3, 0xA9};
    CHECK(isValidUTF8(e, sizeof e));
    const uint8_t pound[] = {0xC2, 0xA3, ' ', '5'};
    CHECK(isValidUTF8(pound, sizeof pound));
    const uint8_t overlong[] = {0xC0, 0x80};
    CHECK(!isValidUTF8(overlong, sizeof overlong));
    const uint8_t surrogate[] = {0xED, 0xA0, 0x80};
    CHECK(!isValidUTF8(surrogate, sizeof surrogate));
    const uint8_t tooHigh[] = {0xF4, 0x90, 0x80, 0x80};
    CHECK(!isValidUTF8(tooHigh, sizeof tooHigh));
    const uint8_t cut[] = {0xE2, 0x82};
    CHECK(!isValidUTF8(cut, sizeof cut));
}
