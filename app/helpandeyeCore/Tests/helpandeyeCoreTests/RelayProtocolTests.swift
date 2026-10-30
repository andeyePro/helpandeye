import CryptoKit
import XCTest
@testable import helpandeyeCore

final class RelayProtocolTests: XCTestCase {
    func testSignatureVerifiesOverTheSameInputTheRelayRebuilds() throws {
        let me = DeviceIdentity()
        let body = Data(#"{"sealed":"AA=="}"#.utf8)
        let h = try RelayProtocol.headers(method: "POST", pathAndQuery: "/g/x/messages", body: body, identity: me, now: Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(h["X-HelpA-Time"], "1793000000000")
        let input = RelayProtocol.signingInput(method: "POST", pathAndQuery: "/g/x/messages", timestamp: h["X-HelpA-Time"]!, body: body)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: h["X-HelpA-Key"]!)!)
        XCTAssertTrue(key.isValidSignature(Data(base64Encoded: h["X-HelpA-Signature"]!)!, for: input))
        XCTAssertEqual(String(decoding: input, as: UTF8.self).components(separatedBy: "\n").first, "HELPA-RELAY-1")
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

    func testAPassIsReadForItsGroupAndExpiryAndSentWithEachRequest() throws {
        let secrets = GroupSecrets.random()
        let id = RelayProtocol.id(of: secrets.groupID)
        let sig = String(repeating: "A", count: 86)
        guard let pass = RelayPass(" 1.\(id).1800000000.\(sig)\n") else { return XCTFail("not read as a pass") }
        XCTAssertEqual(pass.token, "1.\(id).1800000000.\(sig)", "trimmed, as pasted")
        XCTAssertEqual(pass.groupID, id)
        XCTAssertEqual(pass.expiry, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(pass.isFor(secrets)); XCTAssertFalse(pass.isFor(.random()))
        XCTAssertEqual(RelayPass("1.\(id).1800000000.\(sig.prefix(40))\n \(sig.dropFirst(40))")?.token, pass.token, "wrapped onto two lines on the way, as a message does")
        XCTAssertNil(RelayPass("2.\(id).1800000000.\(sig)"), "another version")
        XCTAssertNil(RelayPass("1.\(id).+1800000000.\(sig)"), "digits only, as the relay reads it")
        XCTAssertNil(RelayPass("1.\(id).soon.\(sig)"))
        XCTAssertNil(RelayPass("1.\(id).1800000000.\(sig.dropLast())"))
        XCTAssertNil(RelayPass("1.\(id).1800000000"))
        var g = GroupState(name: "x", secrets: secrets, members: [])
        XCTAssertEqual(g.passState(at: Date(timeIntervalSince1970: 1)), .none)
        g.relayPass = "1.\(RelayProtocol.id(of: GroupSecrets.random().groupID)).1800000000.\(sig)"
        XCTAssertEqual(g.passState(at: Date(timeIntervalSince1970: 1)), .none, "another group's pass counts for nothing")
        g.relayPass = pass.token
        XCTAssertEqual(g.passState(at: Date(timeIntervalSince1970: 1_799_999_999)), .valid(until: pass.expiry))
        XCTAssertEqual(g.passState(at: pass.expiry), .expired(on: pass.expiry))
        let me = DeviceIdentity()
        let with = try RelayProtocol.headers(method: "GET", pathAndQuery: "/g/x/messages", body: Data(), identity: me, now: Date(), pass: pass.token)
        XCTAssertEqual(with["X-HelpA-Pass"], pass.token)
        XCTAssertNil(try RelayProtocol.headers(method: "GET", pathAndQuery: "/g/x/messages", body: Data(), identity: me, now: Date())["X-HelpA-Pass"])
    }

    func testIdentityRoundTripsThroughTheKeychainForm() throws {
        let me = DeviceIdentity()
        let back = try DeviceIdentity(rawRepresentation: me.rawRepresentation)
        XCTAssertEqual(back.publicKey, me.publicKey); XCTAssertEqual(back.signingPublicKey, me.signingPublicKey)
        XCTAssertThrowsError(try DeviceIdentity(rawRepresentation: Data(count: 32)))
    }
}
