#include "buttons.hpp"

namespace helpandi {

namespace {
constexpr uint64_t kTapEveryMs = 10000;
constexpr uint64_t kWarnLeftMs = 30000;
constexpr uint32_t kCountdownMs = 60000;

bool urgent(Action a) { return a == Action::red || a == Action::amber; }
}  // namespace

// A call made after the whole of the usual countdown still keeps every tap and the warning.
static_assert((kCountdownMs - 1) / kTapEveryMs + 1 + ButtonMachine::kMaxActionEvents <= ButtonMachine::kMaxEvents,
              "room for the countdown's taps, its warning and every action in one call");

Layout threeButtons() {
    Layout l{};
    l.bindings[size_t(Input::red)] = {Action::red, Action::none, Action::none};
    l.bindings[size_t(Input::amber)] = {Action::amber, Action::none, Action::none};
    l.bindings[size_t(Input::green)] = {Action::green, Action::none, Action::none};
    l.bindings[size_t(Input::prg)] = {Action::none, Action::none, Action::none};
    l.debounceMs = 30;
    l.longPressMs = 3000;
    l.countdownMs = kCountdownMs;
    return l;
}

Layout prgOnly() {
    Layout l{};
    l.bindings[size_t(Input::red)] = {Action::none, Action::none, Action::none};
    l.bindings[size_t(Input::amber)] = {Action::none, Action::none, Action::none};
    l.bindings[size_t(Input::green)] = {Action::none, Action::none, Action::none};
    l.bindings[size_t(Input::prg)] = {Action::none, Action::countdown, Action::green};
    l.debounceMs = 30;
    l.longPressMs = 3000;
    l.countdownMs = kCountdownMs;
    return l;
}

ButtonMachine::ButtonMachine(const Layout& layout, uint8_t wokenBy) : layout_(layout), wokenBy_(wokenBy) {
    for (size_t i = 0; i < kInputCount; i++) {
        const Binding& b = layout_.bindings[i];
        if (urgent(b.onPress) || urgent(b.onShort) || urgent(b.onLong)) urgentInputs_ |= uint8_t(1 << i);
    }
}

void ButtonMachine::emit(Event::Type type, Colour colour) {
    bool droppable = type == Event::Type::tap || type == Event::Type::warn;
    if (outCount_ < kMaxEvents - (droppable ? kMaxActionEvents : 0)) out_[outCount_++] = Event{type, colour};
}

void ButtonMachine::send(Colour colour, uint64_t nowMs) {
    if (colour != Colour::green) {
        urgentSeen_ = true;
        urgentAt_ = nowMs;
    } else if (urgentSeen_ && nowMs - urgentAt_ < kNoOKAfterUrgentMs) {
        return;
    }
    emit(Event::Type::send, colour);
}

void ButtonMachine::act(Action a, uint64_t nowMs) {
    switch (a) {
    case Action::red: send(Colour::red, nowMs); break;
    case Action::amber: send(Colour::amber, nowMs); break;
    case Action::green: send(Colour::green, nowMs); break;
    case Action::countdown:
        if (counting_) break;
        counting_ = true;
        countdownStart_ = nowMs;
        emit(Event::Type::countdownStarted);
        break;
    case Action::none: break;
    }
}

void ButtonMachine::countdownEvents(uint64_t from, uint64_t to) {
    uint64_t length = layout_.countdownMs;
    uint64_t a = from > countdownStart_ ? from - countdownStart_ : 0;
    uint64_t b = to > countdownStart_ ? to - countdownStart_ : 0;
    for (uint64_t mark = kTapEveryMs; mark < length; mark += kTapEveryMs) {
        if (!(a < mark && mark <= b)) continue;
        emit(Event::Type::tap);
        if (length >= kWarnLeftMs && mark == length - kWarnLeftMs) emit(Event::Type::warn);
    }
    if (a < length && length <= b) {
        counting_ = false;
        send(Colour::red, to);
    }
}

void ButtonMachine::press(State& s, const Binding& b, uint64_t nowMs) {
    s.pressed = true;
    s.longDone = false;
    // A button held since start-up, or stuck, keeps `swallow` and never makes a call.
    s.swallow = true;
    if (s.armed && counting_) {
        counting_ = false;
        emit(Event::Type::countdownStopped);
        Action first = b.onPress != Action::none ? b.onPress : b.onShort;
        if (urgent(first)) act(first, nowMs);
    } else if (s.armed && b.onPress != Action::none) {
        act(b.onPress, nowMs);
    } else if (s.armed) {
        s.swallow = false;
    }
}

size_t ButtonMachine::update(uint64_t nowMs, uint8_t levels, Event* out) {
    out_ = out;
    outCount_ = 0;
    if (levels & urgentInputs_) {
        urgentSeen_ = true;
        urgentAt_ = nowMs;
    }
    if (counting_) {
        // A press that began before the end, certain only now, stops the countdown instead.
        uint64_t to = nowMs;
        for (size_t i = 0; i < kInputCount; i++) {
            const State& s = inputs_[i];
            bool raw = (levels >> i) & 1;
            if (s.armed && !s.pressed && raw && s.raw && nowMs - s.rawSince >= layout_.debounceMs && s.rawSince < to)
                to = s.rawSince;
        }
        countdownEvents(lastUpdate_, to);
    }
    lastUpdate_ = nowMs;

    for (size_t i = 0; i < kInputCount; i++) {
        State& s = inputs_[i];
        const Binding& b = layout_.bindings[i];
        bool raw = (levels >> i) & 1;
        if ((wokenBy_ >> i) & 1) {
            s.raw = true;
            s.rawSince = nowMs;
            s.armed = true;
            s.pressedAt = nowMs;
            press(s, b, nowMs);
        }
        if (raw != s.raw) {
            s.raw = raw;
            s.rawSince = nowMs;
        }
        bool stable = nowMs - s.rawSince >= layout_.debounceMs;

        if (stable && raw && !s.pressed) {
            s.pressedAt = s.rawSince;
            press(s, b, nowMs);
        } else if (stable && !raw && s.pressed) {
            s.pressed = false;
            if (s.armed && !s.swallow && !s.longDone) act(b.onShort, nowMs);
        }
        if (stable && !raw) s.armed = true;

        if (s.pressed && !s.swallow && !s.longDone && b.onLong != Action::none &&
            nowMs - s.pressedAt >= layout_.longPressMs) {
            s.longDone = true;
            act(b.onLong, nowMs);
        }
    }
    wokenBy_ = 0;
    return outCount_;
}

uint32_t ButtonMachine::secondsLeft(uint64_t nowMs) const {
    if (!counting_) return 0;
    uint64_t elapsed = nowMs - countdownStart_;
    if (elapsed >= layout_.countdownMs) return 0;
    return uint32_t((layout_.countdownMs - elapsed + 999) / 1000);
}

}  // namespace helpandi
