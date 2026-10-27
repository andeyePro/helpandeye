import XCTest
@testable import HelpAndICore

/// Prints a signed request for relay/test/interop.test.js, which checks the relay verifies what
/// the app signs. Regenerate with: swift test --filter RelayVectorTests 2>&1 | grep VECTOR
final class RelayVectorTests: XCTestCase {
    func testPrintVector() throws {
        let me = DeviceIdentity()
        let body = Data(#"{"sealed":"AAEC"}"#.utf8)
        let h = try RelayProtocol.headers(method: "POST", pathAndQuery: "/g/ABCDEFGHIJKLMNOP/messages", body: body, identity: me, now: Date())
        let v = ["key": h["X-HelpAndI-Key"]!, "timestamp": h["X-HelpAndI-Time"]!, "signature": h["X-HelpAndI-Signature"]!,
                 "path": "/g/ABCDEFGHIJKLMNOP/messages", "body": String(decoding: body, as: UTF8.self)]
        print("VECTOR:" + String(decoding: try JSONSerialization.data(withJSONObject: v, options: .sortedKeys), as: UTF8.self))
    }
}
