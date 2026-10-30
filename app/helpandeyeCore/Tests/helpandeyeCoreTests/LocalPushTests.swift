import XCTest
@testable import helpandeyeCore

/// The locked-phone listener (app/helpandeyeLocalPush) takes bytes from anything on the Wi-Fi
/// through `LocalWire.Session`, so nothing on the wire may crash it or pass as a frame.
@MainActor final class LocalPushTests: XCTestCase {
    func testGarbageOnTheWireNeverCrashesOrPassesAsAFrame() {
        let me = DeviceIdentity()
        var g = GroupState(name: "Mill Lane", secrets: .random(), members: [])
        g.members.append(Member(number: 1, name: "Sam", role: .responder, publicKey: me.publicKey, signingKey: me.signingPublicKey))
        var frames = 0
        for round in 0..<300 {
            var s = LocalWire.Session(group: g, me: 1, identity: me)
            _ = s.opening()
            let body = Data((0..<Int.random(in: 0...200)).map { _ in UInt8.random(in: 0...255) })
            // Random bytes, then the same bytes well framed (a length and a kind), including a
            // frame or receipt before any proof, in one piece and byte by byte.
            let kind = UInt8(round % 5)
            let framed = Data([UInt8((body.count + 1) >> 8), UInt8((body.count + 1) & 0xFF), kind]) + body
            for bytes in [body, framed] {
                let (events, _) = s.take(bytes)
                if events.contains(where: { if case .frame = $0 { true } else { false } }) { frames += 1 }
            }
            var one = LocalWire.Session(group: g, me: 1, identity: me)
            for b in framed { _ = one.take(Data([b])) }
        }
        XCTAssertEqual(frames, 0, "nothing unproven passes as a frame")
    }
}
