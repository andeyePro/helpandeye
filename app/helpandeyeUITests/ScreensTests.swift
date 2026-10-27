import XCTest

/// Walks every screen a new coordinator who also calls for help sees, saving a screenshot of each
/// and running Apple's accessibility audit on it. `tests/screens.sh` runs it on each simulator, in
/// light and dark mode and at the largest text size, then the screenshots are looked at by eye.
final class ScreensTests: XCTestCase {
    private let app = XCUIApplication()
    private var problems: [String] = []
    private var shots: URL? { ProcessInfo.processInfo.environment["SHOTS_DIR"].map { URL(fileURLWithPath: $0) } }

    override func setUp() {
        continueAfterFailure = true
        app.launch()
        allowSystemAlerts()
    }

    func testEveryScreen() throws {
        look("welcome")
        app.buttons["Start a group"].tap()
        look("start-group")
        type("Group name, such as your street", "Mill Lane")
        tapKeyboardDone()
        type("Your name, as the group will see it", "Sam")
        tapKeyboardDone()
        type("Mobile number (optional)", "07700900111")
        shoot("start-group-typing")
        tapKeyboardDone()
        // The switch itself sits at the right-hand end of the row.
        reveal(app.switches["I may also call for help"]).coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        reveal(app.buttons["Start the group"]).tap()
        allowSystemAlerts()

        look("help")
        reveal(app.buttons["Come when convenient"]).tap()
        allowSystemAlerts()
        look("help-not-sent")

        app.tabBars.buttons["Respond"].tap()
        look("respond")
        app.tabBars.buttons["Group"].tap()
        look("group")
        app.swipeUp(); app.swipeUp()
        look("group-lower")
        app.tabBars.buttons["Box"].tap()
        look("box")

        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// The phone-number keyboard has no return key, so Done above it must be there.
    private func tapKeyboardDone() {
        // The keyboard, and the bar above it, may be drawn by the system's keyboard process.
        let places = [app, XCUIApplication(bundleIdentifier: "com.apple.InputUI"), XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        if let done = places.map({ $0.buttons["Done"] }).first(where: { $0.waitForExistence(timeout: 1) }) {
            done.tap()
        } else {
            problems.append("start-group: no Done button above the keyboard")
            app.swipeDown()
        }
    }

    /// Scrolls until the element can be tapped: at the largest text sizes a form is several
    /// screens long.
    @discardableResult
    private func reveal(_ e: XCUIElement) -> XCUIElement {
        for _ in 0..<8 where !(e.exists && e.isHittable) { app.swipeUp() }
        return e
    }

    private func type(_ field: String, _ text: String) {
        // Found by the label read out to VoiceOver, which is also shown above the box.
        let f = reveal(app.textFields[field])
        f.tap()
        f.typeText(text)
    }

    /// A screenshot only: with the keyboard up, the audit reads text behind it as unreadable.
    private func shoot(_ name: String) {
        // Let sheets and pushes finish moving: a screen caught mid-animation is half transparent.
        Thread.sleep(forTimeInterval: 1.5)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let shots { try? png.write(to: shots.appendingPathComponent("\(name).png")) }
    }

    /// Saves a screenshot and records what the audit finds, without stopping at the first problem.
    private func look(_ name: String) {
        shoot(name)
        try? app.performAccessibilityAudit { issue in
            let line = "\(name): \(issue.auditType) – \(issue.compactDescription) – \(issue.element?.debugDescription.prefix(120) ?? "")"
            self.problems.append(line)
            print("AUDIT " + line)
            return true
        }
    }

    /// Notification and location prompts belong to the system, not the app under test.
    private func allowSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Allow While Using App"] where springboard.buttons[label].waitForExistence(timeout: 2) {
            springboard.buttons[label].tap()
        }
    }
}
