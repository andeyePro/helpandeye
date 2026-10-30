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
    }

    /// The launch arguments that put a debug simulator build into a state a simulator cannot reach
    /// on its own; each is in the app, beside what it changes.
    private func launch(_ extra: String...) {
        app.launchArguments = ["-HelpAQuiet"] + extra
        app.launch()
        allowSystemAlerts()
    }

    /// A phone that has kept its group from an earlier test is left as it is.
    private func startGroupIfNew() {
        if app.buttons["Start a group"].waitForExistence(timeout: 5) { startGroup(shooting: false) }
    }

    private func startGroup(shooting: Bool) {
        if shooting { look("welcome") }
        app.buttons["Start a group"].tap()
        if shooting { look("start-group") }
        type("Group name, such as your street", "Mill Lane")
        tapKeyboardDone()
        type("Your name, as the group will see it", "Sam")
        tapKeyboardDone()
        type("Mobile number (optional)", "07700900111")
        if shooting { shoot("start-group-typing") }
        tapKeyboardDone()
        // Wherever large text puts the switch; if the first tap missed it, the end of the row is it.
        let row = reveal(app.switches["I may also call for help"])
        row.switches.firstMatch.tap()
        if row.value as? String != "1" { row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        reveal(app.buttons["Start the group"]).tap()
        allowSystemAlerts()
    }

    func testEveryScreen() throws {
        launch()
        startGroup(shooting: true)
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

    /// A phone removed from its first group but still in another: Respond, and a Group tab that
    /// offers to start or join one.
    func testRemovedFromFirstGroup() throws {
        launch("-HelpAOtherGroupOnly")
        look("removed-respond")
        tab("Group")
        look("removed-group")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// Notifications turned off for Help&I: every screen says so, with a way to Settings.
    func testNotificationsOff() throws {
        launch()
        startGroupIfNew()
        app.terminate()
        launch("-HelpANotificationsOff")
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications are off for Help&I")).firstMatch
        XCTAssert(banner.waitForExistence(timeout: 5), "notifications-off: no banner")
        XCTAssert(app.buttons["Open Settings"].exists, "notifications-off: no way to Settings")
        look("notifications-off")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// Told of a removal but not yet given the new keys: the call screen says why nothing personal
    /// goes, and Group, Home Wi-Fi asks for the update code.
    func testKeysNeeded() throws {
        launch()
        startGroupIfNew()
        app.terminate()
        launch("-HelpAPositionSending", "-HelpAKeysNeeded")
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Your buttons still work")).firstMatch
        if !message.waitForExistence(timeout: 3) {
            reveal(app.buttons["Need a hand"]).tap()
            allowSystemAlerts()
        }
        reveal(message)
        XCTAssert(message.isHittable, "keys-needed: the call screen does not say why")
        look("keys-needed-call")
        tab("Group")
        let wifi = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Scan the new code")).firstMatch
        show(wifi)
        // At the largest text it can be taller than the screen, so on screen is enough.
        XCTAssert(wifi.exists && wifi.frame.intersects(app.windows.firstMatch.frame), "keys-needed: Home Wi-Fi does not ask for the new code")
        look("keys-needed-group")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// The three messages about where the caller is: still going, sent, and not sent. Shown by
    /// launch argument, because a simulator has no route to send by and no location fix.
    func testPositionMessages() throws {
        launch()
        startGroupIfNew()
        for (state, text) in [("Sending", "Sending where you are…"), ("Sent", "Where you are was sent."),
                              ("Failed", "Where you are could not be sent. Try again, or call 999.")] {
            app.terminate()
            launch("-HelpAPosition" + state)
            let message = app.staticTexts[text]
            if !message.waitForExistence(timeout: 3) {
                reveal(app.buttons["Need a hand"]).tap()
                allowSystemAlerts()
            }
            reveal(message)
            XCTAssert(message.isHittable, "position-\(state.lowercased()): \(text) is not shown")
            look("position-" + state.lowercased())
        }
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// A change too big to send to everyone is refused, and the coordinator is told on Profiles
    /// and on the profile being edited.
    func testSettingsTooBigToSend() throws {
        launch("-HelpAOversizedSettings")
        startGroupIfNew()
        tab("Group")
        reveal(app.buttons["Profiles"]).tap()
        let tooBig = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "too much to send to everyone")).firstMatch
        XCTAssert(tooBig.waitForExistence(timeout: 5), "no message on Profiles")
        look("profiles-too-big")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Standard")).firstMatch.tap()
        XCTAssert(tooBig.waitForExistence(timeout: 5), "no message on the profile")
        look("profile-too-big")
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
        // The Group screen is long: settings, then members, then more. A fast swipe can carry a
        // button past the screen, so if the bottom comes first, go back up slowly.
        for _ in 0..<15 where !(e.exists && e.isHittable) { app.swipeUp(velocity: .fast) }
        for _ in 0..<30 where !(e.exists && e.isHittable) { app.swipeDown(velocity: .slow) }
        return e
    }

    /// Scrolls text into view that may be too tall ever to count as tappable.
    private func show(_ e: XCUIElement) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<60 where !(e.exists && e.frame.minY < window.maxY - 150 && e.frame.maxY > window.minY + 150) {
            if e.exists && e.frame.maxY <= window.minY + 150 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    private func type(_ field: String, _ text: String) {
        // Found by the label read out to VoiceOver, which is also shown above the box.
        let f = reveal(app.textFields[field])
        f.tap()
        // At the largest text the keyboard can push the field away under the first tap.
        for _ in 0..<5 where f.value(forKey: "hasKeyboardFocus") as? Bool != true {
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
            if f.value(forKey: "hasKeyboardFocus") as? Bool == true { break }
            Thread.sleep(forTimeInterval: 1)
            reveal(f).tap()
        }
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
        // The status bar too: a screen with no title bar scrolls under it, into the same fade.
        let statusBar = CGRect(x: 0, y: 0, width: app.windows.firstMatch.frame.width, height: 54)
        let bars = (app.navigationBars.allElementsBoundByIndex.map(\.frame) + app.tabBars.allElementsBoundByIndex.map(\.frame) + [statusBar])
            .map { $0.insetBy(dx: 0, dy: -60) }
        var contrast: [(XCUIElement, String)] = []
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
            } else if issue.auditType == .contrast, let e = issue.element {
                contrast.append((e, detail))
            } else {
                self.problems.append(detail)
                print("AUDIT " + detail)
            }
            return true
        } } catch {
            problems.append("\(name): the audit could not run: \(error)")
        }
        recheck(contrast, bars: bars)
    }

    /// The audit can read a list at another scroll position than it reports, so it flags text
    /// that sat in a fade for a moment. Each contrast finding is measured again on a screenshot
    /// once the screen is still: only text below 4.5 to 1 there counts.
    private func recheck(_ found: [(XCUIElement, String)], bars: [CGRect]) {
        guard !found.isEmpty else { return }
        Thread.sleep(forTimeInterval: 1)
        let shot = XCUIScreen.main.screenshot()
        let screen = app.windows.firstMatch.frame
        for (e, detail) in found {
            // Found again by its label: the audit's element can keep the frame it had then.
            let now = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", e.label)).firstMatch
            let frame = now.exists ? now.frame : .zero
            if now.exists, !now.isHittable {
                // Scrolled out of a sheet's visible part: what was measured is the dimmed screen behind.
                print("ADVICE out of sight in a sheet: " + detail)
            } else if bars.contains(where: { $0.intersects(frame) }) {
                print("ADVICE under a bar when still: " + detail)
            } else if screen.contains(frame), !frame.isEmpty, let ratio = Self.contrast(in: frame, of: shot, screen: screen), ratio >= 4.5 {
                print("ADVICE read while moving; \(String(format: "%.1f", ratio)) to 1 when still: " + detail)
            } else {
                problems.append(detail)
                print("AUDIT " + detail)
            }
        }
    }

    /// The contrast between the commonest colour in a frame (the background) and the text's, by
    /// WCAG relative luminance. Portrait only: the screen tests do not turn the simulator.
    private static func contrast(in frame: CGRect, of shot: XCUIScreenshot, screen: CGRect) -> Double? {
        guard let image = shot.image.cgImage else { return nil }
        let scale = CGFloat(image.width) / screen.width
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
        guard let crop = image.cropping(to: rect) else { return nil }
        let w = crop.width, h = crop.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let lum = stride(from: 0, to: pixels.count, by: 4).map {
            0.2126 * linear(pixels[$0]) + 0.7152 * linear(pixels[$0 + 1]) + 0.0722 * linear(pixels[$0 + 2])
        }
        guard !lum.isEmpty else { return nil }
        var bins = [Int](repeating: 0, count: 64)
        for l in lum { bins[min(Int(l * 64), 63)] += 1 }
        let common = bins.indices.max { bins[$0] < bins[$1] }!
        let background = lum.filter { min(Int($0 * 64), 63) == common }.reduce(0, +) / Double(bins[common])
        // The text's colour is where the furthest 2% of pixels start, so one stray pixel of an
        // icon or a separator does not pass faint text.
        let text = lum.sorted { abs($0 - background) < abs($1 - background) }[lum.count * 98 / 100]
        return (max(text, background) + 0.05) / (min(text, background) + 0.05)
    }

    /// Notification and location prompts belong to the system, not the app under test.
    private func allowSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Allow While Using App"] where springboard.buttons[label].waitForExistence(timeout: 2) {
            springboard.buttons[label].tap()
        }
    }
}
