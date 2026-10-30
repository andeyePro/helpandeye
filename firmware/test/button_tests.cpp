// The countdown cases mirror HelpCountdownTests.swift and MANUAL-TESTS section 40 (the watch).
#include "../core/buttons.hpp"
#include "test.hpp"

using namespace helpandi;

namespace {

constexpr uint8_t kRed = 1 << uint8_t(Input::red);
constexpr uint8_t kAmber = 1 << uint8_t(Input::amber);
constexpr uint8_t kGreen = 1 << uint8_t(Input::green);
constexpr uint8_t kPrg = 1 << uint8_t(Input::prg);

struct Run {
    ButtonMachine m;
    Event events[64];
    size_t count = 0;

    explicit Run(const Layout& l) : m(l) {}

    // Polls every 5 ms from `from` to `to` with these buttons held.
    void hold(uint64_t from, uint64_t to, uint8_t levels) {
        for (uint64_t t = from; t <= to; t += 5) at(t, levels);
    }
    void at(uint64_t t, uint8_t levels) {
        Event e[ButtonMachine::kMaxEvents];
        size_t n = m.update(t, levels, e);
        for (size_t i = 0; i < n && count < 64; i++) events[count++] = e[i];
    }
    size_t sends(Colour c) const {
        size_t n = 0;
        for (size_t i = 0; i < count; i++)
            if (events[i].type == Event::Type::send && events[i].colour == c) n++;
        return n;
    }
    size_t of(Event::Type type) const {
        size_t n = 0;
        for (size_t i = 0; i < count; i++)
            if (events[i].type == type) n++;
        return n;
    }
};

// Red, amber and green on press, and PRG starting the countdown, so presses during it can be tried.
Layout withCountdown() {
    Layout l = threeButtons();
    l.bindings[size_t(Input::prg)] = {Action::none, Action::countdown, Action::none};
    return l;
}

// A short press of PRG from 1000 ms, released at 1105: the countdown starts once the release is
// certain, at 1135.
constexpr uint64_t kStart = 1135;

void startCountdown(Run& r) {
    r.hold(1000, 1100, kPrg);
    r.hold(1105, 1200, 0);
}

}  // namespace

TEST(aPressSendsAtOnceAndOnlyOnce) {
    Run r(threeButtons());
    r.hold(0, 100, 0);
    r.hold(105, 130, kRed);
    CHECK(r.count == 0);  // not yet certain
    r.hold(135, 135, kRed);
    CHECK(r.sends(Colour::red) == 1);  // on the press, not on release
    r.hold(140, 10000, kRed);          // held for ten seconds: still one call
    r.hold(10005, 10100, 0);
    CHECK(r.sends(Colour::red) == 1);
    CHECK(r.count == 1);
}

TEST(bounceShorterThanTheDebounceTimeIsNotAPress) {
    Run r(threeButtons());
    r.hold(0, 100, 0);
    for (uint64_t t = 105; t < 300; t += 20) {
        r.at(t, kAmber);
        r.at(t + 10, 0);
    }
    CHECK(r.count == 0);
    r.hold(300, 340, kAmber);
    CHECK(r.sends(Colour::amber) == 1);
}

TEST(aButtonHeldAtStartUpIsNeverACall) {
    Run r(threeButtons());
    r.hold(0, 5000, kRed | kGreen);  // stuck, or leant on while the box was plugged in
    CHECK(r.count == 0);
    r.hold(5005, 5100, 0);
    CHECK(r.count == 0);
    r.hold(5105, 5200, kRed);
    CHECK(r.sends(Colour::red) == 1);
}

TEST(eachButtonSendsItsOwnColour) {
    Run r(threeButtons());
    r.hold(0, 100, 0);
    r.hold(105, 200, kGreen);
    r.hold(205, 300, 0);
    r.hold(305, 400, kAmber);
    CHECK(r.sends(Colour::green) == 1 && r.sends(Colour::amber) == 1 && r.sends(Colour::red) == 0);
}

TEST(theCountdownTapsWarnsAndSendsHelp) {
    Run r(prgOnly());
    r.hold(0, 100, 0);
    startCountdown(r);
    CHECK(r.of(Event::Type::countdownStarted) == 1);
    CHECK(r.m.counting());
    CHECK(r.m.secondsLeft(kStart + 500) == 60);
    CHECK(r.m.secondsLeft(kStart + 1000) == 59);
    r.hold(1205, kStart + 59990, 0);
    CHECK(r.of(Event::Type::tap) == 5);
    CHECK(r.of(Event::Type::warn) == 1);
    CHECK(r.sends(Colour::red) == 0);
    r.hold(kStart + 59995, kStart + 60100, 0);
    CHECK(r.sends(Colour::red) == 1);
    CHECK(!r.m.counting());
    CHECK(r.events[r.count - 1].type == Event::Type::send);
}

TEST(theWarningComesWithTheThirtySecondTap) {
    Run r(prgOnly());
    r.hold(0, 100, 0);
    startCountdown(r);
    r.hold(1205, kStart + 30000, 0);
    CHECK(r.of(Event::Type::tap) == 3);
    CHECK(r.events[r.count - 2].type == Event::Type::tap);
    CHECK(r.events[r.count - 1].type == Event::Type::warn);
}

TEST(aLateWakeDoesEverythingMissedWithHelpLast) {
    Run r(prgOnly());
    r.hold(0, 100, 0);
    startCountdown(r);
    size_t before = r.count;
    r.at(kStart + 61000, 0);
    CHECK(r.count - before == 7);  // five taps, the warning, then Help
    CHECK(r.events[r.count - 1].type == Event::Type::send && r.events[r.count - 1].colour == Colour::red);
}

TEST(aPressStopsTheCountdownAndOnlyImOKSendsNothing) {
    Run green(withCountdown());
    green.hold(0, 100, 0);
    startCountdown(green);
    green.hold(5000, 5100, kGreen);
    green.hold(5105, 70000, 0);
    CHECK(green.of(Event::Type::countdownStopped) == 1);
    CHECK(green.count == 2);  // started, stopped: nothing sent

    Run amber(withCountdown());
    amber.hold(0, 100, 0);
    startCountdown(amber);
    amber.hold(5000, 5100, kAmber);
    amber.hold(5105, 70000, 0);
    CHECK(amber.of(Event::Type::countdownStopped) == 1);
    CHECK(amber.sends(Colour::amber) == 1 && amber.sends(Colour::red) == 0);

    Run red(withCountdown());
    red.hold(0, 100, 0);
    startCountdown(red);
    red.hold(5000, 5100, kRed);
    red.hold(5105, 70000, 0);
    CHECK(red.sends(Colour::red) == 1);  // Help at once, and not again at the end
}

TEST(onAPlainHeltecAPressOfPRGStopsTheCountdown) {
    Run r(prgOnly());
    r.hold(0, 100, 0);
    startCountdown(r);
    r.hold(5000, 9000, kPrg);  // held past the long-press time: still only a stop
    r.hold(9005, 70000, 0);
    CHECK(r.of(Event::Type::countdownStopped) == 1);
    CHECK(r.of(Event::Type::countdownStarted) == 1);
    CHECK(r.sends(Colour::red) == 0 && r.sends(Colour::green) == 0);
}

TEST(aLongPressOfPRGSendsImOKOnce) {
    Run r(prgOnly());
    r.hold(0, 100, 0);
    r.hold(105, 3000, kPrg);
    CHECK(r.count == 0);
    r.hold(3005, 3200, kPrg);
    CHECK(r.sends(Colour::green) == 1);
    r.hold(3205, 8000, kPrg);
    r.hold(8005, 8100, 0);
    CHECK(r.sends(Colour::green) == 1);
    CHECK(r.of(Event::Type::countdownStarted) == 0);
}

TEST(aPressAsTheCountdownEndsStillLeavesHelpSent) {
    Run r(withCountdown());
    r.hold(0, 100, 0);
    startCountdown(r);
    r.hold(1205, kStart + 59965, 0);
    // I'm OK pressed and certain in the same poll as the end: Help has gone, then I'm OK goes too.
    r.hold(kStart + 59970, kStart + 60000, kGreen);
    CHECK(r.sends(Colour::red) == 1);
    CHECK(r.sends(Colour::green) == 1);
    CHECK(r.of(Event::Type::countdownStopped) == 0);
}
