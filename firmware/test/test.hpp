// A very small test runner, so the host tests need nothing but a C++17 compiler.
#pragma once

#include <cstdio>
#include <cstring>

namespace test {

struct Case {
    const char* name;
    void (*run)();
    Case* next;
};

inline Case*& cases() {
    static Case* head = nullptr;
    return head;
}

inline int& failures() {
    static int n = 0;
    return n;
}

struct Register {
    Register(Case* c) {
        c->next = cases();
        cases() = c;
    }
};

inline void fail(const char* file, int line, const char* what) {
    std::printf("  FAIL %s:%d: %s\n", file, line, what);
    failures()++;
}

}  // namespace test

#define TEST(name)                                                  \
    static void name();                                             \
    static test::Case name##_case{#name, name, nullptr};            \
    static test::Register name##_register{&name##_case};            \
    static void name()

#define CHECK(cond) \
    do {            \
        if (!(cond)) test::fail(__FILE__, __LINE__, #cond); \
    } while (0)

#define CHECK_BYTES(actual, length, expected)                                                         \
    do {                                                                                              \
        if ((length) != sizeof(expected) || std::memcmp((actual), (expected), sizeof(expected)) != 0) \
            test::fail(__FILE__, __LINE__, "bytes differ: " #actual " vs " #expected);                \
    } while (0)
