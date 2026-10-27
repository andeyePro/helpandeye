import XCTest
@testable import HelpAndICore

/// The same hand-written cases as relay/test/relay.test.js, run against the Swift copy of the
/// relay's membership rules that the fuzz test uses, so the two cannot drift apart unnoticed.
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
        let r = RelayModel()
        XCTAssertEqual(r.setMembers(signer: second, generation: 1, members: [c(o), c(second), c(member)], removed: [], primary: o, groupID: id), 200)
        XCTAssertEqual(r.members.first { $0.key == member }?.role, "member")
        XCTAssertEqual(r.setMembers(signer: second, generation: 2, members: [c(o), c(second)], removed: [], primary: second, groupID: id), 409)
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
