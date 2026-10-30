// Mirrors ResendTests.swift and the acknowledgement and settling rules in Requests.swift.
#include "../core/call.hpp"
#include "test.hpp"

using namespace helpandi;

namespace {
const uint32_t t0 = 1793000000;  // wall clock at the press
const uint64_t m0 = 5000;        // monotonic seconds at the press

OutgoingCall redCall() {
    OutgoingCall c(5, 1, Colour::red, t0, m0);
    c.mesh = RouteState::sent;
    return c;
}

AckFrame ack(uint32_t unit, uint16_t request, uint16_t who, uint32_t at) { return AckFrame{unit, request, who, at, {}}; }
}  // namespace

TEST(resendsBackOffThenEveryTenMinutes) {
    CHECK(resend::due(0) == 0);
    CHECK(resend::due(1) == 30);
    CHECK(resend::due(2) == 90);
    CHECK(resend::due(4) == 450);
    CHECK(resend::due(5) == 1050);
    CHECK(resend::due(6) == 1650);
}

TEST(resendsUntilAcknowledgedAndNeverStopsOnATimer) {
    OutgoingCall c = redCall();
    CHECK(!c.resendDue(m0 + 29));
    CHECK(c.resendDue(m0 + 30));
    c.markResent(m0 + 30);
    CHECK(!c.resendDue(m0 + 31));
    CHECK(c.resendDue(m0 + 86400 * 7));  // a week later it is still going out
    c.receive(ack(5, 1, 2, t0));
    CHECK(c.status() == CallerStatus::seen);
    CHECK(!c.resendDue(m0 + 86400 * 7));
    uint64_t next;
    CHECK(!c.nextResend(next));
}

TEST(aCallNobodyCouldSendIsRetriedAndShowsTheCross) {
    OutgoingCall c(5, 1, Colour::amber, t0, m0);
    c.mesh = RouteState::failed;
    CHECK(c.status() == CallerStatus::notSent);
    CHECK(c.resendDue(m0 + 30));  // a radio that comes back gets the call
    OutgoingCall untried(5, 2, Colour::red, t0, m0);
    CHECK(untried.status() == CallerStatus::notSent);
}

TEST(statusNeverSaysMoreThanItKnows) {
    OutgoingCall c(5, 1, Colour::red, t0, m0);
    c.mesh = RouteState::sending;
    CHECK(c.status() == CallerStatus::sending);
    c.phone = RouteState::sent;
    CHECK(c.status() == CallerStatus::waitingForResponder);
    c.mesh = RouteState::failed;
    CHECK(c.status() == CallerStatus::waitingForResponder);
}

TEST(missedResendSlotsAreSkippedNotSentBackToBack) {
    OutgoingCall c = redCall();
    c.markResent(m0 + 1000);
    CHECK(c.resends == 4);
    CHECK(!c.resendDue(m0 + 1000));
    CHECK(c.resendDue(m0 + 1050));
}

TEST(imOKIsRepeatedAFewTimesThenLeft) {
    OutgoingCall c(5, 1, Colour::green, t0, m0);
    c.mesh = RouteState::sent;
    for (uint64_t n = 1; n <= resend::kGapCount; n++) {
        CHECK(c.resendDue(m0 + resend::due(n)));
        c.markResent(m0 + resend::due(n));
    }
    CHECK(!c.resendDue(m0 + 86400));
    uint64_t next;
    CHECK(!c.nextResend(next));
}

TEST(onlyAnAcknowledgementOfThisCallCounts) {
    OutgoingCall c = redCall();
    c.receive(ack(5, 2, 3, t0));  // another request
    c.receive(ack(6, 1, 3, t0));  // another unit
    c.receive(ack(5, 1, 3, t0 - kClockAllowance - 1));  // made before the press: an old call's
    CHECK(c.status() == CallerStatus::waitingForResponder);
    c.receive(ack(5, 1, 3, t0 - kClockAllowance));  // a responder's clock a little behind
    CHECK(c.status() == CallerStatus::seen);
    c.receive(ack(5, 1, 3, t0 + 5));
    CHECK(c.ackCount == 1);
}

TEST(acknowledgementsFromRemovedRespondersAreTakenBack) {
    OutgoingCall c = redCall();
    c.receive(ack(5, 1, 3, t0));
    c.receive(ack(5, 1, 4, t0));
    c.revoke([](uint16_t who) { return who != 3; });
    CHECK(c.ackCount == 1 && c.acknowledgedBy[0] == 4);
    c.revoke([](uint16_t) { return false; });
    CHECK(c.status() == CallerStatus::waitingForResponder);
    CHECK(c.resendDue(m0 + 30));
}

TEST(aCloseIsFinalAndImOKNeverUndoesIt) {
    OutgoingCall c = redCall();
    c.settle(CallState::closedByCaller, 9, t0 - kClockAllowance - 1);  // older than the call
    CHECK(!c.settled);
    c.settle(CallState::callerOK, 9, t0 + 10);
    CHECK(c.status() == CallerStatus::waitingForResponder);
    CHECK(c.resendDue(m0 + 30));  // I'm OK goes with the resends: a responder still checks
    c.settle(CallState::closedWithConsent, 1, t0 + 20);
    CHECK(c.status() == CallerStatus::closed);
    c.settle(CallState::callerOK, 9, t0 + 30);
    CHECK(c.settledState == CallState::closedWithConsent && c.settledBy == 1);
    c.settle(CallState::closedByCaller, 9, t0 + 40);
    CHECK(c.settledState == CallState::closedWithConsent);
    CHECK(!c.resendDue(m0 + 86400));
}

TEST(imOKSettlesWhatTheProfileSays) {
    OutgoingCall calls[] = {redCall(), redCall(), redCall(), OutgoingCall(5, 4, Colour::green, t0, m0), redCall()};
    calls[1].receive(ack(5, 1, 3, t0));
    calls[2].settle(CallState::callerOK, 9, t0);
    calls[4].settle(CallState::closedByCaller, 9, t0);
    size_t out[5];

    // B: only those still waiting for a responder.
    size_t n = settledByOK(calls, 5, false, out, 5);
    CHECK(n == 1 && out[0] == 0);

    // A: every open Help or Need a hand, seen or not.
    n = settledByOK(calls, 5, true, out, 5);
    CHECK(n == 3 && out[0] == 0 && out[1] == 1 && out[2] == 2);
}

TEST(aCloseIsRepeatedOnTheCallsResendTimes) {
    CloseRepeat r(m0);
    bool finished = false;
    CHECK(!r.tick(m0 + 29, finished));
    CHECK(r.tick(m0 + 30, finished) && !finished);
    CHECK(!r.tick(m0 + 31, finished));
    CHECK(r.tick(m0 + 90, finished) && !finished);
    CHECK(r.tick(m0 + 210, finished) && !finished);
    CHECK(r.tick(m0 + 450, finished) && finished);
}

TEST(aCloseAfterALongSleepGoesOnceAndStops) {
    CloseRepeat r(m0);
    bool finished = false;
    CHECK(r.tick(m0 + 1000, finished) && finished);
}
