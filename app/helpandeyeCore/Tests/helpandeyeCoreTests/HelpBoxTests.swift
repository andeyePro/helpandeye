import XCTest
@testable import helpandeyeCore

/// The app's side of a Help&I box (firmware/DESIGN.md, sections 6 and 10): the bytes it sends and
/// reads are pinned to DESIGN.md's tables and to what the firmware's `core/provision.hpp` writes,
/// and the sealed report to bytes the firmware core made with fixed keys (TweetNaCl, as in
/// `firmware/test`).
final class HelpBoxTests: XCTestCase {
    func hex(_ s: String) -> Data {
        let s = s.replacingOccurrences(of: " ", with: "")
        return Data(stride(from: 0, to: s.count, by: 2).map { i in
            UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }

    // The firmware's fixed keys: the box's identity from the seed TweetNaCl was given, and the
    // responders' X25519 scalar 0x30, 0x31, ... clamped.
    let seed = "112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f20"
    let boxKey = "ffb3b57c2f8bd3bb1fc072037fbf02d1a091c3a9ff80d23715ff5acd743c278d"
    let boxSealKey = "1177fcefdba0569caa43f97fc45179cb635f4193789fabae5d364854638bba3a"
    let respondersPrivate = "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"
    let respondersPublic = "34e42d4af5ef94a07a3a84201b889d4cd1a743cb27b11b6a10438a8feb8e5847"

    /// The firmware's test group: ID 0 to 15, channel secret 0x50 to 0x5F, the box member 4 on
    /// unit 70004, the first coordinator member 1.
    func firmwareGroup() -> GroupState {
        var secrets = GroupSecrets(groupID: Data((0..<16).map { UInt8($0) }), channelSecret: Data((0..<16).map { UInt8(0x50 + $0) }),
                                   groupKey: Data(count: 32), generation: 1)
        secrets.responderPrivateKey = hex(respondersPrivate)
        secrets.responderPublicKey = hex(respondersPublic)
        var g = GroupState(name: "Mill Lane", secrets: secrets, members: [])
        g.members.append(Member(number: 1, name: "Sam", role: .coordinator, publicKey: Data(count: 32), signingKey: Data(repeating: 1, count: 32)))
        g.members.append(Member(number: 4, name: "Kitchen box", role: .caller, publicKey: hex(boxSealKey), unit: 70004, signingKey: hex(boxKey)))
        g.highestMember = 4
        return g
    }

    func testAHelpAndIBoxIsKnownByItsFirmwareVersion() {
        func info(_ version: String) -> MeshCore.DeviceInfo {
            var d = Data([0x0D, 9, 50, 8]); var w = ByteWriter(); w.u32(0); d.append(w.data)
            d.append(Data(count: 12)); d.append(Data("Heltec V4".utf8) + Data(count: 31)); d.append(Data(version.utf8) + Data(count: 20 - version.utf8.count))
            guard case let .deviceInfo(info)? = MeshCore.Response(d) else { XCTFail(); return MeshCore.DeviceInfo(firmwareVersion: 0, maxChannels: 0, blePin: 0, model: "", version: "") }
            return info
        }
        XCTAssertTrue(info("v1.18.0-hi1").isHelpBox)
        XCTAssertFalse(info("v1.18.0").isHelpBox, "a stock box gets no Help&I command")
        XCTAssertFalse(info("v1.12.0-hi").isHelpBox)
        XCTAssertFalse(info("").isHelpBox)
    }

    func testSetGroupBytesMatchTheFirmware() throws {
        var g = firmwareGroup()
        g.policy.profiles[0].afterOK = .closesCall
        g.policy.reportsPowerCut.insert(4)
        let setup = try XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date()))
        XCTAssertEqual(setup.member, 4); XCTAssertEqual(setup.unit, 70004)
        // writeSetGroup in the firmware's provision.cpp, with the same settings.
        XCTAssertEqual(try MeshCore.Command.boxSetGroup(body: setup.group).encoded(), hex(
            "71 000102030405060708090a0b0c0d0e0f 0400 74110100 05 00 \(respondersPublic) 505152535455565758595a5b5c5d5e5f"
            + " 00000000000000000000000000000000 00000000 0100"))
        XCTAssertEqual(setup.members.count, 1)
        XCTAssertEqual(try MeshCore.Command.boxSetMembers(page: setup.members[0]).encoded().prefix(7), hex("72 01000000 00 02"))
        XCTAssertEqual(setup.members[0].count, 6 + 2 * 35)
        XCTAssertEqual(setup.members[0].subdata(in: 6..<9), hex("0100 04"), "the coordinator first")
        XCTAssertEqual(setup.members[0].subdata(in: 41..<44), hex("0400 01"), "then the box, a caller")
        XCTAssertEqual(setup.members[0].suffix(32), hex(boxKey))
        XCTAssertThrowsError(try MeshCore.Command.boxSetGroup(body: setup.group.dropLast()).encoded())
        XCTAssertThrowsError(try MeshCore.Command.boxSetMembers(page: setup.members[0].dropLast()).encoded())
        XCTAssertNil(HelpBox.setup(for: g, box: Data(repeating: 9, count: 32), at: Date()), "a box that is not a member gets nothing")
    }

    func testFlagsAntennaAndChangeoverGoInSetGroup() throws {
        var g = firmwareGroup()
        var p = Profile(id: 1, name: "Box"); p.callerMayClose = true
        g.policy.profiles.append(p); g.policy.profileOf[4] = 1
        g.policy.antennaOf[4] = .external(gainDBi: 3)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        g.remove(1, at: now)
        let during = try XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: now))
        XCTAssertEqual(during.group[22], 2, "the caller may close, I'm OK does not close, no power-cut reports")
        XCTAssertEqual(during.group[23], HelpBox.AntennaCode.external3dBi.rawValue)
        XCTAssertEqual(during.group.subdata(in: 56..<72), g.secrets.channelSecret, "the new channel")
        XCTAssertEqual(during.group.subdata(in: 72..<88), hex("505152535455565758595a5b5c5d5e5f"), "and the old one during the changeover")
        var w = ByteWriter(); w.u32(UInt32(now.addingTimeInterval(GroupState.changeoverPeriod).timeIntervalSince1970))
        XCTAssertEqual(during.group.subdata(in: 88..<92), w.data)
        XCTAssertEqual(during.group.suffix(2), Data([0, 0]), "no first coordinator left")
        let after = try XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: now.addingTimeInterval(GroupState.changeoverPeriod)))
        XCTAssertEqual(after.group.subdata(in: 72..<92), Data(count: 20), "the old channel goes once the changeover is over")
        XCTAssertEqual(after.members[0][5], 1, "the members page says one member is left")
    }

    func testTheAntennaCodeNeverLoosensTheCap() {
        XCTAssertEqual(HelpBox.antennaCode(.standardWhip), .whip)
        XCTAssertEqual(HelpBox.antennaCode(.higherGainWhip), .external5dBi)
        XCTAssertEqual(HelpBox.antennaCode(.external(gainDBi: 0)), .stub)
        XCTAssertEqual(HelpBox.antennaCode(.external(gainDBi: 2.5)), .external3dBi)
        XCTAssertEqual(HelpBox.antennaCode(.external(gainDBi: 4)), .external5dBi)
        XCTAssertEqual(HelpBox.antennaCode(.external(gainDBi: 8)), .external5dBi, "the firmware has no higher code (TODO)")
    }

    func testMembersGoInPagesOfFourRespondersFirstUpToThirtyTwo() throws {
        var g = firmwareGroup()
        for n in UInt16(10)..<50 {
            g.members.append(Member(number: n, name: "\(n)", role: n % 3 == 0 ? .responder : .caller, publicKey: Data(count: 32), unit: UInt32(n), signingKey: Data(repeating: UInt8(n), count: 32)))
        }
        g.members.append(Member(number: 99, name: "no key", role: .responder, publicKey: Data(count: 32)))
        let setup = try XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date()))
        XCTAssertEqual(setup.members.count, 8)
        for (i, page) in setup.members.enumerated() {
            XCTAssertEqual(Int(page[4]), i * 4, "index"); XCTAssertEqual(page[5], 32, "total")
            XCTAssertEqual(page.count, 6 + 4 * 35)
        }
        let roles = setup.members.flatMap { page in stride(from: 6, to: page.count, by: 35).map { page[$0 + 2] } }
        XCTAssertEqual(roles.prefix(14), [4] + [UInt8](repeating: 2, count: 13), "the coordinator, then every responder")
        XCTAssertEqual(roles.suffix(18), [UInt8](repeating: 1, count: 18), "then as many callers as fit")
    }

    /// Set names (0x76) as the firmware's `writeNamesChunk` writes them: version, index, total, then
    /// member, length and the first name in UTF-8; none at all clears the box's names.
    func testNamesGoOnlyWhenTheGroupPutsThemOnBoxes() throws {
        var g = firmwareGroup()
        g.members[0].name = "Sam Smith"
        g.members.append(Member(number: 5, name: "Zoë", role: .responder, publicKey: Data(count: 32), signingKey: Data(repeating: 5, count: 32)))
        g.members.append(Member(number: 6, name: "Pat", role: .caller, publicKey: Data(count: 32), unit: 70006, signingKey: Data(repeating: 6, count: 32)))
        XCTAssertNil(try XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date())).names, "off unless the group chose it")
        g.policy.namesOnBox = true
        let names = try XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date())?.names)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(try MeshCore.Command.boxSetNames(page: names[0]).encoded(), hex("76 01000000 00 02 0100 03 53616d 0500 04 5a6fc3ab"),
                       "responders only, first names only")
        XCTAssertEqual(try MeshCore.Command.boxSetNames(page: HelpBox.noNames[0]).encoded(), hex("76 00000000 00 00"))
    }

    func testANameIsCutAtAWholeCharacterAndTheyGoInPagesOfEight() throws {
        let long = Member(number: 2, name: "Bartholomew-Alexandré", role: .responder, publicKey: Data(count: 32))
        let page = HelpBox.namePages([long], version: 1)[0]
        XCTAssertEqual(page.suffix(from: 9), Data("Bartholomew-Alex".utf8))
        let accented = Member(number: 3, name: "Éléonore-Françoise", role: .responder, publicKey: Data(count: 32))
        XCTAssertEqual(String(data: HelpBox.namePages([accented], version: 1)[0].suffix(from: 9), encoding: .utf8), "Éléonore-Fran", "never half a letter")
        let many = (1...20).map { Member(number: UInt16($0), name: "R\($0)", role: .responder, publicKey: Data(count: 32)) }
        let pages = HelpBox.namePages(many, version: 9)
        XCTAssertEqual(pages.map { $0[4] }, [0, 8, 16]); XCTAssertEqual(pages.map { $0[5] }, [20, 20, 20])
        XCTAssertTrue(HelpBox.namePages([Member(number: 4, name: "  ", role: .responder, publicKey: Data(count: 32))], version: 1) == HelpBox.namePages([], version: 1),
                      "a blank name is left out")
    }

    /// Pairing sends the group and members; a join or a removal the members again, a setting the
    /// group again, and a box that says it holds nothing everything.
    func testOnlyWhatChangedGoesAgainAndEverythingOnceTheBoxHoldsNothing() throws {
        var g = firmwareGroup()
        var sync = HelpBox.Sync()
        func due(_ namesHeld: Int = 0) throws -> [HelpBox.Sync.Part] {
            try sync.due(XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date())), namesHeld: namesHeld).map(\.part)
        }
        func send(_ namesHeld: Int = 0) throws {
            for d in try sync.due(XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date())), namesHeld: namesHeld) { sync.done(d) }
        }
        XCTAssertEqual(try due(), [.group, .members], "at pairing, and no names")
        try send()
        XCTAssertEqual(try due(), [])
        g.members.append(Member(number: 5, name: "Zoë", role: .responder, publicKey: Data(count: 32), signingKey: Data(repeating: 5, count: 32)))
        g.membershipVersion += 1
        XCTAssertEqual(try due(), [.members], "someone joined")
        try send()
        g.policy.reportsPowerCut.insert(4)
        XCTAssertEqual(try due(), [.group], "a setting changed")
        try send()
        g.policy.namesOnBox = true
        XCTAssertEqual(try due(), [.names])
        try send()
        g.policy.namesOnBox = false
        XCTAssertEqual(try due(0), [], "names off, and the box holds none: nothing")
        let clear = try sync.due(XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date())), namesHeld: 2)
        XCTAssertEqual(clear.map(\.part), [.names]); XCTAssertEqual(clear[0].pages, HelpBox.noNames, "a box still holding names forgets them")
        sync.boxHoldsNothing()
        XCTAssertEqual(try due(), [.group, .members], "reset: set up again")
        XCTAssertEqual(try sync.due(XCTUnwrap(HelpBox.setup(for: g, box: hex(boxKey), at: Date())), namesHeld: 0)[1].commands.count, 1)
    }

    /// Info (0xA0) as DESIGN.md's table gives it: version, provisioned, unit, member, next request,
    /// mains, battery, hours, antenna, power cap, members, calls, the sealing key, names.
    func testTheBoxRepliesAreRead() throws {
        let d = hex("a0 01 01 74110100 0400 0700 02 930f 0c00 00 0f 02 01 \(boxSealKey) 03")
        guard case let .boxInfo(info)? = MeshCore.Response(d) else { return XCTFail() }
        XCTAssertEqual(info, MeshCore.BoxInfo(protocolVersion: 1, provisioned: true, unit: 70004, member: 4, nextRequest: 7, mains: .off,
                                              mainsEstimated: false, batteryMillivolts: 3987, hoursLeft: 12, antennaCode: 0, powerCap: 15,
                                              members: 2, calls: 1, sealKey: hex(boxSealKey), names: 3))
        var estimated = d
        estimated[11] = 2 | 4
        guard case let .boxInfo(probably)? = MeshCore.Response(estimated) else { return XCTFail() }
        XCTAssertEqual(probably.mains, .off); XCTAssertTrue(probably.mainsEstimated, "plus 4: from the battery, without the mains wire")
        var noSend = d
        noSend[17] = 0x80
        guard case let .boxInfo(capped)? = MeshCore.Response(noSend) else { return XCTFail() }
        XCTAssertNil(capped.powerCap, "-128: the box must not send")
        XCTAssertNil(MeshCore.Response(d.dropLast()), "the names byte is part of it")
        XCTAssertNil(MeshCore.Response(d.prefix(20)), "an info reply from before the sealing key is not read as one")
        guard case let .boxCall(call)? = MeshCore.Response(hex("a1 0200 01 e8030000 02 01")) else { return XCTFail() }
        XCTAssertEqual(call, MeshCore.BoxCall(request: 2, colour: .red, pressedAt: 1000, status: .seen(responder: 0), acknowledgements: 1))
        XCTAssertEqual(MeshCore.Response(hex("a2")), .boxEndOfCalls)
        let frame = HelpFrame.call(unit: 70004, request: 1, colour: .red, sentAt: 1000)
        XCTAssertEqual(MeshCore.Response(Data([0xA3]) + frame.encoded()), .boxFrame(frame))
        XCTAssertNil(MeshCore.Response(hex("a3 ff")), "not a frame")
        XCTAssertEqual(try MeshCore.Command.boxInfo.encoded(), hex("70"))
        XCTAssertEqual(try MeshCore.Command.boxRouteResult(request: 258, sent: true).encoded(), hex("74 0201 01"))
        XCTAssertEqual(try MeshCore.Command.boxGetCalls.encoded(), hex("73"))
    }

    func testACoordinatorAddsTheBoxAsAMemberOfItsOwn() throws {
        var g = firmwareGroup()
        g.members.removeAll { $0.number == 4 }
        let number = try XCTUnwrap(g.addBox(key: hex(boxKey), sealKey: hex(boxSealKey), name: "Hall box", by: 1))
        let box = try XCTUnwrap(g.member(number))
        XCTAssertEqual(box.role, .caller); XCTAssertEqual(box.unit, 70001); XCTAssertEqual(box.name, "Hall box")
        XCTAssertEqual(box.signingKey, hex(boxKey)); XCTAssertEqual(box.publicKey, hex(boxSealKey), "the sealing key from its info reply")
        XCTAssertEqual(g.membershipVersion, 2)
        XCTAssertEqual(g.boxMember(key: hex(boxKey))?.number, number)
        XCTAssertNil(g.addBox(key: hex(boxKey), sealKey: hex(boxSealKey), name: "Again", by: 1), "never twice")
        XCTAssertNil(g.addBox(key: Data(count: 31), sealKey: hex(boxSealKey), name: "Bad", by: 1))
        XCTAssertNil(g.addBox(key: Data(repeating: 3, count: 32), sealKey: Data(count: 32), name: "No key", by: 1),
                     "a box that could not read its own key cannot be sealed for")
        XCTAssertNotNil(g.addedFrame(number), "told to everyone like any member")
    }

    /// The sealed power-cut report exactly as the firmware core made it with the fixed keys above
    /// (firmware/DESIGN.md, section 10): part 1 a Power cut follow-up, part 2 the hours left, or on
    /// a box without the mains wire its "probably".
    let sealedPowerCut = "1074110100020001a0a1a2a3a43f692da011d370d1c1de3e8130ff4b030c5dc2e8786973081c0ffdb37ca945f573689649b069453c7ad6311062ab7de428d733ca6f84ee526220a1a63963b501b4f1c3a2cca9246bd4da3f9bebad17628e22204f9fe0ad50bf65f40a3a"
    let sealedHours = "1074110100020002a0a1a2a3a4b3ec6bae3cd5770f0506230047dc1906986160a56c351536ddcb97bb2d61e81f3c354a82464f41cddd18f0ec1ff79173947c9c04f7bd92f93d408d4bbcfcd24a8231c734d84725240fa882f1b8b92aee94553d40e19f204cb4b6f7945ffd4c4f39ef7c520915ba2d2d30d931e86307c8c3413dea511ea8a2083a02e8"

    let sealedProbably = "1074110100020002a0a1a2a3a4b3ec6bb23cd5770f0506230073cd141e886760e72a7a1f38cad59dbb2172bc477d355682145400d5cc1bf6bbf4ee23285ab59cfef0c798856723395acef943e7afd06a743e44b7a4ce01ed08e6d0093af0011d4e67af0e7e16f9d6c76d2589a714bda047e8b6c671c0843d036a5fc73081ecfac8ff9c915db9ef808eb64c154610bb74df83a51076"

    func testAResponderOpensTheFirmwaresSealedPowerCutReport() throws {
        let g = firmwareGroup()
        let report = try XCTUnwrap(HelpFrame(hex(sealedPowerCut)))
        XCTAssertEqual(hex(sealedPowerCut).count, 106)
        guard case .forResponders(70004, 2, 1, _) = report else { return XCTFail("\(report)") }
        let inner = HelpFrame.followUp(unit: 70004, request: 2, part: 1, category: .powerCut)
        XCTAssertEqual(inner.encoded(), hex("12 74110100 0200 01 04"), "the inner frame's bytes, as the design gives them")
        XCTAssertEqual(ForResponders.open(report, in: g, at: Date()), inner)
        let hours = try XCTUnwrap(HelpFrame(hex(sealedHours)))
        XCTAssertEqual(ForResponders.open(hours, in: g, at: Date()), .note(unit: 70004, request: 2, part: 2, text: "About 24 hours of battery left."))
        let probably = try XCTUnwrap(HelpFrame(hex(sealedProbably)))
        let note = try XCTUnwrap(ForResponders.open(probably, in: g, at: Date()))
        XCTAssertEqual(note, .note(unit: 70004, request: 2, part: 2, text: HelpBox.probablePowerCutNote))
        XCTAssertEqual(note.encoded(), hex("16 74110100 0200 02 2b") + Data("Power probably cut: the battery is falling.".utf8),
                       "the note's bytes, as the design gives them")
        var caller = g
        caller.secrets.responderPrivateKey = nil
        XCTAssertNil(ForResponders.open(report, in: caller, at: Date()), "a caller cannot read it")
        var other = g
        other.members[1].publicKey = Data(repeating: 7, count: 32)
        XCTAssertNil(ForResponders.open(report, in: other, at: Date()), "it opens only with the box's own sealing key")
    }

    func testAPowerReportIsShownCalmlyNotAsACallForHelp() throws {
        var inbox = ResponderInbox()
        let t = Date()
        guard case let .new(key) = inbox.receive(.followUp(unit: 70004, request: 2, part: 1, category: .powerCut), via: .mesh, at: t) else { return XCTFail() }
        inbox.receive(.note(unit: 70004, request: 2, part: 2, text: "About 24 hours of battery left."), via: .mesh, at: t)
        let r = try XCTUnwrap(inbox.requests[key])
        XCTAssertTrue(r.isPowerReport)
        XCTAssertTrue(r.isOpen, "a person acknowledges it, like any request")
        XCTAssertEqual(r.orderedNotes, ["About 24 hours of battery left."])
        var withCall = inbox
        withCall.receive(.call(unit: 70004, request: 2, colour: .red, sentAt: UInt32(t.timeIntervalSince1970)), via: .mesh, at: t)
        XCTAssertFalse(withCall.requests[key]!.isPowerReport, "a Power cut chosen on a call is the call's")
        XCTAssertFalse(r.powerCutIsProbable, "a box with the mains wire knows")
        var estimated = ResponderInbox()
        estimated.receive(.followUp(unit: 70004, request: 3, part: 1, category: .powerCut), via: .mesh, at: t)
        estimated.receive(.note(unit: 70004, request: 3, part: 2, text: HelpBox.probablePowerCutNote), via: .mesh, at: t)
        XCTAssertTrue(estimated.requests[IncomingRequest.Key(unit: 70004, request: 3)]!.powerCutIsProbable)
    }
}

/// The box's frames through the phone that is paired with it, over the fakes of EngineTests.
@MainActor final class BoxEngineTests: XCTestCase {
    var air: Air!
    var clock: Clock!
    var coordinator: Phone!
    var household: Phone!
    var responder: Phone!
    /// The box's own keys: its MeshCore identity, which signs, and the X25519 key it seals with,
    /// which it reports in its info reply.
    let boxIdentity = DeviceIdentity()
    var boxKey: Data { boxIdentity.signingPublicKey }
    var boxUnit: UInt32 { coordinator.engine.group!.boxMember(key: boxKey)!.unit! }

    override func setUp() async throws {
        air = Air(); clock = Clock()
        coordinator = Phone(air: air, clock: clock)
        household = Phone(air: air, clock: clock)
        responder = Phone(air: air, clock: clock)
        coordinator.engine.createGroup(name: "Mill Lane", myName: "Sam", call: false)
        join(household, name: "Pat", call: true, respond: true)
        join(responder, name: "Jo", call: false, respond: true)
        // The household's phone is paired with the box, so its key is the box's.
        household.mesh.boxPublicKey = boxKey
        coordinator.relay.isConfigured = true; household.relay.isConfigured = true; responder.relay.isConfigured = true
        await air.run()
        coordinator.engine.tick()
        await air.run()
        for p in air.phones { await p.engine.boxReady() }
        await air.run()
        XCTAssertNil(coordinator.engine.addBox(key: boxKey, sealKey: boxIdentity.publicKey, name: "Kitchen box"))
        await air.run()
        air.groupSends = []
    }

    func join(_ p: Phone, name: String, call: Bool, respond: Bool) {
        let c = coordinator.engine!
        let invite = Joining.invitation(for: c.group!, coordinator: coordinator.identity)
        let request = Joining.request(invite, name: name, call: call, respond: respond, me: p.identity)
        var welcome: Joining.Welcome?
        c.updateGroup { g in welcome = try! Joining.admit(request, to: &g, invite: invite, coordinator: coordinator.identity) }
        p.engine.joined(try! Joining.open(welcome!, invite: invite, me: p.identity), as: welcome!.memberNumber)
    }

    var boxMember: UInt16 { coordinator.engine.group!.boxMember(key: boxKey)!.number }
    func boxCall(_ number: UInt16, _ colour: Colour = .red) -> HelpFrame {
        .call(unit: boxUnit, request: number, colour: colour, sentAt: UInt32(clock.now.timeIntervalSince1970))
    }
    var key: IncomingRequest.Key { IncomingRequest.Key(unit: boxUnit, request: 1) }

    func testTheBoxIsAMemberOnEveryPhoneAndGetsItsSetUp() throws {
        for p in [coordinator, household, responder] {
            let m = try XCTUnwrap(p!.engine.group?.boxMember(key: boxKey))
            XCTAssertEqual(m.role, .caller); XCTAssertNotNil(m.unit)
            XCTAssertEqual(m.publicKey, boxIdentity.publicKey, "its sealing key, from its info reply")
        }
        XCTAssertEqual(responder.engine.group?.boxMember(key: boxKey)?.name, "Kitchen box")
        XCTAssertEqual(household.engine.pairedBoxUnit, boxUnit)
        XCTAssertNil(responder.engine.pairedBoxUnit, "another phone's box is not this household's")
        XCTAssertEqual(coordinator.engine.activity.log.entries.last?.text, "You added the box Kitchen box")
        XCTAssertNotNil(household.engine.addBox(key: boxKey, sealKey: boxIdentity.publicKey, name: "Again"), "only a coordinator adds, and never twice")
        let setup = try XCTUnwrap(HelpBox.setup(for: household.engine.group!, box: boxKey, at: clock.now))
        XCTAssertEqual(setup.member, boxMember); XCTAssertEqual(setup.unit, boxUnit)
        XCTAssertEqual(setup.group.suffix(2), Data([1, 0]), "the first coordinator")
        XCTAssertEqual(setup.members[0][5], 4, "every member, the box included")
    }

    func testTheBoxsCallIsCarriedOnThePhonesRoutesAndNeverAlertsTheHousehold() async throws {
        let took = await household.engine.receiveFromBox(boxCall(1))
        XCTAssertEqual(took, true, "the internet took it, for the box's 0x74")
        await air.run()
        let r = try XCTUnwrap(household.engine.activity.outgoing.first { $0.fromBox })
        XCTAssertEqual(r.unit, boxUnit); XCTAssertEqual(r.routes[.internet], .sent); XCTAssertNil(r.routes[.mesh], "the box sent on the radio itself")
        XCTAssertNil(household.engine.current, "not the household's own call")
        XCTAssertNil(household.alerts.scheduled[key], "the household is not alerted for its own box")
        XCTAssertNil(household.engine.activity.inbox.requests[key])
        XCTAssertNotNil(responder.alerts.scheduled[key], "a responder is")
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.heardOn, [.internet])
        XCTAssertTrue(air.groupSends.isEmpty, "the phone did not send the call on the radio again")
        XCTAssertEqual(household.engine.name(ofUnit: boxUnit), "Kitchen box")
        let again = await household.engine.receiveFromBox(boxCall(1))
        XCTAssertEqual(again, true, "the same call again is not sent twice")
        XCTAssertEqual(household.engine.activity.outgoing.filter(\.fromBox).count, 1)
    }

    func testAnAcknowledgementFromTheInternetReachesTheBoxOverTheRadio() async throws {
        _ = await household.engine.receiveFromBox(boxCall(1))
        await air.run()
        responder.mesh.isReady = false
        responder.engine.acknowledge(key)
        await air.run()
        let r = try XCTUnwrap(household.engine.activity.outgoing.first { $0.fromBox })
        XCTAssertEqual(r.status, .seen(responder: responder.engine.saved!.me))
        XCTAssertEqual(air.groupSends.count, 1, "the household's phone put the acknowledgement on the radio for the box")
        guard case .ack(boxUnit, 1, _, _, _) = air.groupSends[0] else { return XCTFail() }
    }

    func testTheBoxsOwnOKAndACoordinatorsCloseSettleItsCall() async throws {
        _ = await household.engine.receiveFromBox(boxCall(1))
        await air.run()
        let gid = household.engine.group!.secrets.groupID
        let ok = HelpFrame.signing(.callState(unit: boxUnit, request: 1, state: .callerOK, at: UInt32(clock.now.timeIntervalSince1970), reason: ""),
                                   as: boxMember, identity: boxIdentity, group: gid)
        let none = await household.engine.receiveFromBox(ok)
        XCTAssertNil(none)
        await air.run()
        XCTAssertEqual(household.engine.activity.outgoing.first { $0.fromBox }?.settled?.state, .callerOK)
        XCTAssertEqual(responder.engine.activity.inbox.requests[key]?.callerIsOK, true, "carried over the internet")
        XCTAssertTrue(air.groupSends.isEmpty, "and not on the radio again")
        coordinator.mesh.isReady = false
        coordinator.engine.close(key, consent: true)
        await air.run()
        XCTAssertEqual(household.engine.activity.outgoing.first { $0.fromBox }?.status, .closed(by: coordinator.engine.saved!.me))
        XCTAssertEqual(air.groupSends.count, 1, "the close goes on the radio for the box")
    }

    func testTheHouseholdsOwnButtonsLeaveTheBoxsCallAlone() async throws {
        _ = await household.engine.receiveFromBox(boxCall(1))
        household.engine.press(.red)
        await air.run()
        XCTAssertEqual(household.engine.current?.unit, household.engine.me?.unit)
        household.engine.press(.green)
        await air.run()
        XCTAssertNil(household.engine.activity.outgoing.first { $0.fromBox }?.settled, "I'm OK on the phone settles only the phone's calls")
        XCTAssertNotNil(household.engine.activity.outgoing.first { !$0.fromBox && $0.colour == .red }?.settled)
        XCTAssertNil(household.engine.addNote("a note"), "notes go on the phone's own call")
        XCTAssertTrue(household.engine.activity.outgoing.first { $0.fromBox }!.notes.isEmpty)
    }

    func testTheBoxsSealedPowerCutReportReachesRespondersCalmly() async throws {
        let g = household.engine.group!
        let report = try XCTUnwrap(ForResponders.seal(.followUp(unit: boxUnit, request: 2, part: 1, category: .powerCut), from: boxIdentity, as: boxMember, in: g, at: clock.now).first)
        let none = await household.engine.receiveFromBox(report)
        XCTAssertNil(none)
        await air.run()
        let k = IncomingRequest.Key(unit: boxUnit, request: 2)
        let r = try XCTUnwrap(responder.engine.activity.inbox.requests[k])
        XCTAssertTrue(r.isPowerReport)
        let alert = try XCTUnwrap(responder.alerts.scheduled[k])
        XCTAssertTrue(alert.calm)
        XCTAssertEqual(alert.title, "Kitchen box: power cut at home")
        XCTAssertEqual(alert.body, "Their box is on its battery. Please check on them when you can, then acknowledge in Help&I.")
        XCTAssertNil(household.engine.activity.inbox.requests[k], "the household is not alerted about its own box")
        let note = try XCTUnwrap(ForResponders.seal(.note(unit: boxUnit, request: 2, part: 2, text: "About 12 hours of battery left."), from: boxIdentity, as: boxMember, in: g, at: clock.now).first)
        _ = await household.engine.receiveFromBox(note)
        await air.run()
        XCTAssertEqual(responder.engine.activity.inbox.requests[k]?.orderedNotes, ["About 12 hours of battery left."])
        XCTAssertTrue(responder.engine.activity.inbox.requests[k]!.isOpen, "until a person acknowledges")
    }

    func testABoxWithoutTheMainsWireSaysProbably() async throws {
        let g = household.engine.group!
        for inner in [HelpFrame.followUp(unit: boxUnit, request: 3, part: 1, category: .powerCut),
                      .note(unit: boxUnit, request: 3, part: 2, text: HelpBox.probablePowerCutNote)] {
            _ = await household.engine.receiveFromBox(try XCTUnwrap(ForResponders.seal(inner, from: boxIdentity, as: boxMember, in: g, at: clock.now).first))
            await air.run()
        }
        let k = IncomingRequest.Key(unit: boxUnit, request: 3)
        XCTAssertEqual(responder.engine.activity.inbox.requests[k]?.powerCutIsProbable, true)
        let alert = try XCTUnwrap(responder.alerts.scheduled[k])
        XCTAssertEqual(alert.title, "Kitchen box: probably a power cut at home", "the alert says it may be wrong")
        XCTAssertTrue(alert.calm)
    }

    func testAProbablePowerCutGoesAsANoteWordedAsAGuess() async throws {
        household.relay.isConfigured = false; household.mesh.isReady = false
        XCTAssertEqual(household.engine.tellRespondersOfProbablePowerCut(), HelpEngine.cannotSendPersonal)
        XCTAssertNil(household.engine.current, "no Need a hand that could not carry the note")
        household.relay.isConfigured = true; household.mesh.isReady = true
        XCTAssertNil(household.engine.tellRespondersOfProbablePowerCut())
        await air.run()
        let r = try XCTUnwrap(household.engine.current)
        XCTAssertEqual(r.colour, .amber, "a new Need a hand, as nothing was open")
        XCTAssertEqual(r.notes, [HelpBox.probablePowerCutNote])
        let k = IncomingRequest.Key(unit: r.unit, request: r.number)
        XCTAssertEqual(responder.engine.activity.inbox.requests[k]?.orderedNotes, ["Power probably cut: the battery is falling."])
        household.engine.press(.red)
        XCTAssertNil(household.engine.tellRespondersOfProbablePowerCut())
        XCTAssertEqual(household.engine.current?.colour, .red, "on an open call, the note goes on it")
        XCTAssertEqual(household.engine.current?.notes, [HelpBox.probablePowerCutNote])
    }

    func testAnotherUnitsCallFromTheBoxIsIgnored() async {
        let other = HelpFrame.call(unit: household.engine.me!.unit!, request: 5, colour: .red, sentAt: UInt32(clock.now.timeIntervalSince1970))
        let none = await household.engine.receiveFromBox(other)
        XCTAssertNil(none)
        XCTAssertTrue(household.engine.activity.outgoing.isEmpty)
        let other2 = await responder.engine.receiveFromBox(boxCall(1))
        XCTAssertNil(other2, "a phone not paired with the box carries nothing for it")
        XCTAssertTrue(responder.engine.activity.outgoing.isEmpty)
    }
}
