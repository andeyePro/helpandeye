#include "frame.hpp"

#include <cstring>

namespace helpandi {

namespace {

constexpr uint8_t kCallHeader = kFormatVersion << 4 | 1;
constexpr uint8_t kAckHeader = kFormatVersion << 4 | 3;
constexpr uint8_t kSignedHeader = kFormatVersion << 4 | 10;
// The first 16 kinds used the low nibble up, so later kinds have whole header bytes.
constexpr uint8_t kSettingsHeader = 0x21;
constexpr uint8_t kCallStateHeader = 0x22;
constexpr uint8_t kChangeRequestHeader = 0x23;

// Given the whole frame's size first, so a buffer too small for it is left untouched.
class Writer {
public:
    Writer(uint8_t* out, size_t cap, size_t need) : out_(out), cap_(cap), failed_(need > cap) {}
    void u8(uint8_t v) { put(&v, 1); }
    void u16(uint16_t v) {
        uint8_t b[2] = {uint8_t(v), uint8_t(v >> 8)};
        put(b, 2);
    }
    void u32(uint32_t v) {
        uint8_t b[4] = {uint8_t(v), uint8_t(v >> 8), uint8_t(v >> 16), uint8_t(v >> 24)};
        put(b, 4);
    }
    void bytes(const uint8_t* p, size_t n) { put(p, n); }
    size_t length() const { return failed_ ? 0 : used_; }

private:
    void put(const uint8_t* p, size_t n) {
        if (failed_ || cap_ - used_ < n) {
            failed_ = true;
            return;
        }
        if (n) std::memcpy(out_ + used_, p, n);
        used_ += n;
    }
    uint8_t* out_;
    size_t cap_;
    size_t used_ = 0;
    bool failed_;
};

class Reader {
public:
    Reader(const uint8_t* data, size_t length) : data_(data), length_(length) {}
    bool u8(uint8_t& v) { return take(&v, 1); }
    bool u16(uint16_t& v) {
        uint8_t b[2];
        if (!take(b, 2)) return false;
        v = uint16_t(b[0] | b[1] << 8);
        return true;
    }
    bool u32(uint32_t& v) {
        uint8_t b[4];
        if (!take(b, 4)) return false;
        v = uint32_t(b[0]) | uint32_t(b[1]) << 8 | uint32_t(b[2]) << 16 | uint32_t(b[3]) << 24;
        return true;
    }
    bool take(uint8_t* out, size_t n) {
        if (length_ - offset_ < n) return false;
        if (n) std::memcpy(out, data_ + offset_, n);
        offset_ += n;
        return true;
    }
    bool atEnd() const { return offset_ == length_; }

private:
    const uint8_t* data_;
    size_t length_;
    size_t offset_ = 0;
};

bool validColour(uint8_t c) { return c >= 1 && c <= 3; }
bool validState(uint8_t s) { return s >= 1 && s <= 4; }

// Swift's String(data:encoding:) accepts a NUL inside text, so this does too.
size_t sequenceLength(uint8_t lead) {
    if (lead < 0x80) return 1;
    if (lead >= 0xC2 && lead <= 0xDF) return 2;
    if (lead >= 0xE0 && lead <= 0xEF) return 3;
    if (lead >= 0xF0 && lead <= 0xF4) return 4;
    return 0;
}

}  // namespace

bool isValidUTF8(const uint8_t* s, size_t n) {
    size_t i = 0;
    while (i < n) {
        size_t len = sequenceLength(s[i]);
        if (len == 0 || n - i < len) return false;
        for (size_t k = 1; k < len; k++)
            if ((s[i + k] & 0xC0) != 0x80) return false;
        if (len == 3) {
            if (s[i] == 0xE0 && s[i + 1] < 0xA0) return false;  // overlong
            if (s[i] == 0xED && s[i + 1] > 0x9F) return false;  // surrogate
        }
        if (len == 4) {
            if (s[i] == 0xF0 && s[i + 1] < 0x90) return false;  // overlong
            if (s[i] == 0xF4 && s[i + 1] > 0x8F) return false;  // past U+10FFFF
        }
        i += len;
    }
    return true;
}

size_t encode(const CallFrame& f, uint8_t* out, size_t cap) {
    if (!validColour(uint8_t(f.colour))) return 0;
    Writer w(out, cap, kCallBytes);
    w.u8(kCallHeader);
    w.u32(f.unit);
    w.u16(f.request);
    w.u8(uint8_t(f.colour));
    w.u32(f.sentAt);
    return w.length();
}

size_t encode(const AckFrame& f, uint8_t* out, size_t cap) {
    Writer w(out, cap, kAckBytes);
    w.u8(kAckHeader);
    w.u32(f.unit);
    w.u16(f.request);
    w.u16(f.responder);
    w.u32(f.ackedAt);
    w.bytes(f.signature, kSignatureBytes);
    return w.length();
}

size_t encode(const CallStateFrame& f, uint8_t* out, size_t cap) {
    if (!validState(uint8_t(f.state)) || f.reasonLength > kMaxReasonBytes || !isValidUTF8(f.reason, f.reasonLength))
        return 0;
    Writer w(out, cap, 13 + size_t(f.reasonLength));
    w.u8(kCallStateHeader);
    w.u32(f.unit);
    w.u16(f.request);
    w.u8(uint8_t(f.state));
    w.u32(f.at);
    w.u8(f.reasonLength);
    w.bytes(f.reason, f.reasonLength);
    return w.length();
}

size_t encode(const SignedFrame& f, uint8_t* out, size_t cap) {
    if (f.innerLength > kMaxSignedInner) return 0;
    Writer w(out, cap, 4 + size_t(f.innerLength) + kSignatureBytes);
    w.u8(kSignedHeader);
    w.u16(f.signer);
    w.u8(f.innerLength);
    w.bytes(f.inner, f.innerLength);
    w.bytes(f.signature, kSignatureBytes);
    return w.length();
}

Frame decode(const uint8_t* data, size_t length) {
    Frame f;
    f.kind = FrameKind::none;
    Reader r(data, length);
    uint8_t head;
    if (!r.u8(head)) return f;

    if (head == kCallStateHeader) {
        CallStateFrame& c = f.callState;
        uint8_t state;
        if (!r.u32(c.unit) || !r.u16(c.request) || !r.u8(state) || !validState(state) || !r.u32(c.at) ||
            !r.u8(c.reasonLength) || c.reasonLength > kMaxReasonBytes || !r.take(c.reason, c.reasonLength) ||
            !isValidUTF8(c.reason, c.reasonLength) || !r.atEnd())
            return f;
        c.state = CallState(state);
        f.kind = FrameKind::callState;
        return f;
    }
    if (head == kSettingsHeader || head == kChangeRequestHeader) {
        f.kind = FrameKind::other;
        return f;
    }
    if (head >> 4 != kFormatVersion) return f;

    switch (head) {
    case kCallHeader: {
        CallFrame& c = f.call;
        uint8_t colour;
        if (!r.u32(c.unit) || !r.u16(c.request) || !r.u8(colour) || !validColour(colour) || !r.u32(c.sentAt) ||
            !r.atEnd())
            return f;
        c.colour = Colour(colour);
        f.kind = FrameKind::call;
        return f;
    }
    case kAckHeader: {
        AckFrame& a = f.ack;
        if (!r.u32(a.unit) || !r.u16(a.request) || !r.u16(a.responder) || !r.u32(a.ackedAt) ||
            !r.take(a.signature, kSignatureBytes) || !r.atEnd())
            return f;
        f.kind = FrameKind::ack;
        return f;
    }
    case kSignedHeader: {
        SignedFrame& s = f.signedFrame;
        if (!r.u16(s.signer) || !r.u8(s.innerLength) || s.innerLength > kMaxSignedInner ||
            !r.take(s.inner, s.innerLength) || !r.take(s.signature, kSignatureBytes) || !r.atEnd())
            return f;
        f.kind = FrameKind::signedFrame;
        return f;
    }
    default:
        // Every low nibble is a kind in use (HelpFrame.Kind), so any other 0x1_ byte is one.
        f.kind = FrameKind::other;
        return f;
    }
}

bool mayGoOnGroupChannel(const Frame& f) {
    switch (f.kind) {
    case FrameKind::call:
    case FrameKind::ack:
        return true;
    // A coordinator's reason is personal: the radio carries the close without it.
    case FrameKind::callState:
        return f.callState.reasonLength == 0;
    case FrameKind::signedFrame:
        return mayGoOnGroupChannel(decode(f.signedFrame.inner, f.signedFrame.innerLength));
    default:
        return false;
    }
}

size_t ackSignatureInput(const AckFrame& f, const uint8_t* group, size_t groupLength, uint8_t* out, size_t cap) {
    static const char label[] = "HELPA-ACK-2";
    Writer w(out, cap, sizeof label - 1 + groupLength + 12);
    w.bytes(reinterpret_cast<const uint8_t*>(label), sizeof label - 1);
    w.bytes(group, groupLength);
    w.u32(f.unit);
    w.u16(f.request);
    w.u16(f.responder);
    w.u32(f.ackedAt);
    return w.length();
}

size_t signedSignatureInput(uint16_t signer, const uint8_t* inner, size_t innerLength, const uint8_t* group,
                            size_t groupLength, uint8_t* out, size_t cap) {
    static const char label[] = "HELPA-SIGNED-2";
    Writer w(out, cap, sizeof label - 1 + groupLength + 2 + innerLength);
    w.bytes(reinterpret_cast<const uint8_t*>(label), sizeof label - 1);
    w.bytes(group, groupLength);
    w.u16(signer);
    w.bytes(inner, innerLength);
    return w.length();
}

}  // namespace helpandi
