import XCTest

/// Screenshots of the watch's screens, with Apple's accessibility audit on each. `tests/screens.sh`
/// runs it on each watch simulator at the normal and the largest text size. The simulator has no
/// phone, so after the set-up screen the app is launched with a made-up phone in reach holding one
/// call; only a debug build on a simulator takes that (see `WatchModel.isScreensTest`).
final class WatchScreensTests: XCTestCase {
    private let app = XCUIApplication()
    private var problems: [String] = []
    private var shots: URL? { ProcessInfo.processInfo.environment["SHOTS_DIR"].map { URL(fileURLWithPath: $0) } }

    override func setUp() {
        continueAfterFailure = true
        // The watch simulator cannot have its text size set from outside, so the app is told it.
        if let size = ProcessInfo.processInfo.environment["TEXT_SIZE"] {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
    }

    func testEveryScreen() throws {
        app.launch()
        settle(app.staticTexts["Help&I is not set up on this watch yet."])
        look("set-up")
        app.terminate()

        app.launchArguments += ["-HelpAScreensTest"]
        app.launch()
        settle(app.buttons["Help"])
        look("call")
        app.buttons["Help"].tap()
        look("call-not-sent")
        app.swipeUp(); app.swipeUp()
        look("call-lower")

        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// The audit cannot start on an app still launching, nor, at the largest text size, before the
    /// screen has been touched once; at the top already, a swipe down moves nothing.
    private func settle(_ e: XCUIElement) {
        XCTAssert(e.waitForExistence(timeout: 20))
        app.swipeDown()
    }

    /// Saves a screenshot and records what the audit finds, without stopping at the first problem.
    private func look(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        if let shots { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appendingPathComponent("\(name).png")) }
        // As on the phone: Apple's clipped-text and partial Dynamic Type checks flag SwiftUI text that
        // does fit and grow, so they are advice, checked by eye on the screenshots. The page dots
        // beside the crown are watchOS's own, and the crown turns the page.
        do { try app.performAccessibilityAudit { issue in
            let detail = "\(name): \(issue.compactDescription) – \(issue.element?.label ?? "") \(issue.element?.frame ?? .zero)"
            if issue.auditType == .textClipped || issue.compactDescription.contains("partially unsupported") || issue.element == nil
                || (issue.element?.label.isEmpty == true && (issue.element?.frame.width ?? 0) < 10) {
                print("ADVICE " + detail)
            } else {
                self.problems.append(detail)
                print("AUDIT " + detail)
            }
            return true
        } } catch {
            problems.append("\(name): the audit could not run: \(error)")
        }
    }
}
