import XCTest
@testable import helpandeyeCore

/// The same hand-written cases as relay/test/relay.test.js, run against the Swift copy of the
/// relay's membership rules that the fuzz test uses. With the recorded publishes that
/// relay/test/model.test.js replays, they catch the two drifting apart on the rules they cover;
/// a rule changed in one and covered by neither is still a gap, so a relay change updates both.
final class RelayModelTests: XCTestCase {
    func key() -> String { DeviceIdentity().signingPublicKey.base64EncodedString() }
    func c(_ k: String) -> RelayModel.Entry { .init(key: k, role: "coordinator") }
    func m(_ k: String) -> RelayModel.Entry { .init(key: k, role: "member") }

    func testListsAddPeopleAndOnlyTheOwnersRemovalsCount() {
        let r = RelayModel(), owner = key(), second = key(), x = key(), y = key()
        XCTAssertEqual(r.setMembers(signer: owner, generation: 1, members: [c(owner), c(second), m(x)], removed: [], primary: owner, groupID: nil), 200)
        XCTAssertEqual(r.setMembers(signer: second, generation: 2, members: [c(owner), c(second), m(x), m(y)], removed: [], primary: nil, groupID: nil), 200)
        XCTAssertEqual(r.setMembers(signer: owner, generation: 2, members: [c(owner), c(second), m(x)], removed: [], primary: nil, groupID: nil), 200)
        XCTAssertTrue(r.isMember(y))
        XCTAssertEqual(r.setMembers(signer: second, generation: 3, members: [c(owner), c(second), m(y)], removed: [x], primary: nil, groupID: nil), 403)
        XCTAssertEqual(r.setMembers(signer: owner, generation: 3, members: [c(owner), c(second), m(y)], removed: [x], primary: nil, groupID: nil), 200)
        XCTAssertEqual(r.setMembers(signer: second, generation: 4, members: [c(owner), c(second), m(x), m(y)], removed: [], primary: nil, groupID: nil), 200)
        XCTAssertFalse(r.isMember(x))
        XCTAssertEqual(r.setMembers(signer: owner, generation: 6, members: [c(owner)], removed: [owner], primary: nil, groupID: nil), 409)
        XCTAssertEqual(r.setMembers(signer: owner, generation: 6, members: [c(owner), c(owner)], removed: [], primary: nil, groupID: nil), 400)
    }

    func testOnlyTheFirstCoordinatorCanRegisterTheGroup() {
        let owner = DeviceIdentity(), second = key(), member = key()
        let o = owner.signingPublicKey.base64EncodedString()
        let id = GroupSecrets.forOwner(signingKey: owner.signingPublicKey).groupID
        XCTAssertEqual(RelayModel().setMembers(signer: member, generation: 1, members: [c(member)], removed: [], primary: member, groupID: id), 403)
        // Another coordinator is turned away for now, not for good: once the first registers, the
        // same list is taken, and what it lists as coordinators it may only add as members.
        let r = RelayModel()
        XCTAssertEqual(r.setMembers(signer: second, generation: 1, members: [c(o), c(second), c(member)], removed: [], primary: o, groupID: id), 425)
        XCTAssertTrue(r.members.isEmpty)
        XCTAssertEqual(r.setMembers(signer: o, generation: 1, members: [c(o), c(second)], removed: [], primary: o, groupID: id), 200)
        XCTAssertEqual(r.setMembers(signer: second, generation: 1, members: [c(o), c(second), c(member)], removed: [], primary: o, groupID: id), 200)
        XCTAssertEqual(r.members.first { $0.key == member }?.role, "member")
        XCTAssertEqual(r.setMembers(signer: second, generation: 2, members: [c(o), c(second)], removed: [], primary: second, groupID: id), 409)
    }

    /// As relay.test.js: someone a removed coordinator added goes with them, and that coordinator's
    /// stale list cannot bring them back; only the owner can.
    func testPeopleTakenOffWithACoordinatorComeBackOnlyIfTheOwnerListsThem() {
        let r = RelayModel(), owner = key(), second = key(), third = key(), y = key()
        _ = r.setMembers(signer: owner, generation: 1, members: [c(owner), c(second), c(third)], removed: [], primary: owner, groupID: nil)
        _ = r.setMembers(signer: second, generation: 2, members: [c(owner), c(second), c(third), m(y)], removed: [], primary: nil, groupID: nil)
        XCTAssertEqual(r.setMembers(signer: owner, generation: 3, members: [c(owner), c(third)], removed: [second], primary: nil, groupID: nil), 200)
        XCTAssertFalse(r.isMember(y))
        XCTAssertEqual(r.setMembers(signer: third, generation: 3, members: [c(owner), c(third), m(y)], removed: [], primary: nil, groupID: nil), 200)
        XCTAssertFalse(r.isMember(y), "an older list from another coordinator does not restore them")
        XCTAssertEqual(r.setMembers(signer: owner, generation: 4, members: [c(owner), c(third), m(y)], removed: [], primary: nil, groupID: nil), 200)
        XCTAssertTrue(r.isMember(y))
    }

    func testRemovingACoordinatorTakesOffOnlyTheirUnknownAddsAndRolesNeverGoBack() {
        let r = RelayModel(), owner = key(), second = key(), y = key(), z = key()
        _ = r.setMembers(signer: owner, generation: 1, members: [c(owner), c(second)], removed: [], primary: owner, groupID: nil)
        _ = r.setMembers(signer: second, generation: 2, members: [c(owner), c(second), m(y), m(z)], removed: [], primary: nil, groupID: nil)
        XCTAssertEqual(r.setMembers(signer: owner, generation: 3, members: [c(owner), m(z)], removed: [second], primary: nil, groupID: nil), 200)
        XCTAssertEqual(Set(r.members.map(\.key)), [owner, z])
        _ = r.setMembers(signer: owner, generation: 5, members: [c(owner), m(z)], removed: [], primary: nil, groupID: nil)
        _ = r.setMembers(signer: owner, generation: 4, members: [c(owner), c(z)], removed: [], primary: nil, groupID: nil)
        XCTAssertEqual(r.members.first { $0.key == z }?.role, "member")
    }
}
