import XCTest
@testable import helpandeyeCore

final class RequestTests: XCTestCase {
    let sig = Data(repeating: 7, count: 64)
    var at0: UInt32 { UInt32(t0.timeIntervalSince1970) }
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testCallerSeesSendingThenWaitingNeverDelivered() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: t0)
        XCTAssertEqual(r.status, .notSent, "nothing attempted is nothing sent")
        r.update(.mesh, .sending); r.update(.internet, .sending)
        XCTAssertEqual(r.status, .sending)
        r.update(.internet, .sent)
        XCTAssertEqual(r.status, .waitingForResponder)
        r.update(.mesh, .sent)
        XCTAssertEqual(r.status, .waitingForResponder, "a route accepting the message is not a person seeing it")
    }

    func testCrossOnlyWhenEveryRouteFailed() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .amber, createdAt: t0)
        r.update(.mesh, .failed("no board")); r.update(.internet, .sending)
        XCTAssertEqual(r.status, .sending)
        r.update(.internet, .failed("offline"))
        XCTAssertEqual(r.status, .notSent)
    }

    func testOnlyAMatchingAckReassures() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: t0)
        r.update(.mesh, .sent)
        r.receive(.ack(unit: 5, request: 2, responder: 9, ackedAt: at0, signature: sig))
        r.receive(.ack(unit: 6, request: 1, responder: 9, ackedAt: at0, signature: sig))
        r.receive(.call(unit: 5, request: 1, colour: .red, sentAt: 0))
        XCTAssertEqual(r.status, .waitingForResponder)
        r.receive(.ack(unit: 5, request: 1, responder: 9, ackedAt: at0 - 3600, signature: sig))
        XCTAssertEqual(r.status, .waitingForResponder, "an ack from before this request was made is stale")
        r.receive(.ack(unit: 5, request: 1, responder: 9, ackedAt: at0 - 60, signature: sig))
        XCTAssertEqual(r.status, .seen(responder: 9), "a minute of clock difference is allowed")
    }

    func testFollowUpsAreNumbered() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: t0)
        XCTAssertEqual(r.add(.fallen), .followUp(unit: 5, request: 1, part: 1, category: .fallen))
        XCTAssertEqual(r.add(.unwell), .followUp(unit: 5, request: 1, part: 2, category: .unwell))
    }

    func testInboxDeduplicatesAcrossRoutes() {
        var inbox = ResponderInbox()
        let call = HelpFrame.call(unit: 5, request: 1, colour: .red, sentAt: 0)
        let key = IncomingRequest.Key(unit: 5, request: 1)
        XCTAssertEqual(inbox.receive(call, via: .mesh, at: t0), .new(key))
        XCTAssertEqual(inbox.receive(call, via: .mesh, at: t0), .duplicate)
        XCTAssertEqual(inbox.receive(call, via: .internet, at: t0), .updated(key))
        XCTAssertEqual(inbox.requests.count, 1)
        XCTAssertEqual(inbox.requests[key]?.heardOn, [.mesh, .internet])
    }

    func testFollowUpBeforeCallStillAlertsAndAssembles() {
        var inbox = ResponderInbox()
        let key = IncomingRequest.Key(unit: 5, request: 1)
        XCTAssertEqual(inbox.receive(.followUp(unit: 5, request: 1, part: 2, category: .unwell), via: .mesh, at: t0), .new(key))
        XCTAssertEqual(inbox.receive(.followUp(unit: 5, request: 1, part: 1, category: .fallen), via: .mesh, at: t0), .updated(key))
        XCTAssertEqual(inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: 0), via: .mesh, at: t0), .updated(key))
        XCTAssertEqual(inbox.requests[key]?.colour, .red)
        XCTAssertEqual(inbox.requests[key]?.orderedCategories, [.fallen, .unwell])
    }

    func testNothingAcknowledgesOrClosesByItself() {
        var inbox = ResponderInbox()
        let key = IncomingRequest.Key(unit: 5, request: 1)
        inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: 0), via: .mesh, at: t0)
        for frame in [HelpFrame.call(unit: 5, request: 1, colour: .green, sentAt: 0),
                      .followUp(unit: 5, request: 1, part: 1, category: .other),
                      .availability(responder: 1, from: 0, until: 10, available: true)] {
            inbox.receive(frame, via: .internet, at: t0.addingTimeInterval(86_400 * 30))
        }
        XCTAssertEqual(inbox.requests[key]?.isAcknowledged, false)
        XCTAssertEqual(inbox.requests.count, 1)
    }

    func testAcknowledgeProducesFrameForCaller() {
        var inbox = ResponderInbox()
        let key = IncomingRequest.Key(unit: 5, request: 1)
        inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: 0), via: .mesh, at: t0)
        let me = DeviceIdentity()
        let frame = inbox.acknowledge(key, by: 4, at: t0, identity: me, group: Data())
        guard case let .ack(5, 1, 4, at, _)? = frame else { return XCTFail() }
        XCTAssertEqual(at, at0)
        XCTAssertTrue(frame!.isValidAck(signedBy: me.signingPublicKey, group: Data()))
        XCTAssertFalse(frame!.isValidAck(signedBy: DeviceIdentity().signingPublicKey, group: Data()))
        XCTAssertTrue(inbox.requests[key]!.isAcknowledged)
        XCTAssertNil(inbox.acknowledge(IncomingRequest.Key(unit: 9, request: 9), by: 4, at: t0, identity: me, group: Data()))
    }

    func testAckBeforeCallMeansTheCallArrivesAlreadyInHand() {
        var inbox = ResponderInbox()
        let key = IncomingRequest.Key(unit: 5, request: 1)
        XCTAssertEqual(inbox.receive(.ack(unit: 5, request: 1, responder: 2, ackedAt: 0, signature: sig), via: .mesh, at: t0), .updated(key))
        XCTAssertEqual(inbox.receive(.call(unit: 5, request: 1, colour: .amber, sentAt: 0), via: .mesh, at: t0), .updated(key))
        XCTAssertEqual(inbox.receive(.followUp(unit: 5, request: 1, part: 1, category: .fallen), via: .mesh, at: t0), .updated(key))
        XCTAssertEqual(inbox.receive(.ack(unit: 5, request: 1, responder: 2, ackedAt: 0, signature: sig), via: .internet, at: t0), .duplicate)
        XCTAssertEqual(inbox.requests[key]?.colour, .amber)
        XCTAssertTrue(inbox.requests[key]!.isAcknowledged)
    }

    func testCallRecordsWhenItWasPressed() {
        var inbox = ResponderInbox()
        inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: at0 - 30), via: .mesh, at: t0)
        XCTAssertEqual(inbox.requests[IncomingRequest.Key(unit: 5, request: 1)]?.sentAt, t0.addingTimeInterval(-30))
    }

    func testInboxAndRequestsSurviveARestart() throws {
        var inbox = ResponderInbox()
        inbox.receive(.call(unit: 5, request: 1, colour: .red, sentAt: at0), via: .mesh, at: t0)
        inbox.receive(.followUp(unit: 5, request: 1, part: 1, category: .fallen), via: .internet, at: t0)
        let back = try JSONDecoder().decode(ResponderInbox.self, from: JSONEncoder().encode(inbox))
        XCTAssertEqual(back.requests, inbox.requests)
        var out = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: t0)
        out.update(.mesh, .failed("x")); out.update(.internet, .sent)
        XCTAssertEqual(try JSONDecoder().decode(OutgoingRequest.self, from: JSONEncoder().encode(out)), out)
    }

    func testSortPutsUnacknowledgedRedFirst() {
        var inbox = ResponderInbox()
        inbox.receive(.call(unit: 1, request: 1, colour: .amber, sentAt: 0), via: .mesh, at: t0)
        inbox.receive(.call(unit: 2, request: 1, colour: .red, sentAt: 0), via: .mesh, at: t0.addingTimeInterval(5))
        inbox.receive(.call(unit: 3, request: 1, colour: .red, sentAt: 0), via: .mesh, at: t0.addingTimeInterval(9))
        _ = inbox.acknowledge(IncomingRequest.Key(unit: 2, request: 1), by: 1, at: t0, identity: DeviceIdentity(), group: Data())
        XCTAssertEqual(inbox.sorted.map(\.key.unit), [3, 1, 2])
    }
}

final class WithdrawnCategoryTests: XCTestCase {
    func testACategoryPressedByMistakeCanBeTakenBackEvenIfHeardOutOfOrder() {
        var r = OutgoingRequest(unit: 70001, number: 4, colour: .amber, createdAt: Date())
        let locked = r.add(.lockedOut)
        let fallen = r.add(.fallen)
        let back = r.withdraw(.lockedOut)
        XCTAssertEqual(r.categories, [.fallen])
        XCTAssertNil(r.withdraw(.lockedOut), "nothing left to take back")
        XCTAssertEqual(HelpFrame(back!.encoded()), back)

        var inbox = ResponderInbox()
        _ = inbox.receive(locked, via: .mesh, at: Date())
        _ = inbox.receive(fallen, via: .mesh, at: Date())
        XCTAssertEqual(inbox.receive(back!, via: .mesh, at: Date()), .updated(IncomingRequest.Key(unit: 70001, request: 4)))
        XCTAssertEqual(inbox.requests.values.first?.orderedCategories, [.fallen])
        _ = inbox.receive(locked, via: .internet, at: Date())
        XCTAssertEqual(inbox.requests.values.first?.orderedCategories, [.fallen], "a late copy does not bring it back")
    }

    func testOneHugeCharacterIsCutBetweenCodePoints() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: Date())
        let huge = "e" + String(repeating: "\u{301}", count: 30)
        let pieces = r.addNotes("hi " + huge + " there", pieceBytes: 56).compactMap { f -> String? in
            if case let .note(_, _, _, text) = f { return text } else { return nil }
        }
        XCTAssertTrue(pieces.allSatisfy { $0.utf8.count <= 56 })
        XCTAssertEqual(pieces.joined().unicodeScalars.filter { $0 != " " }.count, ("hi" + huge + "there").unicodeScalars.count)
    }

    /// Each note and choice has its own part, numbered to 255; past that none is made, rather than
    /// one taking the place of another.
    func testACallsPartsRunOutRatherThanOverwrite() {
        var r = OutgoingRequest(unit: 5, number: 1, colour: .red, createdAt: Date())
        for i in 1...254 { XCTAssertNotNil(r.addNote("note \(i)")) }
        XCTAssertEqual(r.addNotes("two words", pieceBytes: 4), [], "two pieces do not fit in the one part left")
        XCTAssertEqual(r.addNote("last"), .note(unit: 5, request: 1, part: 255, text: "last"))
        XCTAssertNil(r.addNote("one more"))
        XCTAssertEqual(r.partsLeft, 0)
        XCTAssertEqual(r.notes.count, 255)
    }
}
