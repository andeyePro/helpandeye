#include <cstdint>

#include "test.hpp"

int main() {
    int run = 0;
    for (test::Case* c = test::cases(); c; c = c->next) {
        int before = test::failures();
        c->run();
        std::printf("%s %s\n", test::failures() == before ? "ok  " : "FAIL", c->name);
        run++;
    }
    std::printf("%d tests, %d failed checks\n", run, test::failures());
    return test::failures() == 0 ? 0 : 1;
}

// TweetNaCl's randomness, fixed so the tests' keys are the same every run.
extern "C" void randombytes(unsigned char* out, unsigned long long n) {
    static uint32_t state = 0x48656c70;
    for (unsigned long long i = 0; i < n; i++) {
        state = state * 1664525u + 1013904223u;
        out[i] = uint8_t(state >> 24);
    }
}
