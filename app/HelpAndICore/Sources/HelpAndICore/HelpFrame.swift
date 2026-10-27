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
    /// Short text the caller typed. Personal content: never on the group channel (decision 12).
    case note(unit: UInt32, request: UInt16, part: UInt8, text: String)
    /// Where the caller is, in degrees times 10^7, with accuracy in metres. Personal content too.
    case position(unit: UInt32, request: UInt16, latitudeE7: Int32, longitudeE7: Int32, accuracy: UInt16)
    /// A caller turned check-ins on, changed them or turned them off (an empty list). Responders'
    /// phones then watch for a missed one too. A routine is personal, so this goes only over the
    /// internet or in a key update, never on the group channel.
    case checkIns(unit: UInt32, since: UInt32, grace: UInt16, times: [UInt16])
    /// A member's box: its MeshCore public key, so other boards can add it as a contact and send it
    /// direct messages. A public key is not personal, so this may go on the group channel. Signed by
    /// the member's own key, so nobody can point a member's private messages at another box.
    case board(member: UInt16, publicKey: Data, signature: Data)
    /// Another frame signed by the member who sent it. Availability changes and notice
    /// acknowledgements count only inside one, so a removed phone that still knows the old channel
    /// key cannot take responders off the rota or clear a coordinator's notice.
    case signed(signer: UInt16, inner: Data, signature: Data)
    /// A coordinator added someone. No name: other phones show "Member n" until they get the name
    /// in a key update. Counts only inside a frame signed by a coordinator.
    case memberAdded(member: UInt16, role: Member.Role, unit: UInt32, signingKey: Data)
    /// A coordinator removed someone; their acknowledgements stop counting at once. Signed too.
    case memberRemoved(member: UInt16)
    /// A coordinator acknowledged a notice, such as a rota gap or the relay allowance running low,
    /// so other phones need not widen it.
    case noticeAck(notice: Notice, by: UInt16, at: UInt32)

    public static let formatVersion: UInt8 = 1
    /// MeshCore data_type for Help&I datagrams: inside the testing range, which needs no
    /// registration. See TODO.md about registering a permanent value.
    public static let meshDataType: UInt16 = 0xFF48
    /// MeshCore's radio-side limit for a channel datagram payload.
    public static let maxPayload = 165

    enum Kind: UInt8 { case call = 1, followUp = 2, ack = 3, availability = 4, noticeAck = 5, note = 6, position = 7, checkIns = 8, board = 9, signed = 10, memberAdded = 11, memberRemoved = 12 }

    /// The most text a note may carry, in UTF-8 bytes, so a sealed note still fits a mesh packet.
    public static let maxNoteBytes = 120

    /// Whether this frame may go on the shared group channel. Notes and positions may not: they
    /// travel only end-to-end encrypted to the group key over the internet, or (later) as direct
    /// messages under each responder's own key (decision 12).
    public var mayGoOnGroupChannel: Bool {
        switch self { case .note, .position, .checkIns: false; default: true }
    }

    /// Makes a note, cutting the text at a character boundary to fit.
    public static func note(unit: UInt32, request: UInt16, part: UInt8, typed: String) -> HelpFrame {
        var text = ""
        for ch in typed.trimmingCharacters(in: .whitespacesAndNewlines) {
            if (text + String(ch)).utf8.count > maxNoteBytes { break }
            text.append(ch)
        }
        return .note(unit: unit, request: request, part: part, text: text)
    }

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
        case let .note(unit, request, part, text):
            let bytes = Data(text.utf8.prefix(Self.maxNoteBytes))
            w.u8(Self.header(.note)); w.u32(unit); w.u16(request); w.u8(part); w.u8(UInt8(bytes.count)); w.bytes(bytes)
        case let .position(unit, request, lat, lon, accuracy):
            w.u8(Self.header(.position)); w.u32(unit); w.u16(request); w.i32(lat); w.i32(lon); w.u16(accuracy)
        case let .checkIns(unit, since, grace, times):
            w.u8(Self.header(.checkIns)); w.u32(unit); w.u32(since); w.u16(grace); w.u8(UInt8(min(times.count, 8)))
            for t in times.prefix(8) { w.u16(t) }
        case let .board(member, key, signature):
            w.u8(Self.header(.board)); w.u16(member); w.bytes(key.count == 32 ? key : Data(count: 32))
            w.bytes(signature.count == 64 ? signature : Data(count: 64))
        case let .memberAdded(member, role, unit, key):
            w.u8(Self.header(.memberAdded)); w.u16(member); w.u8(role.code); w.u32(unit)
            w.bytes(key.count == 32 ? key : Data(count: 32))
        case let .memberRemoved(member):
            w.u8(Self.header(.memberRemoved)); w.u16(member)
        case let .signed(signer, inner, signature):
            w.u8(Self.header(.signed)); w.u16(signer); w.u8(UInt8(min(inner.count, 80))); w.bytes(inner.prefix(80))
            w.bytes(signature.count == 64 ? signature : Data(count: 64))
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
        case .note:
            guard let unit = r.u32(), let req = r.u16(), let part = r.u8(), let len = r.u8(), Int(len) <= Self.maxNoteBytes,
                  let bytes = r.take(Int(len)), let text = String(bytes: bytes, encoding: .utf8) else { return nil }
            self = .note(unit: unit, request: req, part: part, text: text)
        case .position:
            guard let unit = r.u32(), let req = r.u16(), let lat = r.i32(), let lon = r.i32(), let acc = r.u16(),
                  abs(lat) <= 900_000_000, abs(lon) <= 1_800_000_000 else { return nil }
            self = .position(unit: unit, request: req, latitudeE7: lat, longitudeE7: lon, accuracy: acc)
        case .checkIns:
            guard let unit = r.u32(), let since = r.u32(), let grace = r.u16(), let n = r.u8(), n <= 8 else { return nil }
            var times: [UInt16] = []
            for _ in 0..<n {
                guard let t = r.u16(), t < 1440 else { return nil }
                times.append(t)
            }
            self = .checkIns(unit: unit, since: since, grace: grace, times: times)
        case .board:
            guard let member = r.u16(), let key = r.take(32), let sig = r.take(64) else { return nil }
            self = .board(member: member, publicKey: Data(key), signature: Data(sig))
        case .memberAdded:
            guard let member = r.u16(), let role = r.u8().flatMap(Member.Role.init(code:)), let unit = r.u32(),
                  let key = r.take(32) else { return nil }
            self = .memberAdded(member: member, role: role, unit: unit, signingKey: Data(key))
        case .memberRemoved:
            guard let member = r.u16() else { return nil }
            self = .memberRemoved(member: member)
        case .signed:
            guard let signer = r.u16(), let n = r.u8(), n <= 80, let inner = r.take(Int(n)), let sig = r.take(64) else { return nil }
            self = .signed(signer: signer, inner: Data(inner), signature: Data(sig))
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

    static func boardInput(member: UInt16, key: Data) -> Data {
        var w = ByteWriter()
        w.bytes(Data("HELPANDI-BOARD-1".utf8)); w.u16(member); w.bytes(key)
        return w.data
    }

    public static func signedBoard(member: UInt16, publicKey: Data, identity: DeviceIdentity) -> HelpFrame {
        let sig = (try? identity.signingKey.signature(for: boardInput(member: member, key: publicKey))) ?? Data(count: 64)
        return .board(member: member, publicKey: publicKey, signature: sig)
    }

    static func signedInput(signer: UInt16, inner: Data) -> Data {
        var w = ByteWriter()
        w.bytes(Data("HELPANDI-SIGNED-1".utf8)); w.u16(signer); w.bytes(inner)
        return w.data
    }

    /// Wraps a frame in the sender's signature. Only small frames that carry no personal content.
    public static func signing(_ frame: HelpFrame, as signer: UInt16, identity: DeviceIdentity) -> HelpFrame {
        let inner = frame.encoded()
        let sig = (try? identity.signingKey.signature(for: signedInput(signer: signer, inner: inner))) ?? Data(count: 64)
        return .signed(signer: signer, inner: inner, signature: sig)
    }

    /// The wrapped frame, if the signature is the given key's and the frame is about the signer
    /// themselves: their own availability, or a notice they acknowledged.
    public func verifiedInner(signedBy key: Data?) -> HelpFrame? {
        guard case let .signed(signer, inner, sig) = self, let key,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              pub.isValidSignature(sig, for: Self.signedInput(signer: signer, inner: inner)),
              let frame = HelpFrame(inner) else { return nil }
        switch frame {
        case let .availability(who, _, _, _) where who == signer: return frame
        case let .noticeAck(_, by, _) where by == signer: return frame
        // The caller of this checks that the signer is a coordinator.
        case .memberAdded, .memberRemoved: return frame
        default: return nil
        }
    }

    /// True only for a box key signed by the given member's key.
    public func isValidBoard(signedBy key: Data?) -> Bool {
        guard case let .board(member, boardKey, sig) = self, let key,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(sig, for: Self.boardInput(member: member, key: boardKey))
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

/// Frames are saved in their wire form.
extension HelpFrame: Codable {
    public init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard let f = HelpFrame(data) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a Help&I frame")) }
        self = f
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(encoded())
    }
}

/// Help&I frames sent as MeshCore direct text messages, for personal content that must not go on
/// the group channel (decision 12). MeshCore encrypts each direct message to the receiving board's
/// own key. A text message holds about 150 characters, so the frame goes as base64 after a short
/// prefix, and notes are cut to fit.
public enum MeshText {
    public static let prefix = "HI1:"
    public static let maxCharacters = 150
    /// The longest note that still fits once framed and base64 encoded.
    public static let maxNoteBytes = 96

    public static func encode(_ frame: HelpFrame) -> String? {
        var f = frame
        if case let .note(unit, request, part, text) = frame {
            f = .note(unit: unit, request: request, part: part, text: fit(text, bytes: maxNoteBytes))
        }
        let s = prefix + f.encoded().base64EncodedString()
        return s.count <= maxCharacters ? s : nil
    }

    public static func decode(_ text: String) -> HelpFrame? {
        guard text.hasPrefix(prefix), let data = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { return nil }
        return HelpFrame(data)
    }

    static func fit(_ text: String, bytes: Int) -> String {
        var out = ""
        for ch in text {
            if (out + String(ch)).utf8.count > bytes { break }
            out.append(ch)
        }
        return out
    }
}
