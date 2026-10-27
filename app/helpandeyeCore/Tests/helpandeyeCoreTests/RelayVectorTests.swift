import XCTest
@testable import helpandeyeCore

/// Prints a signed request for relay/test/interop.test.js, which checks the relay verifies what
/// the app signs. Regenerate with: swift test --filter RelayVectorTests 2>&1 | grep VECTOR
final class RelayVectorTests: XCTestCase {
    func testPrintVector() throws {
        let me = DeviceIdentity()
        let body = Data(#"{"sealed":"AAEC"}"#.utf8)
        let h = try RelayProtocol.headers(method: "POST", pathAndQuery: "/g/ABCDEFGHIJKLMNOP/messages", body: body, identity: me, now: Date())
        let v = ["key": h["X-HelpA-Key"]!, "timestamp": h["X-HelpA-Time"]!, "signature": h["X-HelpA-Signature"]!,
                 "path": "/g/ABCDEFGHIJKLMNOP/messages", "body": String(decoding: body, as: UTF8.self)]
        print("VECTOR:" + String(decoding: try JSONSerialization.data(withJSONObject: v, options: .sortedKeys), as: UTF8.self))
    }
}
