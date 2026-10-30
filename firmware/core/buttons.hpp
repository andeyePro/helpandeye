// The box's buttons: debouncing, press, long press, and the countdown to Help with its cancel.
// Fed the raw button levels every few milliseconds; says what to send and what to sound.
//
// The countdown follows HelpCountdown.swift and the watch's rule for a press during it: the
// countdown stops, I'm OK then sends nothing, and Help or Need a hand go at once. A press that
// began before the end counts as during it, even when debouncing confirms it after.
//
// I'm OK never goes while Help or Need a hand is held, in the same poll as either, or within
// kNoOKAfterUrgentMs of either: someone who has fallen on the box must not cancel their own call.
//
// UNTESTED ON HARDWARE. Host tests only (firmware/test).
#pragma once

#include <cstddef>
#include <cstdint>

#include "frame.hpp"

namespace helpandi {

// Bit positions in the levels passed to ButtonMachine::update.
enum class Input : uint8_t { red = 0, amber = 1, green = 2, prg = 3 };
constexpr size_t kInputCount = 4;

enum class Action : uint8_t { none, red, amber, green, countdown };

struct Binding {
    // As soon as the press is certain (after debouncing), not on release: someone may keep
    // holding the button.
    Action onPress;
    // On release before the long-press time, when the press itself did nothing.
    Action onShort;
    // Once, when held for the long-press time.
    Action onLong;
};

struct Layout {
    Binding bindings[kInputCount];
    uint32_t debounceMs;
    uint32_t longPressMs;
    uint32_t countdownMs;
};

// Red, amber and green each send at once when pressed. The PRG button does nothing.
Layout threeButtons();

// A plain Heltec with only its PRG button, for development: a short press starts the countdown
// to Help, which any press stops; a long press sends I'm OK. Not for the people Help&I is for.
Layout prgOnly();

struct Event {
    enum class Type : uint8_t {
        // Send a call of this colour now.
        send,
        countdownStarted,
        // Every ten seconds of the countdown: a beep, where the watch taps the wrist.
        tap,
        // Thirty seconds left: the spoken or shown warning.
        warn,
        // A press stopped the countdown. Nothing is sent for it.
        countdownStopped,
    };
    Type type;
    Colour colour;
};

constexpr uint64_t kNoOKAfterUrgentMs = 3000;

class ButtonMachine {
public:
    // Room to pass to `update`. Everything but a tap or the warning is always kept: those are
    // what a late call may leave out of a long countdown.
    static constexpr size_t kMaxEvents = 16;
    // The most events other than taps and the warning one call can give: the countdown's Help,
    // and for each button a stop and its own call.
    static constexpr size_t kMaxActionEvents = 1 + 2 * kInputCount;

    // `wokenBy` has bit Input set for each button that woke the board from deep sleep: that press
    // counts at once, even if already released. Zero for a cold power-on, when a button already
    // held counts only after it has been seen released.
    explicit ButtonMachine(const Layout& layout, uint8_t wokenBy = 0);

    // `levels` has bit Input set while that button is pressed. Writes what is due since the last
    // call to `out`, which must have room for kMaxEvents, and returns how many. A late call does
    // everything missed, the countdown first, so a press after it ended still leaves Help sent.
    size_t update(uint64_t nowMs, uint8_t levels, Event* out);

    bool counting() const { return counting_; }
    // Whole seconds left on the countdown, as shown.
    uint32_t secondsLeft(uint64_t nowMs) const;

private:
    struct State {
        bool raw = false;
        uint64_t rawSince = 0;
        bool pressed = false;
        uint64_t pressedAt = 0;
        // A button seen held at start-up, or stuck, counts only after it has been seen released.
        bool armed = false;
        bool longDone = false;
        // The rest of a press that stopped a countdown, or did its work on press, is ignored.
        bool swallow = false;
    };

    void press(State& s, const Binding& b, uint64_t nowMs);
    void send(Colour colour, uint64_t nowMs);
    void act(Action a, uint64_t nowMs);
    void emit(Event::Type type, Colour colour = Colour::red);
    void countdownEvents(uint64_t from, uint64_t to);

    Layout layout_;
    State inputs_[kInputCount];
    uint8_t wokenBy_;
    // Buttons bound to Help or Need a hand.
    uint8_t urgentInputs_ = 0;
    bool urgentSeen_ = false;
    uint64_t urgentAt_ = 0;
    bool counting_ = false;
    uint64_t countdownStart_ = 0;
    uint64_t lastUpdate_ = 0;
    Event* out_ = nullptr;
    size_t outCount_ = 0;
};

}  // namespace helpandi
