import XCTest
@testable import helpandeyeCore

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
        let f = HelpFrame.signedAck(unit: 1, request: 2, responder: 3, at: Date(timeIntervalSince1970: 100), identity: me, group: Data())
        XCTAssertEqual(f.encoded().count, 77)
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertTrue(f.isValidAck(signedBy: me.signingPublicKey, group: Data()))
        guard case let .ack(u, r, _, at, s) = f else { return XCTFail() }
        XCTAssertFalse(HelpFrame.ack(unit: u, request: r, responder: 4, ackedAt: at, signature: s).isValidAck(signedBy: me.signingPublicKey, group: Data()),
                       "a signature cannot be moved to another responder")
        XCTAssertFalse(f.isValidAck(signedBy: nil, group: Data()))
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

    func testMobileNumbersRoundTripButStayOffTheGroupChannel() {
        let f = HelpFrame.memberPhone(member: 7, phone: "+447700900123", at: 1_793_000_000)
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertFalse(f.mayGoOnGroupChannel)
        XCTAssertFalse(HelpFrame.signing(f, as: 7, identity: DeviceIdentity(), group: Data(count: 16)).mayGoOnGroupChannel)
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
        // The most negative 32-bit value is rejected, not a crash.
        d.replaceSubrange(7..<11, with: withUnsafeBytes(of: Int32.min.littleEndian) { Data($0) })
        XCTAssertNil(HelpFrame(d))
        d.replaceSubrange(7..<11, with: withUnsafeBytes(of: Int32(-900_000_000).littleEndian) { Data($0) })
        XCTAssertNotNil(HelpFrame(d))
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
        let f = HelpFrame.signedBoard(member: 3, publicKey: Data(repeating: 9, count: 32), identity: me, group: Data())
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertTrue(f.mayGoOnGroupChannel)
        XCTAssertEqual(f.encoded().count, 99)
        XCTAssertTrue(f.isValidBoard(signedBy: me.signingPublicKey, group: Data()))
        XCTAssertFalse(f.isValidBoard(signedBy: DeviceIdentity().signingPublicKey, group: Data()))
        guard case let .board(_, k, s) = f else { return XCTFail() }
        XCTAssertFalse(HelpFrame.board(member: 4, publicKey: k, signature: s).isValidBoard(signedBy: me.signingPublicKey, group: Data()))
    }
}

final class SignedFrameTests: XCTestCase {
    func testAvailabilityCountsOnlyWhenSignedByThatResponder() {
        let me = DeviceIdentity(), other = DeviceIdentity()
        let mine = HelpFrame.availability(responder: 3, from: 10, until: 20, available: false)
        let f = HelpFrame.signing(mine, as: 3, identity: me, group: Data())
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertLessThanOrEqual(f.encoded().count, HelpFrame.maxPayload)
        XCTAssertEqual(f.verifiedInner(signedBy: me.signingPublicKey, group: Data()), mine)
        XCTAssertNil(f.verifiedInner(signedBy: other.signingPublicKey, group: Data()))
        XCTAssertNil(HelpFrame.signing(mine, as: 4, identity: me, group: Data()).verifiedInner(signedBy: me.signingPublicKey, group: Data()),
                     "a responder cannot sign someone else's availability")
        XCTAssertNil(HelpFrame.signing(.call(unit: 1, request: 1, colour: .red, sentAt: 0), as: 3, identity: me, group: Data())
            .verifiedInner(signedBy: me.signingPublicKey, group: Data()), "only availability and notice acks are unwrapped")
    }

    func testNoticeAckCountsOnlyFromItsSigner() {
        let me = DeviceIdentity()
        let ack = HelpFrame.noticeAck(notice: .rotaGap, by: 1, at: 5)
        XCTAssertEqual(HelpFrame.signing(ack, as: 1, identity: me, group: Data()).verifiedInner(signedBy: me.signingPublicKey, group: Data()), ack)
    }

    /// The same bytes firmware/test/frame_tests.cpp expects, so the box's C++ and the app agree
    /// byte for byte on calls, acknowledgements, call states and what is signed.
    func testFramesMatchTheFirmwareVectors() {
        let call = HelpFrame.call(unit: 70001, request: 12, colour: .red, sentAt: 1_793_000_000)
        XCTAssertEqual([UInt8](call.encoded()), [0x11, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x01, 0x40, 0x02, 0xDF, 0x6A])
        let ack = HelpFrame.ack(unit: 70001, request: 12, responder: 3, ackedAt: 1_793_000_060, signature: Data(repeating: 7, count: 64))
        XCTAssertEqual([UInt8](ack.encoded()), [0x13, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x03, 0x00, 0x7C, 0x02, 0xDF, 0x6A] + [UInt8](repeating: 7, count: 64))
        let ok = HelpFrame.callState(unit: 70001, request: 12, state: .callerOK, at: 1_793_000_100, reason: "")
        XCTAssertEqual([UInt8](ok.encoded()), [0x22, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x01, 0xA4, 0x02, 0xDF, 0x6A, 0x00])
        let closed = HelpFrame.callState(unit: 70001, request: 12, state: .closedWithReason, at: 1_793_000_100, reason: "Off")
        XCTAssertEqual([UInt8](closed.encoded()), [0x22, 0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x04, 0xA4, 0x02, 0xDF, 0x6A, 0x03] + Array("Off".utf8))
        let group = Data(0...15)
        XCTAssertEqual(HelpFrame.ackInput(unit: 70001, request: 12, responder: 3, ackedAt: 1_793_000_060, group: group),
                       Data("HELPA-ACK-2".utf8) + group + Data([0x71, 0x11, 0x01, 0x00, 0x0C, 0x00, 0x03, 0x00, 0x7C, 0x02, 0xDF, 0x6A]))
        XCTAssertEqual(HelpFrame.signedInput(signer: 5, inner: ok.encoded(), group: group),
                       Data("HELPA-SIGNED-2".utf8) + group + Data([0x05, 0x00]) + ok.encoded())
    }

    func testTheChangeoverEndFrame() {
        let f = HelpFrame.changeoverEnds(generation: 3, at: 1_793_600_000)
        XCTAssertEqual(f.encoded().count, 9)
        XCTAssertEqual(HelpFrame(f.encoded()), f)
        XCTAssertTrue(f.mayGoOnGroupChannel)
    }
}

extension HelpFrameTests {
    /// Decision 20: the deputy naming and the takeover carry their own signatures and fit the radio.
    func testDeputyAndTakeoverFramesRoundTripAndFitTheRadio() {
        let first = DeviceIdentity(), deputy = DeviceIdentity(), other = DeviceIdentity()
        let group = Data(repeating: 3, count: 16)
        let naming = HelpFrame.signedDeputy(member: 1002, key: deputy.signingPublicKey, version: 2, identity: first, group: group)
        XCTAssertEqual(HelpFrame(naming.encoded()), naming)
        XCTAssertTrue(naming.isValidDeputy(signedBy: first.signingPublicKey, group: group))
        XCTAssertFalse(naming.isValidDeputy(signedBy: other.signingPublicKey, group: group))
        XCTAssertFalse(naming.isValidDeputy(signedBy: first.signingPublicKey, group: Data(repeating: 4, count: 16)), "one group's naming is worthless in another")
        let sig = { (by: DeviceIdentity, n: UInt16) in Takeover.Signature(signer: n, signature: HelpFrame.takeoverSignature(fromKey: first.signingPublicKey, toKey: deputy.signingPublicKey, identity: by, group: group)) }
        var asDeputy = Takeover(from: 1, to: 1002, version: 9, signatures: [sig(deputy, 1002)])
        guard case let .deputy(_, _, _, namingSig) = naming else { return XCTFail() }
        asDeputy.deputyVersion = 2; asDeputy.deputySignature = namingSig
        let agreed = Takeover(from: 1, to: 1002, version: 9, signatures: [sig(deputy, 1002), sig(other, 2001)])
        let alone = Takeover(from: 1, to: 1002, version: 9, signatures: [sig(deputy, 1002)])
        for t in [asDeputy, agreed, alone] {
            let f = HelpFrame.takeover(t)
            XCTAssertEqual(HelpFrame(f.encoded()), f)
            XCTAssertLessThanOrEqual(f.encoded().count, HelpFrame.maxPayload)
            XCTAssertTrue(f.mayGoOnGroupChannel)
        }
        XCTAssertTrue(asDeputy.namedDeputy(fromKey: first.signingPublicKey, toKey: deputy.signingPublicKey, group: group))
        XCTAssertFalse(agreed.namedDeputy(fromKey: first.signingPublicKey, toKey: deputy.signingPublicKey, group: group))
        let consent = HelpFrame.takeoverConsent(from: 1, to: 1002, signer: 2001, signature: sig(other, 2001).signature)
        XCTAssertEqual(HelpFrame(consent.encoded()), consent)
        XCTAssertEqual(consent.encoded().count, 71)
        // No signatures, three signatures, or bytes left over: not a frame.
        var d = HelpFrame.takeover(alone).encoded()
        d[13] = 0
        XCTAssertNil(HelpFrame(d))
        d[13] = 3
        XCTAssertNil(HelpFrame(d))
        XCTAssertNil(HelpFrame(HelpFrame.takeover(alone).encoded() + [0]))
    }
}
