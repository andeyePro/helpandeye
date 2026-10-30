// The box's buttons: debouncing, press, long press, and the countdown to Help with its cancel.
// Fed the raw button levels every few milliseconds; says what to send and what to sound.
//
// The countdown follows HelpCountdown.swift and the watch's rule for a press during it: the
// countdown stops, I'm OK then sends nothing, and Help or Need a hand go at once.
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

class ButtonMachine {
public:
    // Room to pass to `update`: enough for a whole missed countdown and every button at once.
    static constexpr size_t kMaxEvents = 16;

    explicit ButtonMachine(const Layout& layout);

    // `levels` has bit Input set while that button is pressed. Writes what is due since the last
    // call to `out`, which must have room for kMaxEvents, and returns how many. A late call does
    // everything missed, the countdown first, so a press at the moment it ends still leaves Help sent.
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

    void act(Action a, uint64_t nowMs);
    void emit(Event::Type type, Colour colour = Colour::red);
    void countdownEvents(uint64_t from, uint64_t to);

    Layout layout_;
    State inputs_[kInputCount];
    bool counting_ = false;
    uint64_t countdownStart_ = 0;
    uint64_t lastUpdate_ = 0;
    Event* out_ = nullptr;
    size_t outCount_ = 0;
};

}  // namespace helpandi
