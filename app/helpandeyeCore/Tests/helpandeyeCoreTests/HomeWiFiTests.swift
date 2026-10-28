import XCTest
@testable import helpandeyeCore

/// Decision 19: within one home Wi-Fi network the group's phones work with no box, no server and
/// no internet.
@MainActor final class HomeWiFiTests: XCTestCase {
    var t: EngineTests!

    override func setUp() async throws {
        t = EngineTests()
        try await t.setUp()
        for p in t.air.phones {
            p.mesh.isReady = false
            p.wifi.network = "home"
            p.engine.tick()
        }
    }

    func testACallAndItsAcknowledgementGoPhoneToPhoneOverHomeWiFi() async {
        t.caller.engine.press(.red)
        await t.air.run()
        XCTAssertEqual(t.caller.request?.routes[.wifi], .sent)
        XCTAssertEqual(t.caller.request?.status, .waitingForResponder, "no box and no internet, but the call went")
        XCTAssertEqual(t.responder.engine.activity.inbox.requests[t.key]?.heardOn, [.wifi])
        XCTAssertNotNil(t.responder.alerts.scheduled[t.key])
        XCTAssertTrue(t.responder.engine.acknowledge(t.key))
        await t.air.run()
        XCTAssertEqual(t.caller.request?.status, .seen(responder: t.responder.engine.saved!.me))
    }

    func testPersonalDetailAndAReasonCanGoOverHomeWiFi() async {
        t.caller.engine.press(.red)
        await t.air.run()
        XCTAssertNil(t.caller.engine.addNote("Back door is open"))
        await t.air.run()
        XCTAssertEqual(t.responder.engine.activity.inbox.requests[t.key]?.orderedNotes, ["Back door is open"])
        XCTAssertTrue(t.coordinator.engine.close(t.key, consent: false, reason: "Came round, all well"))
        await t.air.run()
        XCTAssertEqual(t.responder.engine.activity.inbox.requests[t.key]?.settled?.reason, "Came round, all well")
    }

    func testAPhoneOffTheNetworkIsNotReachedAndTheCallSaysSo() async {
        t.responder.wifi.network = "elsewhere"
        t.coordinator.wifi.network = "elsewhere"
        t.caller.engine.press(.red)
        await t.air.run()
        XCTAssertEqual(t.caller.request?.status, .notSent, "the cross: nobody could be told")
        XCTAssertEqual(t.caller.request?.routes[.wifi], .failed("No other phones of the group on this Wi-Fi"))
        XCTAssertNil(t.responder.engine.activity.inbox.requests[t.key])
    }

    func testMessagesOnTheWire() throws {
        let g = t.caller.engine.group!
        let call = HelpFrame.call(unit: 70001, request: 1, colour: .red, sentAt: 1_793_000_000)
        let a = try XCTUnwrap(LocalWire.message(call, in: g)), b = try XCTUnwrap(LocalWire.message(.followUp(unit: 70001, request: 1, part: 1, category: .fallen), in: g))
        var reader = LocalWire.Reader()
        let stream = a + b
        var sealed: [String] = []
        for i in stride(from: 0, to: stream.count, by: 7) { sealed += reader.take(stream.subdata(in: i..<min(i + 7, stream.count))) }
        XCTAssertEqual(sealed.count, 2)
        XCTAssertEqual(LocalWire.open(sealed[0], in: g, at: t.clock.now), call)
        let other = GroupState(name: "Elsewhere", secrets: .random(), members: [])
        XCTAssertNil(LocalWire.open(sealed[0], in: other, at: t.clock.now), "another group on the same Wi-Fi cannot read it")
        var junk = LocalWire.Reader()
        XCTAssertEqual(junk.take(Data([0xFF, 0xFF, 1, 2])), [])
        XCTAssertTrue(junk.broken)
    }

    func testTheAdvertisedNameSaysNothingAboutTheGroup() {
        let g = t.caller.engine.group!
        let name = LocalWire.serviceName(for: g)
        XCTAssertEqual(name, LocalWire.serviceName(for: g))
        XCTAssertFalse(name.contains("Mill"))
        XCTAssertNotEqual(name, LocalWire.serviceName(for: GroupState(name: "Mill Lane", secrets: .random(), members: [])))
    }
}
