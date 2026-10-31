import XCTest
@testable import helpandeyeCore

// If the first coordinator's phone is lost (decision 20): a deputy, two coordinators, or one after
// seven days' silence take over; the lost phone is removed, the keys change, and the relay follows.

@MainActor final class TakeoverTests: XCTestCase {
    var t: EngineTests!
    var second: Phone!
    var third: Phone!
    var n2: UInt16 { second.engine.saved!.me }
    var n3: UInt16 { third.engine.saved!.me }
    var coordinator: Phone { t.coordinator }
    var caller: Phone { t.caller }
    var responder: Phone { t.responder }
    var air: Air { t.air }

    override func setUp() async throws {
        t = EngineTests()
        try await t.setUp()
        second = Phone(air: air, clock: t.clock)
        third = Phone(air: air, clock: t.clock)
        t.join(second, call: false, respond: true)
        t.join(third, call: false, respond: true)
        await air.run()
        coordinator.engine.promote(n2)
        coordinator.engine.promote(n3)
        for p in air.phones { p.relay.isConfigured = true }
        await t.relaySetUp()
        XCTAssertEqual(air.relay.owner, coordinator.relay.key)
        XCTAssertEqual(caller.engine.group?.member(n3)?.role, .coordinator)
    }

    /// The first coordinator's phone is lost: nothing more comes from it.
    func lose(_ p: Phone) { p.mesh.isReady = false; p.relay.isConfigured = false }

    func everyoneFollows(_ newFirst: Phone, file: StaticString = #filePath, line: UInt = #line) {
        let n = newFirst.engine.saved!.me
        let phones: [Phone] = [caller, responder, second, third]
        for p in phones where p !== newFirst {
            XCTAssertEqual(p.engine.group?.primaryCoordinator, n, "\(p.engine.saved!.me) follows the new first coordinator", file: file, line: line)
            XCTAssertNil(p.engine.group?.member(1), "the lost phone is out", file: file, line: line)
            XCTAssertTrue(p.engine.group?.removedMembers.contains(1) == true, file: file, line: line)
            XCTAssertEqual(p.engine.group?.membershipVersion, newFirst.engine.group?.membershipVersion, file: file, line: line)
        }
        XCTAssertTrue(newFirst.engine.isPrimaryCoordinator, file: file, line: line)
        XCTAssertNotNil(newFirst.engine.group?.previousSecrets, "new keys, as after any removal", file: file, line: line)
        XCTAssertEqual(air.relay.owner, newFirst.relay.key, "the relay takes the new first coordinator, under the same group ID", file: file, line: line)
        XCTAssertTrue(air.relay.removed.contains(coordinator.relay.key!), "and has the lost phone's key as removed", file: file, line: line)
    }

    func testTheDeputyTakesOverAtOnce() async {
        coordinator.engine.nameDeputy(n2)
        await air.run()
        XCTAssertEqual(caller.engine.group?.currentDeputy, n2, "everyone is told who the deputy is")
        XCTAssertEqual(third.engine.group?.currentDeputy, n2)
        XCTAssertEqual(coordinator.engine.activity.log.entries.last?.text, "You named Responder as deputy")
        XCTAssertEqual(third.engine.activity.log.entries.last?.text, "Sam named \(third.engine.name(ofMember: n2)) as deputy")
        XCTAssertNil(third.engine.takeoverPath, "only the deputy may take over at once")
        lose(coordinator)
        XCTAssertEqual(second.engine.takeoverPath, .deputy)
        XCTAssertTrue(second.engine.takeOver())
        await air.run()
        everyoneFollows(second)
        XCTAssertEqual(second.engine.activity.log.entries.last?.text, "You took over as first coordinator from Sam, as the deputy they named")
        XCTAssertEqual(third.engine.activity.log.entries.last?.text, "\(third.engine.name(ofMember: n2)) took over as first coordinator from Sam, as the deputy they named")
        XCTAssertNil(second.engine.group?.deputy, "the new first coordinator names their own")
        // The group went on with its keys changed: the caller waits for an update code, as after
        // any removal of someone who could respond, and the new first coordinator can remove people.
        XCTAssertTrue(caller.engine.group!.needsKeyUpdate)
        second.engine.removeMember(responder.engine.saved!.me)
        await air.run()
        XCTAssertNil(caller.engine.group?.member(responder.engine.saved!.me), "the new first coordinator's removals are followed")
        XCTAssertFalse(air.relay.isMember(responder.relay.key!), "by the relay too")
    }

    func testAReplacedDeputyCannotTakeOverAtOnce() async {
        coordinator.engine.nameDeputy(n2)
        await air.run()
        let first = second.engine.group!
        let naming = first.deputySignature
        coordinator.engine.nameDeputy(nil)
        await air.run()
        XCTAssertNil(caller.engine.group?.currentDeputy, "everyone is told there is no deputy now")
        coordinator.engine.tick()
        await air.run()
        XCTAssertEqual(air.relay.deputyVersion, coordinator.engine.group?.deputyVersion, "and the relay, with the member list")
        XCTAssertNil(second.engine.takeoverPath)
        lose(coordinator)
        // The old naming, kept and sent anyway, moves no one.
        var t = Takeover(from: 1, to: n2, version: 99, signatures: [signature(of: second, to: second)])
        t.deputyVersion = first.deputyVersion; t.deputySignature = naming
        caller.engine.receive(.takeover(t), via: .mesh)
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
    }

    func testTwoCoordinatorsTakeOverAtOnce() async {
        lose(coordinator)
        XCTAssertNil(third.engine.takeoverPath)
        XCTAssertFalse(third.engine.takeOver(), "one coordinator alone must wait")
        second.engine.agreeToTakeover(by: n3)
        await air.run()
        XCTAssertEqual(third.engine.takeoverPath, .agreed(by: n2))
        XCTAssertEqual(third.engine.activity.log.entries.last?.text, "\(third.engine.name(ofMember: n2)) agreed that you may take over as first coordinator")
        XCTAssertNil(second.engine.takeoverPath, "agreeing to another's takeover opens nothing for oneself")
        XCTAssertTrue(third.engine.takeOver())
        await air.run()
        everyoneFollows(third)
        XCTAssertEqual(second.engine.activity.log.entries.last?.text,
                       "\(second.engine.name(ofMember: n3)) took over as first coordinator from Sam, with your agreement")
    }

    func testOneCoordinatorTakesOverAfterSevenDaysOfSilence() async {
        lose(coordinator)
        await t.advance(6 * 86_400)
        XCTAssertNil(second.engine.takeoverPath)
        XCTAssertFalse(second.engine.takeOver(), "not before seven days")
        // Nor does a frame claiming it, signed by a coordinator alone, move anyone before then.
        let early = forgedTakeover(by: second, from: 1)
        caller.engine.receive(early, via: .mesh)
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
        await t.advance(86_400 + 60)
        XCTAssertEqual(second.engine.takeoverPath, .silence)
        XCTAssertEqual(second.engine.takeoverOpensAt!.timeIntervalSince(t.clock.now), -60, accuracy: 1)
        XCTAssertFalse(second.engine.takeOver(), "the relay is asked first")
        XCTAssertNil(second.engine.group?.takeover)
        await air.run()
        XCTAssertNil(second.engine.takeoverProblem)
        everyoneFollows(second)
        XCTAssertEqual(third.engine.activity.log.entries.last?.text, "\(third.engine.name(ofMember: n2)) took over as first coordinator from Sam, after seven days without word from them")
    }

    /// The new first coordinator's naming of a deputy counts on every phone and on the relay, even
    /// those that heard more of the lost phone's namings than the new first coordinator did.
    func testTheNewFirstCoordinatorsDeputyCountsWhereTheLostPhonesNamingsWentFurther() async {
        coordinator.engine.nameDeputy(n3)
        await air.run()
        // The second coordinator is out of touch while the deputy is changed twice more.
        second.mesh.isReady = false; second.relay.isConfigured = false
        coordinator.engine.nameDeputy(nil)
        await air.run()
        coordinator.engine.nameDeputy(n3)
        coordinator.engine.tick()
        await air.run()
        second.mesh.isReady = true; second.relay.isConfigured = true
        XCTAssertEqual(second.engine.group?.deputyVersion, 1)
        XCTAssertEqual(caller.engine.group?.deputyVersion, 3)
        XCTAssertEqual(air.relay.deputyVersion, 3)
        lose(coordinator)
        await t.advance(8 * 86_400)
        XCTAssertEqual(second.engine.takeoverPath, .silence)
        second.engine.takeOver()
        await air.run()
        everyoneFollows(second)
        second.engine.nameDeputy(n3)
        second.engine.tick()
        await air.run()
        for p in [caller, responder, third] as [Phone] {
            XCTAssertEqual(p.engine.group?.currentDeputy, n3, "\(p.engine.saved!.me) takes the new first coordinator's deputy")
        }
        XCTAssertEqual(air.relay.deputyVersion, second.engine.group?.deputyVersion, "and so does the relay")
    }

    /// The third coordinator, the deputy, takes over just as the second does with the third's
    /// agreement, before either hears the other.
    private func twoTakeOversAtOnce() async {
        coordinator.engine.nameDeputy(n3)
        await air.run()
        lose(coordinator)
        third.engine.agreeToTakeover(by: n2)
        await air.run()
        XCTAssertEqual(second.engine.takeoverPath, .agreed(by: n3))
        XCTAssertEqual(third.engine.takeoverPath, .deputy)
        XCTAssertTrue(second.engine.takeOver())
        XCTAssertTrue(third.engine.takeOver())
        await air.run()
    }

    /// The loser's phone steps back to the keys every member still has, says so calmly, and takes
    /// the winner's update code.
    private func stepsBack(_ loser: Phone, to winner: Phone, file: StaticString = #filePath, line: UInt = #line) throws {
        let w = winner.engine.saved!.me
        let g = try XCTUnwrap(loser.engine.group)
        XCTAssertFalse(loser.engine.isPrimaryCoordinator, file: file, line: line)
        XCTAssertEqual(loser.engine.activity.tookOverFirst, w, file: file, line: line)
        XCTAssertEqual(loser.engine.activity.log.entries.last?.text,
                       "\(loser.engine.name(ofMember: w)) also took over as first coordinator, and the group follows them rather than you", file: file, line: line)
        XCTAssertEqual(g.secrets.channelSecret, winner.engine.group?.previousSecrets?.channelSecret, "the keys before, as every member has", file: file, line: line)
        XCTAssertNil(g.previousSecrets, file: file, line: line)
        XCTAssertTrue(g.needsKeyUpdate, file: file, line: line)
        let update = try Joining.update(XCTUnwrap(winner.engine.group), for: XCTUnwrap(g.member(loser.engine.saved!.me)), coordinator: winner.identity)
        loser.engine.applyKeyUpdate(try Joining.openUpdate(update, current: g, me: loser.identity, relayOwner: loser.engine.activity.relayOwner))
        XCTAssertEqual(loser.engine.group?.secrets, winner.engine.group?.secrets, file: file, line: line)
        XCTAssertFalse(loser.engine.group!.needsKeyUpdate, file: file, line: line)
        XCTAssertNil(loser.engine.activity.tookOverFirst, file: file, line: line)
    }

    /// Two takeovers at once: the second's phone is offline just then, so the relay takes the
    /// third's. Phones that have not read the relay yet follow the lower member number, the
    /// second; once they read it, every phone follows the third, the second's included.
    func testTwoTakeoversAtOnceSettleOnTheOneTheRelayTook() async throws {
        second.relay.isConfigured = false
        await twoTakeOversAtOnce()
        XCTAssertEqual(air.relay.owner, third.relay.key)
        XCTAssertTrue(third.engine.isPrimaryCoordinator, "the relay took it")
        XCTAssertTrue(second.engine.isPrimaryCoordinator, "not heard from the relay yet")
        for p in [caller, responder] as [Phone] { XCTAssertEqual(p.engine.group?.primaryCoordinator, n2, "the lower member number, for now") }
        second.relay.isConfigured = true
        air.poll()
        await air.run()
        everyoneFollows(third)
        try stepsBack(second, to: third)
        XCTAssertEqual(responder.engine.group?.takeover?.to, n3)
        // The second's phone, sending its own list again, is refused; the relay keeps the third.
        second.engine.tick()
        await air.run()
        XCTAssertEqual(air.relay.owner, third.relay.key)
        XCTAssertFalse(second.engine.isPrimaryCoordinator)
    }

    /// With no relay, every phone follows the lower member number, the third's phone included.
    func testTwoTakeoversAtOnceWithoutARelaySettleOnTheLowerNumber() async throws {
        for p in air.phones { p.relay.isConfigured = false }
        await twoTakeOversAtOnce()
        XCTAssertLessThan(n2, n3)
        for p in [caller, responder, third] as [Phone] {
            XCTAssertEqual(p.engine.group?.primaryCoordinator, n2, "\(p.engine.saved!.me) follows the second")
            XCTAssertNil(p.engine.group?.member(1))
            XCTAssertEqual(p.engine.group?.membershipVersion, second.engine.group?.membershipVersion)
        }
        XCTAssertTrue(second.engine.isPrimaryCoordinator)
        try stepsBack(third, to: second)
        // Heard again, as during the changeover, nothing moves.
        await t.advance(86_400 + 60)
        for p in [caller, responder, third] as [Phone] { XCTAssertEqual(p.engine.group?.primaryCoordinator, n2) }
        XCTAssertTrue(second.engine.isPrimaryCoordinator)
    }

    /// A phone that alone heard nothing for a week (abroad, say) asks the relay, which has heard
    /// from the first coordinator's phone: nothing changes, anywhere, and it says why.
    func testTheRelayHavingHeardTheFirstCoordinatorWithinAWeekKeepsThem() async {
        lose(coordinator)
        for _ in 0..<8 {
            await t.advance(86_400)
            air.relay.heard(coordinator.relay.key!, at: t.clock.now)
        }
        XCTAssertEqual(second.engine.takeoverPath, .silence, "nothing heard on this phone for a week")
        let sends = air.groupSends.count
        XCTAssertFalse(second.engine.takeOver())
        XCTAssertTrue(second.engine.askingRelayToTakeOver)
        await air.run()
        XCTAssertFalse(second.engine.askingRelayToTakeOver)
        XCTAssertEqual(second.engine.takeoverProblem, "Sam's phone has been in touch in the last week, so it cannot be taken over yet.")
        XCTAssertFalse(second.engine.isPrimaryCoordinator)
        XCTAssertNil(second.engine.group?.previousSecrets, "no keys of its own")
        XCTAssertNotNil(second.engine.group?.member(1))
        for p in [caller, responder, third] as [Phone] { XCTAssertEqual(p.engine.group?.primaryCoordinator, 1) }
        XCTAssertEqual(air.groupSends.count, sends, "no takeover sent")
        XCTAssertEqual(air.relay.owner, coordinator.relay.key)
    }

    /// With no relay to confirm the silence, one coordinator alone cannot take over: a second
    /// must agree.
    func testWithoutARelayOneCoordinatorAloneNeedsASecond() async {
        for p in air.phones { p.relay.isConfigured = false }
        lose(coordinator)
        await t.advance(8 * 86_400)
        XCTAssertTrue(second.engine.primaryIsSilent)
        XCTAssertNil(second.engine.takeoverPath)
        XCTAssertFalse(second.engine.takeOver())
        await air.run()
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
        third.engine.agreeToTakeover(by: n2)
        await air.run()
        XCTAssertEqual(second.engine.takeoverPath, .agreed(by: n3))
        XCTAssertTrue(second.engine.takeOver())
        await air.run()
        for p in [caller, responder, third] as [Phone] { XCTAssertEqual(p.engine.group?.primaryCoordinator, n2) }
    }

    /// Phones pass on the acknowledgements they hold while a caller is still sending, so the lost
    /// phone's old one can arrive days later: it is not word from them now.
    func testAnOldAcknowledgementPassedOnDoesNotRestartTheSevenDays() async {
        let ack = HelpFrame.signedAck(unit: 70001, request: 1, responder: 1, at: t.clock.now, identity: coordinator.identity, group: t.gid)
        lose(coordinator)
        await t.advance(8 * 86_400)
        XCTAssertEqual(second.engine.takeoverPath, .silence)
        second.engine.receive(ack, via: .mesh)
        XCTAssertEqual(second.engine.takeoverPath, .silence, "an acknowledgement made eight days ago")
    }

    func testTheFirstCoordinatorBeingHeardKeepsTheSilencePathShut() async {
        // The first coordinator's daily member list is heard, so the seven days never run out.
        await t.advance(10 * 86_400)
        XCTAssertNil(second.engine.takeoverPath)
        XCTAssertFalse(second.engine.takeOver())
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
        XCTAssertEqual(air.relay.owner, coordinator.relay.key)
    }

    func testOnlyACoordinatorCanTakeOverOrAgree() async {
        lose(coordinator)
        // A responder's agreement opens nothing.
        responder.engine.agreeToTakeover(by: n3)
        await air.run()
        XCTAssertNil(third.engine.takeoverPath)
        XCTAssertTrue(third.engine.activity.takeoverConsents.isEmpty)
        await t.advance(8 * 86_400)
        XCTAssertNil(responder.engine.takeoverPath)
        XCTAssertFalse(responder.engine.takeOver())
        // A responder's signature is worth nothing on anyone's phone, even after seven days.
        caller.engine.receive(forgedTakeover(by: responder, from: 1), via: .mesh)
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
        // Nor can the first coordinator's own signature, or one coordinator's twice, stand for two.
        var t2 = Takeover(from: 1, to: n3, version: 99, signatures: [signature(of: third, to: third), signature(of: coordinator, to: third)])
        t.caller.engine.receive(.takeover(t2), via: .mesh)
        t2 = Takeover(from: 1, to: n3, version: 99, signatures: [signature(of: third, to: third), signature(of: third, to: third)])
        t.caller.engine.receive(.takeover(t2), via: .mesh)
        // A takeover of someone who is not the first coordinator changes nothing either.
        t.caller.engine.receive(forgedTakeover(by: third, from: n2), via: .mesh)
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
    }

    func testTheLostPhonesLaterFramesCountForNothing() async {
        coordinator.engine.nameDeputy(n2)
        await air.run()
        lose(coordinator)
        XCTAssertTrue(second.engine.takeOver())
        await air.run()
        // The lost phone turns up again, still believing it runs the group.
        coordinator.mesh.isReady = true; coordinator.relay.isConfigured = true
        let sentBefore = coordinator.relay.sent.count
        caller.engine.press(.red)
        await air.run()
        caller.engine.receive(.signedAck(unit: t.key.unit, request: t.key.request, responder: 1, at: t.clock.now, identity: coordinator.identity, group: t.gid), via: .mesh)
        coordinator.engine.removeMember(n3)
        coordinator.engine.nameDeputy(n3)
        await air.run()
        XCTAssertEqual(caller.request?.status, .waitingForResponder, "its acknowledgement does not reassure")
        XCTAssertEqual(caller.engine.group?.member(n3)?.role, .coordinator, "its removals change nothing")
        XCTAssertNil(caller.engine.group?.deputy)
        XCTAssertEqual(coordinator.relay.sent.count, sentBefore, "the relay refuses it")
        XCTAssertFalse(air.relay.isMember(coordinator.relay.key!))
        // Found with its deputy naming and a takeover of its own, it cannot take the group back.
        XCTAssertNil(coordinator.engine.takeoverPath)
    }

    func testAPhoneThatMissedTheTakeoverCatchesUpFromTheKeyUpdate() async {
        coordinator.engine.nameDeputy(n2)
        await air.run()
        lose(coordinator)
        air.keep = { frame, _, to in !(to === self.caller && { if case .takeover = frame { true } else { false } }()) }
        caller.relay.isConfigured = false
        XCTAssertTrue(second.engine.takeOver())
        await air.run()
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1, "the caller never heard")
        XCTAssertNotNil(caller.engine.group?.member(1))
        let g = second.engine.group!
        let update = try! Joining.update(g, for: g.member(caller.engine.saved!.me)!, coordinator: second.identity)
        let opened = try! Joining.openUpdate(update, current: caller.engine.group!, me: caller.identity)
        caller.engine.applyKeyUpdate(opened)
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, n2)
        XCTAssertNil(caller.engine.group?.member(1))
        XCTAssertEqual(caller.engine.group?.secrets, g.secrets.sanitised)
        XCTAssertFalse(caller.engine.group!.needsKeyUpdate)
        // An update sealed by a coordinator who did not take over still opens nothing.
        XCTAssertThrowsError(try Joining.openUpdate(try! Joining.update(g, for: g.member(caller.engine.saved!.me)!, coordinator: third.identity),
                                                    current: responder.engine.group!, me: responder.identity))
    }

    func testTheDailyRepeatCarriesTheTakeoverToAPhoneThatMissedIt() async {
        lose(coordinator)
        second.engine.agreeToTakeover(by: n3)
        await air.run()
        air.keep = { frame, _, to in !(to === self.caller && { if case .takeover = frame { true } else { false } }()) }
        caller.relay.isConfigured = false
        XCTAssertTrue(third.engine.takeOver())
        await air.run()
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, 1)
        air.keep = { _, _, _ in true }
        await t.advance(86_400 + 60)
        XCTAssertEqual(caller.engine.group?.primaryCoordinator, n3, "repeated with the member list during the changeover")
    }

    func testTheRelayTakesTheNewAuthorityOnlyWithProof() async {
        lose(coordinator)
        let relay = air.relay
        let c = { (p: Phone) in RelayModel.Entry(key: p.relay.key!, role: "coordinator") }
        let m = { (p: Phone) in RelayModel.Entry(key: p.relay.key!, role: "member") }
        let list = [c(second), c(third), m(caller), m(responder)]
        let gid = caller.engine.group!.secrets.groupID
        let sig = { (by: Phone, to: Phone) in
            RelayProtocol.Takeover.Signature(key: by.relay.key!, signature: HelpFrame.takeoverSignature(fromKey: self.coordinator.identity.signingPublicKey, toKey: to.identity.signingPublicKey, identity: by.identity, group: gid).base64EncodedString())
        }
        let alone = RelayProtocol.Takeover(from: coordinator.relay.key!, to: second.relay.key!, signatures: [sig(second, second)], deputy: nil)
        // One coordinator alone, within seven days: not yet; a stranger's or a member's signature: never.
        XCTAssertEqual(relay.setMembers(signer: second.relay.key!, generation: 9, members: list, removed: [coordinator.relay.key!], primary: second.relay.key!, groupID: gid, takeover: alone, now: t.clock.now), 425)
        let byMember = RelayProtocol.Takeover(from: coordinator.relay.key!, to: second.relay.key!, signatures: [sig(second, second), sig(responder, second)], deputy: nil)
        XCTAssertEqual(relay.setMembers(signer: second.relay.key!, generation: 9, members: list, removed: [coordinator.relay.key!], primary: second.relay.key!, groupID: gid, takeover: byMember, now: t.clock.now), 403)
        XCTAssertEqual(relay.setMembers(signer: third.relay.key!, generation: 9, members: list, removed: [coordinator.relay.key!], primary: second.relay.key!, groupID: gid, takeover: alone, now: t.clock.now), 425, "only the new first coordinator's own list brings it")
        XCTAssertEqual(relay.setMembers(signer: second.relay.key!, generation: 9, members: list, removed: [], primary: second.relay.key!, groupID: gid, takeover: alone, now: t.clock.now.addingTimeInterval(8 * 86_400)), 400, "a takeover removes the lost phone")
        XCTAssertEqual(relay.owner, coordinator.relay.key)
        // The relay's own seven days, then accepted; and a wrongly named deputy does not shorten them.
        let fake = RelayProtocol.Takeover(from: coordinator.relay.key!, to: second.relay.key!, signatures: [sig(second, second)],
                                          deputy: .init(version: 1, signature: Data(count: 64).base64EncodedString()))
        XCTAssertEqual(relay.setMembers(signer: second.relay.key!, generation: 9, members: list, removed: [coordinator.relay.key!], primary: second.relay.key!, groupID: gid, takeover: fake, now: t.clock.now), 425)
        XCTAssertEqual(relay.setMembers(signer: second.relay.key!, generation: 9, members: list, removed: [coordinator.relay.key!], primary: second.relay.key!, groupID: gid, takeover: alone, now: t.clock.now.addingTimeInterval(8 * 86_400)), 200)
        XCTAssertEqual(relay.owner, second.relay.key)
        XCTAssertFalse(relay.isMember(coordinator.relay.key!))
        // Done once, the record on later lists changes nothing, from anyone.
        XCTAssertEqual(relay.setMembers(signer: third.relay.key!, generation: 10, members: list, removed: [coordinator.relay.key!], primary: second.relay.key!, groupID: gid, takeover: alone, now: t.clock.now), 200)
        XCTAssertEqual(relay.owner, second.relay.key)
    }

    func testAnOlderGroupLoadsWithNoDeputyAndNoTakeover() throws {
        let saved = try JSONEncoder().encode(caller.engine.group!)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        for k in ["deputy", "deputyVersion", "deputySignature", "takeover"] { json[k] = nil }
        let g = try JSONDecoder().decode(GroupState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(g.deputy); XCTAssertNil(g.takeover); XCTAssertEqual(g.primaryCoordinator, 1)
    }

    func testAPhoneSavedBeforeStartsItsSevenDaysWhenItFirstOpens() throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(caller.engine.saved!)) as? [String: Any])
        saved["primaryHeardAt"] = nil
        let s = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(try XCTUnwrap(s.primaryHeardAt).timeIntervalSinceNow, 0, accuracy: 5)
    }

    /// A takeover frame from `from` to `by`, with `by`'s signature alone.
    private func forgedTakeover(by: Phone, from: UInt16) -> HelpFrame {
        .takeover(Takeover(from: from, to: by.engine.saved!.me, version: 99, signatures: [signature(of: by, to: by, from: from)]))
    }

    private func signature(of by: Phone, to: Phone, from: UInt16 = 1) -> Takeover.Signature {
        let g = caller.engine.group!
        let fromKey = g.member(from)?.signingKey ?? coordinator.identity.signingPublicKey
        return .init(signer: by.engine.saved!.me, signature: HelpFrame.takeoverSignature(fromKey: fromKey, toKey: to.identity.signingPublicKey, identity: by.identity, group: g.secrets.groupID))
    }
}

extension GroupSecrets {
    /// As a caller holds them: without the responders' private key.
    var sanitised: GroupSecrets { var s = self; s.responderPrivateKey = nil; return s }
}
