#include "seal.hpp"

#include <cstring>

#include "frame.hpp"

namespace helpandi {

namespace {

uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
uint32_t rotl(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

uint32_t loadBE(const uint8_t* p) {
    return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | uint32_t(p[3]);
}

uint32_t loadLE(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}

void storeLE(uint8_t* p, uint32_t v) {
    p[0] = uint8_t(v);
    p[1] = uint8_t(v >> 8);
    p[2] = uint8_t(v >> 16);
    p[3] = uint8_t(v >> 24);
}

void storeLE64(uint8_t* p, uint64_t v) {
    storeLE(p, uint32_t(v));
    storeLE(p + 4, uint32_t(v >> 32));
}

const uint32_t kSha256K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

class Sha256 {
public:
    Sha256() {
        static const uint32_t init[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                         0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
        std::memcpy(h_, init, sizeof h_);
    }

    void update(const uint8_t* data, size_t length) {
        total_ += length;
        while (length) {
            size_t take = 64 - fill_ < length ? 64 - fill_ : length;
            std::memcpy(block_ + fill_, data, take);
            fill_ += take;
            data += take;
            length -= take;
            if (fill_ == 64) {
                compress();
                fill_ = 0;
            }
        }
    }

    void finish(uint8_t out[32]) {
        uint64_t bits = total_ * 8;
        uint8_t pad = 0x80;
        update(&pad, 1);
        uint8_t zero = 0;
        while (fill_ != 56) update(&zero, 1);
        uint8_t len[8];
        for (int i = 0; i < 8; i++) len[i] = uint8_t(bits >> (56 - 8 * i));
        update(len, 8);
        for (int i = 0; i < 8; i++) {
            out[4 * i] = uint8_t(h_[i] >> 24);
            out[4 * i + 1] = uint8_t(h_[i] >> 16);
            out[4 * i + 2] = uint8_t(h_[i] >> 8);
            out[4 * i + 3] = uint8_t(h_[i]);
        }
    }

private:
    void compress() {
        uint32_t w[64];
        for (int i = 0; i < 16; i++) w[i] = loadBE(block_ + 4 * i);
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3], e = h_[4], f = h_[5], g = h_[6], h = h_[7];
        for (int i = 0; i < 64; i++) {
            uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = h + s1 + ch + kSha256K[i] + w[i];
            uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = s0 + maj;
            h = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
        }
        h_[0] += a;
        h_[1] += b;
        h_[2] += c;
        h_[3] += d;
        h_[4] += e;
        h_[5] += f;
        h_[6] += g;
        h_[7] += h;
    }

    uint32_t h_[8];
    uint8_t block_[64];
    size_t fill_ = 0;
    uint64_t total_ = 0;
};

void quarterRound(uint32_t* s, int a, int b, int c, int d) {
    s[a] += s[b]; s[d] = rotl(s[d] ^ s[a], 16);
    s[c] += s[d]; s[b] = rotl(s[b] ^ s[c], 12);
    s[a] += s[b]; s[d] = rotl(s[d] ^ s[a], 8);
    s[c] += s[d]; s[b] = rotl(s[b] ^ s[c], 7);
}

}  // namespace

void chacha20Block(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12], uint8_t out[64]) {
    uint32_t state[16] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    for (int i = 0; i < 8; i++) state[4 + i] = loadLE(key + 4 * i);
    state[12] = counter;
    for (int i = 0; i < 3; i++) state[13 + i] = loadLE(nonce + 4 * i);
    uint32_t x[16];
    std::memcpy(x, state, sizeof x);
    for (int i = 0; i < 10; i++) {
        quarterRound(x, 0, 4, 8, 12);
        quarterRound(x, 1, 5, 9, 13);
        quarterRound(x, 2, 6, 10, 14);
        quarterRound(x, 3, 7, 11, 15);
        quarterRound(x, 0, 5, 10, 15);
        quarterRound(x, 1, 6, 11, 12);
        quarterRound(x, 2, 7, 8, 13);
        quarterRound(x, 3, 4, 9, 14);
    }
    for (int i = 0; i < 16; i++) storeLE(out + 4 * i, x[i] + state[i]);
}

namespace {

// poly1305-donna's 32-bit form: five 26-bit limbs.
class Poly1305 {
public:
    explicit Poly1305(const uint8_t key[32]) {
        r_[0] = loadLE(key) & 0x3ffffff;
        r_[1] = (loadLE(key + 3) >> 2) & 0x3ffff03;
        r_[2] = (loadLE(key + 6) >> 4) & 0x3ffc0ff;
        r_[3] = (loadLE(key + 9) >> 6) & 0x3f03fff;
        r_[4] = (loadLE(key + 12) >> 8) & 0x00fffff;
        for (int i = 0; i < 4; i++) pad_[i] = loadLE(key + 16 + 4 * i);
        std::memset(h_, 0, sizeof h_);
    }

    void update(const uint8_t* data, size_t length) {
        while (length) {
            size_t take = 16 - fill_ < length ? 16 - fill_ : length;
            std::memcpy(block_ + fill_, data, take);
            fill_ += take;
            data += take;
            length -= take;
            if (fill_ == 16) {
                absorb(block_, 1u << 24);
                fill_ = 0;
            }
        }
    }

    void finish(uint8_t tag[16]) {
        if (fill_) {
            block_[fill_++] = 1;
            while (fill_ < 16) block_[fill_++] = 0;
            absorb(block_, 0);
        }
        uint32_t c = h_[1] >> 26; h_[1] &= 0x3ffffff;
        h_[2] += c; c = h_[2] >> 26; h_[2] &= 0x3ffffff;
        h_[3] += c; c = h_[3] >> 26; h_[3] &= 0x3ffffff;
        h_[4] += c; c = h_[4] >> 26; h_[4] &= 0x3ffffff;
        h_[0] += c * 5; c = h_[0] >> 26; h_[0] &= 0x3ffffff;
        h_[1] += c;

        uint32_t g[5];
        g[0] = h_[0] + 5; c = g[0] >> 26; g[0] &= 0x3ffffff;
        g[1] = h_[1] + c; c = g[1] >> 26; g[1] &= 0x3ffffff;
        g[2] = h_[2] + c; c = g[2] >> 26; g[2] &= 0x3ffffff;
        g[3] = h_[3] + c; c = g[3] >> 26; g[3] &= 0x3ffffff;
        g[4] = h_[4] + c - (1u << 26);

        uint32_t mask = (g[4] >> 31) - 1;
        for (int i = 0; i < 5; i++) h_[i] = (h_[i] & ~mask) | (g[i] & mask);

        uint32_t w0 = h_[0] | (h_[1] << 26);
        uint32_t w1 = (h_[1] >> 6) | (h_[2] << 20);
        uint32_t w2 = (h_[2] >> 12) | (h_[3] << 14);
        uint32_t w3 = (h_[3] >> 18) | (h_[4] << 8);
        uint64_t f = uint64_t(w0) + pad_[0]; storeLE(tag, uint32_t(f));
        f = uint64_t(w1) + pad_[1] + (f >> 32); storeLE(tag + 4, uint32_t(f));
        f = uint64_t(w2) + pad_[2] + (f >> 32); storeLE(tag + 8, uint32_t(f));
        f = uint64_t(w3) + pad_[3] + (f >> 32); storeLE(tag + 12, uint32_t(f));
    }

private:
    void absorb(const uint8_t* m, uint32_t hibit) {
        uint32_t s1 = r_[1] * 5, s2 = r_[2] * 5, s3 = r_[3] * 5, s4 = r_[4] * 5;
        uint32_t h0 = h_[0] + (loadLE(m) & 0x3ffffff);
        uint32_t h1 = h_[1] + ((loadLE(m + 3) >> 2) & 0x3ffffff);
        uint32_t h2 = h_[2] + ((loadLE(m + 6) >> 4) & 0x3ffffff);
        uint32_t h3 = h_[3] + ((loadLE(m + 9) >> 6) & 0x3ffffff);
        uint32_t h4 = h_[4] + ((loadLE(m + 12) >> 8) | hibit);
        uint64_t d0 = uint64_t(h0) * r_[0] + uint64_t(h1) * s4 + uint64_t(h2) * s3 + uint64_t(h3) * s2 + uint64_t(h4) * s1;
        uint64_t d1 = uint64_t(h0) * r_[1] + uint64_t(h1) * r_[0] + uint64_t(h2) * s4 + uint64_t(h3) * s3 + uint64_t(h4) * s2;
        uint64_t d2 = uint64_t(h0) * r_[2] + uint64_t(h1) * r_[1] + uint64_t(h2) * r_[0] + uint64_t(h3) * s4 + uint64_t(h4) * s3;
        uint64_t d3 = uint64_t(h0) * r_[3] + uint64_t(h1) * r_[2] + uint64_t(h2) * r_[1] + uint64_t(h3) * r_[0] + uint64_t(h4) * s4;
        uint64_t d4 = uint64_t(h0) * r_[4] + uint64_t(h1) * r_[3] + uint64_t(h2) * r_[2] + uint64_t(h3) * r_[1] + uint64_t(h4) * r_[0];
        uint32_t c = uint32_t(d0 >> 26); h0 = uint32_t(d0) & 0x3ffffff;
        d1 += c; c = uint32_t(d1 >> 26); h1 = uint32_t(d1) & 0x3ffffff;
        d2 += c; c = uint32_t(d2 >> 26); h2 = uint32_t(d2) & 0x3ffffff;
        d3 += c; c = uint32_t(d3 >> 26); h3 = uint32_t(d3) & 0x3ffffff;
        d4 += c; c = uint32_t(d4 >> 26); h4 = uint32_t(d4) & 0x3ffffff;
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
        h1 += c;
        h_[0] = h0; h_[1] = h1; h_[2] = h2; h_[3] = h3; h_[4] = h4;
    }

    uint32_t r_[5];
    uint32_t pad_[4];
    uint32_t h_[5];
    uint8_t block_[16];
    size_t fill_ = 0;
};

void polyPadding(Poly1305& p, size_t length) {
    static const uint8_t zero[16] = {};
    if (length % 16) p.update(zero, 16 - length % 16);
}

}  // namespace

void sha256(const uint8_t* data, size_t length, uint8_t out[32]) {
    Sha256 h;
    h.update(data, length);
    h.finish(out);
}

void hmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* data, size_t length, uint8_t out[32]) {
    uint8_t k[64] = {};
    if (keyLength > 64) {
        sha256(key, keyLength, k);
    } else {
        std::memcpy(k, key, keyLength);
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }
    Sha256 inner;
    inner.update(ipad, 64);
    inner.update(data, length);
    uint8_t innerHash[32];
    inner.finish(innerHash);
    Sha256 outer;
    outer.update(opad, 64);
    outer.update(innerHash, 32);
    outer.finish(out);
}

void hkdfSha256(const uint8_t* ikm, size_t ikmLength, const uint8_t* salt, size_t saltLength, const uint8_t* info,
                size_t infoLength, uint8_t* out, size_t outLength) {
    uint8_t prk[32];
    hmacSha256(salt, saltLength, ikm, ikmLength, prk);
    uint8_t block[32 + 255 + 1];
    size_t blockLength = 0;
    uint8_t t[32];
    for (uint8_t i = 1; outLength; i++) {
        std::memcpy(block + blockLength, info, infoLength);
        block[blockLength + infoLength] = i;
        hmacSha256(prk, 32, block, blockLength + infoLength + 1, t);
        size_t take = outLength < 32 ? outLength : 32;
        std::memcpy(out, t, take);
        out += take;
        outLength -= take;
        std::memcpy(block, t, 32);
        blockLength = 32;
    }
}

void chacha20Poly1305Seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* aad, size_t aadLength,
                          const uint8_t* plain, size_t length, uint8_t* out, uint8_t tag[16]) {
    uint8_t block[64];
    chacha20Block(key, 0, nonce, block);
    Poly1305 mac(block);
    for (size_t i = 0; i < length; i++) {
        if (i % 64 == 0) chacha20Block(key, uint32_t(i / 64) + 1, nonce, block);
        out[i] = plain[i] ^ block[i % 64];
    }
    mac.update(aad, aadLength);
    polyPadding(mac, aadLength);
    mac.update(out, length);
    polyPadding(mac, length);
    uint8_t lengths[16];
    storeLE64(lengths, aadLength);
    storeLE64(lengths + 8, length);
    mac.update(lengths, 16);
    mac.finish(tag);
}

void respondersKey(const uint8_t shared[32], const uint8_t* group, size_t groupLength, uint8_t key[32]) {
    static const char label[] = "HELPA-RESPONDERS-1";
    hkdfSha256(shared, 32, group, groupLength, reinterpret_cast<const uint8_t*>(label), sizeof label - 1, key, 32);
}

void respondersNonce(uint32_t unit, uint16_t request, uint8_t part, const uint8_t salt[5], uint8_t nonce[12]) {
    nonce[0] = uint8_t(unit >> 24);
    nonce[1] = uint8_t(unit >> 16);
    nonce[2] = uint8_t(unit >> 8);
    nonce[3] = uint8_t(unit);
    nonce[4] = uint8_t(request >> 8);
    nonce[5] = uint8_t(request);
    nonce[6] = part;
    std::memcpy(nonce + 7, salt, kSealSaltBytes);
}

size_t sealForResponders(const uint8_t key[32], const uint8_t* group, size_t groupLength, uint32_t unit,
                         uint16_t request, uint8_t part, const uint8_t salt[5], const uint8_t* inner,
                         size_t innerLength, uint8_t* out, size_t cap) {
    size_t need = 1 + kSealOverhead + innerLength;
    if (cap < need) return 0;
    out[0] = kFormatVersion << 4;
    out[1] = uint8_t(unit);
    out[2] = uint8_t(unit >> 8);
    out[3] = uint8_t(unit >> 16);
    out[4] = uint8_t(unit >> 24);
    out[5] = uint8_t(request);
    out[6] = uint8_t(request >> 8);
    out[7] = part;
    std::memcpy(out + 8, salt, kSealSaltBytes);
    uint8_t nonce[kSealNonceBytes];
    respondersNonce(unit, request, part, salt, nonce);
    chacha20Poly1305Seal(key, nonce, group, groupLength, inner, innerLength, out + 8 + kSealSaltBytes,
                         out + 8 + kSealSaltBytes + innerLength);
    return need;
}

}  // namespace helpandi
