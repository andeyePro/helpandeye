import CryptoKit
import Foundation

/// The client side of the relay protocol (relay/src/relay.js). Frames are sealed with the group
/// key before they leave the phone; the relay stores ciphertext and public keys only.
public enum RelayProtocol {
    public static func signingInput(method: String, pathAndQuery: String, timestamp: String, body: Data) -> Data {
        let hash = Data(SHA256.hash(data: body)).base64EncodedString()
        return Data("HELPA-RELAY-1\n\(method)\n\(pathAndQuery)\n\(timestamp)\n\(hash)".utf8)
    }

    public static func headers(method: String, pathAndQuery: String, body: Data, identity: DeviceIdentity, now: Date) throws -> [String: String] {
        let ts = String(Int64(now.timeIntervalSince1970 * 1000))
        let sig = try identity.signingKey.signature(for: signingInput(method: method, pathAndQuery: pathAndQuery, timestamp: ts, body: body))
        return ["X-HelpA-Key": identity.signingPublicKey.base64EncodedString(), "X-HelpA-Time": ts,
                "X-HelpA-Signature": sig.base64EncodedString(), "Content-Type": "application/json"]
    }

    /// The path for a group: its ID in URL-safe base64.
    public static func path(for group: GroupSecrets, _ kind: String) -> String {
        let id = group.groupID.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "/g/\(id)/\(kind)"
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
        /// The group's first coordinator, who owns the group on the relay whoever registers it.
        public let primary: String?
    }

    public static func memberList(_ group: GroupState) -> MemberList {
        MemberList(generation: group.membershipVersion, members: group.members.compactMap { m in
            m.signingKey.map { .init(key: $0.base64EncodedString(), role: m.role == .coordinator ? "coordinator" : "member") }
        }, removed: group.removedKeys.map { $0.base64EncodedString() }.sorted(),
        primary: group.primaryCoordinator.flatMap { group.member($0)?.signingKey }?.base64EncodedString())
    }
}
