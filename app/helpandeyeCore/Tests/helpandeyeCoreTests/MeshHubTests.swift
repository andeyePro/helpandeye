import XCTest
@testable import helpandeyeCore

@MainActor final class FakeSharedBox: SharedBox {
    var isReady = true
    var radio: RadioSettings? = RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8)
    var boxPublicKey: Data? = Data(repeating: 7, count: 32)
    var unavailableReason = "No box"
    var channelGroups: [[Data]] = []
    var sent: [(HelpFrame, [Data])] = []
    func send(_ frame: HelpFrame, urgent: Bool, on secrets: [Data]) async -> MeshSendResult { sent.append((frame, secrets)); return .sent }
    func sendText(_ text: String, to key: Data) async -> MeshSendResult { .sent }
    func addContact(_ key: Data, name: String) async {}
}

@MainActor final class OffRelay: RelayLink {
    let isConfigured = false
    let lastProblem: String? = nil
    func configure(group: GroupState?, identity: DeviceIdentity) {}
    func publishMembers() async -> PublishResult { .unreachable }
    func send(_ frame: HelpFrame, wake: RelayWake?) async -> String? { "No internet" }
}

/// A responder (here also calling, to send something) in two groups, with one box.
@MainActor final class MeshHubTests: XCTestCase {
    let me = DeviceIdentity()
    let box = FakeSharedBox()
    lazy var hub = MeshHub(box: box)

    /// A group of its own coordinator and this phone, and this phone's engine for it.
    func engine(_ name: String) -> (HelpEngine, HubLink, GroupState) {
        let coord = DeviceIdentity()
        var g = GroupState(name: name, secrets: .forOwner(signingKey: coord.signingPublicKey), members: [])
        g.members.append(Member(number: 1, name: "Coordinator", role: .coordinator, publicKey: coord.publicKey, signingKey: coord.signingPublicKey))
        g.highestMember = 1
        let invite = Joining.invitation(for: g, coordinator: coord, role: .both)
        let w = try! Joining.admit(Joining.request(invite, name: "Me", call: true, respond: true, me: me), to: &g, invite: invite, coordinator: coord)
        let link = hub.link(for: g.secrets.groupID)
        let e = HelpEngine(identity: me, mesh: link, relay: OffRelay(), alerts: FakeAlerts(), store: NoStore(), saved: nil, activity: Activity())
        link.onFrame = { [weak e] in e?.receive($0, via: .mesh) }
        e.joined(try! Joining.open(w, invite: invite, me: me), as: w.memberNumber)
        e.bandChanged(box.radio?.band)
        e.tick()
        return (e, link, g)
    }

    func testEachGroupSendsOnlyOnItsOwnChannelAndHearsOnlyItsOwn() async {
        let (a, _, ga) = engine("Mill Lane")
        let (b, _, gb) = engine("Church Street")
        XCTAssertEqual(box.channelGroups, [[ga.secrets.channelSecret], [gb.secrets.channelSecret]], "the box listens for both")
        a.press(.red)
        await a.settle()
        let calls = box.sent.filter { if case .call = $0.0 { return true }; return false }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1, [ga.secrets.channelSecret], "Mill Lane's call never goes on Church Street's channel")
        XCTAssertTrue(box.sent.allSatisfy { $0.1.count == 1 }, "nothing goes on both groups' channels")
        // Someone else's call heard on Church Street's channel reaches only that group's engine.
        let call = HelpFrame.call(unit: 99_999, request: 1, colour: .red, sentAt: UInt32(Date().timeIntervalSince1970))
        hub.received(call, on: gb.secrets.channelSecret)
        XCTAssertNotNil(b.activity.inbox.requests[.init(unit: 99_999, request: 1)])
        XCTAssertNil(a.activity.inbox.requests[.init(unit: 99_999, request: 1)])
        hub.remove(gb.secrets.groupID)
        XCTAssertEqual(box.channelGroups, [[ga.secrets.channelSecret]], "leaving a group frees its channel")
    }

    func testTheGroupsShareOneBoxsRadioAllowance() async {
        let (a, _, _) = engine("Mill Lane")
        let (b, _, _) = engine("Church Street")
        await a.settle(); await b.settle()
        // Group A's call uses `c` of the hour; leave only half that again, set through group A.
        let before = hub.airtime.budget!.used(at: Date())
        a.press(.red)
        await a.settle()
        let c = hub.airtime.budget!.used(at: Date()) - before
        var tight = AirtimeBudget(dutyCycle: c * 1.5 / 3600 / 0.9)
        tight.record(c, at: Date())
        a.setAirtimeForTesting(tight)
        b.press(.red)
        await b.settle()
        XCTAssertEqual(a.current?.routes[.mesh], .sent)
        XCTAssertEqual(b.current?.routes[.mesh], .failed("Radio time used up for now"), "group B's call counts against the same hour")
    }
}
