import CryptoKit
import Foundation

/// The colour of a call. Red is "come now", amber "come when convenient", green "I'm OK now".
public enum Colour: UInt8, Sendable, CaseIterable, Codable {
    case red = 1, amber = 2, green = 3
}

/// Follow-up categories a caller can add after the first press. Codes, not text, so they fit on
/// the group channel without carrying personal detail (decision 12).
public enum CallCategory: UInt8, Sendable, CaseIterable, Codable {
    case fallen = 1, unwell = 2, lockedOut = 3, powerCut = 4, needCompany = 5, missedCheckIn = 6, other = 99
}

/// Things a coordinator is told about and must acknowledge.
public enum Notice: UInt8, Sendable, Codable, CaseIterable {
    case rotaGap = 1, allowanceLow = 2
}

/// One Help&I message on the MeshCore group channel, sent as a channel data datagram.
///
/// Every frame starts with a byte holding the format version (high nibble) and the kind (low
/// nibble), then the caller's unit number and request number, so a responder can always tie a
/// frame to its request even when frames arrive out of order or twice.
public enum HelpFrame: Equatable, Sendable {
    /// A red, amber or green press. Sent at once, with nothing else in it.
    case call(unit: UInt32, request: UInt16, colour: Colour, sentAt: UInt32)
    /// A category added after the call, numbered so the responder app can assemble the set.
    case followUp(unit: UInt32, request: UInt16, part: UInt8, category: CallCategory)
    /// A responder pressed acknowledge. `responder` is their member number in the group. Signed
    /// with the responder's own key, so neither a removed phone nor another member can fake one
    /// and falsely reassure a caller.
    case ack(unit: UInt32, request: UInt16, responder: UInt16, ackedAt: UInt32, signature: Data)
    /// A responder's availability changed while there was no internet (rota, app spec).
    case availability(responder: UInt16, from: UInt32, until: UInt32, available: Bool)
    /// A coordinator acknowledged a notice, such as a rota gap or the relay allowance running low,
    /// so other phones need not widen it.
    case noticeAck(notice: Notice, by: UInt16, at: UInt32)

    public static let formatVersion: UInt8 = 1
    /// MeshCore data_type for Help&I datagrams: inside the testing range, which needs no
    /// registration. See TODO.md about registering a permanent value.
    public static let meshDataType: UInt16 = 0xFF48
    /// MeshCore's radio-side limit for a channel datagram payload.
    public static let maxPayload = 165

    enum Kind: UInt8 { case call = 1, followUp = 2, ack = 3, availability = 4, noticeAck = 5 }

    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .call(unit, request, colour, sentAt):
            w.u8(Self.header(.call)); w.u32(unit); w.u16(request); w.u8(colour.rawValue); w.u32(sentAt)
        case let .followUp(unit, request, part, category):
            w.u8(Self.header(.followUp)); w.u32(unit); w.u16(request); w.u8(part); w.u8(category.rawValue)
        case let .ack(unit, request, responder, ackedAt, signature):
            w.u8(Self.header(.ack)); w.u32(unit); w.u16(request); w.u16(responder); w.u32(ackedAt)
            w.bytes(signature.count == 64 ? signature : Data(count: 64))
        case let .availability(responder, from, until, available):
            w.u8(Self.header(.availability)); w.u16(responder); w.u32(from); w.u32(until); w.u8(available ? 1 : 0)
        case let .noticeAck(notice, by, at):
            w.u8(Self.header(.noticeAck)); w.u8(notice.rawValue); w.u16(by); w.u32(at)
        }
        return w.data
    }

    /// Returns nil for anything that is not a well-formed Help&I frame of a version this app
    /// understands, so stray traffic on the channel is ignored rather than shown.
    public init?(_ data: Data) {
        var r = ByteReader(data)
        guard let head = r.u8(), head >> 4 == Self.formatVersion, let kind = Kind(rawValue: head & 0x0F) else { return nil }
        switch kind {
        case .call:
            guard let unit = r.u32(), let req = r.u16(), let c = r.u8().flatMap(Colour.init), let at = r.u32() else { return nil }
            self = .call(unit: unit, request: req, colour: c, sentAt: at)
        case .followUp:
            guard let unit = r.u32(), let req = r.u16(), let part = r.u8(), let cat = r.u8().flatMap(CallCategory.init) else { return nil }
            self = .followUp(unit: unit, request: req, part: part, category: cat)
        case .ack:
            guard let unit = r.u32(), let req = r.u16(), let who = r.u16(), let at = r.u32(), let sig = r.take(64) else { return nil }
            self = .ack(unit: unit, request: req, responder: who, ackedAt: at, signature: Data(sig))
        case .availability:
            guard let who = r.u16(), let from = r.u32(), let until = r.u32(), let a = r.u8(), a <= 1, from < until else { return nil }
            self = .availability(responder: who, from: from, until: until, available: a == 1)
        case .noticeAck:
            guard let n = r.u8().flatMap(Notice.init), let by = r.u16(), let at = r.u32() else { return nil }
            self = .noticeAck(notice: n, by: by, at: at)
        }
        guard r.isAtEnd else { return nil }
    }

    private static func header(_ kind: Kind) -> UInt8 { formatVersion << 4 | kind.rawValue }

    static func ackInput(unit: UInt32, request: UInt16, responder: UInt16, ackedAt: UInt32) -> Data {
        var w = ByteWriter()
        w.bytes(Data("HELPANDI-ACK-1".utf8)); w.u32(unit); w.u16(request); w.u16(responder); w.u32(ackedAt)
        return w.data
    }

    public static func signedAck(unit: UInt32, request: UInt16, responder: UInt16, at: Date, identity: DeviceIdentity) -> HelpFrame {
        let t = UInt32(max(at.timeIntervalSince1970, 0))
        let sig = (try? identity.signingKey.signature(for: ackInput(unit: unit, request: request, responder: responder, ackedAt: t))) ?? Data(count: 64)
        return .ack(unit: unit, request: request, responder: responder, ackedAt: t, signature: sig)
    }

    /// True only for an acknowledgement signed by the given member's key.
    public func isValidAck(signedBy key: Data?) -> Bool {
        guard case let .ack(unit, request, responder, at, sig) = self, let key,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(sig, for: Self.ackInput(unit: unit, request: request, responder: responder, ackedAt: at))
    }
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    var isAtEnd: Bool { offset == bytes.count }
    var remaining: Int { bytes.count - offset }
    mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func u16() -> UInt16? { take(2).map { UInt16($0[0]) | UInt16($0[1]) << 8 } }
    mutating func u32() -> UInt32? {
        take(4).map { UInt32($0[0]) | UInt32($0[1]) << 8 | UInt32($0[2]) << 16 | UInt32($0[3]) << 24 }
    }
    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, offset + n <= bytes.count else { return nil }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
    mutating func rest() -> [UInt8] { take(remaining) ?? [] }
}
