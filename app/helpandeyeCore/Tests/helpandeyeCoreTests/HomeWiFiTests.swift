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

    /// Two ends of one connection, handing each other what they send, a few bytes at a time.
    private func connect(_ a: inout LocalWire.Session, _ b: inout LocalWire.Session) -> (a: [LocalWire.Session.Event], b: [LocalWire.Session.Event]) {
        var toA = b.opening, toB = a.opening, seenA: [LocalWire.Session.Event] = [], seenB: [LocalWire.Session.Event] = []
        while !toA.isEmpty || !toB.isEmpty {
            let inA = toA, inB = toB
            toA = Data(); toB = Data()
            for i in stride(from: 0, to: inA.count, by: 5) {
                let r = a.take(inA.subdata(in: i..<min(i + 5, inA.count)), at: t.clock.now); seenA += r.events; toB += r.reply
            }
            for i in stride(from: 0, to: inB.count, by: 5) {
                let r = b.take(inB.subdata(in: i..<min(i + 5, inB.count)), at: t.clock.now); seenB += r.events; toA += r.reply
            }
        }
        return (seenA, seenB)
    }

    func testTwoMembersProveWhoTheyAreAndConfirmWhatTheyRead() throws {
        let g = t.caller.engine.group!
        var caller = LocalWire.Session(group: g, me: t.caller.engine.saved!.me, identity: t.caller.identity)
        var responder = LocalWire.Session(group: g, me: t.responder.engine.saved!.me, identity: t.responder.identity)
        let seen = connect(&caller, &responder)
        XCTAssertEqual(seen.a, [.peer(t.responder.engine.saved!.me)])
        XCTAssertEqual(seen.b, [.peer(t.caller.engine.saved!.me)])
        let call = HelpFrame.call(unit: 70001, request: 1, colour: .red, sentAt: 1_793_000_000)
        let got = responder.take(try XCTUnwrap(caller.message(call, id: 7)), at: t.clock.now).events
        XCTAssertEqual(got, [.frame(call, id: 7)])
        XCTAssertEqual(caller.take(responder.receipt(for: 7), at: t.clock.now).events, [.receipt(7)])
    }

    func testThisPhonesOwnOtherHalfNeverCountsAsAnotherPhone() {
        let g = t.caller.engine.group!, me = t.caller.engine.saved!.me
        var app = LocalWire.Session(group: g, me: me, identity: t.caller.identity)
        var itsExtension = LocalWire.Session(group: g, me: me, identity: t.caller.identity)
        let seen = connect(&app, &itsExtension)
        XCTAssertEqual(seen.a, [])
        XCTAssertTrue(app.broken && itsExtension.broken)
    }

    func testNobodyOutsideTheGroupCountsOrGetsAnything() throws {
        let g = t.caller.engine.group!
        var caller = LocalWire.Session(group: g, me: t.caller.engine.saved!.me, identity: t.caller.identity)
        // Someone who knows the group key but signs with another key, claiming a member's number.
        var stranger = LocalWire.Session(group: g, me: t.responder.engine.saved!.me, identity: DeviceIdentity())
        _ = connect(&caller, &stranger)
        XCTAssertNil(caller.peer)
        XCTAssertNil(caller.message(.call(unit: 70001, request: 1, colour: .red, sentAt: 0), id: 1), "nothing goes to an unproven end")
        // Another group on the same Wi-Fi.
        var mine = LocalWire.Session(group: g, me: t.caller.engine.saved!.me, identity: t.caller.identity)
        var other = LocalWire.Session(group: GroupState(name: "Elsewhere", secrets: .random(), members: []), me: 1, identity: DeviceIdentity())
        _ = connect(&mine, &other)
        XCTAssertNil(mine.peer)
        // A receipt or frame before any proof, or junk, ends it.
        var fresh = LocalWire.Session(group: g, me: t.caller.engine.saved!.me, identity: t.caller.identity)
        XCTAssertEqual(fresh.take(LocalWire.Session(group: g, me: 9, identity: DeviceIdentity()).receipt(for: 1), at: t.clock.now).events, [])
        XCTAssertTrue(fresh.broken)
        var junk = LocalWire.Session(group: g, me: 1, identity: DeviceIdentity())
        _ = junk.take(Data([0xFF, 0xFF, 1, 2]), at: t.clock.now)
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
