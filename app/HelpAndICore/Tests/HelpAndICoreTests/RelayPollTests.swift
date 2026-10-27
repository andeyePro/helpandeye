import XCTest
@testable import HelpAndICore

/// Pages as relay.js `since` makes them: up to 200 messages after `after` (or the last 200 for a
/// negative one), `next` the last sequence looked at, `latest` the newest.
final class RelayPollTests: XCTestCase {
    let keys = GroupSecrets.random()
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func message(_ seq: Int, at: Date) -> RelayPoll.Message {
        let sealed = try! RelayProtocol.seal(.call(unit: 1, request: UInt16(seq % 60000 + 1), colour: .red, sentAt: 0), with: keys)
        return .init(seq: seq, at: at.timeIntervalSince1970 * 1000, sealed: sealed)
    }

    /// The relay's log, and `since` over it.
    func page(_ log: [RelayPoll.Message], after: Int, epoch: String = "e1") -> RelayPoll.Page {
        let latest = log.last?.seq ?? 0
        let from = after < 0 ? max(latest + after, 0) : after
        let slice = Array(log.filter { $0.seq > from }.prefix(RelayPoll.pageSize))
        return .init(latest: latest, next: slice.last?.seq ?? max(from, latest), epoch: epoch, messages: slice)
    }

    func testAnOpenCallIsResentWithinTheFirstReadWindow() {
        XCTAssertLessThan(Resend.steady, RelayPoll.recentWindow)
    }

    func testAFirstReadHearsRecentCallsOnly() {
        let log = (1...10).map { message($0, at: $0 <= 5 ? t0.addingTimeInterval(-86_400) : t0.addingTimeInterval(-60)) }
        let o = RelayPoll.read(page(log, after: RelayPoll.after(nil)), from: nil, at: t0, keys: [keys])
        XCTAssertEqual(o.frames.count, 5, "the old ones are not alerted as new")
        XCTAssertEqual(o.position.seq, 10)
    }

    func testCarriesOnFromItsPlaceAndThroughABacklog() {
        let log = (1...450).map { message($0, at: t0) }
        var pos: RelayPoll.Position? = .init(epoch: "e1", seq: 0)
        var heard = 0, reads = 0
        repeat {
            let o = RelayPoll.read(page(log, after: RelayPoll.after(pos)), from: pos, at: t0, keys: [keys])
            heard += o.frames.count; pos = o.position; reads += 1
            if !o.more { break }
        } while reads < 10
        XCTAssertEqual(heard, 450, "nothing skipped")
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(pos?.seq, 450)
    }

    func testExpiredMessagesDoNotStallThePlace() {
        let p = RelayPoll.Page(latest: 300, next: 200, epoch: "e1", messages: [])
        let o = RelayPoll.read(p, from: .init(epoch: "e1", seq: 0), at: t0, keys: [keys])
        XCTAssertEqual(o.position.seq, 200)
    }

    func testAResetRelayIsNoticedEvenIfItHasRefilledPastThePlace() {
        let fresh = (1...50).map { message($0, at: t0) }
        // The phone was at 30 in the old log; the new log already has 50.
        let o = RelayPoll.read(page(fresh, after: 30, epoch: "e2"), from: .init(epoch: "e1", seq: 30), at: t0, keys: [keys])
        XCTAssertTrue(o.more)
        XCTAssertEqual(o.position, .init(epoch: "e2", seq: 0))
        let again = RelayPoll.read(page(fresh, after: o.position.seq, epoch: "e2"), from: o.position, at: t0, keys: [keys])
        XCTAssertEqual(again.frames.count, 50, "every message in the new log is read")
    }

    func testAPlacePastTheEndIsAReset() {
        let o = RelayPoll.read(.init(latest: 5, next: 40, epoch: nil, messages: []), from: .init(epoch: nil, seq: 40), at: t0, keys: [keys])
        XCTAssertEqual(o.position.seq, 0)
    }

    func testMessagesInAnotherKeyAreSkippedButTheirPlaceIsPassed() {
        let other = GroupSecrets.random()
        let m = RelayPoll.Message(seq: 1, at: t0.timeIntervalSince1970 * 1000, sealed: try! RelayProtocol.seal(.call(unit: 1, request: 1, colour: .red, sentAt: 0), with: other))
        let o = RelayPoll.read(.init(latest: 1, next: 1, epoch: "e1", messages: [m]), from: .init(epoch: "e1", seq: 0), at: t0, keys: [keys])
        XCTAssertTrue(o.frames.isEmpty)
        XCTAssertEqual(o.position.seq, 1)
    }
}
