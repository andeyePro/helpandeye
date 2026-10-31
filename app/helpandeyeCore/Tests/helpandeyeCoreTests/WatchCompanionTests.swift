import XCTest
@testable import helpandeyeCore

/// A caller's watch, out of reach of their phone, calling over the internet as the same member.
@MainActor final class WatchCompanionTests: XCTestCase {
    var air: Air!
    var clock: Clock!
    var coordinator: Phone!
    var caller: Phone!
    var responder: Phone!
    var watch: Phone!

    func join(_ p: Phone, call: Bool, respond: Bool) {
        let c = coordinator.engine!
        let invite = Joining.invitation(for: c.group!, coordinator: coordinator.identity)
        let request = Joining.request(invite, name: "Member", call: call, respond: respond, me: p.identity)
        var welcome: Joining.Welcome?
        c.updateGroup { g in welcome = try! Joining.admit(request, to: &g, invite: invite, coordinator: coordinator.identity) }
        p.engine.joined(try! Joining.open(welcome!, invite: invite, me: p.identity), as: welcome!.memberNumber)
    }

    func relaySetUp() async {
        coordinator.engine.tick()
        await air.run()
    }

    func advance(_ seconds: TimeInterval) async {
        clock.now = clock.now.addingTimeInterval(seconds)
        for p in air.phones { p.engine.tick() }
        await air.run()
    }

    override func setUp() async throws {
        air = Air(); clock = Clock()
        coordinator = Phone(air: air, clock: clock)
        caller = Phone(air: air, clock: clock)
        responder = Phone(air: air, clock: clock)
        coordinator.engine.createGroup(name: "Mill Lane", myName: "Sam", call: false)
        join(caller, call: true, respond: false)
        join(responder, call: false, respond: true)
        await air.run()
        watch = Phone(air: air, clock: clock, watchOf: caller)
        XCTAssertTrue(watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: caller.identity)))
        watch.mesh.isReady = false
        for p in air.phones { p.relay.isConfigured = true }
        await relaySetUp()
        await air.run()
    }

    func testTheWatchCallsAloneAndOnlyAHumanAckShowsSeen() async {
        caller.relay.isConfigured = false; caller.mesh.isReady = false
        watch.engine.press(.red)
        await air.run()
        let r = watch.request!
        XCTAssertGreaterThanOrEqual(r.number, 0x8000, "the watch numbers its calls apart from the phone's")
        XCTAssertEqual(r.routes[.internet], .sent)
        let key = IncomingRequest.Key(unit: r.unit, request: r.number)
        XCTAssertNotNil(responder.alerts.scheduled[key], "the responder is alerted")
        await advance(3600)
        XCTAssertEqual(watch.request?.status, .waitingForResponder, "nothing acknowledges by itself")
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(watch.request?.status, .seen(responder: responder.engine.saved!.me))
    }

    func testPhoneAndWatchNeverReuseANumber() async {
        caller.engine.press(.amber)
        watch.engine.press(.amber)
        await air.run()
        XCTAssertLessThan(caller.request!.number, 0x8000)
        XCTAssertNotEqual(caller.request!.number, watch.request!.number)
        // A newer handover from the phone keeps the watch's own numbering.
        let before = watch.engine.saved!.lastRequest
        watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: caller.identity))
        XCTAssertEqual(watch.engine.saved!.lastRequest, before)
    }

    /// Full review: a replaced or erased watch carries on above the numbers the phone has had,
    /// and a different press under an old number is still sent by the phone.
    func testANewWatchNeverReusesACallNumber() async {
        watch.engine.press(.red)
        XCTAssertTrue(caller.engine.adopt(watch.request!.callFrame))
        let used = watch.request!.number
        let fresh = WatchHandover(saved: caller.engine.saved!, identity: caller.identity).state(keeping: nil)
        XCTAssertEqual(fresh.lastRequest, used, "a new watch numbers its next call above it")
        await advance(3600)
        let reused = HelpFrame.call(unit: watch.request!.unit, request: used, colour: .amber, sentAt: UInt32(clock.now.timeIntervalSince1970))
        XCTAssertTrue(caller.engine.adopt(reused))
        XCTAssertEqual(caller.engine.activity.outgoing.filter { $0.number == used }.map(\.colour), [.amber], "sent as the new call it is")
    }

    func testAWatchCallSentByBothWatchAndPhoneIsOneCall() async {
        watch.engine.press(.red)
        XCTAssertTrue(caller.engine.adopt(watch.request!.callFrame), "the phone takes its watch's call")
        XCTAssertTrue(caller.engine.adopt(watch.request!.callFrame), "and taking it twice changes nothing")
        await air.run()
        let key = IncomingRequest.Key(unit: watch.request!.unit, request: watch.request!.number)
        XCTAssertEqual(caller.request?.number, key.request, "under the watch's number, not a second call")
        XCTAssertEqual(caller.engine.activity.outgoing.filter { $0.number == key.request }.count, 1)
        XCTAssertEqual(responder.engine.activity.inbox.requests.count, 1, "responders hear one call")
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(watch.request?.status, .seen(responder: responder.engine.saved!.me))
        XCTAssertEqual(caller.request?.status, .seen(responder: responder.engine.saved!.me))
        XCTAssertFalse(responder.engine.adopt(watch.request!.callFrame), "only the caller's own phone takes it")
        XCTAssertFalse(caller.engine.adopt(.call(unit: key.unit, request: 5, colour: .red, sentAt: 0)), "only watch-numbered calls")
    }

    /// Codex NR2: the watch's I'm OK, reaching the phone after Help was pressed there, leaves that
    /// Help open and urgent, even where I'm OK closes calls.
    func testAWatchImOKArrivingLateNeverSettlesAHelpPressedOnThePhoneSinceIt() async {
        coordinator.engine.updateGroup { $0.policy.profiles[0].afterOK = .closesCall }
        await air.run()
        caller.engine.press(.amber)
        await air.run()
        let amber = caller.request!.number
        clock.now = clock.now.addingTimeInterval(5)
        watch.engine.press(.green)
        let ok = watch.request!.callFrame
        clock.now = clock.now.addingTimeInterval(0.5)
        caller.engine.press(.red)
        let red = caller.request!.number
        XCTAssertTrue(caller.engine.adopt(ok))
        await air.run()
        XCTAssertNotNil(caller.engine.activity.outgoing.first { $0.number == amber }?.settled, "what was open when I'm OK was pressed is settled")
        XCTAssertNil(caller.engine.activity.outgoing.first { $0.number == red }?.settled, "the later Help is not")
        let heard = responder.engine.activity.inbox.requests[IncomingRequest.Key(unit: caller.request!.unit, request: red)]
        XCTAssertEqual(heard?.isOpen, true)
        XCTAssertEqual(heard?.callerIsOK, false)
    }

    func testHeldAlertsLetGoLateBuzzOnceNotInABurst() {
        let t = clock.now
        let a = Alert(key: .init(unit: 1, request: 1), title: "t", body: "b", calm: false,
                      times: [t.addingTimeInterval(-300), t.addingTimeInterval(-120), t.addingTimeInterval(60)])
        XCTAssertEqual(a.fromNow(t).times, [t, t.addingTimeInterval(60)])
        XCTAssertEqual(Alert(key: a.key, title: "t", body: "b", calm: false, times: [t.addingTimeInterval(60)]).fromNow(t).times, [t.addingTimeInterval(60)])
    }

    func testAHandoverCarriesEveryGroupTheOwnerRespondsIn() throws {
        let other = coordinator.engine.saved!
        let h = WatchHandover(saved: responder.engine.saved!, identity: responder.identity, others: [other])
        let back = try JSONDecoder().decode(WatchHandover.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.each.map(\.group.name), [responder.engine.group!.name, other.group.name])
        XCTAssertTrue(back.each.allSatisfy { $0.keys == responder.identity.rawRepresentation })
        // One from a phone before several groups still opens.
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        plain["others"] = nil
        let old = try JSONDecoder().decode(WatchHandover.self, from: JSONSerialization.data(withJSONObject: plain))
        XCTAssertEqual(old.each.count, 1)
    }

    /// Watch review: the group goes to the watch whole, so what it needs to act for the phone goes
    /// with it: the relay pass (sent with every request, so a relay that requires one takes the
    /// watch's call) and the settings' version and signer.
    func testAHandoverCarriesThePassAndTheSettingsSigner() async throws {
        let token = "1.\(RelayProtocol.id(of: coordinator.engine.group!.secrets.groupID)).1800000000.\(String(repeating: "B", count: 86))"
        XCTAssertTrue(coordinator.engine.setRelayPass(token))
        await air.run()
        let s = caller.engine.saved!
        XCTAssertEqual(s.group.relayPass, token, "the phone heard the pass")
        let back = try JSONDecoder().decode(WatchHandover.self, from: JSONEncoder().encode(WatchHandover(saved: s, identity: caller.identity)))
        XCTAssertEqual(back.group.pass?.token, token)
        XCTAssertEqual(back.group.settingsVersion, s.group.settingsVersion)
        XCTAssertEqual(back.group.settingsSigner, coordinator.engine.saved!.me)
        for p in air.phones { p.relay.requiresPass = true }
        XCTAssertTrue(watch.engine.take(back))
        watch.engine.press(.red)
        await air.run()
        XCTAssertEqual(watch.request?.routes[.internet], .sent, "the watch sends the group's pass")
    }

    /// Watch review: told through the handover when its keys stop, a watch out of reach shows the
    /// cross from that day, as the phone does, and works again once the phone has the new keys.
    func testTheWatchIsToldWhenItsKeysStopAndShowsTheCrossAfter() async {
        coordinator.engine.updateGroup { $0.remove(self.responder.engine.saved!.me, at: self.clock.now) }
        await air.run()
        XCTAssertNotNil(caller.engine.keysEndAt)
        XCTAssertTrue(watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: caller.identity)))
        XCTAssertEqual(watch.engine.keysEndAt, caller.engine.keysEndAt)
        XCTAssertFalse(watch.engine.keysExpired)
        await advance(GroupState.changeoverPeriod + 60)
        XCTAssertTrue(watch.engine.keysExpired)
        watch.engine.press(.red)
        await air.run()
        XCTAssertEqual(watch.request?.status, .notSent)
        XCTAssertEqual(watch.request?.routes[.internet], .failed(HelpEngine.keysExpiredReason))
        let g = coordinator.engine.group!
        let update = try! Joining.update(g, for: g.member(caller.engine.saved!.me)!, coordinator: coordinator.identity)
        caller.engine.applyKeyUpdate(try! Joining.openUpdate(update, current: caller.engine.group!, me: caller.identity))
        XCTAssertTrue(watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: caller.identity)))
        XCTAssertNil(watch.engine.keysEndAt)
        XCTAssertTrue(watch.engine.availableRoutes.contains(.internet))
    }

    /// Watch review: a phone updated before its watch may hand over a choice, a setting or a group
    /// the watch cannot read. That part is left out; the rest still comes, so the watch keeps
    /// following its phone.
    func testAHandoverFromANewerPhoneStillOpens() throws {
        let h = WatchHandover(saved: responder.engine.saved!, identity: responder.identity, others: [coordinator.engine.saved!])
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        plain["ownChosen"] = ["sounds", "aSettingToCome"]
        plain["own"] = ["id": 0, "name": "Mine", "face": "aFaceToCome"]
        plain["others"] = (plain["others"] as! [[String: Any]]) + [["group": ["name": "unreadable"], "me": 1]]
        let back = try JSONDecoder().decode(WatchHandover.self, from: JSONSerialization.data(withJSONObject: plain))
        XCTAssertEqual(back.ownChosen, [.sounds])
        XCTAssertEqual(back.own?.name, "Mine")
        XCTAssertEqual(back.own?.face, .wordsAndSymbol, "an unknown face falls back")
        XCTAssertEqual(back.others.map(\.group.name), [coordinator.engine.group!.name])
    }

    /// Watch review: the phone's word that it left a group may be replaced on its way by the next
    /// handover, so a handover of another group, or another place in one, starts the watch afresh
    /// by itself. A key update after a removal is the same group and does not.
    func testAHandoverOfAnotherGroupStartsTheWatchAfresh() throws {
        let held = watch.engine.saved!
        XCTAssertFalse(WatchHandover(saved: caller.engine.saved!, identity: caller.identity).startsAfresh(from: held))
        XCTAssertFalse(WatchHandover(saved: caller.engine.saved!, identity: caller.identity).startsAfresh(from: nil))
        var rekeyed = caller.engine.saved!
        rekeyed.group.secrets = rekeyed.group.secrets.rotated()
        XCTAssertFalse(WatchHandover(saved: rekeyed, identity: caller.identity).startsAfresh(from: held), "new keys, same group")
        let elsewhere = Phone(air: air, clock: clock)
        elsewhere.engine.createGroup(name: "Station Road", myName: "Jo", call: true)
        var moved = elsewhere.engine.saved!
        moved.me = held.me
        XCTAssertTrue(WatchHandover(saved: moved, identity: caller.identity).startsAfresh(from: held), "another group")
        var renumbered = caller.engine.saved!
        renumbered.me = held.me + 1
        XCTAssertTrue(WatchHandover(saved: renumbered, identity: caller.identity).startsAfresh(from: held), "another place in it")
        XCTAssertEqual(WatchHandover(saved: moved, identity: caller.identity).state(keeping: held).lastRequest, 0,
                       "another group's numbering starts again")
    }

    /// Watch review: an acknowledgement the watch took from its phone is taken back on the watch,
    /// with its alerts again, when the person who made it is removed: the watch settles a call on
    /// a signature it checked, never on its phone's word alone, so a stale word cannot silence it.
    func testAnAcknowledgementTakenFromThePhoneIsTakenBackOnARemoval() async {
        let other = Phone(air: air, clock: clock)
        join(other, call: false, respond: true)
        other.relay.isConfigured = true
        await air.run()
        let rw = Phone(air: air, clock: clock, watchOf: responder)
        rw.engine.take(WatchHandover(saved: responder.engine.saved!, identity: responder.identity))
        rw.mesh.isReady = false; rw.relay.isConfigured = true
        caller.engine.press(.red)
        await air.run()
        let key = IncomingRequest.Key(unit: caller.request!.unit, request: caller.request!.number)
        other.engine.acknowledge(key)
        await air.run()
        let ack = responder.engine.activity.inbox.requests[key]!.acks[other.engine.saved!.me]!
        rw.engine.receive(ack, via: .internet)
        XCTAssertEqual(rw.engine.activity.inbox.requests[key]?.isOpen, false)
        XCTAssertNil(rw.alerts.scheduled[key])
        coordinator.engine.updateGroup { $0.remove(other.engine.saved!.me, at: self.clock.now) }
        await air.run()
        rw.engine.take(WatchHandover(saved: responder.engine.saved!, identity: responder.identity))
        XCTAssertEqual(rw.engine.activity.inbox.requests[key]?.isOpen, true, "open again on the watch")
        XCTAssertNotNil(rw.alerts.scheduled[key], "and alerting again")
    }

    /// Watch review: a responder's phone that acknowledged, or heard an acknowledgement, over the
    /// radio alone gives its watch the signed acknowledgement it holds (in the application
    /// context), so the watch stops alerting at once instead of buzzing for a call already in hand.
    func testAnAcknowledgementThePhoneHoldsSettlesTheWatchToo() async {
        let rw = Phone(air: air, clock: clock, watchOf: responder)
        rw.engine.take(WatchHandover(saved: responder.engine.saved!, identity: responder.identity))
        rw.mesh.isReady = false; rw.relay.isConfigured = true
        caller.engine.press(.red)
        await air.run()
        let key = IncomingRequest.Key(unit: caller.request!.unit, request: caller.request!.number)
        XCTAssertNotNil(rw.alerts.scheduled[key])
        responder.relay.isConfigured = false
        responder.engine.acknowledge(key)
        await air.run()
        XCTAssertNotNil(rw.alerts.scheduled[key], "over the radio alone, the watch cannot hear it")
        let ack = responder.engine.activity.inbox.requests[key]!.acks[responder.engine.saved!.me]!
        let forged = HelpFrame.signedAck(unit: key.unit, request: key.request, responder: responder.engine.saved!.me, at: clock.now,
                                         identity: DeviceIdentity(), group: caller.engine.group!.secrets.groupID)
        rw.engine.receive(forged, via: .internet)
        XCTAssertEqual(rw.engine.activity.inbox.requests[key]?.isOpen, true, "only a signature the watch can check counts")
        rw.engine.receive(ack, via: .internet)
        XCTAssertEqual(rw.engine.activity.inbox.requests[key]?.isOpen, false)
        XCTAssertNil(rw.alerts.scheduled[key])
        XCTAssertTrue(rw.alerts.cancelled.contains(key))
    }

    func testAWatchAcknowledgementGoesOnlyToAGroupItCanBeSureOf() {
        XCTAssertEqual(AckRouting.group(named: "gB", holding: ["gA", "gB"]), "gB")
        XCTAssertEqual(AckRouting.group(named: nil, holding: ["gA"]), "gA", "an older watch's ack, one group holds that call")
        XCTAssertNil(AckRouting.group(named: "", holding: ["gA", "gB"]), "two groups hold the same numbers: no guess")
        XCTAssertNil(AckRouting.group(named: nil, holding: []))
    }

    func testAHandoverWithOtherKeysIsRefused() {
        XCTAssertFalse(watch.engine.take(WatchHandover(saved: caller.engine.saved!, identity: DeviceIdentity())))
        XCTAssertFalse(responder.engine.take(WatchHandover(saved: responder.engine.saved!, identity: responder.identity)),
                       "a phone never takes a handover")
    }

    func testAResponderWatchAcknowledgesForItsOwner() async {
        let rw = Phone(air: air, clock: clock, watchOf: responder)
        rw.engine.take(WatchHandover(saved: responder.engine.saved!, identity: responder.identity))
        rw.mesh.isReady = false; rw.relay.isConfigured = true
        responder.relay.isConfigured = false; responder.mesh.isReady = false
        caller.engine.press(.red)
        await air.run()
        let key = IncomingRequest.Key(unit: caller.request!.unit, request: caller.request!.number)
        XCTAssertNotNil(rw.alerts.scheduled[key], "the watch alerts its wearer")
        rw.engine.acknowledge(key)
        await air.run()
        XCTAssertEqual(caller.request?.status, .seen(responder: responder.engine.saved!.me), "signed as its owner, it counts")
    }

    func testACoordinatorsWatchLeavesTheMemberListToThePhone() async {
        let cw = Phone(air: air, clock: clock, watchOf: coordinator)
        cw.engine.take(WatchHandover(saved: coordinator.engine.saved!, identity: coordinator.identity))
        cw.mesh.isReady = false; cw.relay.isConfigured = true
        await advance(2 * 86_400)
        XCTAssertEqual(cw.relay.publishes, 0, "only the phone publishes the member list")
        XCTAssertTrue(cw.engine.activity.notices.isEmpty, "rota gaps are the phone's to raise")
    }
}
