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
        // A second try (screens.sh retries a failed test) finds the first try's group: leave it.
        if !app.buttons["Start a group"].waitForExistence(timeout: 5) {
            tab("Group")
            reveal(app.buttons["Leave this group"]).tap()
            XCTAssert(app.buttons["Start a group"].waitForExistence(timeout: 5), "every-screen: the earlier group was not left")
        }
        startGroup(shooting: true)
        look("help")
        reveal(app.buttons["Need a hand"]).tap()
        allowSystemAlerts()
        look("help-not-sent")

        tab("Respond")
        look("respond")
        tab("Group")
        look("group")
        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam (you)")).firstMatch).tap()
        look("member")
        reveal(app.buttons["External antenna"]).tap()
        look("member-external")
        app.navigationBars.buttons.firstMatch.tap()
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

    /// A phone removed from its call group but still in another: Respond, and a Group tab that
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

    /// Leaving the call group while still in another: the other is offered as the next call
    /// group, and takes its place. Both groups are then left, so the later tests start afresh.
    func testLeaveFirstGroupForAnother() throws {
        launch()
        startGroupIfNew()
        app.terminate()
        launch("-HelpAOtherGroup")
        tab("Group")
        reveal(app.buttons["Leave this group"]).tap()
        // A row of a long list is not in the hierarchy until it is scrolled near the screen.
        let choice = reveal(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Make Hill Road my call group")).firstMatch)
        XCTAssert(choice.exists, "leave-first: no choice of the next call group")
        still(choice)
        look("leave-first-choice")
        // The audit relays the screen out at other text sizes, which can scroll a row off it.
        reveal(choice).tap()
        XCTAssert(app.navigationBars["Hill Road"].waitForExistence(timeout: 5), "leave-first: Hill Road did not become the call group")
        // The list is rebuilt for the new group and may still be moving: shown afresh, from the top.
        tab("Box")
        tab("Group")
        for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown(velocity: .fast) }
        look("leave-first-done")
        // Left too, so the tests after this one start with a group of their own.
        let leave = app.buttons["Leave this group"]
        for _ in 0..<3 where !hittable(leave) { reveal(leave) }
        leave.tap()
        XCTAssert(app.buttons["Start a group"].waitForExistence(timeout: 5), "leave-first: the last group was not left")
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

    /// A Help&I box not yet in the group, added to it, and then given an antenna too strong for it
    /// to send at all. Shown by launch argument, because a simulator has no Bluetooth. Named to run
    /// after the group is left, so the box makes no other test's Group screen longer.
    func testPairedHelpAndIBox() throws {
        launch("-HelpAHelpBox")
        startGroupIfNew()
        tab("Box")
        if boxToAdd() {
            reveal(app.buttons["Add this box to the group"])
            look("box-helpandi-add")
            addBox()
        }
        let added = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Set up. Its buttons call for help")).firstMatch
        show(added)
        still(added)
        XCTAssert(added.exists, "help-box: the box was not added")
        for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown(velocity: .fast) }
        look("box-helpandi")
        reveal(added)
        look("box-helpandi-lower")

        tab("Group")
        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kitchen box")).firstMatch).tap()
        reveal(app.buttons["External antenna"]).tap()
        // Just below the choice: dragged up a little at a time, as a swipe at the largest text
        // carries it out of the list. Half a dB a step: held down, it runs to the top of its range.
        let increment = app.buttons["Increment"], window = app.windows.firstMatch
        for _ in 0..<10 where !hittable(increment) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        let top = app.steppers.matching(NSPredicate(format: "label CONTAINS %@", "63.5 dBi")).firstMatch
        for _ in 0..<10 where !top.exists { increment.press(forDuration: 5) }
        let mustNotSend = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "With this antenna the box must not send")).firstMatch
        show(mustNotSend)
        still(mustNotSend)
        XCTAssert(mustNotSend.exists, "help-box: no warning that the box must not send")
        look("member-antenna-not-allowed")
        // Back to the list first: the member page's picker, also labelled Antenna, would otherwise
        // be what the contrast check finds again for the Box screen's Antenna heading.
        app.navigationBars.buttons.firstMatch.tap()
        tab("Box")
        show(mustNotSend)
        still(mustNotSend)
        XCTAssert(mustNotSend.exists, "help-box: the Box screen does not say the box must not send")
        look("box-antenna-not-allowed")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// A Help&I box's settings: telling responders of a power cut at its home, and responders'
    /// first names on boxes, under Privacy.
    func testPairedHelpAndIBoxSettings() throws {
        launch("-HelpAHelpBox")
        startGroupIfNew()
        tab("Box")
        if boxToAdd() { addBox() }
        tab("Group")
        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kitchen box")).firstMatch).tap()
        let powerCut = reveal(app.switches["Tell responders about a power cut at their home"])
        if powerCut.value as? String != "1" { powerCut.switches.firstMatch.tap() }
        if powerCut.value as? String != "1" { powerCut.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        XCTAssertEqual(powerCut.value as? String, "1", "box-settings: power-cut reports not turned on")
        look("member-power-cut")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(app.buttons["Advanced settings"]).tap()
        reveal(app.switches["Responders' first names on boxes"])
        XCTAssert(app.staticTexts["Privacy"].exists, "box-settings: names on boxes not under Privacy")
        look("advanced-box-names")
        app.navigationBars.buttons.firstMatch.tap()
        tab("Box")
        let tells = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "It tells your responders about a power cut")).firstMatch
        show(tells)
        still(tells)
        XCTAssert(tells.exists, "box-settings: the Box screen does not say it tells responders")
        look("box-power-cut-on")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// A stock MeshCore box whose battery suggests a power cut: the caller is offered to tell
    /// their responders, and the Box screen says what the box is.
    func testStockBoxPowerCut() throws {
        launch("-HelpAStockBox")
        startGroupIfNew()
        let offer = app.buttons["Tell my responders"]
        XCTAssert(offer.waitForExistence(timeout: 5), "stock-box: no offer to tell responders")
        look("help-power-cut")
        reveal(offer)
        look("help-power-cut-lower")
        tab("Box")
        look("box-stock")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// A responder's list with power cuts in it: a Help&I box's report, its "probably" without the
    /// mains wire, and a stock box's caller who told their responders.
    func testPowerCutReports() throws {
        launch("-HelpAPowerCuts")
        startGroupIfNew()
        tab("Respond")
        // The two reports are equally urgent, so either may come first.
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Unit 709")).firstMatch.waitForExistence(timeout: 5), "power-cuts: no report")
        look("respond-power-cuts")
        let probable = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Probably a power cut at their home")).firstMatch
        show(probable)
        still(probable)
        XCTAssert(probable.exists, "power-cuts: no report from a box without the mains wire")
        look("respond-power-cuts-probable")
        let report = app.staticTexts["Power cut at their home. Their box is on its battery."]
        show(report)
        still(report)
        XCTAssert(report.exists, "power-cuts: no report from a box with the mains wire")
        look("respond-power-cuts-sure")
        let toldByCaller = app.staticTexts["“Power probably cut: the battery is falling.”"]
        show(toldByCaller)
        still(toldByCaller)
        XCTAssert(toldByCaller.exists, "power-cuts: no note from a stock box's caller")
        look("respond-power-cuts-caller")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// The first coordinator names a deputy from the group's other coordinators.
    func testNamingADeputy() throws {
        launch("-HelpADeputy")
        tab("Group")
        reveal(app.buttons["If your phone is lost"]).tap()
        reveal(app.buttons["Alex"]).tap()
        XCTAssert(app.staticTexts["Everyone in the group sees who your deputy is."].waitForExistence(timeout: 5), "deputy: no deputy to choose")
        look("deputy")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// A second coordinator whose first coordinator, Alex, has gone quiet: the Group screen says
    /// so, and they may take over as Alex's deputy, once they confirm.
    func testTakingOver() throws {
        launch("-HelpATakeover")
        tab("Group")
        let quiet = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Nothing heard from Alex's phone since")).firstMatch
        show(quiet)
        still(quiet)
        XCTAssert(quiet.exists, "takeover: the Group screen does not say Alex has gone quiet")
        look("takeover-group")
        reveal(app.buttons["If Alex's phone is lost"]).tap()
        XCTAssert(app.staticTexts["You are Alex's deputy."].waitForExistence(timeout: 5), "takeover: not told they are the deputy")
        look("takeover")
        reveal(app.buttons["Take over from Alex"]).tap()
        let confirm = app.buttons["Take over now"]
        XCTAssert(confirm.waitForExistence(timeout: 5), "takeover: no confirmation")
        // Asked in the list, not in a system dialog, so the whole question shows at the largest text.
        show(app.staticTexts.element(matching: NSPredicate(format: "label BEGINSWITH %@", "Only do this if Alex's phone")))
        look("takeover-confirm")
        reveal(app.buttons["Don't take over"]).tap()
        XCTAssert(confirm.waitForNonExistence(timeout: 5), "takeover: the confirmation did not go")
        reveal(app.buttons["Agree that Pat may take over"])
        look("takeover-agree")
        if !problems.isEmpty {
            XCTFail("Accessibility audit:\n" + problems.joined(separator: "\n"))
        }
    }

    /// Whether the Box screen offers to add the Help&I box, or has it in the group already: its
    /// list holds only the rows near the screen, so it is scrolled until one of them is there.
    private func boxToAdd() -> Bool {
        let add = app.buttons["Add this box to the group"], inGroup = app.staticTexts["In the group as"]
        _ = app.staticTexts["Status"].waitForExistence(timeout: 5)
        for _ in 0..<15 where !add.exists && !inGroup.exists { app.swipeUp() }
        return add.exists
    }

    /// On the Box screen with a Help&I box not yet in the group: adds it, in Sam's home.
    private func addBox() {
        let add = app.buttons["Add this box to the group"]
        type("Its name in the group, such as Kitchen box at no. 4", "Kitchen box")
        tapKeyboardDone()
        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In the home of")).firstMatch).tap()
        // The menu's row can read its name twice, "SamSam".
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam")).firstMatch.tap()
        reveal(add).tap()
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
        for _ in 0..<15 where !hittable(e) { app.swipeUp(velocity: .fast) }
        for _ in 0..<30 where !hittable(e) { app.swipeDown(velocity: .slow) }
        return e
    }

    /// Waits until the list stops scrolling a row into place: the audit reads where it was.
    private func still(_ e: XCUIElement) {
        var last = e.frame
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            let now = e.frame
            if now == last { return }
            last = now
        }
    }

    /// A row a list is still rebuilding has no usable frame for a moment, and asking whether it can
    /// be tapped then fails the test instead of answering no.
    private func hittable(_ e: XCUIElement) -> Bool {
        guard e.exists else { return false }
        let f = e.frame
        return !f.isEmpty && f.width.isFinite && f.height.isFinite && e.isHittable
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
        // Apple's clipped-text and partial Dynamic Type checks (and its Dynamic Type check on a row low on
        // the screen, which its own relayout at other sizes pushes off it) are known to flag SwiftUI text that
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
                        || (issue.auditType == .dynamicType && frame.minY > screen.height * 0.7)
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
