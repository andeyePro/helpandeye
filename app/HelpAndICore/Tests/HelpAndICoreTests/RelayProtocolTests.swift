import CryptoKit
import XCTest
@testable import HelpAndICore

final class RelayProtocolTests: XCTestCase {
    func testSignatureVerifiesOverTheSameInputTheRelayRebuilds() throws {
        let me = DeviceIdentity()
        let body = Data(#"{"sealed":"AA=="}"#.utf8)
        let h = try RelayProtocol.headers(method: "POST", pathAndQuery: "/g/x/messages", body: body, identity: me, now: Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(h["X-HelpAndI-Time"], "1793000000000")
        let input = RelayProtocol.signingInput(method: "POST", pathAndQuery: "/g/x/messages", timestamp: h["X-HelpAndI-Time"]!, body: body)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: h["X-HelpAndI-Key"]!)!)
        XCTAssertTrue(key.isValidSignature(Data(base64Encoded: h["X-HelpAndI-Signature"]!)!, for: input))
        XCTAssertEqual(String(decoding: input, as: UTF8.self).components(separatedBy: "\n").first, "HELPANDI-RELAY-1")
    }

    func testSealedFramesOpenOnlyWithTheGroupKeyIncludingTheOldOne() throws {
        let old = GroupSecrets.random(), new = old.rotated()
        let f = HelpFrame.call(unit: 1, request: 2, colour: .red, sentAt: 3)
        XCTAssertEqual(RelayProtocol.open(try RelayProtocol.seal(f, with: old), with: [new, old]), f)
        XCTAssertNil(RelayProtocol.open(try RelayProtocol.seal(f, with: old), with: [new]))
        XCTAssertNil(RelayProtocol.open("not base64", with: [old]))
    }

    func testGroupPathIsURLSafeAndMatchesTheRelayPattern() {
        let p = RelayProtocol.path(for: GroupSecrets(groupID: Data(repeating: 0xFB, count: 16), channelSecret: Data(repeating: 1, count: 16), groupKey: Data(count: 32), generation: 1), "messages")
        XCTAssertTrue(p.range(of: #"^/g/[A-Za-z0-9_-]{16,64}/messages$"#, options: .regularExpression) != nil, p)
    }

    func testMemberListCarriesPublicKeysAndRolesOnly() {
        let c = DeviceIdentity(), m = DeviceIdentity()
        let g = GroupState(name: "x", secrets: .random(), members: [
            Member(number: 1, name: "Sam", role: .coordinator, publicKey: c.publicKey, signingKey: c.signingPublicKey),
            Member(number: 2, name: "Alex", role: .both, publicKey: m.publicKey, unit: 70001, phone: "07700900000", signingKey: m.signingPublicKey),
        ])
        let list = RelayProtocol.memberList(g)
        XCTAssertEqual(list.members.map(\.role), ["coordinator", "member"])
        let json = String(decoding: try! JSONEncoder().encode(list), as: UTF8.self)
        XCTAssertFalse(json.contains("Alex")); XCTAssertFalse(json.contains("07700")); XCTAssertFalse(json.contains("70001"))
    }

    func testIdentityRoundTripsThroughTheKeychainForm() throws {
        let me = DeviceIdentity()
        let back = try DeviceIdentity(rawRepresentation: me.rawRepresentation)
        XCTAssertEqual(back.publicKey, me.publicKey); XCTAssertEqual(back.signingPublicKey, me.signingPublicKey)
        XCTAssertThrowsError(try DeviceIdentity(rawRepresentation: Data(count: 32)))
    }
}
