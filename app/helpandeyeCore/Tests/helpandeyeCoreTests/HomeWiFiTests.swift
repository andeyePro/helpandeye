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

    func testWithWiFiAndTheRelayBothWorkingEachCallIsHeardOnce() async {
        for p in t.air.phones { p.relay.isConfigured = true }
        await t.relaySetUp()
        t.caller.engine.press(.red)
        await t.air.run()
        XCTAssertNil(t.caller.engine.addNote("Back door is open"))
        await t.air.run()
        let heard = t.responder.engine.activity.inbox.requests[t.key]
        XCTAssertEqual(heard?.heardOn, [.wifi, .internet])
        XCTAssertEqual(heard?.orderedNotes, ["Back door is open"], "once, though it came both ways")
        XCTAssertEqual(t.responder.engine.activity.inbox.requests.count, 1)
        XCTAssertEqual(t.caller.request?.routes[.wifi], .sent)
        XCTAssertEqual(t.caller.request?.routes[.internet], .sent)
        // Off the Wi-Fi, the relay alone still carries a follow-up.
        t.responder.wifi.network = nil
        t.caller.engine.add(.fallen)
        await t.air.run()
        XCTAssertEqual(t.responder.engine.activity.inbox.requests[t.key]?.orderedCategories, [.fallen])
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

    func testWithTheInternetRouteSetUpACoordinatorsMessageCountsOnlyIfTheRelayTookIt() async {
        t.coordinator.wifi.network = "elsewhere"
        for p in t.air.phones { p.relay.isConfigured = true }
        let refused = await t.caller.engine.askCoordinator(about: .sounds, "Too loud")
        XCTAssertNotNil(refused, "only the responder at home heard it; the relay did not take it")
        await t.relaySetUp()
        let sent = await t.caller.engine.askCoordinator(about: .sounds, "Too loud")
        XCTAssertNil(sent)
        await t.air.run()
        XCTAssertEqual(t.coordinator.engine.activity.changeRequests.count, 1)
    }

    /// Codex NR5: with no internet route, a request for the coordinators counts as sent only if a
    /// coordinator's phone took it in, not any member's.
    func testOnHomeWiFiAloneARequestForTheCoordinatorCountsOnlyIfTheirPhoneTookIt() async {
        t.coordinator.wifi.network = "elsewhere"
        let refused = await t.caller.engine.askCoordinator(about: .sounds, "Too loud")
        XCTAssertNotNil(refused, "only an ordinary responder was on the Wi-Fi")
        t.coordinator.wifi.network = "home"
        let sent = await t.caller.engine.askCoordinator(about: .sounds, "Too loud")
        XCTAssertNil(sent)
        await t.air.run()
        XCTAssertEqual(t.coordinator.engine.activity.changeRequests.count, 1)
    }

    /// Codex NR1: a reason for closing, still waiting on the Wi-Fi when this phone leaves and starts
    /// another group, never goes out to the new group.
    func testASendWaitingOnTheWiFiNeverGoesToAGroupJoinedMeanwhile() async {
        for p in t.air.phones { p.relay.isConfigured = true }
        await t.relaySetUp()
        t.caller.engine.press(.red)
        await t.air.run()
        let before = t.coordinator.relay.sent.count
        t.coordinator.wifi.whileWaiting = {
            self.t.coordinator.engine.leave()
            self.t.coordinator.engine.createGroup(name: "Hill Road", myName: "Sam", call: false)
        }
        XCTAssertTrue(t.coordinator.engine.close(t.key, consent: false, reason: "Spoke to her, she has had her insulin"))
        await t.air.run()
        XCTAssertEqual(t.coordinator.engine.group?.name, "Hill Road")
        let reason = Data("insulin".utf8)
        XCTAssertFalse(t.coordinator.relay.sent.dropFirst(before).contains { $0.0.encoded().range(of: reason) != nil },
                       "nothing from the old group went out sealed for the new one")
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
                let r = a.take(inA.subdata(in: i..<min(i + 5, inA.count))); seenA += r.events; toB += r.reply
            }
            for i in stride(from: 0, to: inB.count, by: 5) {
                let r = b.take(inB.subdata(in: i..<min(i + 5, inB.count))); seenB += r.events; toA += r.reply
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
        let got = responder.take(try XCTUnwrap(caller.message(call, id: 7))).events
        XCTAssertEqual(got, [.frame(call, id: 7)])
        XCTAssertEqual(caller.take(try XCTUnwrap(responder.receipt(for: 7))).events, [.receipt(7)])
        XCTAssertNil(responder.receipt(for: 7), "one receipt per frame taken in")
    }

    /// Codex NR3: something on the network between two members, passing their handshake along,
    /// must not be able to make a receipt up, swap the frame, or hand a phone back its own.
    func testNothingBetweenTwoMembersCanMakeUpOrRedirectAReceipt() throws {
        let g = t.caller.engine.group!
        var caller = LocalWire.Session(group: g, me: t.caller.engine.saved!.me, identity: t.caller.identity)
        var responder = LocalWire.Session(group: g, me: t.responder.engine.saved!.me, identity: t.responder.identity)
        _ = connect(&caller, &responder)
        let call = HelpFrame.call(unit: 70001, request: 1, colour: .red, sentAt: 1_793_000_000)
        let sent = try XCTUnwrap(caller.message(call, id: 7))
        // A bare number, the old receipt, from a stranger: ignored.
        XCTAssertEqual(caller.take(LocalWire.Session.wrap(.receipt, LocalWire.Session.u32(7))).events, [])
        // The caller's own frame handed back to it is neither a frame nor a reason to confirm.
        XCTAssertEqual(caller.take(sent).events, [])
        // A receipt for a different frame with the same number does not confirm this one.
        var other = caller
        _ = responder.take(try XCTUnwrap(other.message(.call(unit: 70001, request: 2, colour: .red, sentAt: 1_793_000_000), id: 7)))
        XCTAssertEqual(caller.take(try XCTUnwrap(responder.receipt(for: 7))).events, [])
        // A receipt from another connection between the same two does not count on this one.
        var caller2 = LocalWire.Session(group: g, me: t.caller.engine.saved!.me, identity: t.caller.identity)
        var responder2 = LocalWire.Session(group: g, me: t.responder.engine.saved!.me, identity: t.responder.identity)
        _ = connect(&caller2, &responder2)
        _ = responder2.take(try XCTUnwrap(caller2.message(call, id: 8)))
        _ = responder.take(sent)
        XCTAssertEqual(caller.take(try XCTUnwrap(responder2.receipt(for: 8))).events, [])
        XCTAssertEqual(caller.take(try XCTUnwrap(responder.receipt(for: 7))).events, [.receipt(7)], "the real one still counts")
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
        XCTAssertEqual(fresh.take(LocalWire.Session.wrap(.receipt, Data(count: 40))).events, [])
        XCTAssertTrue(fresh.broken)
        var junk = LocalWire.Session(group: g, me: 1, identity: DeviceIdentity())
        _ = junk.take(Data([0xFF, 0xFF, 1, 2]))
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
