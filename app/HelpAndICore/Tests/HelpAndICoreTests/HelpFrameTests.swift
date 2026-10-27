import XCTest
@testable import HelpAndICore

final class HelpFrameTests: XCTestCase {
    let sig = Data(repeating: 7, count: 64)
    func testEveryKindRoundTrips() {
        let frames: [HelpFrame] = [
            .call(unit: 70001, request: 12, colour: .red, sentAt: 1_793_000_000),
            .followUp(unit: 70001, request: 12, part: 2, category: .fallen),
            .ack(unit: 70001, request: 12, responder: 3, ackedAt: 1_793_000_060, signature: sig),
            .availability(responder: 3, from: 1_793_000_000, until: 1_793_003_600, available: false),
            .noticeAck(notice: .allowanceLow, by: 1, at: 1_793_000_100),
        ]
        for f in frames {
            XCTAssertEqual(HelpFrame(f.encoded()), f)
            XCTAssertLessThanOrEqual(f.encoded().count, HelpFrame.maxPayload)
        }
    }

    func testAckIsSignedAndFits() {
        let me = DeviceIdentity()
        let f = HelpFrame.signedAck(unit: 1, request: 2, responder: 3, at: Date(timeIntervalSince1970: 100), identity: me)
        XCTAssertEqual(f.encoded().count, 77)
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertTrue(f.isValidAck(signedBy: me.signingPublicKey))
        guard case let .ack(u, r, _, at, s) = f else { return XCTFail() }
        XCTAssertFalse(HelpFrame.ack(unit: u, request: r, responder: 4, ackedAt: at, signature: s).isValidAck(signedBy: me.signingPublicKey),
                       "a signature cannot be moved to another responder")
        XCTAssertFalse(f.isValidAck(signedBy: nil))
    }

    func testCallIsTwelveBytesAndCarriesNoText() {
        let d = HelpFrame.call(unit: 1, request: 1, colour: .amber, sentAt: 0).encoded()
        XCTAssertEqual(d.count, 12)
        XCTAssertEqual(d.first, 0x11)
    }

    func testRejectsStrayTraffic() {
        XCTAssertNil(HelpFrame(Data()))
        XCTAssertNil(HelpFrame(Data("hello".utf8)))
        var wrongVersion = HelpFrame.call(unit: 1, request: 1, colour: .red, sentAt: 0).encoded()
        wrongVersion[0] = 0x21
        XCTAssertNil(HelpFrame(wrongVersion))
        var trailing = HelpFrame.call(unit: 1, request: 1, colour: .red, sentAt: 0).encoded()
        trailing.append(0)
        XCTAssertNil(HelpFrame(trailing))
        var badColour = HelpFrame.call(unit: 1, request: 1, colour: .red, sentAt: 0).encoded()
        badColour[7] = 9
        XCTAssertNil(HelpFrame(badColour))
        XCTAssertNil(HelpFrame(HelpFrame.call(unit: 1, request: 1, colour: .red, sentAt: 0).encoded().dropLast()))
    }

    func testAvailabilityMustRunForwards() {
        var d = HelpFrame.availability(responder: 1, from: 10, until: 20, available: true).encoded()
        d.replaceSubrange(7..<11, with: [5, 0, 0, 0])
        XCTAssertNil(HelpFrame(d))
    }
}
