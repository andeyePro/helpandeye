// Sealing a report for the responders alone (decision 12), as ForResponders.swift does: a key
// from X25519 agreement between the box and the responders' key through HKDF-SHA256, then
// ChaCha20-Poly1305 with the group's ID as the associated data. The X25519 step is the board's
// (MeshCore links a Curve25519); everything after it is here, so one implementation serves the
// board and the host tests.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

namespace helpandi {

constexpr size_t kSealKeyBytes = 32;
constexpr size_t kSealSaltBytes = 5;
constexpr size_t kSealNonceBytes = 12;
constexpr size_t kSealTagBytes = 16;
// Unit, request, part, the salt and the tag: what a sealed frame adds to its inner one after the
// header byte.
constexpr size_t kSealOverhead = 7 + kSealSaltBytes + kSealTagBytes;

void sha256(const uint8_t* data, size_t length, uint8_t out[32]);
void hmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* data, size_t length, uint8_t out[32]);
void hkdfSha256(const uint8_t* ikm, size_t ikmLength, const uint8_t* salt, size_t saltLength, const uint8_t* info,
                size_t infoLength, uint8_t* out, size_t outLength);

// One ChaCha20 keystream block (RFC 8439 section 2.3).
void chacha20Block(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12], uint8_t out[64]);

// RFC 8439 AEAD. `out` takes `length` bytes of ciphertext; the tag goes separately.
void chacha20Poly1305Seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* aad, size_t aadLength,
                          const uint8_t* plain, size_t length, uint8_t* out, uint8_t tag[16]);

// The responders' key for this box: HKDF of the X25519 shared secret with the group's ID as the
// salt and ForResponders' label as the info.
void respondersKey(const uint8_t shared[32], const uint8_t* group, size_t groupLength, uint8_t key[32]);

// The nonce: unit and request big-endian (the one place they are), the part, then the salt.
void respondersNonce(uint32_t unit, uint16_t request, uint8_t part, const uint8_t salt[5], uint8_t nonce[12]);

// A whole kind-0 frame: header, unit, request, part, the salt, then `inner` sealed and its tag.
// `inner` is the signed frame the caller made. Returns the bytes written, or 0 when `cap` is
// too small.
size_t sealForResponders(const uint8_t key[32], const uint8_t* group, size_t groupLength, uint32_t unit,
                         uint16_t request, uint8_t part, const uint8_t salt[5], const uint8_t* inner,
                         size_t innerLength, uint8_t* out, size_t cap);

}  // namespace helpandi
