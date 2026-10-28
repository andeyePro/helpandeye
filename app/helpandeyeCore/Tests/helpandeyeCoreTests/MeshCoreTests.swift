import XCTest
@testable import helpandeyeCore

final class MeshCoreTests: XCTestCase {
    func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { i in
            UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }

    func testCommandsMatchTheProtocolDocument() throws {
        XCTAssertEqual(try MeshCore.Command.deviceQuery.encoded(), hex("1603"))
        XCTAssertEqual(try MeshCore.Command.getChannel(index: 1).encoded(), hex("1f01"))
        XCTAssertEqual(try MeshCore.Command.syncNextMessage.encoded(), hex("0a"))
        XCTAssertEqual(try MeshCore.Command.setDeviceTime(1_234_567_890).encoded(), hex("06d2029649"))
        // The document's datagram example: flood, data type 0xFFFF, payload A1 B2 C3, channel 1.
        XCTAssertEqual(try MeshCore.Command.sendChannelData(index: 1, dataType: 0xFFFF, payload: hex("a1b2c3")).encoded(),
                       hex("3e01ffffffa1b2c3"))
        XCTAssertEqual(try MeshCore.Command.appStart(name: "HelpA").encoded().prefix(8), hex("0101000000000000"))
    }

    func testSetChannelIsFiftyBytesAndRefusesAZeroSecret() throws {
        let secret = Data((1...16).map { UInt8($0) })
        let d = try MeshCore.Command.setChannel(index: 2, name: "Help&I", secret: secret).encoded()
        XCTAssertEqual(d.count, 50)
        XCTAssertEqual(d.suffix(16), secret)
        XCTAssertThrowsError(try MeshCore.Command.setChannel(index: 2, name: "x", secret: Data(count: 16)).encoded())
        XCTAssertThrowsError(try MeshCore.Command.setChannel(index: 2, name: "x", secret: Data(count: 32)).encoded())
    }

    func testAddContactLayout() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let d = try MeshCore.Command.addContact(publicKey: key, name: "Box 2").encoded()
        XCTAssertEqual(d.count, 144)
        XCTAssertEqual(d.first, 0x09)
        XCTAssertEqual(d.subdata(in: 1..<33), key)
        XCTAssertEqual(d[33], 1, "chat contact"); XCTAssertEqual(d[35], 0xFF, "no path known yet")
        XCTAssertEqual(d.subdata(in: 100..<105), Data("Box 2".utf8))
        XCTAssertThrowsError(try MeshCore.Command.addContact(publicKey: Data(count: 6), name: "x").encoded())
    }

    func testSetPinAndReadItBack() throws {
        XCTAssertEqual(try MeshCore.Command.setPin(654_321).encoded(), hex("25f1fb0900"))
        XCTAssertThrowsError(try MeshCore.Command.setPin(12_345).encoded())
        XCTAssertThrowsError(try MeshCore.Command.setPin(1_000_000).encoded())
        var d = Data([0x0D, 9, 50, 8]); var w = ByteWriter(); w.u32(123_456); d.append(w.data)
        d.append(Data(count: 12)); d.append(Data("Heltec V4".utf8) + Data(count: 31)); d.append(Data("v1.12.0".utf8) + Data(count: 13))
        guard case let .deviceInfo(info)? = MeshCore.Response(d) else { return XCTFail() }
        XCTAssertEqual(info.blePin, 123_456); XCTAssertEqual(info.maxChannels, 8); XCTAssertEqual(info.model, "Heltec V4")
    }

    func testDatagramLimit() {
        XCTAssertNoThrow(try MeshCore.Command.sendChannelData(index: 1, dataType: 1, payload: Data(count: 165)).encoded())
        XCTAssertThrowsError(try MeshCore.Command.sendChannelData(index: 1, dataType: 1, payload: Data(count: 166)).encoded())
        XCTAssertThrowsError(try MeshCore.Command.sendChannelData(index: 1, dataType: 0, payload: Data()).encoded())
    }

    func testParsesChannelDatagram() {
        let frame = HelpFrame.call(unit: 9, request: 1, colour: .red, sentAt: 0).encoded()
        var d = hex("1bf6000001ff48ff"); d.append(UInt8(frame.count)); d.append(frame)
        guard case let .channelData(ch, type, payload, snr)? = MeshCore.Response(d) else { return XCTFail() }
        XCTAssertEqual(ch, 1); XCTAssertEqual(type, HelpFrame.meshDataType); XCTAssertEqual(snr, -2.5)
        XCTAssertEqual(HelpFrame(payload), .call(unit: 9, request: 1, colour: .red, sentAt: 0))
        XCTAssertNil(MeshCore.Response(d.dropLast()))
    }

    func testParsesSelfInfoRadioSettings() {
        var d = Data([0x05, 1, 22, 22]); d.append(Data(repeating: 0xAB, count: 32))
        d.append(Data(count: 8)); d.append(Data([0, 0, 0, 0]))
        var w = ByteWriter(); w.u32(869_618); w.u32(62_500); w.u8(8); w.u8(8); w.bytes(Data("Box 1".utf8))
        d.append(w.data)
        guard case let .selfInfo(info)? = MeshCore.Response(d) else { return XCTFail() }
        XCTAssertEqual(info.radio, RadioSettings(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8))
        XCTAssertEqual(info.name, "Box 1"); XCTAssertEqual(info.txPower, 22)
    }

    func testParsesSentAndContactTextV3() {
        guard case let .sent(flood, ack, timeout)? = MeshCore.Response(hex("060178563412e8030000")) else { return XCTFail() }
        XCTAssertTrue(flood); XCTAssertEqual(ack, 0x12345678); XCTAssertEqual(timeout, 1000)
        var d = hex("100800 00a1a2a3a4a5a6 ff 00 d2029649".replacingOccurrences(of: " ", with: "")); d.append(Data("hi".utf8))
        guard case let .contactText(prefix, text, at)? = MeshCore.Response(d) else { return XCTFail() }
        XCTAssertEqual(prefix, hex("a1a2a3a4a5a6")); XCTAssertEqual(text, "hi"); XCTAssertEqual(at, 1_234_567_890)
    }

    func testParsesErrorsAndPushes() {
        XCTAssertEqual(MeshCore.Response(hex("0106")), .error(code: 6))
        XCTAssertEqual(MeshCore.Response(hex("83")), .messagesWaiting)
        XCTAssertEqual(MeshCore.Response(hex("0a")), .noMoreMessages)
        XCTAssertEqual(MeshCore.Response(hex("88")), .other(code: 0x88))
        XCTAssertNil(MeshCore.Response(Data()))
    }
}

final class ChannelPlanTests: XCTestCase {
    let old = Data(repeating: 1, count: 16), new = Data(repeating: 2, count: 16), other = Data(repeating: 9, count: 16)
    func slot(_ i: UInt8, _ name: String, _ secret: Data) -> ChannelPlan.Slot { .init(index: i, name: name, secret: secret) }

    func testFindsOrWritesTheChannels() {
        let p = ChannelPlan.plan(slots: [slot(0, "Public", other), slot(1, "", Data(count: 16)), slot(2, "Help&I", old)], secrets: [new, old])
        XCTAssertEqual(p.writes, [.init(index: 1, name: "Help&I", secret: new)])
        XCTAssertEqual(p.current, 1); XCTAssertEqual(p.previous, 2)
    }

    func testAFullBoxRecoversWhenTheChangeoverEnds() {
        let full = [slot(0, "Public", other), slot(1, "Help&I", old)]
        let during = ChannelPlan.plan(slots: full, secrets: [new, old])
        XCTAssertNil(during.current, "no room for the new channel while the old one is still needed")
        let after = ChannelPlan.plan(slots: full, secrets: [new])
        XCTAssertEqual(after.writes, [.init(index: 1, name: "Help&I", secret: new)], "the old slot is reused")
        XCTAssertEqual(after.current, 1)
    }

    func testSeveralGroupsShareTheBoxsChannelsCurrentOnesFirst() {
        let a = Data(repeating: 1, count: 16), aOld = Data(repeating: 2, count: 16), b = Data(repeating: 3, count: 16)
        let theirs = Data(repeating: 9, count: 16), stale = Data(repeating: 8, count: 16)
        let slots: [ChannelPlan.Slot] = [.init(index: 0, name: "Public", secret: theirs), .init(index: 1, name: "Help&I", secret: stale),
                                         .init(index: 2, name: "", secret: Data(count: 16))]
        let plan = ChannelPlan.plan(slots: slots, groups: [[a, aOld], [b]])
        XCTAssertEqual(plan.channels[a], 1, "a Help&I channel no group uses is reused")
        XCTAssertEqual(plan.channels[b], 2, "the second group's current channel comes before the first's old one")
        XCTAssertNil(plan.channels[aOld], "no room left for the old channel")
        XCTAssertEqual(plan.writes.map(\.name), ["Help&I", "Help&I 2"])
        XCTAssertFalse(plan.writes.contains { $0.index == 0 }, "someone else's channel is never overwritten")
    }

    func testOtherChannelsAreNeverOverwritten() {
        let p = ChannelPlan.plan(slots: [slot(0, "Public", other), slot(1, "Family", Data(repeating: 5, count: 16))], secrets: [new])
        XCTAssertTrue(p.writes.isEmpty)
        XCTAssertNil(p.current)
    }
}
