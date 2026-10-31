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
        /// Help&I's own commands, answered only by a box on Help&I's firmware (firmware/DESIGN.md,
        /// section 6): what the box holds, the group, its members and responders' first names
        /// (`HelpBox.Setup`), its calls, and what the phone's routes did with one.
        case boxInfo
        case boxSetGroup(body: Data)
        case boxSetMembers(page: Data)
        case boxSetNames(page: Data)
        case boxGetCalls
        case boxRouteResult(request: UInt16, sent: Bool)

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
            case .boxInfo: w.u8(0x70)
            case let .boxSetGroup(body):
                guard body.count == HelpBox.groupBodyBytes else { throw MeshCoreError.badBoxSetup }
                w.u8(0x71); w.bytes(body)
            case let .boxSetMembers(page):
                guard page.count >= 6, (page.count - 6) % HelpBox.memberBytes == 0, page.count <= 6 + HelpBox.membersPerPage * HelpBox.memberBytes else {
                    throw MeshCoreError.badBoxSetup
                }
                w.u8(0x72); w.bytes(page)
            case let .boxSetNames(page):
                guard page.count >= 6 else { throw MeshCoreError.badBoxSetup }
                w.u8(0x76); w.bytes(page)
            case .boxGetCalls: w.u8(0x73)
            case let .boxRouteResult(request, sent): w.u8(0x74); w.u16(request); w.u8(sent ? 1 : 0)
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

        /// Help&I's build of the firmware says so in its version, `v1.18.0-hi1` (firmware/DESIGN.md,
        /// section 6); a stock box does not, and gets no Help&I command.
        public var isHelpBox: Bool { version.range(of: #"-hi[0-9]+$"#, options: .regularExpression) != nil }
    }

    /// What a Help&I box holds (reply 0xA0 to `boxInfo`).
    public struct BoxInfo: Equatable, Sendable {
        public enum Mains: UInt8, Sendable { case unknown = 0, on = 1, off = 2 }
        public let protocolVersion: UInt8
        public let provisioned: Bool
        public let unit: UInt32
        public let member: UInt16
        public let nextRequest: UInt16
        public let mains: Mains
        /// Mains from the battery's trend, on a box without the mains wire: "probably".
        public let mainsEstimated: Bool
        public let batteryMillivolts: Int
        public let hoursLeft: Int
        public let antennaCode: UInt8
        /// The highest radio setting the box allows itself, in dBm; nil where it must not send.
        public let powerCap: Int?
        public let members: Int
        public let calls: Int
        /// The X25519 key the box seals with, for its member entry; all zero if it could not read
        /// its own key.
        public let sealKey: Data
        /// How many responders' first names it holds.
        public let names: Int
    }

    /// One of the box's own calls (reply 0xA1 to `boxGetCalls`), with the status the box shows.
    public struct BoxCall: Equatable, Sendable {
        public let request: UInt16
        public let colour: Colour
        public let pressedAt: UInt32
        public let status: CallerStatus
        public let acknowledgements: Int
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
        /// From a Help&I box: what it holds, each of its calls and the end of them, and a frame it
        /// made for the phone to carry (push 0xA3).
        case boxInfo(BoxInfo)
        case boxCall(BoxCall)
        case boxEndOfCalls
        case boxFrame(HelpFrame)
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
            case 0xA0:
                guard let proto = r.u8(), let provisioned = r.u8(), let unit = r.u32(), let member = r.u16(), let next = r.u16(),
                      let mainsByte = r.u8(), let mains = BoxInfo.Mains(rawValue: mainsByte & 3), let mv = r.u16(), let hours = r.u16(),
                      let antenna = r.u8(), let cap = r.u8(), let members = r.u8(), let calls = r.u8(), let seal = r.take(32),
                      let names = r.u8() else { return nil }
                self = .boxInfo(BoxInfo(protocolVersion: proto, provisioned: provisioned != 0, unit: unit, member: member, nextRequest: next,
                                        mains: mains, mainsEstimated: mainsByte & 4 != 0, batteryMillivolts: Int(mv), hoursLeft: Int(hours),
                                        antennaCode: antenna, powerCap: Int8(bitPattern: cap) == -128 ? nil : Int(Int8(bitPattern: cap)),
                                        members: Int(members), calls: Int(calls), sealKey: Data(seal), names: Int(names)))
            case 0xA1:
                guard let request = r.u16(), let colour = r.u8().flatMap(Colour.init), let at = r.u32(), let status = r.u8(), let acks = r.u8() else { return nil }
                let s: CallerStatus
                switch status {
                case 0: s = .sending
                case 1: s = .waitingForResponder
                case 2: s = .seen(responder: 0)
                case 3: s = .notSent
                case 4: s = .closed(by: 0)
                default: return nil
                }
                self = .boxCall(BoxCall(request: request, colour: colour, pressedAt: at, status: s, acknowledgements: Int(acks)))
            case 0xA2: self = .boxEndOfCalls
            case 0xA3:
                guard let f = HelpFrame(Data(r.rest())) else { return nil }
                self = .boxFrame(f)
            default: self = .other(code: code)
            }
        }
    }
}

public enum MeshCoreError: Error, Equatable {
    case badSecret, payloadTooLarge, badContact, badPin, badBoxSetup
}

private func cString(_ bytes: [UInt8]) -> String {
    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}
