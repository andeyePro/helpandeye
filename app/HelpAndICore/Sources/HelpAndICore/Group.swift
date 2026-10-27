import CryptoKit
import Foundation

/// A member's place in a group. Numbers, not names, are what travel on air (decision 12); the
/// name lives only on group members' phones.
public struct Member: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case caller, responder, both, coordinator }
    public var id: UInt16 { number }
    public let number: UInt16
    public var name: String
    public var role: Role
    /// X25519 public key of the member's phone, used to send them group secrets.
    public let publicKey: Data
    /// The member's unit number, if they can call for help.
    public var unit: UInt32?

    public init(number: UInt16, name: String, role: Role, publicKey: Data, unit: UInt32? = nil) {
        self.number = number; self.name = name; self.role = role; self.publicKey = publicKey; self.unit = unit
    }

    public var canCall: Bool { role != .responder && unit != nil }
    public var canRespond: Bool { role != .caller }
}

/// The secrets every member of a group holds. Made at random by the coordinator's phone; never
/// built into the app or firmware.
public struct GroupSecrets: Codable, Equatable, Sendable {
    public let groupID: Data
    /// Written into each member's board as a private MeshCore channel.
    public let channelSecret: Data
    /// End-to-end key for the internet route.
    public let groupKey: Data
    public let generation: UInt32

    public static func random(generation: UInt32 = 1, groupID: Data? = nil) -> GroupSecrets {
        GroupSecrets(groupID: groupID ?? randomBytes(16), channelSecret: randomNonZero(16), groupKey: randomBytes(32), generation: generation)
    }

    /// New channel secret and group key after a phone is removed; the group keeps its ID.
    public func rotated() -> GroupSecrets { .random(generation: generation + 1, groupID: groupID) }

    public init(groupID: Data, channelSecret: Data, groupKey: Data, generation: UInt32) {
        self.groupID = groupID; self.channelSecret = channelSecret; self.groupKey = groupKey; self.generation = generation
    }
}

public struct GroupState: Codable, Equatable, Sendable {
    public var name: String
    public var secrets: GroupSecrets
    /// Kept while boards move to new secrets, so they can still listen on the old channel.
    public var previousSecrets: GroupSecrets?
    public var members: [Member]
    public var removedUnits: Set<UInt32> = []
    public var policy: StoredPolicy = .init()

    public struct StoredPolicy: Codable, Equatable, Sendable {
        public var useDistance = false
        public var redInterval: TimeInterval = 120
        public var amberInterval: TimeInterval = 900
        public init() {}
    }

    public init(name: String, secrets: GroupSecrets, members: [Member]) {
        self.name = name; self.secrets = secrets; self.members = members
    }

    public func member(_ number: UInt16) -> Member? { members.first { $0.number == number } }
    public func member(unit: UInt32) -> Member? { members.first { $0.unit == unit } }

    public var nextMemberNumber: UInt16 { (members.map(\.number).max() ?? 0) + 1 }

    /// Unit numbers are never reused, even after a phone is removed.
    public var nextUnit: UInt32 {
        max((members.compactMap(\.unit) + removedUnits).max() ?? 70000, 70000) + 1
    }

    /// Removes a member and rotates the secrets, so a lost phone cannot read new traffic.
    public mutating func remove(_ number: UInt16) {
        guard let m = member(number) else { return }
        members.removeAll { $0.number == number }
        if let u = m.unit { removedUnits.insert(u) }
        previousSecrets = secrets
        secrets = secrets.rotated()
    }

    public var escalationPolicy: EscalationPolicy {
        EscalationPolicy(useDistance: policy.useDistance, redInterval: policy.redInterval, amberInterval: policy.amberInterval)
    }
}

/// The phone's own identity. The private key never leaves the phone.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }
    public init(rawRepresentation: Data) throws { privateKey = try .init(rawRepresentation: rawRepresentation) }
}

/// Joining a group in person, with no network: three QR codes.
///
/// 1. The coordinator shows an `Invitation`.
/// 2. The new member scans it and shows a `JoinRequest` with their phone's public key.
/// 3. The coordinator scans that, approves, and shows a `Welcome`: the group state sealed to the
///    new member's key, so only their phone can open it.
///
/// The same three codes can be sent as text for joining at a distance, with `safetyNumber`
/// read aloud on a call so that both people know nobody swapped a key on the way.
public enum Joining {
    public struct Invitation: Codable, Equatable, Sendable {
        public let groupID: Data
        public let groupName: String
        public let coordinatorKey: Data
        public let token: Data
    }

    public struct JoinRequest: Codable, Equatable, Sendable {
        public let token: Data
        public let name: String
        public let wantsToCall: Bool
        public let wantsToRespond: Bool
        public let publicKey: Data
    }

    public struct Welcome: Codable, Equatable, Sendable {
        public let groupID: Data
        public let memberNumber: UInt16
        public let sealed: Data
    }

    public enum Failure: Error, Equatable { case wrongToken, wrongGroup, cannotOpen, badCode }

    public static func invitation(for group: GroupState, coordinator: DeviceIdentity) -> Invitation {
        Invitation(groupID: group.secrets.groupID, groupName: group.name, coordinatorKey: coordinator.publicKey, token: randomBytes(16))
    }

    public static func request(_ invite: Invitation, name: String, call: Bool, respond: Bool, me: DeviceIdentity) -> JoinRequest {
        JoinRequest(token: invite.token, name: name, wantsToCall: call, wantsToRespond: respond, publicKey: me.publicKey)
    }

    /// Adds the member and seals the group for them. Run on the coordinator's phone.
    public static func admit(_ request: JoinRequest, to group: inout GroupState, invite: Invitation, coordinator: DeviceIdentity) throws -> Welcome {
        guard request.token == invite.token else { throw Failure.wrongToken }
        guard invite.groupID == group.secrets.groupID else { throw Failure.wrongGroup }
        let role: Member.Role = request.wantsToCall && request.wantsToRespond ? .both : (request.wantsToCall ? .caller : .responder)
        let number = group.nextMemberNumber
        group.members.append(Member(number: number, name: request.name, role: role, publicKey: request.publicKey,
                                    unit: request.wantsToCall ? group.nextUnit : nil))
        let box = try seal(JSONEncoder().encode(group), to: request.publicKey, from: coordinator, context: invite.token)
        return Welcome(groupID: group.secrets.groupID, memberNumber: number, sealed: box)
    }

    /// Opens a welcome on the new member's phone.
    public static func open(_ welcome: Welcome, invite: Invitation, me: DeviceIdentity) throws -> GroupState {
        guard welcome.groupID == invite.groupID else { throw Failure.wrongGroup }
        let plain = try unseal(welcome.sealed, from: invite.coordinatorKey, me: me, context: invite.token)
        return try JSONDecoder().decode(GroupState.self, from: plain)
    }

    /// Six digits both phones show for the same pair of keys, to read aloud when joining at a
    /// distance.
    public static func safetyNumber(_ a: Data, _ b: Data) -> String {
        let pair = [a, b].sorted { $0.lexicographicallyPrecedes($1) }
        let digest = SHA256.hash(data: pair[0] + pair[1])
        let n = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return String(format: "%06u", n)
    }

    /// Text form of any of the three codes, for QR codes and for sending as a link.
    public static func code<T: Encodable>(_ value: T) throws -> String {
        "HELPANDI1:" + (try JSONEncoder().encode(value)).base64EncodedString()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from code: String) throws -> T {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("HELPANDI1:"), let data = Data(base64Encoded: String(trimmed.dropFirst(10))) else { throw Failure.badCode }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Seals `plain` for the holder of `recipient` (X25519, HKDF-SHA256, ChaCha20-Poly1305).
public func seal(_ plain: Data, to recipient: Data, from me: DeviceIdentity, context: Data) throws -> Data {
    let key = try sharedKey(me: me, other: recipient, context: context)
    return try ChaChaPoly.seal(plain, using: key).combined
}

public func unseal(_ box: Data, from sender: Data, me: DeviceIdentity, context: Data) throws -> Data {
    do {
        let key = try sharedKey(me: me, other: sender, context: context)
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: key)
    } catch {
        throw Joining.Failure.cannotOpen
    }
}

private func sharedKey(me: DeviceIdentity, other: Data, context: Data) throws -> SymmetricKey {
    let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: other)
    let secret = try me.privateKey.sharedSecretFromKeyAgreement(with: theirs)
    return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("Help&I join v1".utf8), outputByteCount: 32)
}

func randomBytes(_ n: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
}

func randomNonZero(_ n: Int) -> Data {
    while true {
        let d = randomBytes(n)
        if d.contains(where: { $0 != 0 }) { return d }
    }
}
