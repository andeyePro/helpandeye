import CryptoKit
import Foundation

/// The colour of a call. Red asks for help now, amber for a hand when someone can, green says "I'm OK".
public enum Colour: UInt8, Sendable, CaseIterable, Codable {
    case red = 1, amber = 2, green = 3
}

/// Follow-up categories a caller can add after the first press. Codes, not text, so they fit on
/// the group channel without carrying personal detail (decision 12).
public enum CallCategory: UInt8, Sendable, CaseIterable, Codable {
    case fallen = 1, unwell = 2, lockedOut = 3, powerCut = 4, needCompany = 5, missedCheckIn = 6, other = 99
    /// Sent in a follow-up's place when the caller takes it back, such as one pressed by mistake.
    case withdrawn = 0

    /// What a caller can choose from.
    public static let choices: [CallCategory] = [.fallen, .unwell, .lockedOut, .powerCut, .needCompany, .other]
}

/// A person settling a call (decision 6): the caller saying they are OK, the caller closing it, or
/// a coordinator closing it with the caller's consent or a written reason.
public enum CallState: UInt8, Sendable, Codable {
    /// I'm OK after the call: the urgent repeats stop, but a responder still checks.
    case callerOK = 1
    case closedByCaller = 2
    case closedWithConsent = 3
    case closedWithReason = 4

    public var closes: Bool { self != .callerOK }
}

/// Things a coordinator is told about and must acknowledge.
public enum Notice: UInt8, Sendable, Codable, CaseIterable {
    case rotaGap = 1, allowanceLow = 2
    /// For this phone only: two days on, the first coordinator has still not been heard listing it.
    case unconfirmed = 3
    /// For this phone only: the coordinator who invited it was removed before the first
    /// coordinator was heard listing it.
    case inviterLeft = 4

    /// Shared notices are put right for everyone by one coordinator's acknowledgement; this
    /// phone's own are its person's alone, so no other phone's acknowledgement clears them.
    public var isShared: Bool { self == .rotaGap || self == .allowanceLow }
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
    /// A note or position sealed once for all responders (ForResponders): the five-byte nonce
    /// salt, then the ciphertext and its tag. Safe on the group channel: callers cannot open it.
    case forResponders(unit: UInt32, request: UInt16, part: UInt8, sealed: Data)
    /// A coordinator's group settings (GroupSettings, JSON), signed, newest `version` wins. The
    /// first of a second page of kinds: its header is 0x21, as the first page's 16 kinds are used.
    case groupSettings(signer: UInt16, version: UInt32, settings: Data, signature: Data)
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
    case memberAdded(member: UInt16, role: Member.Role, unit: UInt32, signingKey: Data, sealKey: Data, version: UInt32)
    /// A coordinator removed someone; their acknowledgements stop counting at once. Signed too.
    case memberRemoved(member: UInt16, version: UInt32)
    /// A coordinator made someone a coordinator, with their own block of numbers, or changed them
    /// back. Signed too; an older version than the phone has is ignored.
    case memberRole(member: UInt16, role: Member.Role, block: UInt16, version: UInt32)
    /// A member's name, from a coordinator. Personal, so internet only. Signed too.
    case memberName(member: UInt16, name: String)
    /// A member's mobile number, for the ready-written text; empty clears it. `at` orders changes.
    case memberPhone(member: UInt16, phone: String, at: UInt32)
    /// A person settled a call (decision 6). Counts only inside a frame signed by the caller (for
    /// their own call) or a coordinator. A coordinator's reason is for responders only, so a frame
    /// with one goes sealed for them (`forResponders`), over the internet and home Wi-Fi only.
    case callState(unit: UInt32, request: UInt16, state: CallState, at: UInt32, reason: String)
    /// A person asks the coordinators to change one of their settings (app spec, Profiles), from
    /// their settings page only. Counts only inside a frame signed by that person. What they write
    /// is personal, so it goes over the internet only.
    case changeRequest(member: UInt16, setting: Profile.Setting?, at: UInt32, text: String)
    /// From the first coordinator, signed: when the keys before `generation` stop working (the end
    /// of the seven days after a removal), so a phone that heard of the removal late still knows.
    case changeoverEnds(generation: UInt32, at: UInt32)
    /// A coordinator acknowledged a notice, such as a rota gap or the relay allowance running low,
    /// so other phones need not widen it.
    case noticeAck(notice: Notice, by: UInt16, at: UInt32)
    /// The first coordinator names a deputy (member 0 clears it), whose phone may take over if
    /// theirs is lost (decision 20). Carries the deputy's signing key and the first coordinator's
    /// signature over it, so the naming can be checked by the relay, which knows keys not numbers.
    case deputy(member: UInt16, key: Data, version: UInt32, signature: Data)
    /// A coordinator took over as first coordinator from a lost phone (decision 20).
    case takeover(Takeover)
    /// A coordinator agrees that another may take over from the first coordinator: their
    /// signature over the same input as the takeover's, for the other to carry in it.
    case takeoverConsent(from: UInt16, to: UInt16, signer: UInt16, signature: Data)

    public static let formatVersion: UInt8 = 1
    static let settingsHeader: UInt8 = 0x21
    static let callStateHeader: UInt8 = 0x22
    static let changeRequestHeader: UInt8 = 0x23
    static let changeoverHeader: UInt8 = 0x24
    static let deputyHeader: UInt8 = 0x25
    static let takeoverHeader: UInt8 = 0x26
    static let consentHeader: UInt8 = 0x27
    /// Room for what someone writes in a change request inside a signed frame.
    public static let maxRequestBytes = 60
    /// Room for a coordinator's reason inside a signed frame.
    public static let maxReasonBytes = 56
    /// MeshCore data_type for Help&I datagrams: inside the testing range, which needs no
    /// registration. See TODO.md about registering a permanent value.
    public static let meshDataType: UInt16 = 0xFF48
    /// MeshCore's radio-side limit for a channel datagram payload.
    public static let maxPayload = 165

    enum Kind: UInt8 { case forResponders = 0, call = 1, followUp = 2, ack = 3, availability = 4, noticeAck = 5, note = 6, position = 7, checkIns = 8, board = 9, signed = 10, memberAdded = 11, memberRemoved = 12, memberName = 13, memberRole = 14, memberPhone = 15 }

    /// The most text a note may carry, in UTF-8 bytes, so a sealed note still fits a mesh packet.
    public static let maxNoteBytes = 120
    /// The most a group's compressed settings may take: room for several profiles. Too big for the
    /// radio, so settings that large go over the internet only, and in welcome and update codes.
    public static let maxSettingsBytes = 2048
    /// Room for an international mobile number.
    public static let maxPhoneBytes = 20

    /// Whether this frame may go on the shared group channel. Notes and positions may not: they
    /// travel only end-to-end encrypted to the group key over the internet, or (later) as direct
    /// messages under each responder's own key (decision 12).
    public var mayGoOnGroupChannel: Bool {
        switch self {
        case .note, .position, .checkIns, .memberName, .memberPhone: false
        case .followUp: personalPart == nil
        case let .callState(_, _, _, _, reason): reason.isEmpty
        case .changeRequest: false
        // A signed frame may go only if what it wraps may.
        case let .signed(_, inner, _): HelpFrame(inner)?.mayGoOnGroupChannel ?? false
        default: true
        }
    }

    /// The unit, request and part of a note or follow-up (parts from 1) or position (part 0), the
    /// personal content that goes sealed for responders. What a caller chose, such as Fallen, is
    /// personal too; a missed check-in is raised by another member's phone, so goes plainly.
    public var personalPart: (UInt32, UInt16, UInt8)? {
        switch self {
        case let .note(unit, request, part, _): (unit, request, part)
        case let .position(unit, request, _, _, _): (unit, request, 0)
        case let .followUp(unit, request, part, category) where category != .missedCheckIn: (unit, request, part)
        default: nil
        }
    }

    /// What goes sealed for responders (ForResponders): a caller's personal content, or a
    /// coordinator's close with its reason, as part 255, so it never meets a caller's parts.
    public var forRespondersPart: (UInt32, UInt16, UInt8)? {
        if case let .callState(unit, request, _, _, reason) = self { return reason.isEmpty ? nil : (unit, request, 255) }
        return personalPart
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
        case let .memberAdded(member, role, unit, key, sealKey, version):
            w.u8(Self.header(.memberAdded)); w.u16(member); w.u8(role.code); w.u32(unit)
            w.bytes(key.count == 32 ? key : Data(count: 32)); w.bytes(sealKey.count == 32 ? sealKey : Data(count: 32)); w.u32(version)
        case let .memberRemoved(member, version):
            w.u8(Self.header(.memberRemoved)); w.u16(member); w.u32(version)
        case let .memberRole(member, role, block, version):
            w.u8(Self.header(.memberRole)); w.u16(member); w.u8(role.code); w.u16(block); w.u32(version)
        case let .memberName(member, name):
            let bytes = Data(MeshText.fit(name, bytes: 40).utf8)
            w.u8(Self.header(.memberName)); w.u16(member); w.u8(UInt8(bytes.count)); w.bytes(bytes)
        case let .forResponders(unit, request, part, sealed):
            w.u8(Self.header(.forResponders)); w.u32(unit); w.u16(request); w.u8(part); w.bytes(sealed)
        case let .groupSettings(signer, version, settings, signature):
            w.u8(Self.settingsHeader); w.u16(signer); w.u32(version); w.u16(UInt16(min(settings.count, Self.maxSettingsBytes))); w.bytes(settings.prefix(Self.maxSettingsBytes))
            w.bytes(signature.count == 64 ? signature : Data(count: 64))
        case let .callState(unit, request, state, at, reason):
            let bytes = Data(MeshText.fit(reason, bytes: Self.maxReasonBytes).utf8)
            w.u8(Self.callStateHeader); w.u32(unit); w.u16(request); w.u8(state.rawValue); w.u32(at); w.u8(UInt8(bytes.count)); w.bytes(bytes)
        case let .changeoverEnds(generation, at):
            w.u8(Self.changeoverHeader); w.u32(generation); w.u32(at)
        case let .changeRequest(member, setting, at, text):
            let bytes = Data(MeshText.fit(text, bytes: Self.maxRequestBytes).utf8)
            let code = setting.flatMap { Profile.Setting.allCases.firstIndex(of: $0) }.map { UInt8($0 + 1) } ?? 0
            w.u8(Self.changeRequestHeader); w.u16(member); w.u8(code); w.u32(at); w.u8(UInt8(bytes.count)); w.bytes(bytes)
        case let .memberPhone(member, phone, at):
            let bytes = Data(phone.prefix(Self.maxPhoneBytes).utf8)
            w.u8(Self.header(.memberPhone)); w.u16(member); w.u32(at); w.u8(UInt8(bytes.count)); w.bytes(bytes)
        case let .deputy(member, key, version, signature):
            w.u8(Self.deputyHeader); w.u16(member); w.bytes(key.count == 32 ? key : Data(count: 32)); w.u32(version)
            w.bytes(signature.count == 64 ? signature : Data(count: 64))
        case let .takeover(t):
            w.u8(Self.takeoverHeader); w.u16(t.from); w.u16(t.to); w.u32(t.version); w.u32(t.deputySignature == nil ? 0 : t.deputyVersion)
            w.u8(UInt8(min(t.signatures.count, 2)))
            for s in t.signatures.prefix(2) { w.u16(s.signer); w.bytes(s.signature.count == 64 ? s.signature : Data(count: 64)) }
            if let d = t.deputySignature { w.bytes(d.count == 64 ? d : Data(count: 64)) }
        case let .takeoverConsent(from, to, signer, signature):
            w.u8(Self.consentHeader); w.u16(from); w.u16(to); w.u16(signer); w.bytes(signature.count == 64 ? signature : Data(count: 64))
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
        guard let head = r.u8() else { return nil }
        if head == Self.settingsHeader {
            guard let signer = r.u16(), let version = r.u32(), let n = r.u16(), n <= Self.maxSettingsBytes, let settings = r.take(Int(n)),
                  let sig = r.take(64) else { return nil }
            self = .groupSettings(signer: signer, version: version, settings: Data(settings), signature: Data(sig))
            return
        }
        if head == Self.changeoverHeader {
            guard let generation = r.u32(), let at = r.u32() else { return nil }
            self = .changeoverEnds(generation: generation, at: at)
            return
        }
        if head == Self.changeRequestHeader {
            guard let member = r.u16(), let code = r.u8(), let at = r.u32(), let n = r.u8(), Int(n) <= Self.maxRequestBytes,
                  let text = r.take(Int(n)), let words = String(data: Data(text), encoding: .utf8) else { return nil }
            let all = Profile.Setting.allCases
            let setting = code > 0 && Int(code) <= all.count ? all[Int(code) - 1] : nil
            self = .changeRequest(member: member, setting: setting, at: at, text: words)
            return
        }
        if head == Self.deputyHeader {
            guard let member = r.u16(), let key = r.take(32), let version = r.u32(), let sig = r.take(64), r.isAtEnd else { return nil }
            self = .deputy(member: member, key: Data(key), version: version, signature: Data(sig))
            return
        }
        if head == Self.takeoverHeader {
            guard let from = r.u16(), let to = r.u16(), let version = r.u32(), let deputyVersion = r.u32(), let n = r.u8(), (1...2).contains(n) else { return nil }
            var signatures: [Takeover.Signature] = []
            for _ in 0..<n {
                guard let signer = r.u16(), let sig = r.take(64) else { return nil }
                signatures.append(.init(signer: signer, signature: Data(sig)))
            }
            var t = Takeover(from: from, to: to, version: version, signatures: signatures)
            if deputyVersion > 0 {
                guard let d = r.take(64) else { return nil }
                t.deputyVersion = deputyVersion; t.deputySignature = Data(d)
            }
            guard r.isAtEnd else { return nil }
            self = .takeover(t)
            return
        }
        if head == Self.consentHeader {
            guard let from = r.u16(), let to = r.u16(), let signer = r.u16(), let sig = r.take(64), r.isAtEnd else { return nil }
            self = .takeoverConsent(from: from, to: to, signer: signer, signature: Data(sig))
            return
        }
        if head == Self.callStateHeader {
            guard let unit = r.u32(), let req = r.u16(), let state = r.u8().flatMap(CallState.init), let at = r.u32(), let n = r.u8(),
                  Int(n) <= Self.maxReasonBytes, let text = r.take(Int(n)), let reason = String(data: Data(text), encoding: .utf8) else { return nil }
            self = .callState(unit: unit, request: req, state: state, at: at, reason: reason)
            return
        }
        guard head >> 4 == Self.formatVersion, let kind = Kind(rawValue: head & 0x0F) else { return nil }
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
                  (-900_000_000...900_000_000).contains(lat), (-1_800_000_000...1_800_000_000).contains(lon) else { return nil }
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
                  let key = r.take(32), let seal = r.take(32), let version = r.u32() else { return nil }
            self = .memberAdded(member: member, role: role, unit: unit, signingKey: Data(key), sealKey: Data(seal), version: version)
        case .memberRemoved:
            guard let member = r.u16(), let version = r.u32() else { return nil }
            self = .memberRemoved(member: member, version: version)
        case .memberRole:
            guard let member = r.u16(), let role = r.u8().flatMap(Member.Role.init(code:)), let block = r.u16(),
                  let version = r.u32() else { return nil }
            self = .memberRole(member: member, role: role, block: block, version: version)
        case .memberName:
            guard let member = r.u16(), let n = r.u8(), n <= 40, let bytes = r.take(Int(n)),
                  let name = String(bytes: bytes, encoding: .utf8) else { return nil }
            self = .memberName(member: member, name: name)
        case .forResponders:
            guard let unit = r.u32(), let request = r.u16(), let part = r.u8(), let rest = r.take(r.remaining), rest.count > 21 else { return nil }
            self = .forResponders(unit: unit, request: request, part: part, sealed: Data(rest))
        case .memberPhone:
            guard let member = r.u16(), let at = r.u32(), let n = r.u8(), n <= Self.maxPhoneBytes, let bytes = r.take(Int(n)),
                  let phone = String(bytes: bytes, encoding: .utf8) else { return nil }
            self = .memberPhone(member: member, phone: phone, at: at)
        case .signed:
            guard let signer = r.u16(), let n = r.u8(), n <= 80, let inner = r.take(Int(n)), let sig = r.take(64) else { return nil }
            self = .signed(signer: signer, inner: Data(inner), signature: Data(sig))
        }
        guard r.isAtEnd else { return nil }
    }

    private static func header(_ kind: Kind) -> UInt8 { formatVersion << 4 | kind.rawValue }

    // Every signature covers the group's ID too, so one made in one group is worthless in another,
    // where the same unit, member and request numbers can easily occur.

    static func ackInput(unit: UInt32, request: UInt16, responder: UInt16, ackedAt: UInt32, group: Data) -> Data {
        var w = ByteWriter()
        w.bytes(Data("HELPA-ACK-2".utf8)); w.bytes(group); w.u32(unit); w.u16(request); w.u16(responder); w.u32(ackedAt)
        return w.data
    }

    public static func signedAck(unit: UInt32, request: UInt16, responder: UInt16, at: Date, identity: DeviceIdentity, group: Data) -> HelpFrame {
        let t = UInt32(max(at.timeIntervalSince1970, 0))
        let input = ackInput(unit: unit, request: request, responder: responder, ackedAt: t, group: group)
        let sig = (try? identity.signingKey.signature(for: input)) ?? Data(count: 64)
        return .ack(unit: unit, request: request, responder: responder, ackedAt: t, signature: sig)
    }

    static func boardInput(member: UInt16, key: Data, group: Data) -> Data {
        var w = ByteWriter()
        w.bytes(Data("HELPA-BOARD-2".utf8)); w.bytes(group); w.u16(member); w.bytes(key)
        return w.data
    }

    public static func signedBoard(member: UInt16, publicKey: Data, identity: DeviceIdentity, group: Data) -> HelpFrame {
        let sig = (try? identity.signingKey.signature(for: boardInput(member: member, key: publicKey, group: group))) ?? Data(count: 64)
        return .board(member: member, publicKey: publicKey, signature: sig)
    }

    static func signedInput(signer: UInt16, inner: Data, group: Data) -> Data {
        var w = ByteWriter()
        w.bytes(Data("HELPA-SIGNED-2".utf8)); w.bytes(group); w.u16(signer); w.bytes(inner)
        return w.data
    }

    /// Wraps a frame in the sender's signature. Only small frames that carry no personal content.
    public static func signing(_ frame: HelpFrame, as signer: UInt16, identity: DeviceIdentity, group: Data) -> HelpFrame {
        let inner = frame.encoded()
        let sig = (try? identity.signingKey.signature(for: signedInput(signer: signer, inner: inner, group: group))) ?? Data(count: 64)
        return .signed(signer: signer, inner: inner, signature: sig)
    }

    /// The wrapped frame, if the signature is the given key's and the frame is about the signer
    /// themselves: their own availability, or a notice they acknowledged.
    public func verifiedInner(signedBy key: Data?, group: Data) -> HelpFrame? {
        guard case let .signed(signer, inner, sig) = self, let key,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              pub.isValidSignature(sig, for: Self.signedInput(signer: signer, inner: inner, group: group)),
              let frame = HelpFrame(inner) else { return nil }
        switch frame {
        case let .availability(who, _, _, _) where who == signer: return frame
        case let .noticeAck(_, by, _) where by == signer: return frame
        // The caller of this checks that the signer is a coordinator.
        case .memberAdded, .memberRemoved, .memberName, .memberRole, .changeoverEnds: return frame
        // The caller of this checks that the signer is the member or a coordinator.
        case .memberPhone: return frame
        // The caller of this checks that the signer owns the unit.
        case .checkIns, .note, .position, .followUp: return frame
        // The caller of this checks that the signer owns the unit or is a coordinator.
        case .callState: return frame
        case let .changeRequest(member, _, _, _) where member == signer: return frame
        default: return nil
        }
    }

    /// True only for a box key signed by the given member's key.
    public func isValidBoard(signedBy key: Data?, group: Data) -> Bool {
        guard case let .board(member, boardKey, sig) = self, let key,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(sig, for: Self.boardInput(member: member, key: boardKey, group: group))
    }

    /// True only for an acknowledgement signed by the given member's key.
    public func isValidAck(signedBy key: Data?, group: Data) -> Bool {
        guard case let .ack(unit, request, responder, at, sig) = self, let key,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(sig, for: Self.ackInput(unit: unit, request: request, responder: responder, ackedAt: at, group: group))
    }

    // The deputy naming and the takeover are signed over keys, not member numbers, so the relay,
    // which holds keys only, checks the same bytes the phones do (relay.js `takeoverProven`).

    static func deputyInput(key: Data, version: UInt32, group: Data) -> Data {
        var w = ByteWriter()
        w.bytes(Data("HELPA-DEPUTY-1".utf8)); w.bytes(group); w.bytes(key); w.u32(version)
        return w.data
    }

    public static func signedDeputy(member: UInt16, key: Data, version: UInt32, identity: DeviceIdentity, group: Data) -> HelpFrame {
        let sig = (try? identity.signingKey.signature(for: deputyInput(key: key, version: version, group: group))) ?? Data(count: 64)
        return .deputy(member: member, key: key, version: version, signature: sig)
    }

    /// True only for a deputy naming signed by the given key: the first coordinator's.
    public func isValidDeputy(signedBy key: Data?, group: Data) -> Bool {
        guard case let .deputy(_, deputyKey, version, sig) = self else { return false }
        return Self.isValidDeputySignature(sig, by: key, deputyKey: deputyKey, version: version, group: group)
    }

    static func isValidDeputySignature(_ sig: Data, by key: Data?, deputyKey: Data, version: UInt32, group: Data) -> Bool {
        guard let key, let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(sig, for: deputyInput(key: deputyKey, version: version, group: group))
    }

    static func takeoverInput(fromKey: Data, toKey: Data, group: Data) -> Data {
        Data("HELPA-TAKEOVER-1".utf8) + group + fromKey + toKey
    }

    /// A coordinator's signature that `toKey` may take over from `fromKey`: the new first
    /// coordinator's own, or another coordinator's agreement.
    public static func takeoverSignature(fromKey: Data, toKey: Data, identity: DeviceIdentity, group: Data) -> Data {
        (try? identity.signingKey.signature(for: takeoverInput(fromKey: fromKey, toKey: toKey, group: group))) ?? Data(count: 64)
    }

    static func isValidTakeoverSignature(_ sig: Data, by key: Data?, fromKey: Data, toKey: Data, group: Data) -> Bool {
        guard let key, let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(sig, for: takeoverInput(fromKey: fromKey, toKey: toKey, group: group))
    }
}

/// A coordinator taking over as first coordinator from a lost phone (decision 20). Anyone who
/// knows the members' keys can check it, the relay included: the new first coordinator's
/// signature, and with it the lost phone's signed naming of them as deputy, or a second
/// coordinator's signature, or nothing more where the lost phone has not been heard from for
/// seven days. Taking over removes the lost phone and makes new keys, as a removal does.
public struct Takeover: Codable, Equatable, Sendable {
    public struct Signature: Codable, Equatable, Sendable {
        public let signer: UInt16
        public let signature: Data
        public init(signer: UInt16, signature: Data) { self.signer = signer; self.signature = signature }
    }
    public let from: UInt16
    public let to: UInt16
    /// The membership version the removal of the lost phone makes.
    public let version: UInt32
    public var signatures: [Signature]
    public var deputyVersion: UInt32 = 0
    public var deputySignature: Data?
    /// The lost phone's signing key, kept by the phone that applies the takeover for the relay's
    /// benefit, as the member is gone from the list by then. Not sent on air.
    public var fromKey: Data = Data()

    public init(from: UInt16, to: UInt16, version: UInt32, signatures: [Signature]) {
        self.from = from; self.to = to; self.version = version; self.signatures = signatures
    }

    /// Whether the lost phone named the new first coordinator as deputy, given both keys.
    public func namedDeputy(fromKey: Data, toKey: Data, group: Data) -> Bool {
        guard let d = deputySignature else { return false }
        return HelpFrame.isValidDeputySignature(d, by: fromKey, deputyKey: toKey, version: deputyVersion, group: group)
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
