import XCTest
@testable import helpandeyeCore

final class GroupTests: XCTestCase {
    func newGroup(_ coord: DeviceIdentity) -> GroupState {
        GroupState(name: "Mill Lane", secrets: .random(),
                   members: [Member(number: 1, name: "Sam", role: .coordinator, publicKey: coord.publicKey)])
    }

    func testSecretsAreRandomAndTheRightSize() {
        let a = GroupSecrets.random(), b = GroupSecrets.random()
        XCTAssertEqual(a.channelSecret.count, 16); XCTAssertEqual(a.groupKey.count, 32); XCTAssertEqual(a.groupID.count, 16)
        XCTAssertNotEqual(a.channelSecret, b.channelSecret)
        XCTAssertNoThrow(try MeshCore.Command.setChannel(index: 1, name: "Help&I", secret: a.channelSecret).encoded())
    }

    func testThreeScanJoin() throws {
        let coord = DeviceIdentity(), newcomer = DeviceIdentity()
        var group = newGroup(coord)
        let invite = Joining.invitation(for: group, coordinator: coord)
        let inviteCode = try Joining.code(invite)
        let request = Joining.request(try Joining.decode(Joining.Invitation.self, from: inviteCode),
                                      name: "Alex", call: true, respond: false, me: newcomer)
        let welcome = try Joining.admit(try Joining.decode(Joining.JoinRequest.self, from: Joining.code(request)),
                                        to: &group, invite: invite, coordinator: coord)
        let joined = try Joining.open(try Joining.decode(Joining.Welcome.self, from: Joining.code(welcome)), invite: invite, me: newcomer)
        XCTAssertEqual(joined, group.copy(for: .caller))
        XCTAssertNil(joined.secrets.responderPrivateKey, "a caller is not given the responders' key")
        XCTAssertNotNil(joined.secrets.responderPublicKey)
        XCTAssertEqual(joined.member(welcome.memberNumber)?.role, .caller)
        XCTAssertEqual(joined.member(welcome.memberNumber)?.unit, 70001)
        XCTAssertEqual(joined.membershipVersion, 2, "joining bumps the version the relay compares")
        XCTAssertEqual(RelayProtocol.memberList(joined).generation, 2)
    }

    func testTheCoordinatorChoosesTheRoleNotThePersonJoining() throws {
        let coord = DeviceIdentity(), newcomer = DeviceIdentity()
        var group = newGroup(coord)
        let invite = Joining.invitation(for: group, coordinator: coord, role: .responder)
        var request = Joining.request(try Joining.decode(Joining.Invitation.self, from: Joining.code(invite)),
                                      name: "Alex", call: true, respond: false, me: newcomer)
        XCTAssertFalse(request.wantsToCall)
        request = Joining.JoinRequest(token: request.token, name: "Alex", wantsToCall: true, wantsToRespond: false,
                                      publicKey: request.publicKey, signingKey: request.signingKey)
        let welcome = try Joining.admit(request, to: &group, invite: invite, coordinator: coord)
        XCTAssertEqual(group.member(welcome.memberNumber)?.role, .responder, "an edited request does not change the role")
        XCTAssertNil(group.member(welcome.memberNumber)?.unit)
    }

    func testCodesAreReadFromAMessageAndWrongOnesAreNamed() throws {
        let coord = DeviceIdentity()
        let invite = Joining.invitation(for: newGroup(coord), coordinator: coord)
        let code = try Joining.code(invite)
        let mid = code.index(code.startIndex, offsetBy: 40)
        let message = "Join my Help&I group: " + code[..<mid] + "\n" + code[mid...] + " Thanks!"
        XCTAssertEqual(try Joining.decode(Joining.Invitation.self, from: message), invite)
        XCTAssertEqual(Joining.kind(of: message), .invitation)
        XCTAssertNil(Joining.kind(of: "hello"))
        XCTAssertThrowsError(try Joining.decode(Joining.Invitation.self, from: "HELPANDI1:abcd")) { XCTAssertEqual($0 as? Joining.Failure, .otherVersion) }
    }

    func testOnlyRespondersAreGivenTheRespondersKeyOnJoiningAndInUpdates() throws {
        let coord = DeviceIdentity(), responderPhone = DeviceIdentity(), callerPhone = DeviceIdentity()
        var group = newGroup(coord)
        group.members[0] = Member(number: 1, name: "Sam", role: .coordinator, publicKey: coord.publicKey, signingKey: coord.signingPublicKey)
        let ri = Joining.invitation(for: group, coordinator: coord, role: .responder)
        let rw = try Joining.admit(Joining.request(ri, name: "R", call: false, respond: true, me: responderPhone), to: &group, invite: ri, coordinator: coord)
        XCTAssertNotNil(try Joining.open(rw, invite: ri, me: responderPhone).secrets.responderPrivateKey)
        let ci = Joining.invitation(for: group, coordinator: coord, role: .caller)
        let cw = try Joining.admit(Joining.request(ci, name: "C", call: true, respond: false, me: callerPhone), to: &group, invite: ci, coordinator: coord)
        XCTAssertNil(try Joining.open(cw, invite: ci, me: callerPhone).secrets.responderPrivateKey)
        // New keys, as after a removal, and the key update for each member.
        group.previousSecrets = group.secrets
        group.secrets = group.secrets.rotated()
        let current = try Joining.open(cw, invite: ci, me: callerPhone)
        let forCaller = try Joining.openUpdate(Joining.update(group, for: group.member(cw.memberNumber)!, coordinator: coord), current: current, me: callerPhone)
        XCTAssertNil(forCaller.secrets.responderPrivateKey)
        XCTAssertNil(forCaller.previousSecrets?.responderPrivateKey)
        let rCurrent = try Joining.open(rw, invite: ri, me: responderPhone)
        let forResponder = try Joining.openUpdate(Joining.update(group, for: group.member(rw.memberNumber)!, coordinator: coord), current: rCurrent, me: responderPhone)
        XCTAssertNotNil(forResponder.secrets.responderPrivateKey)
    }

    func testWelcomeCodesAreCompactAndTheOldFormStillOpens() throws {
        let coord = DeviceIdentity(), newcomer = DeviceIdentity()
        var group = newGroup(coord)
        let invite = Joining.invitation(for: group, coordinator: coord, role: .both)
        let welcome = try Joining.admit(Joining.request(invite, name: "Alex", call: true, respond: true, me: newcomer), to: &group, invite: invite, coordinator: coord)
        let code = try Joining.code(welcome)
        XCTAssertTrue(code.hasPrefix(Joining.welcomePrefix))
        XCTAssertLessThan(code.count, 1000, "about half the first form's length for a small group")
        XCTAssertEqual(Joining.kind(of: code), .welcome)
        XCTAssertEqual(try Joining.open(Joining.decode(Joining.Welcome.self, from: code), invite: invite, me: newcomer), group)
        // A welcome from a phone before compression: the group sealed as plain JSON, the code as JSON text.
        let plain = try seal(JSONEncoder().encode(group), to: newcomer.publicKey, from: coord, context: invite.token)
        let old = Joining.Welcome(groupID: welcome.groupID, memberNumber: welcome.memberNumber, sealed: plain)
        let oldCode = Joining.prefix + (try JSONEncoder().encode(old)).base64EncodedString()
        XCTAssertEqual(try Joining.open(Joining.decode(Joining.Welcome.self, from: oldCode), invite: invite, me: newcomer), group)
    }

    func testButtonWordsDefaultAndCanBeChangedOrCleared() {
        var p = Profile.standard
        XCTAssertEqual(ButtonWords.words(.red, in: p), "Help")
        ButtonWords.set("  Please come  ", for: ButtonWords.key(.red), in: &p)
        ButtonWords.set(String(repeating: "x", count: 99), for: ButtonWords.key(.fallen), in: &p)
        XCTAssertEqual(ButtonWords.words(.red, in: p), "Please come")
        XCTAssertEqual(ButtonWords.words(.fallen, in: p).count, ButtonWords.longest)
        ButtonWords.set("", for: ButtonWords.key(.red), in: &p)
        XCTAssertEqual(ButtonWords.words(.red, in: p), "Help")
        XCTAssertTrue(ButtonWords.soundsLikeEmergencyService("SOS"))
        XCTAssertFalse(ButtonWords.soundsLikeEmergencyService("Need a hand"))
    }

    func testOnlyTheNewMemberCanOpenTheWelcome() throws {
        let coord = DeviceIdentity(), newcomer = DeviceIdentity(), eavesdropper = DeviceIdentity()
        var group = newGroup(coord)
        let invite = Joining.invitation(for: group, coordinator: coord)
        let welcome = try Joining.admit(Joining.request(invite, name: "A", call: false, respond: true, me: newcomer),
                                        to: &group, invite: invite, coordinator: coord)
        XCTAssertThrowsError(try Joining.open(welcome, invite: invite, me: eavesdropper)) { XCTAssertEqual($0 as? Joining.Failure, .cannotOpen) }
    }

    func testWrongTokenIsRefused() {
        let coord = DeviceIdentity()
        var group = newGroup(coord)
        let invite = Joining.invitation(for: group, coordinator: coord)
        let other = Joining.invitation(for: group, coordinator: coord)
        let request = Joining.request(other, name: "A", call: true, respond: true, me: DeviceIdentity())
        XCTAssertThrowsError(try Joining.admit(request, to: &group, invite: invite, coordinator: coord))
        XCTAssertEqual(group.members.count, 1)
    }

    func testSafetyNumberIsTheSameOnBothPhones() {
        let a = DeviceIdentity().publicKey, b = DeviceIdentity().publicKey
        XCTAssertEqual(Joining.safetyNumber(a, b), Joining.safetyNumber(b, a))
        XCTAssertEqual(Joining.safetyNumber(a, b).count, 6)
    }

    func testRemovingRotatesSecretsAndNeverReusesTheUnit() {
        let coord = DeviceIdentity()
        var group = newGroup(coord)
        group.members.append(Member(number: 2, name: "Lost", role: .caller, publicKey: DeviceIdentity().publicKey, unit: 70001))
        let before = group.secrets
        group.remove(2)
        XCTAssertNil(group.member(2))
        XCTAssertNotEqual(group.secrets.channelSecret, before.channelSecret)
        XCTAssertNotEqual(group.secrets.groupKey, before.groupKey)
        XCTAssertEqual(group.secrets.groupID, before.groupID)
        XCTAssertEqual(group.secrets.generation, 2)
        XCTAssertEqual(group.previousSecrets, before)
        XCTAssertEqual(group.nextUnit, 70002)
    }

    func testUpdateAfterRemovalReachesRemainingMembersOnly() throws {
        let coord = DeviceIdentity(), stays = DeviceIdentity(), lost = DeviceIdentity()
        var group = newGroup(coord)
        group.members.append(Member(number: 2, name: "Stays", role: .responder, publicKey: stays.publicKey))
        group.members.append(Member(number: 3, name: "Lost", role: .caller, publicKey: lost.publicKey, unit: 70001))
        let before = group
        group.remove(3)
        let u = try Joining.update(group, for: group.member(2)!, coordinator: coord)
        XCTAssertEqual(try Joining.openUpdate(u, current: before, me: stays).secrets, group.secrets)
        XCTAssertThrowsError(try Joining.openUpdate(u, current: before, me: lost))
        XCTAssertThrowsError(try Joining.openUpdate(u, current: group, me: stays), "never back to the same or older secrets")
        let forged = try Joining.update(group, for: group.member(2)!, coordinator: DeviceIdentity())
        XCTAssertThrowsError(try Joining.openUpdate(forged, current: before, me: stays), "only a coordinator can seal an update")
    }

    func testOldSecretsStopAfterTheChangeover() {
        let coord = DeviceIdentity()
        var group = newGroup(coord)
        group.members.append(Member(number: 2, name: "Lost", role: .caller, publicKey: DeviceIdentity().publicKey, unit: 70001))
        let t = Date(timeIntervalSince1970: 1_793_000_000)
        group.remove(2, at: t)
        XCTAssertEqual(group.listening(at: t).count, 2)
        XCTAssertEqual(group.listening(at: t.addingTimeInterval(GroupState.changeoverPeriod)), [group.secrets])
    }

    func testOnlyACurrentRespondersSignedAckCounts() {
        let coord = DeviceIdentity(), responder = DeviceIdentity(), caller = DeviceIdentity()
        var group = newGroup(coord)
        group.members.append(Member(number: 2, name: "R", role: .responder, publicKey: responder.publicKey, signingKey: responder.signingPublicKey))
        group.members.append(Member(number: 3, name: "C", role: .caller, publicKey: caller.publicKey, unit: 70001, signingKey: caller.signingPublicKey))
        let now = Date()
        XCTAssertTrue(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 2, at: now, identity: responder, group: group.secrets.groupID)))
        XCTAssertFalse(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 2, at: now, identity: caller, group: group.secrets.groupID)), "someone else's key")
        XCTAssertFalse(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 3, at: now, identity: caller, group: group.secrets.groupID)), "callers cannot acknowledge")
        group.remove(2)
        XCTAssertFalse(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 2, at: now, identity: responder, group: group.secrets.groupID)), "removed")
    }

    func testOthersLearnOfANewMemberSoTheirAcksCount() {
        let coord = DeviceIdentity(), caller = DeviceIdentity(), newcomer = DeviceIdentity()
        var group = newGroup(coord)
        group.members.append(Member(number: 2, name: "Caller", role: .caller, publicKey: caller.publicKey, unit: 70001, signingKey: caller.signingPublicKey))
        var callersCopy = group
        let invite = Joining.invitation(for: group, coordinator: coord)
        let w = try! Joining.admit(Joining.request(invite, name: "New", call: false, respond: true, me: newcomer), to: &group, invite: invite, coordinator: coord)
        let ack = HelpFrame.signedAck(unit: 70001, request: 1, responder: w.memberNumber, at: Date(), identity: newcomer, group: group.secrets.groupID)
        XCTAssertFalse(callersCopy.acceptsAck(ack), "before hearing of them")
        let signed = HelpFrame.signing(group.addedFrame(w.memberNumber)!, as: 1, identity: coord, group: group.secrets.groupID)
        XCTAssertLessThanOrEqual(signed.encoded().count, HelpFrame.maxPayload)
        guard let inner = HelpFrame(signed.encoded())?.verifiedInner(signedBy: coord.signingPublicKey, group: group.secrets.groupID) else { return XCTFail() }
        callersCopy.apply(membership: inner)
        XCTAssertTrue(callersCopy.acceptsAck(ack))
        XCTAssertEqual(callersCopy.member(w.memberNumber)?.name, "Member \(w.memberNumber)")
        callersCopy.apply(membership: .memberRemoved(member: w.memberNumber, version: 99))
        XCTAssertFalse(callersCopy.acceptsAck(ack))
        callersCopy.apply(membership: inner)
        XCTAssertNil(callersCopy.member(w.memberNumber), "an old signed add, replayed by the removed phone, cannot let it back in")
        XCTAssertFalse(callersCopy.acceptsAck(ack))
        var coordCopy = group
        coordCopy.remove(w.memberNumber)
        XCTAssertGreaterThan(coordCopy.nextMemberNumber!, w.memberNumber, "member numbers are never reused")
    }

    func testAGroupSavedByAnEarlierVersionStillLoads() throws {
        let coord = DeviceIdentity()
        let g = newGroup(coord)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
        for k in ["roleVersions", "removedMembers", "highestMember", "membershipVersion", "roleBlocksSeen", "removedUnits"] { json[k] = nil }
        let old = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(GroupState.self, from: old)
        XCTAssertEqual(back.members, g.members)
        XCTAssertEqual(back.membershipVersion, 1)
    }

    func testBlocksAreNeverReusedAndRunOut() {
        let coord = DeviceIdentity()
        var g = newGroup(coord)
        for n in 2...4 { g.members.append(Member(number: UInt16(n), name: "R", role: .responder, publicKey: Data())) }
        _ = g.promote(2)
        XCTAssertEqual(g.member(2)?.block, 1000)
        g.remove(2)
        _ = g.promote(3)
        XCTAssertEqual(g.member(3)?.block, 2000, "a removed coordinator's block is not handed out again")
        XCTAssertEqual(g.nextMemberNumber(by: 3), 2001)
        for n in 2001...2999 { g.members.append(Member(number: UInt16(n), name: "x", role: .responder, publicKey: Data())) }
        XCTAssertNil(g.nextMemberNumber(by: 3), "a full block gives no number rather than a duplicate")
    }

    func testActivitySavedByAnEarlierVersionKeepsOpenRequests() throws {
        var a = Activity()
        a.inbox.receive(.call(unit: 70001, request: 1, colour: .red, sentAt: 1_793_000_000), via: .mesh, at: Date())
        a.outgoing.append(OutgoingRequest(unit: 70002, number: 4, colour: .red, createdAt: Date()))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        for k in ["alertedGreens", "notices", "boardKeys", "checkInWatch", "airtime"] { json[k] = nil }
        var out = (json["outgoing"] as! [[String: Any]])[0]
        out["resends"] = nil; out["parts"] = nil
        json["outgoing"] = [out]
        let back = try JSONDecoder().decode(Activity.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.inbox.requests.count, 1, "the open request survives")
        XCTAssertEqual(back.outgoing.first?.number, 4)
    }

    func testAKeyUpdateFromASecondCoordinatorIsRefused() throws {
        let first = DeviceIdentity(), second = DeviceIdentity(), member = DeviceIdentity()
        var g = newGroup(first)
        g.members.append(Member(number: 2, name: "S", role: .responder, publicKey: second.publicKey))
        g.members.append(Member(number: 3, name: "M", role: .responder, publicKey: member.publicKey))
        _ = g.promote(2)
        let before = g
        g.remove(3)
        var rotated = before
        rotated.secrets = before.secrets.rotated()
        let fromSecond = try Joining.update(rotated, for: before.member(3)!, coordinator: second)
        XCTAssertThrowsError(try Joining.openUpdate(fromSecond, current: before, me: member))
    }

    func testAnOldCheckInScheduleReplayedNeverReplacesANewerOne() {
        var w = CheckInWatch()
        w.apply(.checkIns(unit: 7, since: 200, grace: 30, times: [600]))
        w.apply(.checkIns(unit: 7, since: 100, grace: 30, times: []))
        XCTAssertEqual(w.callers[7]?.schedule.times, [600])
        w.apply(.checkIns(unit: 7, since: 300, grace: 30, times: []))
        XCTAssertNil(w.callers[7])
        w.apply(.checkIns(unit: 7, since: 200, grace: 30, times: [600]))
        XCTAssertNil(w.callers[7], "nor an old 'on' a newer 'off'")
    }

    func testBadCodesAreRejected() {
        XCTAssertThrowsError(try Joining.decode(Joining.Invitation.self, from: "hello"))
        XCTAssertThrowsError(try Joining.decode(Joining.Invitation.self, from: "HELPA1:%%%"))
    }
}
