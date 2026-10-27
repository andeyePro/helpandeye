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

final class PersonalContentTests: XCTestCase {
    func testNotesAndPositionsRoundTripButStayOffTheGroupChannel() {
        let note = HelpFrame.note(unit: 1, request: 2, part: 3, typed: "  Back door is unlocked  ")
        let pos = HelpFrame.position(unit: 1, request: 2, latitudeE7: 554_000_000, longitudeE7: -45_000_000, accuracy: 15)
        XCTAssertEqual(note, .note(unit: 1, request: 2, part: 3, text: "Back door is unlocked"))
        XCTAssertEqual(HelpFrame(note.encoded()), note)
        XCTAssertEqual(HelpFrame(pos.encoded()), pos)
        XCTAssertFalse(note.mayGoOnGroupChannel)
        XCTAssertFalse(pos.mayGoOnGroupChannel)
        XCTAssertTrue(HelpFrame.call(unit: 1, request: 1, colour: .red, sentAt: 0).mayGoOnGroupChannel)
    }

    func testLongNotesAreCutAtACharacterBoundary() {
        let f = HelpFrame.note(unit: 1, request: 1, part: 1, typed: String(repeating: "é", count: 100))
        guard case let .note(_, _, _, text) = f else { return XCTFail() }
        XCTAssertEqual(text.utf8.count, 120)
        XCTAssertEqual(HelpFrame(f.encoded()), f)
    }

    func testImpossiblePositionsAreRejected() {
        var d = HelpFrame.position(unit: 1, request: 1, latitudeE7: 0, longitudeE7: 0, accuracy: 1).encoded()
        d.replaceSubrange(7..<11, with: withUnsafeBytes(of: Int32(950_000_000).littleEndian) { Data($0) })
        XCTAssertNil(HelpFrame(d))
    }

    func testResponderSeesNotesAndPosition() {
        var inbox = ResponderInbox()
        let t = Date()
        let key = IncomingRequest.Key(unit: 1, request: 2)
        inbox.receive(.call(unit: 1, request: 2, colour: .red, sentAt: 0), via: .internet, at: t)
        XCTAssertEqual(inbox.receive(.note(unit: 1, request: 2, part: 2, text: "second"), via: .internet, at: t), .updated(key))
        inbox.receive(.note(unit: 1, request: 2, part: 1, text: "first"), via: .internet, at: t)
        inbox.receive(.position(unit: 1, request: 2, latitudeE7: 554_000_000, longitudeE7: -45_000_000, accuracy: 15), via: .internet, at: t)
        XCTAssertEqual(inbox.requests[key]?.orderedNotes, ["first", "second"])
        XCTAssertEqual(inbox.requests[key]?.position?.latitude ?? 0, 55.4, accuracy: 1e-9)
    }

    func testPartsAreNumberedAcrossCategoriesAndNotes() {
        var r = OutgoingRequest(unit: 1, number: 1, colour: .red, createdAt: Date())
        XCTAssertEqual(r.add(.fallen), .followUp(unit: 1, request: 1, part: 1, category: .fallen))
        XCTAssertEqual(r.addNote("hip"), .note(unit: 1, request: 1, part: 2, text: "hip"))
        XCTAssertEqual(r.notes, ["hip"])
    }
}

final class MeshTextTests: XCTestCase {
    func testNotesAndPositionsFitADirectMessage() {
        let long = HelpFrame.note(unit: 70001, request: 9, part: 2, text: String(repeating: "a", count: 120))
        let text = MeshText.encode(long)!
        XCTAssertLessThanOrEqual(text.count, MeshText.maxCharacters)
        guard case let .note(_, _, _, cut)? = MeshText.decode(text) else { return XCTFail() }
        XCTAssertEqual(cut.utf8.count, MeshText.maxNoteBytes)
        let pos = HelpFrame.position(unit: 70001, request: 9, latitudeE7: 554_000_000, longitudeE7: -45_000_000, accuracy: 12)
        XCTAssertEqual(MeshText.decode(MeshText.encode(pos)!), pos)
    }

    func testOtherTextIsIgnored() {
        XCTAssertNil(MeshText.decode("hello"))
        XCTAssertNil(MeshText.decode("HI1:%%%"))
    }

    func testBoardKeyFrameIsSignedPublicAndRoundTrips() {
        let me = DeviceIdentity()
        let f = HelpFrame.signedBoard(member: 3, publicKey: Data(repeating: 9, count: 32), identity: me)
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertTrue(f.mayGoOnGroupChannel)
        XCTAssertEqual(f.encoded().count, 99)
        XCTAssertTrue(f.isValidBoard(signedBy: me.signingPublicKey))
        XCTAssertFalse(f.isValidBoard(signedBy: DeviceIdentity().signingPublicKey))
        guard case let .board(_, k, s) = f else { return XCTFail() }
        XCTAssertFalse(HelpFrame.board(member: 4, publicKey: k, signature: s).isValidBoard(signedBy: me.signingPublicKey))
    }
}
