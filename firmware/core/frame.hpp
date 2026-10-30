// Help&I frames, as the box needs them: the call, the follow-up, the acknowledgement, the note,
// a removal, the call state and the signed wrapper. Byte for byte the same as app/helpandeyeCore/Sources/helpandeyeCore/HelpFrame.swift,
// which is the reference. Integers are little-endian.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

namespace helpandi {

constexpr uint8_t kFormatVersion = 1;
// MeshCore group data type: inside MeshCore's testing range (TODO.md, MeshCore data_type).
constexpr uint16_t kMeshDataType = 0xFF48;
// MeshCore's MAX_GROUP_DATA_LENGTH: 184 - 16 - 3.
constexpr size_t kMaxPayload = 165;
constexpr size_t kSignatureBytes = 64;
constexpr size_t kMaxSignedInner = 80;
constexpr size_t kMaxReasonBytes = 56;
constexpr size_t kCallBytes = 12;
constexpr size_t kAckBytes = 77;
constexpr size_t kFollowUpBytes = 9;
constexpr size_t kMaxNoteBytes = 120;

enum class Colour : uint8_t { red = 1, amber = 2, green = 3 };

// What a caller adds after the call. Every category but a missed check-in is personal and goes
// sealed for responders; the box sends powerCut (decision 3).
enum class Category : uint8_t {
    withdrawn = 0,
    fallen = 1,
    unwell = 2,
    lockedOut = 3,
    powerCut = 4,
    needCompany = 5,
    missedCheckIn = 6,
    other = 99,
};

enum class CallState : uint8_t { callerOK = 1, closedByCaller = 2, closedWithConsent = 3, closedWithReason = 4 };

// "I'm OK" stops the urgent repeats; every other state ends the call (decision 6).
inline bool closes(CallState s) { return s != CallState::callerOK; }

struct CallFrame {
    uint32_t unit;
    uint16_t request;
    Colour colour;
    uint32_t sentAt;
};

struct AckFrame {
    uint32_t unit;
    uint16_t request;
    uint16_t responder;
    uint32_t ackedAt;
    uint8_t signature[kSignatureBytes];
};

struct FollowUpFrame {
    uint32_t unit;
    uint16_t request;
    uint8_t part;
    Category category;
};

struct NoteFrame {
    uint32_t unit;
    uint16_t request;
    uint8_t part;
    uint8_t length;
    uint8_t text[kMaxNoteBytes];
};

struct MemberRemovedFrame {
    uint16_t member;
    uint32_t version;
};

struct CallStateFrame {
    uint32_t unit;
    uint16_t request;
    CallState state;
    uint32_t at;
    uint8_t reasonLength;
    uint8_t reason[kMaxReasonBytes];
};

struct SignedFrame {
    uint16_t signer;
    uint8_t innerLength;
    uint8_t inner[kMaxSignedInner];
    uint8_t signature[kSignatureBytes];
};

enum class FrameKind : uint8_t {
    // Not a Help&I frame, or a malformed one: ignored, never shown.
    none,
    call,
    followUp,
    ack,
    note,
    memberRemoved,
    callState,
    signedFrame,
    // A well-formed Help&I header for a kind this core does not read (a follow-up, a sealed note,
    // membership...). The box passes it to the phone unread.
    other,
};

struct Frame {
    FrameKind kind;
    union {
        CallFrame call;
        FollowUpFrame followUp;
        AckFrame ack;
        NoteFrame note;
        MemberRemovedFrame memberRemoved;
        CallStateFrame callState;
        SignedFrame signedFrame;
    };
};

// Each returns the number of bytes written, or 0 if the frame is not one HelpFrame.swift would
// produce (an unknown colour or state, a reason too long or not UTF-8, an inner frame over 80
// bytes) or `cap` is too small. The Swift encoder cuts long text instead; the box never sends a
// reason, so here a cut that might differ from Swift's is refused rather than guessed.
size_t encode(const CallFrame& f, uint8_t* out, size_t cap);
size_t encode(const FollowUpFrame& f, uint8_t* out, size_t cap);
size_t encode(const AckFrame& f, uint8_t* out, size_t cap);
size_t encode(const NoteFrame& f, uint8_t* out, size_t cap);
size_t encode(const MemberRemovedFrame& f, uint8_t* out, size_t cap);
size_t encode(const CallStateFrame& f, uint8_t* out, size_t cap);
size_t encode(const SignedFrame& f, uint8_t* out, size_t cap);

// Reads a frame. Anything malformed, or of a version this core does not understand, gives
// FrameKind::none.
Frame decode(const uint8_t* data, size_t length);

// Whether the box may put this frame on the shared group channel (decision 12). Conservative:
// a signed frame whose inner kind this core cannot read is refused.
bool mayGoOnGroupChannel(const Frame& f);

// What each signature covers. Every one includes the group's ID, so a signature from one group
// is worthless in another. Return the number of bytes written, or 0 if `cap` is too small.
size_t ackSignatureInput(const AckFrame& f, const uint8_t* group, size_t groupLength, uint8_t* out, size_t cap);
size_t signedSignatureInput(uint16_t signer, const uint8_t* inner, size_t innerLength, const uint8_t* group,
                            size_t groupLength, uint8_t* out, size_t cap);

// True for well-formed UTF-8 (RFC 3629: no overlong forms, surrogates or values past U+10FFFF).
bool isValidUTF8(const uint8_t* bytes, size_t length);

}  // namespace helpandi
