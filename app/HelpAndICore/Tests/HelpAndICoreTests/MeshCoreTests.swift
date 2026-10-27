import XCTest
@testable import HelpAndICore

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
        XCTAssertEqual(try MeshCore.Command.appStart(name: "HelpAndI").encoded().prefix(8), hex("0101000000000000"))
    }

    func testSetChannelIsFiftyBytesAndRefusesAZeroSecret() throws {
        let secret = Data((1...16).map { UInt8($0) })
        let d = try MeshCore.Command.setChannel(index: 2, name: "Help&I", secret: secret).encoded()
        XCTAssertEqual(d.count, 50)
        XCTAssertEqual(d.suffix(16), secret)
        XCTAssertThrowsError(try MeshCore.Command.setChannel(index: 2, name: "x", secret: Data(count: 16)).encoded())
        XCTAssertThrowsError(try MeshCore.Command.setChannel(index: 2, name: "x", secret: Data(count: 32)).encoded())
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
