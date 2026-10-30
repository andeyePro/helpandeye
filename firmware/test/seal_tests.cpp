// The sealing primitives against their RFC vectors, Poly1305 against TweetNaCl's on odd lengths,
// and the ForResponders layout (nonce and outer frame) byte for byte against ForResponders.swift.
#include <cstring>

#include "../core/seal.hpp"
#include "test.hpp"
extern "C" {
#include "tweetnacl.h"
}

using namespace helpandi;

namespace {

void unhex(const char* hex, uint8_t* out, size_t n) {
    auto nibble = [](char c) { return uint8_t(c >= 'a' ? c - 'a' + 10 : c - '0'); };
    for (size_t i = 0; i < n; i++) out[i] = uint8_t(nibble(hex[2 * i]) << 4 | nibble(hex[2 * i + 1]));
}

bool matchesHex(const uint8_t* actual, size_t n, const char* hex) {
    uint8_t expected[256];
    unhex(hex, expected, n);
    return std::memcmp(actual, expected, n) == 0;
}

}  // namespace

TEST(sha256_abc) {
    uint8_t out[32];
    sha256(reinterpret_cast<const uint8_t*>("abc"), 3, out);
    CHECK(matchesHex(out, 32, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
}

TEST(sha256_empty_and_two_blocks) {
    uint8_t out[32];
    sha256(nullptr, 0, out);
    CHECK(matchesHex(out, 32, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    const char* s = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    sha256(reinterpret_cast<const uint8_t*>(s), std::strlen(s), out);
    CHECK(matchesHex(out, 32, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
}

TEST(hmac_sha256_rfc4231_case2) {
    uint8_t out[32];
    const char* data = "what do ya want for nothing?";
    hmacSha256(reinterpret_cast<const uint8_t*>("Jefe"), 4, reinterpret_cast<const uint8_t*>(data), std::strlen(data), out);
    CHECK(matchesHex(out, 32, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"));
}

TEST(hkdf_sha256_rfc5869_case1) {
    uint8_t ikm[22], salt[13], info[10], out[42];
    std::memset(ikm, 0x0b, sizeof ikm);
    for (int i = 0; i < 13; i++) salt[i] = uint8_t(i);
    for (int i = 0; i < 10; i++) info[i] = uint8_t(0xf0 + i);
    hkdfSha256(ikm, sizeof ikm, salt, sizeof salt, info, sizeof info, out, sizeof out);
    CHECK(matchesHex(out, 42, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"));
}

TEST(chacha20_poly1305_rfc8439_aead) {
    const char* text =
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen "
        "would be it.";
    uint8_t key[32], nonce[12], aad[12];
    for (int i = 0; i < 32; i++) key[i] = uint8_t(0x80 + i);
    unhex("070000004041424344454647", nonce, 12);
    unhex("50515253c0c1c2c3c4c5c6c7", aad, 12);
    uint8_t out[114], tag[16];
    chacha20Poly1305Seal(key, nonce, aad, 12, reinterpret_cast<const uint8_t*>(text), 114, out, tag);
    CHECK(matchesHex(out, 114,
                     "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b"
                     "1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
                     "3ff4def08e4b7a9de576d26586cec64b6116"));
    CHECK(matchesHex(tag, 16, "1ae10b594f09e26a7e902ecbd0600691"));
}

TEST(chacha20_block_rfc8439) {
    uint8_t key[32], nonce[12], out[64];
    for (int i = 0; i < 32; i++) key[i] = uint8_t(i);
    unhex("000000090000004a00000000", nonce, 12);
    chacha20Block(key, 1, nonce, out);
    CHECK(matchesHex(out, 64,
                     "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2"
                     "b5129cd1de164eb9cbd083e8a2503c4e"));
}

TEST(poly1305_matches_tweetnacl_on_every_length) {
    // With no message, the tag is Poly1305 over the padded associated data and the two lengths,
    // keyed by ChaCha20's first block: TweetNaCl's Poly1305 must give the same from the same input.
    for (size_t n = 0; n < 50; n++) {
        uint8_t key[32], nonce[12] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}, aad[64], tag[16];
        for (int i = 0; i < 32; i++) key[i] = uint8_t(i * 7 + n);
        for (size_t i = 0; i < n; i++) aad[i] = uint8_t(i * 13 + n);
        chacha20Poly1305Seal(key, nonce, aad, n, nullptr, 0, nullptr, tag);
        uint8_t input[80] = {};
        std::memcpy(input, aad, n);
        size_t len = (n + 15) / 16 * 16;
        input[len] = uint8_t(n);
        len += 16;
        uint8_t block[64], mac[16];
        chacha20Block(key, 0, nonce, block);
        crypto_onetimeauth(mac, input, len, block);
        CHECK(std::memcmp(mac, tag, 16) == 0);
    }
}

TEST(responders_nonce_is_big_endian_unit_and_request_then_part_and_salt) {
    uint8_t salt[5] = {0xaa, 0xbb, 0xcc, 0xdd, 0xee}, nonce[12];
    respondersNonce(0x00011171, 0x0102, 3, salt, nonce);
    const uint8_t expected[12] = {0x00, 0x01, 0x11, 0x71, 0x01, 0x02, 0x03, 0xaa, 0xbb, 0xcc, 0xdd, 0xee};
    CHECK_BYTES(nonce, 12, expected);
}

TEST(responders_key_is_hkdf_with_group_salt_and_label) {
    uint8_t shared[32], group[16], key[32], expected[32];
    for (int i = 0; i < 32; i++) shared[i] = uint8_t(i);
    for (int i = 0; i < 16; i++) group[i] = uint8_t(0x10 + i);
    respondersKey(shared, group, 16, key);
    const char label[] = "HELPA-RESPONDERS-1";
    hkdfSha256(shared, 32, group, 16, reinterpret_cast<const uint8_t*>(label), sizeof label - 1, expected, 32);
    CHECK_BYTES(key, 32, expected);
}

TEST(sealed_frame_layout_matches_for_responders_swift) {
    // Header 0x10, unit, request and part little-endian, the salt, the ciphertext, the tag.
    uint8_t key[32], group[16], salt[5] = {5, 4, 3, 2, 1}, inner[3] = {0x12, 0x34, 0x56}, out[64];
    for (int i = 0; i < 32; i++) key[i] = uint8_t(0x40 + i);
    for (int i = 0; i < 16; i++) group[i] = uint8_t(0x20 + i);
    size_t n = sealForResponders(key, group, 16, 70001, 7, 2, salt, inner, 3, out, sizeof out);
    CHECK(n == 1 + kSealOverhead + 3);
    const uint8_t head[13] = {0x10, 0x71, 0x11, 0x01, 0x00, 0x07, 0x00, 0x02, 5, 4, 3, 2, 1};
    CHECK(std::memcmp(out, head, 13) == 0);
    uint8_t nonce[12], cipher[3], tag[16];
    respondersNonce(70001, 7, 2, salt, nonce);
    chacha20Poly1305Seal(key, nonce, group, 16, inner, 3, cipher, tag);
    CHECK(std::memcmp(out + 13, cipher, 3) == 0);
    CHECK(std::memcmp(out + 16, tag, 16) == 0);
    CHECK(sealForResponders(key, group, 16, 70001, 7, 2, salt, inner, 3, out, n - 1) == 0);
}
