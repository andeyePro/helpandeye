import XCTest
@testable import helpandeyeCore

private func okOrError(_ r: MeshCore.Response) -> Bool {
    if case .ok = r { return true }
    if case .error = r { return true }
    return false
}

private func channelInfo(_ r: MeshCore.Response) -> Bool {
    if case .channelInfo = r { return true }
    return false
}

@MainActor final class CommandQueueTests: XCTestCase {
    var written: [UInt8] = []
    func queue(timeout: TimeInterval = 0.2) -> CommandQueue { CommandQueue(timeout: timeout) { [unowned self] in self.written.append($0.first!) } }
    let call = MeshCore.Command.sendChannelData(index: 1, dataType: HelpFrame.meshDataType, payload: HelpFrame.call(unit: 1, request: 1, colour: .red, sentAt: 0).encoded())

    func start(_ q: CommandQueue, _ c: MeshCore.Command, urgent: Bool = false, _ expect: @escaping CommandQueue.Expect) -> Task<MeshCore.Response?, Never> {
        Task { @MainActor in await q.run(c, urgent: urgent, expect: expect) }
    }

    func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testNothingIsWrittenBeforeTheLinkIsUp() async {
        let q = queue()
        let r = await q.run(.deviceQuery, expect: { _ in true })
        XCTAssertNil(r)
        XCTAssertEqual(written, [])
    }

    func testOneAtATimeAndACallForHelpJumpsTheQueue() async {
        let q = queue()
        q.linkUp()
        let a = start(q, .getChannel(index: 0), channelInfo)
        await settle()
        let b = start(q, .getChannel(index: 1), channelInfo)
        await settle()
        let help = start(q, call, urgent: true, okOrError)
        await settle()
        XCTAssertEqual(written, [0x1F], "only one command in flight")
        q.receive(.channelInfo(index: 0, name: "", secret: Data(count: 16)))
        XCTAssertEqual(written, [0x1F, 0x3E], "the call for help goes next, ahead of the waiting setup")
        q.receive(.ok)
        XCTAssertEqual(written, [0x1F, 0x3E, 0x1F])
        q.receive(.channelInfo(index: 1, name: "", secret: Data(count: 16)))
        let ra = await a.value, rb = await b.value, rh = await help.value
        XCTAssertNotNil(ra); XCTAssertNotNil(rb); XCTAssertEqual(rh, .ok)
    }

    func testAPushIsNotTakenForAReply() async {
        let q = queue()
        q.linkUp()
        let r = start(q, call, urgent: true, okOrError)
        await settle()
        XCTAssertFalse(q.receive(.messagesWaiting))
        XCTAssertTrue(q.receive(.ok))
        let got = await r.value
        XCTAssertEqual(got, .ok)
    }

    func testATimeoutStopsWritingSoALateReplyCannotBeTakenForTheNextCommand() async {
        let q = queue(timeout: 0.1)
        var timedOut = false
        q.onTimeout = { timedOut = true }
        q.linkUp()
        let slow = start(q, .setDeviceTime(0), okOrError)
        await settle()
        let help = start(q, call, urgent: true, okOrError)
        let s = await slow.value, h = await help.value
        XCTAssertNil(s, "no answer in time")
        XCTAssertNil(h, "the call waiting behind it gets no answer, not the slow command's late one")
        XCTAssertTrue(timedOut)
        XCTAssertEqual(written, [0x06], "nothing more was written on the stale link")
        XCTAssertFalse(q.receive(.ok), "the late reply matches nothing")
        XCTAssertTrue(q.isIdle)
    }

    func testOnlyACommandNeverWrittenCountsAsCertainlyNotSent() async {
        let q = queue(timeout: 0.1)
        q.linkUp()
        let flying = Task { @MainActor in await q.send(self.call, urgent: true, expect: okOrError) }
        await settle()
        let behind = Task { @MainActor in await q.send(self.call, expect: okOrError) }
        let f = await flying.value, b = await behind.value
        XCTAssertEqual(f, .timedOut, "written, so it may have gone on air")
        XCTAssertEqual(b, .notWritten)
        let down = await q.send(call, expect: okOrError)
        XCTAssertEqual(down, .notWritten)
    }

    func testAFailedWriteIsNotWrittenAtOnceAndTheNextCommandGoes() async {
        let q = queue(timeout: 5)
        q.linkUp()
        let first = Task { @MainActor in await q.send(self.call, expect: okOrError) }
        await settle()
        let second = Task { @MainActor in await q.send(.syncNextMessage, expect: { if case .noMoreMessages = $0 { return true }; return false }) }
        await settle()
        q.writeFailed()
        let f = await first.value
        XCTAssertEqual(f, .notWritten)
        XCTAssertEqual(written, [0x3E, 0x0A], "the next command went without waiting out the timeout")
        q.receive(.noMoreMessages)
        let r2 = await second.value
        XCTAssertEqual(r2, .reply(.noMoreMessages))
    }

    func testALinkDropAnswersEverythingWithNothingOnce() async {
        let q = queue()
        q.linkUp()
        let a = start(q, .deviceQuery) { _ in false }
        await settle()
        let b = start(q, call, urgent: true, okOrError)
        await settle()
        q.linkDown()
        let ra = await a.value, rb = await b.value
        XCTAssertNil(ra); XCTAssertNil(rb)
        q.linkDown()
        q.linkUp()
        let c = start(q, .syncNextMessage) { if case .noMoreMessages = $0 { return true }; return false }
        await settle()
        q.receive(.noMoreMessages)
        let rc = await c.value
        XCTAssertEqual(rc, .noMoreMessages, "works again once the link is back")
    }
}
