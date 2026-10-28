@testable import helpandeyeCore
import XCTest

final class CallerFeedbackTests: XCTestCase {
    private func change(_ old: CallerStatus?, _ new: CallerStatus) -> CallerFeedback? {
        CallerFeedback.change(from: old, to: new, words: "Help", name: { $0 == 2 ? "Sam" : "Member \($0)" })
    }

    func testSentIsSaidWithoutASound() {
        XCTAssertEqual(change(.sending, .waitingForResponder), .init(sound: nil, spoken: "Your Help message has been sent."))
        XCTAssertNil(change(.waitingForResponder, .waitingForResponder))
        XCTAssertNil(change(nil, .sending))
    }

    func testNeedAHandIsFollowedByTheGroupsNote() {
        var g = Profile.standard
        let standard = ButtonWords.amberNote(in: g)
        XCTAssertEqual(standard, "You have requested non-urgent assistance. If you need help sooner, please press Help.")
        let f = CallerFeedback.change(from: .sending, to: .waitingForResponder, words: "Need a hand", note: standard, name: { _ in "" })
        XCTAssertEqual(f?.spoken, "Your Need a hand message has been sent. " + standard)
        ButtonWords.set("Hang on, someone will come.", for: ButtonWords.amberNoteKey, in: &g)
        XCTAssertEqual(ButtonWords.amberNote(in: g), "Hang on, someone will come.")
        ButtonWords.set(String(repeating: "a", count: 300), for: ButtonWords.amberNoteKey, in: &g)
        XCTAssertEqual(ButtonWords.amberNote(in: g).count, ButtonWords.longestNote)
        XCTAssertNil(CallerFeedback.change(from: .sending, to: .notSent, words: "Need a hand", note: standard, name: { _ in "" })?
            .spoken.range(of: standard), "a call that did not go says only to try again or call 999")
    }

    func testNotSentHasItsOwnSoundAndPointsTo999() {
        let f = change(.sending, .notSent)
        XCTAssertEqual(f?.sound, .notSent)
        XCTAssertEqual(f?.spoken, "Your Help message has not been sent. Try again, or call 999.")
    }

    /// Only a responder's acknowledgement is ever reassuring (AGENTS.md).
    func testOnlySeenIsReassuring() {
        XCTAssertEqual(change(.waitingForResponder, .seen(responder: 2)),
                       .init(sound: .seen, spoken: "Sam has seen your Help message, and says: I'm dealing with it."))
        for old: CallerStatus? in [nil, .sending, .notSent] {
            for new: CallerStatus in [.sending, .waitingForResponder, .notSent] {
                XCTAssertNotEqual(change(old, new)?.sound, .seen)
                XCTAssertFalse(change(old, new)?.spoken.contains("seen") ?? false)
            }
        }
        XCTAssertNil(change(.seen(responder: 2), .seen(responder: 3)), "a second responder does not repeat it")
    }

    func testTrackerHearsEachChangeOnceAndNotWhatWasThereAtStart() {
        var r = OutgoingRequest(unit: 7, number: 1, colour: .red, createdAt: Date())
        r.update(.internet, .sent)
        var t = CallerFeedback.Tracker(r)
        XCTAssertNil(t.update(r, words: "Help", name: { _ in "Sam" }))
        r.receive(.ack(unit: 7, request: 1, responder: 2, ackedAt: UInt32(Date().timeIntervalSince1970), signature: Data()))
        XCTAssertEqual(t.update(r, words: "Help", name: { _ in "Sam" })?.sound, .seen)
        XCTAssertNil(t.update(r, words: "Help", name: { _ in "Sam" }))
        // A new call starts afresh.
        var next = OutgoingRequest(unit: 7, number: 2, colour: .amber, createdAt: Date())
        next.update(.internet, .sending)
        XCTAssertNil(t.update(next, words: "Need a hand", name: { _ in "Sam" }))
    }
}
