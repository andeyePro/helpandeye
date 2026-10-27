import XCTest
@testable import HelpAndICore

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
        XCTAssertEqual(joined, group)
        XCTAssertEqual(joined.member(welcome.memberNumber)?.role, .caller)
        XCTAssertEqual(joined.member(welcome.memberNumber)?.unit, 70001)
        XCTAssertEqual(joined.membershipVersion, 2, "joining bumps the version the relay compares")
        XCTAssertEqual(RelayProtocol.memberList(joined).generation, 2)
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
        XCTAssertTrue(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 2, at: now, identity: responder)))
        XCTAssertFalse(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 2, at: now, identity: caller)), "someone else's key")
        XCTAssertFalse(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 3, at: now, identity: caller)), "callers cannot acknowledge")
        group.remove(2)
        XCTAssertFalse(group.acceptsAck(.signedAck(unit: 70001, request: 1, responder: 2, at: now, identity: responder)), "removed")
    }

    func testBadCodesAreRejected() {
        XCTAssertThrowsError(try Joining.decode(Joining.Invitation.self, from: "hello"))
        XCTAssertThrowsError(try Joining.decode(Joining.Invitation.self, from: "HELPANDI1:%%%"))
    }
}
