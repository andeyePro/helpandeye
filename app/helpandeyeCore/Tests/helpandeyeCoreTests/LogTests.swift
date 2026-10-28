import XCTest
@testable import helpandeyeCore

@MainActor final class LogTests: XCTestCase {
    var t: EngineTests!

    override func setUp() async throws {
        t = EngineTests()
        try await t.setUp()
    }

    private var log: [String] { t.coordinator.engine.activity.log.entries.map(\.text) }

    func testTheCoordinatorsLogFollowsACall() async {
        t.caller.engine.press(.red)
        await t.air.run()
        XCTAssertTrue(t.responder.engine.acknowledge(t.key))
        await t.air.run()
        XCTAssertTrue(t.coordinator.engine.close(t.key, consent: true))
        XCTAssertEqual(log, ["Caller's Help call 1 heard over the local radio", "Responder acknowledged Caller's Help call 1",
                             "You closed Caller's Help call 1, with the caller's agreement"])
        XCTAssertTrue(t.responder.engine.activity.log.entries.isEmpty, "only coordinators keep a log")
        XCTAssertTrue(t.caller.engine.activity.log.entries.isEmpty)
    }

    func testSettingsChangesAreLoggedAndShownEvenWithTheLogOff() async {
        t.coordinator.engine.updateGroup { $0.policy.profiles.append(Profile(id: 1, name: "Lone worker")) }
        t.coordinator.engine.updateGroup { $0.policy.keepsLog = false }
        t.caller.engine.press(.red)
        await t.air.run()
        XCTAssertEqual(log, ["You added the profile Lone worker", "You switched the log off"], "nothing more once it is off")
        t.coordinator.engine.updateGroup { $0.policy.profiles[1].name = "Out walking" }
        XCTAssertEqual(t.coordinator.engine.activity.lastSettingsChange?.text, "You changed the profile Lone worker, now called Out walking")
        XCTAssertEqual(log.count, 2)
    }

    func testTheLogKeepsTheNewest() {
        var l = GroupLog()
        for i in 0..<(GroupLog.limit + 5) { l.add("\(i)", at: Date(timeIntervalSince1970: TimeInterval(i))) }
        XCTAssertEqual(l.entries.count, GroupLog.limit)
        XCTAssertEqual(l.entries.first?.text, "5")
        XCTAssertTrue(l.text(in: TimeZone(identifier: "UTC")!).hasPrefix("1970-01-01 00:00:05  5\n"))
    }
}

@MainActor final class ChangeRequestTests: XCTestCase {
    var t: EngineTests!

    override func setUp() async throws {
        t = EngineTests()
        try await t.setUp()
    }

    func testAPersonAsksTheCoordinatorsToChangeASetting() async {
        let none = await t.caller.engine.askCoordinator(about: .sounds, "Too loud")
        XCTAssertNotNil(none, "internet only")
        for p in t.air.phones { p.relay.isConfigured = true }
        await t.relaySetUp()
        let problem = await t.caller.engine.askCoordinator(about: .sounds, "Too loud at night")
        XCTAssertNil(problem)
        await t.air.run()
        let asked = t.coordinator.engine.activity.changeRequests
        XCTAssertEqual(asked.map(\.text), ["Too loud at night"])
        XCTAssertEqual(asked.first?.setting, .sounds)
        XCTAssertEqual(asked.first?.member, t.caller.engine.saved!.me)
        XCTAssertTrue(t.responder.engine.activity.changeRequests.isEmpty, "for coordinators only")
        XCTAssertEqual(t.coordinator.engine.activity.log.entries.last?.text, "Caller asked to change the sounds: Too loud at night")
        t.coordinator.engine.dismiss(asked[0])
        XCTAssertTrue(t.coordinator.engine.activity.changeRequests.isEmpty)
        XCTAssertFalse(t.air.groupSends.contains { if case let .signed(_, inner, _) = $0, case .changeRequest? = HelpFrame(inner) { return true }; return false })
    }

    func testOnlyThePersonThemselvesCanAsk() {
        let f = HelpFrame.changeRequest(member: t.caller.engine.saved!.me, setting: nil, at: 0, text: "Hide my buttons")
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        let forged = HelpFrame.signing(f, as: t.responder.engine.saved!.me, identity: t.responder.identity, group: t.gid)
        t.coordinator.engine.receive(forged, via: .internet)
        XCTAssertTrue(t.coordinator.engine.activity.changeRequests.isEmpty)
    }
}
