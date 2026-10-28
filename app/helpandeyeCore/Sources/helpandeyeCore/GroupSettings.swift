import CryptoKit
import Foundation

/// What a coordinator can change for the whole group, under Profiles, Log and Advanced settings:
/// the profiles and who has which, the log, and the relay's address. It goes to every member at
/// once, signed and compressed, over the internet and, when it fits, the group channel; the
/// newest version wins.
public struct GroupSettings: Codable, Equatable, Sendable {
    public var policy: GroupState.StoredPolicy
    public var relayURL: String?
}

extension GroupState {
    /// A short name for keeping a group's things apart on a device (storage, alerts).
    public var tag: String { "g" + secrets.groupID.map { String(format: "%02x", $0) }.joined() }

    public var settings: GroupSettings { GroupSettings(policy: policy, relayURL: relayURL) }

    /// The settings as a signed frame from coordinator `signer`.
    public func settingsFrame(as signer: UInt16, identity: DeviceIdentity) -> HelpFrame? {
        guard let json = try? JSONEncoder().encode(settings), let data = try? (json as NSData).compressed(using: .zlib) as Data,
              data.count <= HelpFrame.maxSettingsBytes else { return nil }
        let input = Self.settingsInput(group: secrets.groupID, signer: signer, version: settingsVersion, settings: data)
        guard let sig = try? identity.signingKey.signature(for: input) else { return nil }
        return .groupSettings(signer: signer, version: settingsVersion, settings: data, signature: sig)
    }

    /// Takes in settings signed by one of this group's coordinators and newer than those held.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func apply(settings frame: HelpFrame) -> Bool {
        guard case let .groupSettings(signer, version, data, sig) = frame, version > settingsVersion,
              let coordinator = member(signer), coordinator.role == .coordinator, let key = coordinator.signingKey,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              pub.isValidSignature(sig, for: Self.settingsInput(group: secrets.groupID, signer: signer, version: version, settings: data)),
              let s = Self.decodeSettings(data) else { return false }
        // Settings from a phone made before profiles carry none: keep the group's own, so a second
        // coordinator still on an older version cannot wipe them by changing the relay address.
        if Self.isPlain(data) {
            policy.useDistance = s.policy.useDistance
        } else {
            policy = s.policy
        }
        relayURL = s.relayURL
        settingsVersion = version
        return true
    }

    /// Compressed, or plain JSON from a phone before profiles (tried first: compressed bytes are
    /// never valid JSON, but plain JSON can look like compressed data).
    static func decodeSettings(_ data: Data) -> GroupSettings? {
        if let plain = try? JSONDecoder().decode(GroupSettings.self, from: data) { return plain }
        guard let json = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? JSONDecoder().decode(GroupSettings.self, from: json)
    }

    static func isPlain(_ data: Data) -> Bool { (try? JSONSerialization.jsonObject(with: data)) != nil }

    static func settingsInput(group: Data, signer: UInt16, version: UInt32, settings: Data) -> Data {
        var d = Data("HELPA-SETTINGS-1".utf8) + group
        withUnsafeBytes(of: signer.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: version.bigEndian) { d.append(contentsOf: $0) }
        return d + settings
    }
}
