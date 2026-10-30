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
