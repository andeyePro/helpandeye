import CryptoKit
import Foundation

/// A member's place in a group. Numbers, not names, are what travel on air (decision 12); the
/// name lives only on group members' phones.
public struct Member: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case caller, responder, both, coordinator

        var code: UInt8 { switch self { case .caller: 1; case .responder: 2; case .both: 3; case .coordinator: 4 } }
        init?(code: UInt8) {
            switch code { case 1: self = .caller; case 2: self = .responder; case 3: self = .both; case 4: self = .coordinator; default: return nil }
        }
    }
    public var id: UInt16 { number }
    public let number: UInt16
    public var name: String
    public var role: Role
    /// X25519 public key of the member's phone, used to send them group secrets.
    public let publicKey: Data
    /// The member's unit number, if they can call for help.
    public var unit: UInt32?
    /// Optional, for the ready-written text when nothing else gets through. Kept on members'
    /// phones only.
    public var phone: String?
    /// Ed25519 key the phone signs relay requests with.
    public var signingKey: Data?
    /// For a coordinator: the first of the 1,000 member numbers they hand out, so two coordinators
    /// adding people while out of touch never give out the same number. 0 for whoever started the
    /// group.
    public var block: UInt16?
    /// The MeshCore public key of the member's box, once it has been heard.
    public var boardKey: Data?

    public init(number: UInt16, name: String, role: Role, publicKey: Data, unit: UInt32? = nil, phone: String? = nil, signingKey: Data? = nil) {
        self.number = number; self.name = name; self.role = role; self.publicKey = publicKey; self.unit = unit
        self.phone = phone; self.signingKey = signingKey
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
    /// Kept while boards move to new secrets, so they can still listen on the old channel, until
    /// `previousUntil`. After that a removed phone's key opens nothing.
    public var previousSecrets: GroupSecrets?
    public var previousUntil: Date?
    public var members: [Member]
    public var removedUnits: Set<UInt32> = []
    /// Member numbers are never reused, and a removed one can never be added back, so an old
    /// signed "member added" replayed by a removed phone cannot let it back in.
    public var removedMembers: Set<UInt16> = []
    public var highestMember: UInt16 = 0
    /// The membership version of each member's last role change, so an old one replayed is ignored.
    public var roleVersions: [UInt16: UInt32] = [:]
    public var policy: StoredPolicy = .init()
    /// The relay for the internet route, such as https://helprelayandeye.example.workers.dev.
    public var relayURL: String?
    /// Goes up whenever someone joins or leaves, so the relay can tell a newer member list from
    /// an out-of-date phone's older one.
    public var membershipVersion: UInt32 = 1

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

    /// The number block of the coordinator whose phone this is: 0 unless they were made a
    /// coordinator later.
    public func block(of coordinator: UInt16?) -> UInt16 { coordinator.flatMap { member($0)?.block } ?? 0 }

    /// The next member number this coordinator hands out. Numbers are never reused.
    public func nextMemberNumber(by coordinator: UInt16?) -> UInt16 {
        let base = block(of: coordinator)
        let used = (members.map(\.number) + removedMembers + [highestMember]).filter { $0 > base && $0 <= base &+ 999 }
        return (used.max() ?? base) + 1
    }

    public var nextMemberNumber: UInt16 { nextMemberNumber(by: nil) }

    /// The next unit number this coordinator hands out. Unit numbers are never reused either.
    public func nextUnit(by coordinator: UInt16?) -> UInt32 {
        let base = 70000 + UInt32(block(of: coordinator)) * 10
        let used = (members.compactMap(\.unit) + removedUnits).filter { $0 > base && $0 <= base + 9999 }
        return (used.max() ?? base) + 1
    }

    public var nextUnit: UInt32 { nextUnit(by: nil) }

    /// Makes a member a coordinator, with their own block of numbers. Returns the signed-ready
    /// frame that tells everyone.
    public mutating func promote(_ number: UInt16) -> HelpFrame? {
        guard let i = members.firstIndex(where: { $0.number == number }), members[i].role != .coordinator else { return nil }
        let blocks = members.compactMap(\.block) + [0]
        members[i].role = .coordinator
        members[i].block = (blocks.max() ?? 0) + 1000
        membershipVersion += 1
        roleVersions[number] = membershipVersion
        return roleFrame(number)
    }

    public func roleFrame(_ number: UInt16) -> HelpFrame? {
        guard let m = member(number) else { return nil }
        return .memberRole(member: number, role: m.role, block: m.block ?? 0, version: roleVersions[number] ?? membershipVersion)
    }

    public static let changeoverPeriod: TimeInterval = 7 * 24 * 3600

    /// Removes a member and rotates the secrets, so a lost phone cannot read new traffic.
    public mutating func remove(_ number: UInt16, at now: Date = Date()) {
        guard let m = member(number) else { return }
        members.removeAll { $0.number == number }
        membershipVersion += 1
        removedMembers.insert(number)
        if let u = m.unit { removedUnits.insert(u) }
        previousSecrets = secrets
        previousUntil = now.addingTimeInterval(Self.changeoverPeriod)
        secrets = secrets.rotated()
    }

    /// The secrets to listen with: the current ones, and the previous ones during a changeover.
    public func listening(at now: Date) -> [GroupSecrets] {
        guard let p = previousSecrets, let until = previousUntil, now < until else { return [secrets] }
        return [secrets, p]
    }

    /// Whether an acknowledgement from this member should count: they must still be in the group
    /// and able to respond, and the ack must carry their signature.
    public func acceptsAck(_ frame: HelpFrame) -> Bool {
        guard case let .ack(_, _, who, _, _) = frame, let m = member(who), m.canRespond else { return false }
        return frame.isValidAck(signedBy: m.signingKey, group: secrets.groupID)
    }

    /// The rota, with every responder available unless they have said otherwise.
    public var defaultRota: Rota {
        Rota(responders: members.filter(\.canRespond).map(\.number), defaultAvailable: true)
    }

    /// Applies a coordinator's signed membership change on another member's phone. A new member
    /// is known by number until their name arrives. Never touches the secrets. Each frame carries the
    /// membership version, so every phone ends up with the same one and any coordinator's member
    /// list is accepted by the relay.
    public mutating func apply(membership frame: HelpFrame, at now: Date = Date()) {
        switch frame {
        case let .memberAdded(number, role, unit, key, sealKey, version):
            let u: UInt32? = role == .responder || unit == 0 ? nil : unit
            guard member(number) == nil, !removedMembers.contains(number), u.map({ !removedUnits.contains($0) }) ?? true else { return }
            members.append(Member(number: number, name: "Member \(number)", role: role, publicKey: sealKey, unit: u, signingKey: key))
            highestMember = max(highestMember, number)
            membershipVersion = max(membershipVersion, version)
        case let .memberRemoved(number, version):
            removedMembers.insert(number)
            membershipVersion = max(membershipVersion, version)
            guard let m = member(number) else { return }
            members.removeAll { $0.number == number }
            if let u = m.unit { removedUnits.insert(u) }
        case let .memberRole(number, role, block, version):
            guard let i = members.firstIndex(where: { $0.number == number }), version > (roleVersions[number] ?? 0) else { return }
            members[i].role = role
            members[i].block = role == .coordinator ? block : nil
            roleVersions[number] = version
            membershipVersion = max(membershipVersion, version)
        case let .memberName(number, name):
            guard let i = members.firstIndex(where: { $0.number == number }), !name.isEmpty else { return }
            members[i].name = name
        default: break
        }
    }

    /// What a coordinator's phone sends so other members learn of a new member.
    public func addedFrame(_ number: UInt16) -> HelpFrame? {
        guard let m = member(number), let key = m.signingKey else { return nil }
        return .memberAdded(member: m.number, role: m.role, unit: m.unit ?? 0, signingKey: key,
                            sealKey: m.publicKey.count == 32 ? m.publicKey : Data(count: 32), version: membershipVersion)
    }

    public var escalationPolicy: EscalationPolicy {
        EscalationPolicy(useDistance: policy.useDistance, redInterval: policy.redInterval, amberInterval: policy.amberInterval)
    }
}

/// The phone's own identity: one key pair for sealing, one for signing relay requests. The
/// private keys never leave the phone.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let signingKey: Curve25519.Signing.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init(), signingKey: Curve25519.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey; self.signingKey = signingKey
    }

    /// The 64 bytes kept in the keychain: the sealing key, then the signing key.
    public var rawRepresentation: Data { privateKey.rawRepresentation + signingKey.rawRepresentation }

    public init(rawRepresentation raw: Data) throws {
        guard raw.count == 64 else { throw Joining.Failure.badCode }
        privateKey = try .init(rawRepresentation: raw.prefix(32))
        signingKey = try .init(rawRepresentation: raw.suffix(32))
    }
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
        public var phone: String? = nil
        public var signingKey: Data? = nil
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

    public static func request(_ invite: Invitation, name: String, call: Bool, respond: Bool, phone: String? = nil, me: DeviceIdentity) -> JoinRequest {
        JoinRequest(token: invite.token, name: name, wantsToCall: call, wantsToRespond: respond, publicKey: me.publicKey,
                    phone: phone, signingKey: me.signingPublicKey)
    }

    /// Adds the member and seals the group for them. Run on the coordinator's phone.
    public static func admit(_ request: JoinRequest, to group: inout GroupState, invite: Invitation, coordinator: DeviceIdentity) throws -> Welcome {
        guard request.token == invite.token else { throw Failure.wrongToken }
        guard invite.groupID == group.secrets.groupID else { throw Failure.wrongGroup }
        let role: Member.Role = request.wantsToCall && request.wantsToRespond ? .both : (request.wantsToCall ? .caller : .responder)
        let me = group.members.first { $0.publicKey == coordinator.publicKey }?.number
        let number = group.nextMemberNumber(by: me)
        group.membershipVersion += 1
        group.highestMember = max(group.highestMember, number)
        group.members.append(Member(number: number, name: request.name, role: role, publicKey: request.publicKey,
                                    unit: request.wantsToCall ? group.nextUnit(by: me) : nil, phone: request.phone,
                                    signingKey: request.signingKey))
        let box = try seal(JSONEncoder().encode(group), to: request.publicKey, from: coordinator, context: invite.token)
        return Welcome(groupID: group.secrets.groupID, memberNumber: number, sealed: box)
    }

    /// Opens a welcome on the new member's phone.
    public static func open(_ welcome: Welcome, invite: Invitation, me: DeviceIdentity) throws -> GroupState {
        guard welcome.groupID == invite.groupID else { throw Failure.wrongGroup }
        let plain = try unseal(welcome.sealed, from: invite.coordinatorKey, me: me, context: invite.token)
        return try JSONDecoder().decode(GroupState.self, from: plain)
    }

    /// New secrets after a phone was removed, sealed for one remaining member. Sent over the
    /// internet route or shown as a QR code.
    public static func update(_ group: GroupState, for member: Member, coordinator: DeviceIdentity) throws -> Welcome {
        let box = try seal(JSONEncoder().encode(group), to: member.publicKey, from: coordinator, context: group.secrets.groupID)
        return Welcome(groupID: group.secrets.groupID, memberNumber: member.number, sealed: box)
    }

    /// Opens an update with the group this phone already has. Only a coordinator of that group can
    /// have sealed it, and an update can never take the group back to older secrets.
    public static func openUpdate(_ welcome: Welcome, current: GroupState, me: DeviceIdentity) throws -> GroupState {
        guard welcome.groupID == current.secrets.groupID else { throw Failure.wrongGroup }
        for c in current.members where c.role == .coordinator {
            if let plain = try? unseal(welcome.sealed, from: c.publicKey, me: me, context: current.secrets.groupID),
               let g = try? JSONDecoder().decode(GroupState.self, from: plain) {
                guard g.secrets.generation > current.secrets.generation else { throw Failure.cannotOpen }
                return g
            }
        }
        throw Failure.cannotOpen
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
