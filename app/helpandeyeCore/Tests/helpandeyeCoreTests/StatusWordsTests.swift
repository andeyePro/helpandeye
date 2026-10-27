import XCTest
@testable import helpandeyeCore

final class StatusWordsTests: XCTestCase {
    let all: [CallerStatus] = [.sending, .waitingForResponder, .seen(responder: 3), .notSent]
    let reassuring = ["seen", "coming", "on the way", "on their way", "help is", "delivered", "received"]

    func testOnlyAnAcknowledgementIsPutAsSeenAndNothingElseReassures() {
        for s in all {
            for w in [StatusWords.phone(s, name: { _ in "Sam" }), StatusWords.watch(s, name: { _ in "Sam" })] {
                let text = w.headline.lowercased()
                if case .seen = s {
                    XCTAssertTrue(text.contains("seen"))
                } else {
                    for r in reassuring { XCTAssertFalse(text.contains(r), "\(s): \"\(w.headline)\" contains \"\(r)\"") }
                }
                XCTAssertFalse(text.contains("coming") || text.contains("on the way") || text.contains("delivered"), "never, even when seen")
            }
        }
    }

    func testTheCrossAnd999WheneverNothingWasSent() {
        for s in all {
            for w in [StatusWords.phone(s, name: { _ in "Sam" }), StatusWords.watch(s, name: { _ in "Sam" })] {
                XCTAssertEqual(w.cross, s == .notSent)
                XCTAssertEqual(w.call999, s == .notSent)
            }
        }
        XCTAssertTrue(StatusWords.watch(.notSent, name: { _ in "" }).headline.contains("999"))
    }
}
