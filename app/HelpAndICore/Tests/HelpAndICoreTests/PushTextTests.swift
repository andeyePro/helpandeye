import XCTest
@testable import HelpAndICore

final class PushTextTests: XCTestCase {
    func group() -> GroupState {
        GroupState(name: "Mill Lane", secrets: .random(),
                   members: [Member(number: 2, name: "Alex", role: .caller, publicKey: Data(), unit: 70001)])
    }

    func testNamesTheCallerAndNeverPromisesHelp() throws {
        let g = group()
        let sealed = try RelayProtocol.seal(.call(unit: 70001, request: 1, colour: .red, sentAt: 0), with: g.secrets)
        let t = PushText.describe(sealed: sealed, group: g, at: Date())
        XCTAssertEqual(t, .init(title: "Alex: come now", body: "Open Help&I to acknowledge."))
        XCTAssertFalse((t!.title + t!.body).lowercased().contains("on the way"))
        XCTAssertFalse((t!.title + t!.body).lowercased().contains("coming"))
    }

    func testAnythingElseKeepsTheGenericText() throws {
        let g = group()
        XCTAssertNil(PushText.describe(sealed: try RelayProtocol.seal(.followUp(unit: 70001, request: 1, part: 1, category: .fallen), with: g.secrets),
                                       group: g, at: Date()))
        XCTAssertNil(PushText.describe(sealed: try RelayProtocol.seal(.call(unit: 70001, request: 1, colour: .red, sentAt: 0), with: GroupSecrets.random()),
                                       group: g, at: Date()), "another group's key")
        XCTAssertNil(PushText.describe(sealed: "junk", group: g, at: Date()))
    }
}
