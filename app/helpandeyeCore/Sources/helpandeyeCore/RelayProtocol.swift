import CryptoKit
import Foundation

/// The client side of the relay protocol (relay/src/relay.js). Frames are sealed with the group
/// key before they leave the phone; the relay stores ciphertext and public keys only.
public enum RelayProtocol {
    /// The relay Help&I runs, which a new group uses unless its coordinator sets another or none.
    public static let defaultRelay = "https://helprelayandeye.andeye.workers.dev"

    public static func signingInput(method: String, pathAndQuery: String, timestamp: String, body: Data) -> Data {
        let hash = Data(SHA256.hash(data: body)).base64EncodedString()
        return Data("HELPA-RELAY-1\n\(method)\n\(pathAndQuery)\n\(timestamp)\n\(hash)".utf8)
    }

    /// `pass` is the group's relay pass (RelayPass), sent with every request for a relay that
    /// requires one.
    public static func headers(method: String, pathAndQuery: String, body: Data, identity: DeviceIdentity, now: Date, pass: String? = nil) throws -> [String: String] {
        let ts = String(Int64(now.timeIntervalSince1970 * 1000))
        let sig = try identity.signingKey.signature(for: signingInput(method: method, pathAndQuery: pathAndQuery, timestamp: ts, body: body))
        var h = ["X-HelpA-Key": identity.signingPublicKey.base64EncodedString(), "X-HelpA-Time": ts,
                 "X-HelpA-Signature": sig.base64EncodedString(), "Content-Type": "application/json"]
        if let pass { h["X-HelpA-Pass"] = pass }
        return h
    }

    /// A group's ID as the relay sees it, in URL-safe base64: in the path, and in its pass.
    public static func id(of groupID: Data) -> String {
        groupID.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func path(for group: GroupSecrets, _ kind: String) -> String {
        "/g/\(id(of: group.groupID))/\(kind)"
    }

    public static func seal(_ frame: HelpFrame, with secrets: GroupSecrets) throws -> String {
        try ChaChaPoly.seal(frame.encoded(), using: SymmetricKey(data: secrets.groupKey)).combined.base64EncodedString()
    }

    /// Tries the current secrets, then the previous ones while members move to new keys.
    public static func open(_ sealed: String, with secrets: [GroupSecrets]) -> HelpFrame? {
        guard let data = Data(base64Encoded: sealed), let box = try? ChaChaPoly.SealedBox(combined: data) else { return nil }
        for s in secrets {
            if let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: s.groupKey)) { return HelpFrame(plain) }
        }
        return nil
    }

    public struct MemberList: Codable, Equatable, Hashable, Sendable {
        public struct Entry: Codable, Equatable, Hashable, Sendable { public let key: String; public let role: String }
        public let generation: UInt32
        public let members: [Entry]
        /// Keys of people removed from the group. Only these ever come off the relay's list.
        public let removed: [String]
        /// The group's first coordinator, who owns the group on the relay and alone registers it.
        public let primary: String?
        /// How `primary` came to own the group, where it was not whoever registered it: the
        /// takeover as the phones signed it, in keys, for the relay to check (decision 20).
        public var takeover: Takeover?
        /// The first coordinator's newest naming of a deputy, so the relay takes no older one.
        public var deputyVersion: UInt32?
    }

    public struct Takeover: Codable, Equatable, Hashable, Sendable {
        public struct Signature: Codable, Equatable, Hashable, Sendable {
            public let key: String
            public let signature: String
            public init(key: String, signature: String) { self.key = key; self.signature = signature }
        }
        public struct Deputy: Codable, Equatable, Hashable, Sendable {
            public let version: UInt32
            public let signature: String
            public init(version: UInt32, signature: String) { self.version = version; self.signature = signature }
        }
        public let from: String
        public let to: String
        public let signatures: [Signature]
        public let deputy: Deputy?

        public init(from: String, to: String, signatures: [Signature], deputy: Deputy?) {
            self.from = from; self.to = to; self.signatures = signatures; self.deputy = deputy
        }

        init?(_ t: helpandeyeCore.Takeover, in group: GroupState) {
            guard t.fromKey.count == 32, let toKey = group.member(t.to)?.signingKey else { return nil }
            from = t.fromKey.base64EncodedString()
            to = toKey.base64EncodedString()
            signatures = t.signatures.compactMap { s in
                group.member(s.signer)?.signingKey.map { .init(key: $0.base64EncodedString(), signature: s.signature.base64EncodedString()) }
            }
            deputy = t.deputySignature.map { .init(version: t.deputyVersion, signature: $0.base64EncodedString()) }
        }
    }

    public static func memberList(_ group: GroupState) -> MemberList {
        var list = MemberList(generation: group.membershipVersion, members: group.members.compactMap { m in
            m.signingKey.map { .init(key: $0.base64EncodedString(), role: m.role == .coordinator ? "coordinator" : "member") }
        }, removed: group.removedKeys.map { $0.base64EncodedString() }.sorted(),
        primary: group.primaryCoordinator.flatMap { group.member($0)?.signingKey }?.base64EncodedString())
        list.takeover = group.takeover.flatMap { Takeover($0, in: group) }
        list.deputyVersion = group.deputyVersion > 0 ? group.deputyVersion : nil
        return list
    }
}
