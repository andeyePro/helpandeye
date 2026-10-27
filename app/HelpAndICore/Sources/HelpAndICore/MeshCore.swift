import Foundation

/// The MeshCore companion protocol, spoken over Bluetooth to a board running MeshCore's standard
/// companion firmware (docs/companion_protocol.md in meshcore-dev/MeshCore, v1.12.0+). One
/// Bluetooth write or notification carries exactly one frame.
public enum MeshCore {
    public static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// The app writes commands here.
    public static let rxUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// The board sends responses and pushes here.
    public static let txUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    /// A flood send: the board relays it to every repeater in range rather than along a path.
    public static let flood: UInt8 = 0xFF

    public enum Command: Equatable, Sendable {
        case appStart(name: String)
        case deviceQuery
        case setDeviceTime(UInt32)
        case getChannel(index: UInt8)
        case setChannel(index: UInt8, name: String, secret: Data)
        case sendChannelData(index: UInt8, dataType: UInt16, payload: Data)
        case sendText(publicKeyPrefix: Data, text: String, sentAt: UInt32, attempt: UInt8)
        case syncNextMessage
        case getBattery
        /// Adds another member's board as a chat contact, so direct messages can be sent to it.
        /// With no known path, the board floods the first message and learns the path from the reply.
        case addContact(publicKey: Data, name: String)
        /// The six-digit Bluetooth pairing code (CMD_SET_DEVICE_PIN, 37 in the firmware source).
        case setPin(UInt32)

        public func encoded() throws -> Data {
            var w = ByteWriter()
            switch self {
            case let .appStart(name):
                w.u8(0x01); w.u8(1); w.bytes(Data(count: 6)); w.bytes(Data(name.utf8))
            case .deviceQuery:
                w.u8(0x16); w.u8(0x03)
            case let .setDeviceTime(t):
                w.u8(0x06); w.u32(t)
            case let .getChannel(i):
                w.u8(0x1F); w.u8(i)
            case let .setChannel(i, name, secret):
                // A zero secret makes a channel anyone can read, so it is never written.
                guard secret.count == 16, secret.contains(where: { $0 != 0 }) else { throw MeshCoreError.badSecret }
                var n = Data(name.utf8.prefix(31)); n.append(Data(count: 32 - n.count))
                w.u8(0x20); w.u8(i); w.bytes(n); w.bytes(secret)
            case let .sendChannelData(i, type, payload):
                guard type != 0, payload.count <= HelpFrame.maxPayload else { throw MeshCoreError.payloadTooLarge }
                w.u8(0x3E); w.u8(i); w.u8(MeshCore.flood); w.u16(type); w.bytes(payload)
            case let .sendText(prefix, text, sentAt, attempt):
                guard prefix.count >= 6 else { throw MeshCoreError.badContact }
                w.u8(0x02); w.u8(0); w.u8(attempt); w.u32(sentAt); w.bytes(prefix.prefix(6)); w.bytes(Data(text.utf8))
            case .syncNextMessage:
                w.u8(0x0A)
            case .getBattery:
                w.u8(0x14)
            case let .setPin(pin):
                guard (100_000...999_999).contains(pin) else { throw MeshCoreError.badPin }
                w.u8(0x25); w.u32(pin)
            case let .addContact(key, name):
                guard key.count == 32 else { throw MeshCoreError.badContact }
                var n = Data(name.utf8.prefix(31)); n.append(Data(count: 32 - n.count))
                w.u8(0x09); w.bytes(key); w.u8(1); w.u8(0); w.u8(0xFF); w.bytes(Data(count: 64)); w.bytes(n)
                w.u32(0); w.i32(0); w.i32(0)
            }
            return w.data
        }
    }

    public struct SelfInfo: Equatable, Sendable {
        public let publicKey: Data
        public let txPower: Int
        public let radio: RadioSettings
        public let name: String
    }

    public struct DeviceInfo: Equatable, Sendable {
        public let firmwareVersion: Int
        public let maxChannels: Int
        /// The Bluetooth pairing code; 123456 is MeshCore's default.
        public let blePin: UInt32
        public let model: String
        public let version: String
    }

    public enum Response: Equatable, Sendable {
        case ok
        case error(code: UInt8)
        case selfInfo(SelfInfo)
        case deviceInfo(DeviceInfo)
        case channelInfo(index: UInt8, name: String, secret: Data)
        case sent(flood: Bool, expectedAck: UInt32, timeoutMs: UInt32)
        case channelData(channel: UInt8, dataType: UInt16, payload: Data, snr: Double)
        case contactText(publicKeyPrefix: Data, text: String, sentAt: UInt32)
        case channelText(channel: UInt8, text: String, sentAt: UInt32)
        case noMoreMessages
        case battery(millivolts: Int)
        case messagesWaiting
        case sendConfirmed
        case other(code: UInt8)

        // swiftlint:disable:next cyclomatic_complexity
        public init?(_ data: Data) {
            var r = ByteReader(data)
            guard let code = r.u8() else { return nil }
            switch code {
            case 0x00: self = .ok
            case 0x01: self = .error(code: r.u8() ?? 0)
            case 0x05:
                guard let _ = r.u8(), let tx = r.u8(), let _ = r.u8(), let key = r.take(32),
                      let _ = r.i32(), let _ = r.i32(), let _ = r.take(4),
                      let f = r.u32(), let bw = r.u32(), let sf = r.u8(), let cr = r.u8() else { return nil }
                let name = String(decoding: r.rest(), as: UTF8.self).trimmingCharacters(in: .controlCharacters)
                self = .selfInfo(SelfInfo(publicKey: Data(key), txPower: Int(tx),
                    radio: RadioSettings(frequencyMHz: Double(f) / 1000, bandwidthKHz: Double(bw) / 1000,
                                         spreadingFactor: Int(sf), codingRate: Int(cr)), name: name))
            case 0x06:
                guard let flag = r.u8(), let ack = r.u32(), let t = r.u32() else { return nil }
                self = .sent(flood: flag == 1, expectedAck: ack, timeoutMs: t)
            case 0x07, 0x10:
                if code == 0x10 { guard r.take(3) != nil else { return nil } }
                guard let prefix = r.take(6), let _ = r.u8(), let type = r.u8(), let at = r.u32() else { return nil }
                if type == 2 { guard r.take(4) != nil else { return nil } }
                self = .contactText(publicKeyPrefix: Data(prefix), text: String(decoding: r.rest(), as: UTF8.self), sentAt: at)
            case 0x08, 0x11:
                if code == 0x11 { guard r.take(3) != nil else { return nil } }
                guard let ch = r.u8(), let _ = r.u8(), let _ = r.u8(), let at = r.u32() else { return nil }
                self = .channelText(channel: ch, text: String(decoding: r.rest(), as: UTF8.self), sentAt: at)
            case 0x0A: self = .noMoreMessages
            case 0x0C:
                guard let mv = r.u16() else { return nil }
                self = .battery(millivolts: Int(mv))
            case 0x0D:
                guard let ver = r.u8() else { return nil }
                guard ver >= 3, let _ = r.u8(), let maxCh = r.u8(), let pin = r.u32(), let _ = r.take(12),
                      let model = r.take(40), let version = r.take(20) else {
                    self = .deviceInfo(DeviceInfo(firmwareVersion: Int(ver), maxChannels: 0, blePin: 0, model: "", version: "")); return
                }
                self = .deviceInfo(DeviceInfo(firmwareVersion: Int(ver), maxChannels: Int(maxCh), blePin: pin,
                                              model: cString(model), version: cString(version)))
            case 0x12:
                guard let i = r.u8(), let name = r.take(32), let secret = r.take(16) else { return nil }
                self = .channelInfo(index: i, name: cString(name), secret: Data(secret))
            case 0x1B:
                guard let snr = r.u8(), r.take(2) != nil, let ch = r.u8(), let _ = r.u8(),
                      let type = r.u16(), let len = r.u8(), let payload = r.take(Int(len)) else { return nil }
                self = .channelData(channel: ch, dataType: type, payload: Data(payload), snr: Double(Int8(bitPattern: snr)) / 4)
            case 0x82: self = .sendConfirmed
            case 0x83: self = .messagesWaiting
            default: self = .other(code: code)
            }
        }
    }
}

public enum MeshCoreError: Error, Equatable {
    case badSecret, payloadTooLarge, badContact, badPin
}

private func cString(_ bytes: [UInt8]) -> String {
    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}
