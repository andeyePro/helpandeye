import CryptoKit
import Foundation

/// The home Wi-Fi route (decision 19): the group's phones on the same Wi-Fi network find each
/// other with Bonjour and pass every message straight to each other, with no server and no
/// internet. Each message is sealed with the group key, as for the relay, so another phone on the
/// network learns nothing but that some Help&I group is there.
@MainActor public protocol LocalLink: AnyObject {
    /// Whether this phone takes part at all; off on a watch, which goes through its phone.
    var isEnabled: Bool { get }
    /// Another of the group's phones is reachable on this network now.
    var hasPeers: Bool { get }
    var unavailableReason: String { get }
    func configure(group: GroupState?, me: UInt16?, identity: DeviceIdentity)
    /// Hands the frame to every other member's phone on the network. Nil once at least one has
    /// confirmed reading it.
    func send(_ frame: HelpFrame) async -> String?
}

/// No home Wi-Fi route: a watch, or a test that does not need one.
@MainActor public final class NoLocalLink: LocalLink {
    public init() {}
    public var isEnabled: Bool { false }
    public var hasPeers: Bool { false }
    public var unavailableReason: String { "Not used here" }
    public func configure(group: GroupState?, me: UInt16?, identity: DeviceIdentity) {}
    public func send(_ frame: HelpFrame) async -> String? { unavailableReason }
}

/// How phones on one network find and talk to each other.
public enum LocalWire {
    /// The Bonjour service type, also listed in the app's Info.plist.
    public static let serviceType = "_helpandi._tcp"

    /// The name a group's phones advertise under: from the group ID, so they find each other, but
    /// say nothing about the group to anyone else on the network.
    public static func serviceName(for group: GroupState) -> String {
        let hash = SHA256.hash(data: Data("HELPA-LAN-1".utf8) + group.secrets.groupID)
        return "helpandi-" + hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The most one message may be: a group's settings, sealed, with room to spare.
    public static let maxMessage = 8192

    /// One connection, from either end. Each side first sends a random challenge; each then proves
    /// which member it is by signing the other's challenge, sealed with the group key. Until that
    /// proof arrives nothing from the other end counts, and a proof from this phone's own member
    /// (its own extension, say) or from anyone not in the group ends the connection: only another
    /// member's phone ever counts as somewhere a call went. Every frame then carries a number, and
    /// the other end returns it once it has read and opened the frame, so "sent" means another
    /// member's Help&I has it, not just that the bytes left.
    public struct Session: Sendable {
        public enum Event: Equatable, Sendable {
            /// The other end proved it is this member.
            case peer(UInt16)
            /// A frame from the proven member, to confirm with `receipt(for:)`.
            case frame(HelpFrame, id: UInt32)
            case receipt(UInt32)
        }

        enum Kind: UInt8 { case challenge = 0, proof = 1, frame = 2, receipt = 3 }

        private let group: GroupState
        private let me: UInt16
        private let signingKey: Data
        private let myChallenge: Data
        private var buffer = Data()
        public private(set) var peer: UInt16?
        public private(set) var broken = false

        public init(group: GroupState, me: UInt16, identity: DeviceIdentity) {
            self.group = group; self.me = me; signingKey = identity.signingKey.rawRepresentation
            myChallenge = randomBytes(16)
        }

        /// What this end sends first.
        public var opening: Data { Self.wrap(.challenge, myChallenge) }

        public func message(_ frame: HelpFrame, id: UInt32) -> Data? {
            guard peer != nil, let box = try? ChaChaPoly.seal(frame.encoded(), using: SymmetricKey(data: group.secrets.groupKey)) else { return nil }
            return Self.wrap(.frame, Self.u32(id) + box.combined)
        }

        public func receipt(for id: UInt32) -> Data { Self.wrap(.receipt, Self.u32(id)) }

        /// Takes bytes from the connection. Returns what happened, and anything to send back.
        public mutating func take(_ bytes: Data, at now: Date) -> (events: [Event], reply: Data) {
            buffer.append(bytes)
            var events: [Event] = [], reply = Data()
            while !broken, buffer.count >= 2 {
                let n = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
                guard n > 0, n <= LocalWire.maxMessage else { broken = true; break }
                guard buffer.count >= 2 + n else { break }
                let body = Data(buffer.subdata(in: buffer.startIndex + 2..<buffer.startIndex + 2 + n))
                buffer = Data(buffer.dropFirst(2 + n))
                guard let kind = Kind(rawValue: body[body.startIndex]) else { broken = true; break }
                let payload = Data(body.dropFirst())
                switch kind {
                case .challenge:
                    guard payload.count == 16, let proof = proof(answering: payload) else { broken = true; break }
                    reply += proof
                case .proof:
                    guard peer == nil, let who = check(payload) else { broken = true; break }
                    peer = who
                    events.append(.peer(who))
                case .frame:
                    guard peer != nil, payload.count > 4 else { broken = true; break }
                    let id = Self.u32(payload.prefix(4))
                    if let frame = open(Data(payload.dropFirst(4)), at: now) { events.append(.frame(frame, id: id)) }
                case .receipt:
                    guard peer != nil, payload.count == 4 else { broken = true; break }
                    events.append(.receipt(Self.u32(payload)))
                }
            }
            if broken { buffer = Data() }
            return (events, reply)
        }

        private func proof(answering challenge: Data) -> Data? {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey),
                  let sig = try? key.signature(for: Self.proofInput(group.secrets.groupID, challenge, me)),
                  let box = try? ChaChaPoly.seal(Self.u16(me) + sig, using: SymmetricKey(data: group.secrets.groupKey)) else { return nil }
            return Self.wrap(.proof, box.combined)
        }

        /// The member who signed this end's own challenge, if it is someone else in the group.
        private func check(_ sealed: Data) -> UInt16? {
            guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
                  let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: group.secrets.groupKey)), plain.count == 66 else { return nil }
            let who = UInt16(plain[plain.startIndex]) << 8 | UInt16(plain[plain.startIndex + 1])
            guard who != me, let key = group.member(who)?.signingKey, let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
                  pub.isValidSignature(Data(plain.dropFirst(2)), for: Self.proofInput(group.secrets.groupID, myChallenge, who)) else { return nil }
            return who
        }

        private func open(_ sealed: Data, at now: Date) -> HelpFrame? {
            guard let box = try? ChaChaPoly.SealedBox(combined: sealed) else { return nil }
            for s in group.listening(at: now) {
                if let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: s.groupKey)) { return HelpFrame(plain) }
            }
            return nil
        }

        static func proofInput(_ group: Data, _ challenge: Data, _ member: UInt16) -> Data {
            Data("HELPA-LAN-PROOF-1".utf8) + group + challenge + u16(member)
        }

        static func wrap(_ kind: Kind, _ payload: Data) -> Data {
            let n = payload.count + 1
            return Data([UInt8(n >> 8), UInt8(n & 0xFF), kind.rawValue]) + payload
        }

        static func u16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
        static func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        static func u32(_ d: Data) -> UInt32 { d.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    }
}
