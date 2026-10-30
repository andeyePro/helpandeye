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

    explicit Run(const Layout& l, uint8_t wokenBy = 0) : m(l, wokenBy) {}

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

TEST(aPressThatBeganBeforeTheEndStopsTheCountdown) {
    Run r(withCountdown());
    r.hold(0, 100, 0);
    startCountdown(r);
    r.hold(1205, kStart + 59965, 0);
    // I'm OK pressed 30 ms before the end, certain only as it ends: a press during the countdown.
    r.hold(kStart + 59970, kStart + 60100, kGreen);
    CHECK(r.of(Event::Type::countdownStopped) == 1);
    CHECK(r.sends(Colour::red) == 0 && r.sends(Colour::green) == 0);
    CHECK(!r.m.counting());

    // The same when the call that confirms it comes late.
    Run late(withCountdown());
    late.hold(0, 100, 0);
    startCountdown(late);
    late.hold(1205, kStart + 59965, 0);
    late.at(kStart + 59970, kGreen);
    late.at(kStart + 61000, kGreen);
    CHECK(late.of(Event::Type::countdownStopped) == 1);
    CHECK(late.sends(Colour::red) == 0 && late.sends(Colour::green) == 0);
}

TEST(aPressAfterTheEndLeavesHelpSentAndImOKDoesNotFollowIt) {
    Run r(withCountdown());
    r.hold(0, 100, 0);
    startCountdown(r);
    r.hold(1205, kStart + 59995, 0);
    r.hold(kStart + 60000, kStart + 60100, kGreen);
    CHECK(r.sends(Colour::red) == 1);
    CHECK(r.sends(Colour::green) == 0);
    CHECK(r.of(Event::Type::countdownStopped) == 0);
}

TEST(allThreePressedAtOnceSendHelpAndNeedAHandButNeverImOK) {
    Run r(threeButtons());
    r.hold(0, 100, 0);
    r.hold(105, 2000, kRed | kAmber | kGreen);
    r.hold(2005, 2100, 0);
    CHECK(r.sends(Colour::red) == 1 && r.sends(Colour::amber) == 1);
    CHECK(r.sends(Colour::green) == 0);
}

TEST(fallingOnRedAndGreenSendsOnlyHelp) {
    // Green touched first: red is already down, though not yet certain, when green is.
    Run r(threeButtons());
    r.hold(0, 100, 0);
    r.hold(105, 110, kGreen);
    r.hold(115, 20000, kGreen | kRed);
    // Rolling off red but still on green: green's press was used up.
    r.hold(20005, 30000, kGreen);
    r.hold(30005, 30100, 0);
    CHECK(r.sends(Colour::red) == 1);
    CHECK(r.sends(Colour::green) == 0);

    // Red touched first.
    Run redFirst(threeButtons());
    redFirst.hold(0, 100, 0);
    redFirst.hold(105, 110, kRed);
    redFirst.hold(115, 5000, kGreen | kRed);
    redFirst.hold(5005, 5100, 0);
    CHECK(redFirst.sends(Colour::red) == 1 && redFirst.sends(Colour::green) == 0);
}

TEST(imOKWaitsUntilHelpOrNeedAHandHasBeenLetGoForAWhile) {
    Run r(threeButtons());
    r.hold(0, 100, 0);
    r.hold(105, 1000, kAmber);
    // Green pressed while amber is still held.
    r.hold(1005, 2000, kAmber | kGreen);
    r.hold(2005, 2100, 0);
    // Green again, certain just inside the time after amber was last seen held.
    const uint64_t letGo = 2000, until = letGo + kNoOKAfterUrgentMs;
    r.hold(2105, until - 40, 0);
    r.hold(until - 35, until + 500, kGreen);
    r.hold(until + 505, until + 600, 0);
    CHECK(r.sends(Colour::amber) == 1 && r.sends(Colour::green) == 0);
    // After it, I'm OK goes.
    r.hold(until + 605, until + 700, kGreen);
    CHECK(r.sends(Colour::green) == 1);
}

TEST(theButtonThatWokeTheBoardCountsAtOnce) {
    // Already let go by the first call: a quick press that woke the board from deep sleep.
    Run tapped(threeButtons(), kRed);
    tapped.hold(400, 500, 0);
    CHECK(tapped.sends(Colour::red) == 1);
    CHECK(tapped.count == 1);

    // Still held: one call, not one now and another once it has been seen released.
    Run held(threeButtons(), kRed);
    held.hold(400, 5000, kRed);
    held.hold(5005, 5100, 0);
    CHECK(held.sends(Colour::red) == 1);
    CHECK(held.count == 1);

    // Only that button: another held from the start is still ignored.
    Run other(threeButtons(), kAmber);
    other.hold(400, 5000, kAmber | kRed);
    other.hold(5005, 5100, 0);
    CHECK(other.sends(Colour::amber) == 1 && other.sends(Colour::red) == 0);
}

TEST(aLongCountdownNeverLosesHelp) {
    Layout l = prgOnly();
    l.countdownMs = 300000;
    Run r(l);
    r.hold(0, 100, 0);
    startCountdown(r);
    // A very late call: 29 taps, the warning and Help are due, more than there is room for.
    Event e[ButtonMachine::kMaxEvents];
    size_t n = r.m.update(kStart + 301000, 0, e);
    CHECK(n == ButtonMachine::kMaxEvents - ButtonMachine::kMaxActionEvents + 1);
    CHECK(e[n - 1].type == Event::Type::send && e[n - 1].colour == Colour::red);
    CHECK(!r.m.counting());
}

TEST(aLateCallFullOfTapsStillKeepsAButtonsCall) {
    // Need a hand on release, pressed before the countdown starts and let go during it.
    Layout l = withCountdown();
    l.bindings[size_t(Input::amber)] = {Action::none, Action::amber, Action::none};
    l.countdownMs = 300000;
    Run r(l);
    r.hold(0, 100, 0);
    r.hold(105, 900, kAmber);
    r.hold(1000, 1100, kPrg | kAmber);
    r.hold(1105, 1200, kAmber);
    CHECK(r.m.counting());
    r.at(1205, 0);
    Event e[ButtonMachine::kMaxEvents];
    size_t n = r.m.update(kStart + 301000, 0, e);
    CHECK(n == ButtonMachine::kMaxEvents - ButtonMachine::kMaxActionEvents + 2);
    CHECK(e[n - 2].type == Event::Type::send && e[n - 2].colour == Colour::red);
    CHECK(e[n - 1].type == Event::Type::send && e[n - 1].colour == Colour::amber);
}
