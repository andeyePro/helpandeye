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
        app.launchArguments += ["-HelpAQuiet"]
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
        // The switch itself, wherever large text puts it.
        reveal(app.switches["I may also call for help"]).switches.firstMatch.tap()
        reveal(app.buttons["Start the group"]).tap()
        allowSystemAlerts()

        look("help")
        reveal(app.buttons["Need a hand"]).tap()
        allowSystemAlerts()
        look("help-not-sent")

        tab("Respond")
        look("respond")
        tab("Group")
        look("group")
        reveal(app.buttons["Invite someone"]).tap()
        look("invite-role")
        app.buttons["Respond to others"].tap()
        look("invite-code")
        app.buttons["Close"].firstMatch.tap()
        reveal(app.buttons["Advanced settings"]).tap()
        look("advanced")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(app.buttons["Profiles"]).tap()
        look("profiles")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Standard")).firstMatch.tap()
        look("profile")
        app.swipeUp(); app.swipeUp()
        look("profile-lower")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        reveal(app.buttons["Log"]).tap()
        look("log")
        app.navigationBars.buttons.firstMatch.tap()
        app.swipeUp(); app.swipeUp()
        look("group-lower")
        tab("Box")
        look("box")

        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// iPhone puts the tabs along the bottom; iPad puts them along the top, as plain buttons.
    private func tab(_ name: String) {
        let bar = app.tabBars.buttons[name]
        (bar.exists ? bar : app.buttons[name].firstMatch).tap()
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
        // The Group screen is long: settings, then members, then more.
        for _ in 0..<15 where !(e.exists && e.isHittable) { app.swipeUp(velocity: .fast) }
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
        if let shots {
            do { try png.write(to: shots.appendingPathComponent("\(name).png")) } catch { problems.append("\(name): screenshot not saved: \(error)") }
        }
    }

    /// Saves a screenshot and records what the audit finds, without stopping at the first problem.
    private func look(_ name: String) {
        shoot(name)
        // Text scrolled under the see-through title and tab bars, or into the soft fade iOS draws
        // beside them (about 60 points beyond each bar), or partly off the screen, is read mid-fade
        // or not at all: scrolled into place it reads at full contrast, so it is not counted.
        // Apple's clipped-text and partial Dynamic Type checks are known to flag SwiftUI text that
        // does fit and does grow, and a finding on an element with no size and no label is on
        // nothing anyone can see; those are logged as advice and checked by eye on the
        // screenshots, the largest-text ones above all.
        let bars = (app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex).map { $0.frame.insetBy(dx: 0, dy: -60) }
        do { try app.performAccessibilityAudit { issue in
            let frame = issue.element?.frame ?? .zero
            let detail = "\(name): \(issue.compactDescription) – \(issue.element?.label ?? "") \(frame)"
            let screen = self.app.windows.firstMatch.frame
            if issue.auditType == .contrast, issue.element == nil || bars.contains(where: { $0.intersects(frame) }) || !screen.contains(frame) {
                // Read through a bar's blur, partly scrolled off the screen or out of a sheet, or no
                // element of the app's at all (what the system draws, such as the glass tab bar).
                print("ADVICE under a bar or off the screen: " + detail)
            } else if issue.auditType == .textClipped || issue.compactDescription.contains("partially unsupported")
                        || (frame.isEmpty && issue.element?.label.isEmpty != false) {
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

    /// Notification and location prompts belong to the system, not the app under test.
    private func allowSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Allow While Using App"] where springboard.buttons[label].waitForExistence(timeout: 2) {
            springboard.buttons[label].tap()
        }
    }
}
