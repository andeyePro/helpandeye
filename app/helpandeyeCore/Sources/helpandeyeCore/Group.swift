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
    public var publicKey: Data
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
    /// The responders' key pair (decision 12). Every member has the public half, so a caller can
    /// seal what they type and where they are once for all responders; only responders hold the
    /// private half, so no caller can read another's. Missing in groups made before it existed.
    public var responderPublicKey: Data?
    public var responderPrivateKey: Data?

    public static func random(generation: UInt32 = 1, groupID: Data? = nil) -> GroupSecrets {
        var s = GroupSecrets(groupID: groupID ?? randomBytes(16), channelSecret: randomNonZero(16), groupKey: randomBytes(32), generation: generation)
        let pair = Curve25519.KeyAgreement.PrivateKey()
        s.responderPrivateKey = pair.rawRepresentation
        s.responderPublicKey = pair.publicKey.rawRepresentation
        return s
    }

    /// A new group's secrets, with an ID made from its first coordinator's signing key: 8 random
    /// bytes, then the first 8 bytes of SHA-256 over a label, those bytes and the key. The relay
    /// checks it, so only a list naming that coordinator can register the group (relay.js
    /// `ownsGroup`).
    public static func forOwner(signingKey: Data) -> GroupSecrets {
        let nonce = randomBytes(8)
        let hash = SHA256.hash(data: Data("HELPA-GROUP-1".utf8) + nonce + signingKey)
        return .random(groupID: nonce + Data(hash.prefix(8)))
    }

    /// Whether this group's ID was made from the given key.
    public func isOwned(by signingKey: Data) -> Bool {
        guard groupID.count == 16 else { return false }
        let hash = SHA256.hash(data: Data("HELPA-GROUP-1".utf8) + groupID.prefix(8) + signingKey)
        return Data(hash.prefix(8)) == groupID.suffix(8)
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
    /// Removed members' signing keys, so the relay can be told exactly who is out.
    public var removedKeys: Set<Data> = []
    /// Removals heard about that this phone has no new keys for yet: until its update code is
    /// scanned, what it seals for responders the removed phone could still open.
    public var removalsWithoutKeys: Set<UInt16> = []
    public var needsKeyUpdate: Bool { !removalsWithoutKeys.isEmpty }
    /// When this phone first heard of a removal it has no new keys for, whoever was removed. Seven
    /// days on, the others stop listening on the old keys, so this phone can no longer reach them.
    public var keysOutdatedSince: Date?
    /// When the first coordinator said this phone's keys stop working, if it has said.
    public var keysEndAt: Date?
    public var highestMember: UInt16 = 0
    /// The membership version of each member's last role change, so an old one replayed is ignored.
    public var roleVersions: [UInt16: UInt32] = [:]
    /// When each member's mobile number was last set, so an older change heard late is ignored.
    public var phoneVersions: [UInt16: UInt32] = [:]
    /// Goes up each time a coordinator changes the group's settings (GroupSettings).
    public var settingsVersion: UInt32 = 0
    /// The coordinator whose settings these are. Two coordinators out of touch can make the same
    /// version: the lower member number wins on every phone, so the group never stays split.
    public var settingsSigner: UInt16 = 0
    /// The highest number block ever given to a coordinator.
    public var highestBlock: UInt16 {
        get { max(members.compactMap(\.block).max() ?? 0, roleBlocksSeen) }
        set { roleBlocksSeen = newValue }
    }
    var roleBlocksSeen: UInt16 = 0
    public var policy: StoredPolicy = .init()
    /// The relay for the internet route, such as https://helprelayandeye.example.workers.dev.
    public var relayURL: String?
    /// The group's pass for a relay that requires one (RelayPass), as pasted in by a coordinator.
    public var relayPass: String?
    /// Goes up whenever someone joins or leaves, so the relay can tell a newer member list from
    /// an out-of-date phone's older one.
    public var membershipVersion: UInt32 = 1
    /// The coordinator the first coordinator named to take over if their phone is lost (decision
    /// 20), with the signature that proves it, so everyone can show it and the relay can check it.
    public var deputy: UInt16?
    public var deputyVersion: UInt32 = 0
    public var deputySignature: Data?
    /// How the first coordinator came to be, where it is not whoever started the group.
    public var takeover: Takeover?

    public struct StoredPolicy: Codable, Equatable, Sendable {
        public var useDistance = false
        /// The group's profiles; the first is the one everyone has until given another.
        public var profiles: [Profile] = [.standard]
        /// Who has which profile, by member number.
        public var profileOf: [UInt16: UInt8] = [:]
        /// Whether coordinators' phones keep the group's log (app spec, The log). On by default.
        public var keepsLog = true
        /// The antenna on each unit's box, by member number (decision 8); the standard whip unless set.
        public var antennaOf: [UInt16: Antenna] = [:]
        /// The boxes whose households chose to have a power cut reported to responders, by the
        /// box's member number (decisions 3 and 4; firmware/DESIGN.md, section 10). Off unless chosen.
        public var reportsPowerCut: Set<UInt16> = []
        /// Whether Help&I boxes hold responders' first names, to say who has seen a call
        /// (firmware/DESIGN.md, section 6). Off unless a coordinator turns it on, as Martin may still
        /// decide against names on boxes (section 14); with it off no name is sent.
        public var namesOnBox = false
        /// Whose home each Help&I box is in, by the box's member number: the member a coordinator
        /// chose. Only that member's phone, connected to the box, treats its calls as its own.
        public var boxHome: [UInt16: UInt16] = [:]
        public init() {}

        enum CodingKeys: String, CodingKey {
            case useDistance, profiles, profileOf, keepsLog, antennaOf, reportsPowerCut, namesOnBox, boxHome, redInterval, amberInterval, buttonWords
        }

        /// Settings from before profiles (escalation times and button words for the whole group)
        /// become the first profile's.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            useDistance = try c.value(.useDistance, or: false)
            profileOf = try c.value(.profileOf, or: [:])
            keepsLog = try c.value(.keepsLog, or: true)
            antennaOf = try c.value(.antennaOf, or: [:])
            reportsPowerCut = try c.value(.reportsPowerCut, or: [])
            namesOnBox = try c.value(.namesOnBox, or: false)
            boxHome = try c.value(.boxHome, or: [:])
            if let p = try c.decodeIfPresent([Profile].self, forKey: .profiles), !p.isEmpty {
                profiles = p
            } else {
                var first = Profile.standard
                first.redInterval = try c.value(.redInterval, or: first.redInterval)
                first.amberInterval = try c.value(.amberInterval, or: first.amberInterval)
                first.buttonWords = try c.value(.buttonWords, or: [:])
                profiles = [first]
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(useDistance, forKey: .useDistance)
            try c.encode(profiles, forKey: .profiles)
            try c.encode(profileOf, forKey: .profileOf)
            try c.encode(keepsLog, forKey: .keepsLog)
            if !antennaOf.isEmpty { try c.encode(antennaOf, forKey: .antennaOf) }
            if !reportsPowerCut.isEmpty { try c.encode(reportsPowerCut.sorted(), forKey: .reportsPowerCut) }
            if namesOnBox { try c.encode(namesOnBox, forKey: .namesOnBox) }
            if !boxHome.isEmpty { try c.encode(boxHome, forKey: .boxHome) }
        }
    }

    public init(name: String, secrets: GroupSecrets, members: [Member]) {
        self.name = name; self.secrets = secrets; self.members = members
    }

    enum CodingKeys: String, CodingKey {
        case name, secrets, previousSecrets, previousUntil, members, removedUnits, removedMembers, removedKeys, removalsWithoutKeys, keysOutdatedSince, keysEndAt, highestMember, roleVersions
        case policy, relayURL, relayPass, membershipVersion, roleBlocksSeen, phoneVersions, settingsVersion, settingsSigner
        case deputy, deputyVersion, deputySignature, takeover
    }

    /// Fields added after the first release are optional when reading, so a group saved by an
    /// earlier version of the app still loads instead of being silently lost.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        secrets = try c.decode(GroupSecrets.self, forKey: .secrets)
        members = try c.decode([Member].self, forKey: .members)
        previousSecrets = try c.decodeIfPresent(GroupSecrets.self, forKey: .previousSecrets)
        previousUntil = try c.decodeIfPresent(Date.self, forKey: .previousUntil)
        removedUnits = try c.decodeIfPresent(Set<UInt32>.self, forKey: .removedUnits) ?? []
        removedMembers = try c.decodeIfPresent(Set<UInt16>.self, forKey: .removedMembers) ?? []
        removedKeys = try c.decodeIfPresent(Set<Data>.self, forKey: .removedKeys) ?? []
        removalsWithoutKeys = try c.decodeIfPresent(Set<UInt16>.self, forKey: .removalsWithoutKeys) ?? []
        keysOutdatedSince = try c.decodeIfPresent(Date.self, forKey: .keysOutdatedSince)
        keysEndAt = try c.decodeIfPresent(Date.self, forKey: .keysEndAt)
        highestMember = try c.decodeIfPresent(UInt16.self, forKey: .highestMember) ?? 0
        roleVersions = try c.decodeIfPresent([UInt16: UInt32].self, forKey: .roleVersions) ?? [:]
        phoneVersions = try c.decodeIfPresent([UInt16: UInt32].self, forKey: .phoneVersions) ?? [:]
        settingsVersion = try c.decodeIfPresent(UInt32.self, forKey: .settingsVersion) ?? 0
        settingsSigner = try c.decodeIfPresent(UInt16.self, forKey: .settingsSigner) ?? 0
        policy = try c.decodeIfPresent(StoredPolicy.self, forKey: .policy) ?? .init()
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL)
        relayPass = try c.decodeIfPresent(String.self, forKey: .relayPass)
        membershipVersion = try c.decodeIfPresent(UInt32.self, forKey: .membershipVersion) ?? 1
        roleBlocksSeen = try c.decodeIfPresent(UInt16.self, forKey: .roleBlocksSeen) ?? 0
        deputy = try c.decodeIfPresent(UInt16.self, forKey: .deputy)
        deputyVersion = try c.decodeIfPresent(UInt32.self, forKey: .deputyVersion) ?? 0
        deputySignature = try c.decodeIfPresent(Data.self, forKey: .deputySignature)
        takeover = try c.decodeIfPresent(Takeover.self, forKey: .takeover)
    }

    /// The group's first coordinator: the only one who removes people (which changes the keys) or
    /// makes new coordinators, so two coordinators out of touch can never split the group onto
    /// different keys or hand out the same numbers. Any coordinator can invite. Whoever started
    /// the group, unless a coordinator has taken over from a lost phone (decision 20).
    public var primaryCoordinator: UInt16? {
        if let t = takeover, member(t.to)?.role == .coordinator { return t.to }
        return members.filter { $0.role == .coordinator && ($0.block ?? 0) == 0 }.map(\.number).min()
    }

    /// The deputy, while they are still a coordinator.
    public var currentDeputy: UInt16? { deputy.flatMap { member($0)?.role == .coordinator ? $0 : nil } }

    /// How long the first coordinator must go unheard before one other coordinator alone can take
    /// over. Their phone repeats the member list daily, so a week is well clear of a day away.
    public static let takeoverSilence: TimeInterval = 7 * 24 * 3600

    /// The deputy naming as the first coordinator signed it, to repeat for phones that missed it.
    public func deputyFrame() -> HelpFrame? {
        guard let sig = deputySignature else { return nil }
        guard let d = deputy else { return .deputy(member: 0, key: Data(count: 32), version: deputyVersion, signature: sig) }
        guard let key = member(d)?.signingKey else { return nil }
        return .deputy(member: d, key: key, version: deputyVersion, signature: sig)
    }

    /// Takes in the first coordinator's naming of a deputy, newer than the one held and signed by
    /// them, naming a member whose key it carries. Returns whether it was.
    @discardableResult
    public mutating func apply(deputy frame: HelpFrame) -> Bool {
        guard case let .deputy(number, key, version, sig) = frame, version > deputyVersion, let first = primaryCoordinator,
              frame.isValidDeputy(signedBy: member(first)?.signingKey, group: secrets.groupID) else { return false }
        if number != 0 { guard member(number)?.signingKey == key else { return false } }
        deputy = number == 0 ? nil : number
        deputyVersion = version
        deputySignature = sig
        return true
    }

    /// Whether this phone accepts a takeover: from its first coordinator, by a coordinator, every
    /// signature a current coordinator's, and the proof enough (decision 20). `silent` is whether
    /// this phone itself has not heard from the first coordinator for `takeoverSilence`.
    public func accepts(_ t: Takeover, silent: Bool) -> Bool {
        guard let from = primaryCoordinator, t.from == from, t.to != from, let fromKey = member(from)?.signingKey,
              let to = member(t.to), to.role == .coordinator, let toKey = to.signingKey else { return false }
        let signers = Set(t.signatures.map(\.signer))
        guard signers.count == t.signatures.count, signers.contains(t.to), !signers.contains(from) else { return false }
        for s in t.signatures {
            guard let m = member(s.signer), m.role == .coordinator,
                  HelpFrame.isValidTakeoverSignature(s.signature, by: m.signingKey, fromKey: fromKey, toKey: toKey, group: secrets.groupID) else { return false }
        }
        // A naming this phone knows was replaced, by another deputy or none, proves nothing.
        let named = t.deputyVersion >= deputyVersion && t.namedDeputy(fromKey: fromKey, toKey: toKey, group: secrets.groupID)
        return named || t.signatures.count >= 2 || silent
    }

    /// Applies a takeover this phone accepts: the lost phone is out, as if removed, and the new
    /// first coordinator names their own deputy.
    public mutating func apply(takeover t: Takeover, at now: Date) {
        var t = t
        t.fromKey = member(t.from)?.signingKey ?? Data()
        apply(membership: .memberRemoved(member: t.from, version: t.version), at: now)
        takeover = t
        deputy = nil
        deputySignature = nil
    }

    /// On the phone taking over: removes the lost phone and makes new keys, as `remove` does, and
    /// records how this phone came to be first coordinator.
    public mutating func takeOver(_ t: Takeover, at now: Date) {
        var t = t
        t.fromKey = member(t.from)?.signingKey ?? Data()
        remove(t.from, at: now)
        takeover = t
        deputy = nil
        deputySignature = nil
    }

    public func member(_ number: UInt16) -> Member? { members.first { $0.number == number } }
    public func member(unit: UInt32) -> Member? { members.first { $0.unit == unit } }

    /// The number block of the coordinator whose phone this is: 0 unless they were made a
    /// coordinator later.
    public func block(of coordinator: UInt16?) -> UInt16 { coordinator.flatMap { member($0)?.block } ?? 0 }

    /// The next member number this coordinator hands out. Numbers are never reused.
    /// Nil when this coordinator's block of 999 numbers is used up.
    public func nextMemberNumber(by coordinator: UInt16?) -> UInt16? {
        let base = block(of: coordinator)
        let used = (members.map(\.number) + removedMembers + [highestMember]).filter { $0 > base && $0 <= base + 999 }
        let next = (used.max() ?? base) + 1
        return next <= base + 999 ? next : nil
    }

    public var nextMemberNumber: UInt16? { nextMemberNumber(by: nil) }

    /// The next unit number this coordinator hands out. Unit numbers are never reused either.
    public func nextUnit(by coordinator: UInt16?) -> UInt32 {
        let base = 70000 + UInt32(block(of: coordinator)) * 10
        let used = (members.compactMap(\.unit) + removedUnits).filter { $0 > base && $0 <= base + 9999 }
        return (used.max() ?? base) + 1
    }

    public var nextUnit: UInt32 { nextUnit(by: nil) }

    /// Makes a member a coordinator, with their own block of numbers. Returns the signed-ready
    /// frame that tells everyone.
    /// Only for someone who already responds: a coordinator responds too, and a caller who cannot
    /// come out must not start getting red alerts. Blocks are never reused, and there are at most
    /// 64 of them.
    public mutating func promote(_ number: UInt16) -> HelpFrame? {
        guard let i = members.firstIndex(where: { $0.number == number }), members[i].role == .responder || members[i].role == .both,
              highestBlock < 63_000 else { return nil }
        members[i].role = .coordinator
        highestBlock += 1000
        members[i].block = highestBlock
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
        if let k = m.signingKey { removedKeys.insert(k) }
        if let u = m.unit { removedUnits.insert(u) }
        previousSecrets = secrets
        previousUntil = now.addingTimeInterval(Self.changeoverPeriod)
        secrets = secrets.rotated()
    }

    /// While a changeover is on: when the old keys stop, for phones that have not scanned yet.
    public func changeoverFrame(at now: Date) -> HelpFrame? {
        guard previousSecrets != nil, let until = previousUntil, until > now else { return nil }
        return .changeoverEnds(generation: secrets.generation, at: UInt32(until.timeIntervalSince1970))
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
            // A member first heard of before sealing keys were sent gets theirs now.
            if let i = members.firstIndex(where: { $0.number == number }), members[i].publicKey.isEmpty, sealKey.contains(where: { $0 != 0 }) {
                members[i].publicKey = sealKey
            }
            guard member(number) == nil, !removedMembers.contains(number), u.map({ !removedUnits.contains($0) }) ?? true else { return }
            members.append(Member(number: number, name: "Member \(number)", role: role, publicKey: sealKey, unit: u, signingKey: key))
            highestMember = max(highestMember, number)
            membershipVersion = max(membershipVersion, version)
        case let .memberRemoved(number, version):
            // Only a phone that held the responders' key could open what callers seal.
            let couldRespond = member(number)?.canRespond ?? true
            if removedMembers.insert(number).inserted {
                if keysOutdatedSince == nil { keysOutdatedSince = now }
                if couldRespond, secrets.responderPublicKey != nil { removalsWithoutKeys.insert(number) }
            }
            membershipVersion = max(membershipVersion, version)
            guard let m = member(number) else { return }
            members.removeAll { $0.number == number }
            if let k = m.signingKey { removedKeys.insert(k) }
            if let u = m.unit { removedUnits.insert(u) }
        case let .memberRole(number, role, block, version):
            // Only responders are made coordinators (promote), so no one gains or loses the
            // responders' key this way. A change that did would need a key update: a phone that
            // stopped responding would still hold the key, and one that started would not.
            guard let i = members.firstIndex(where: { $0.number == number }), version > (roleVersions[number] ?? 0) else { return }
            members[i].role = role
            members[i].block = role == .coordinator ? block : nil
            roleBlocksSeen = max(roleBlocksSeen, block)
            roleVersions[number] = version
            membershipVersion = max(membershipVersion, version)
        case let .changeoverEnds(generation, at) where generation > secrets.generation:
            // Two removals on, the keys this phone holds have already stopped.
            let end = generation > secrets.generation + 1 ? now : Date(timeIntervalSince1970: TimeInterval(at))
            keysEndAt = min(keysEndAt ?? end, end)
            if keysOutdatedSince == nil { keysOutdatedSince = now }
        case let .memberName(number, name):
            guard let i = members.firstIndex(where: { $0.number == number }), !name.isEmpty else { return }
            members[i].name = name
        case let .memberPhone(number, phone, at):
            guard let i = members.firstIndex(where: { $0.number == number }), at > (phoneVersions[number] ?? 0) else { return }
            members[i].phone = phone.isEmpty ? nil : phone
            phoneVersions[number] = at
        default: break
        }
    }

    /// The group as a member in this role may hold it: a caller's copy has no responders' key.
    public func copy(for role: Member.Role) -> GroupState {
        guard role == .caller else { return self }
        var g = self
        g.secrets.responderPrivateKey = nil
        g.previousSecrets?.responderPrivateKey = nil
        return g
    }

    /// What a coordinator's phone sends so other members learn of a new member.
    public func addedFrame(_ number: UInt16) -> HelpFrame? {
        guard let m = member(number), let key = m.signingKey else { return nil }
        return .memberAdded(member: m.number, role: m.role, unit: m.unit ?? 0, signingKey: key,
                            sealKey: m.publicKey.count == 32 ? m.publicKey : Data(count: 32), version: membershipVersion)
    }

    /// The antenna on this member's box, as their coordinator set it.
    public func antenna(of member: UInt16?) -> Antenna { member.flatMap { policy.antennaOf[$0] } ?? .standardWhip }

    /// The transmit-power cap for this unit's box in this band: the highest SX1262 setting its
    /// antenna allows, or nil where it must not send. For the box to take at provisioning.
    public func maxRadioSetting(ofUnit unit: UInt32, in band: Band) -> Int? {
        band.maxRadioSetting(antenna: antenna(of: member(unit: unit)?.number))
    }

    /// How the calls of the caller on `unit` escalate: their profile's alert times.
    public func escalationPolicy(forUnit unit: UInt32?) -> EscalationPolicy {
        let p = profile(ofUnit: unit)
        return EscalationPolicy(useDistance: policy.useDistance, redInterval: p.redInterval, amberInterval: p.amberInterval)
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
        /// Chosen by the coordinator who invites, not by the person joining.
        public var role: Member.Role? = nil
    }

    public struct JoinRequest: Codable, Equatable, Sendable {
        public let token: Data
        public let name: String
        public let wantsToCall: Bool
        public let wantsToRespond: Bool
        public var publicKey: Data
        public var phone: String? = nil
        public var signingKey: Data? = nil
    }

    public struct Welcome: Codable, Equatable, Sendable {
        public let groupID: Data
        public let memberNumber: UInt16
        public let sealed: Data
    }

    public enum Failure: Error, Equatable { case wrongToken, wrongGroup, cannotOpen, badCode, groupFull, otherVersion }

    /// Which of the codes a piece of text holds, so a wrong one can be named.
    public enum Kind: Equatable, Sendable { case invitation, request, welcome }

    public static func invitation(for group: GroupState, coordinator: DeviceIdentity, role: Member.Role? = nil) -> Invitation {
        Invitation(groupID: group.secrets.groupID, groupName: group.name, coordinatorKey: coordinator.publicKey, token: randomBytes(16), role: role)
    }

    public static func request(_ invite: Invitation, name: String, call: Bool, respond: Bool, phone: String? = nil, me: DeviceIdentity) -> JoinRequest {
        let call = invite.role.map { $0 == .caller || $0 == .both } ?? call
        let respond = invite.role.map { $0 != .caller } ?? respond
        return JoinRequest(token: invite.token, name: name, wantsToCall: call, wantsToRespond: respond, publicKey: me.publicKey,
                           phone: phone, signingKey: me.signingPublicKey)
    }

    public static func kind(of code: String) -> Kind? {
        if (try? decode(Welcome.self, from: code)) != nil { return .welcome }
        if (try? decode(JoinRequest.self, from: code)) != nil { return .request }
        if (try? decode(Invitation.self, from: code)) != nil { return .invitation }
        return nil
    }

    /// Adds the member and seals the group for them. Run on the coordinator's phone.
    public static func admit(_ request: JoinRequest, to group: inout GroupState, invite: Invitation, coordinator: DeviceIdentity) throws -> Welcome {
        guard request.token == invite.token else { throw Failure.wrongToken }
        guard invite.groupID == group.secrets.groupID else { throw Failure.wrongGroup }
        // The invitation's role stands, whatever the request says.
        let role: Member.Role = invite.role ?? (request.wantsToCall && request.wantsToRespond ? .both : (request.wantsToCall ? .caller : .responder))
        let me = group.members.first { $0.publicKey == coordinator.publicKey }?.number
        guard let number = group.nextMemberNumber(by: me) else { throw Failure.groupFull }
        group.membershipVersion += 1
        group.highestMember = max(group.highestMember, number)
        group.members.append(Member(number: number, name: request.name, role: role, publicKey: request.publicKey,
                                    unit: role == .caller || role == .both ? group.nextUnit(by: me) : nil, phone: request.phone,
                                    signingKey: request.signingKey))
        let box = try seal(pack(group.copy(for: role)), to: request.publicKey, from: coordinator, context: invite.token)
        return Welcome(groupID: group.secrets.groupID, memberNumber: number, sealed: box)
    }

    /// Opens a welcome on the new member's phone.
    public static func open(_ welcome: Welcome, invite: Invitation, me: DeviceIdentity) throws -> GroupState {
        guard welcome.groupID == invite.groupID else { throw Failure.wrongGroup }
        let plain = try unseal(welcome.sealed, from: invite.coordinatorKey, me: me, context: invite.token)
        return try unpack(plain)
    }

    /// New secrets after a phone was removed, sealed for one remaining member. Sent over the
    /// internet route or shown as a QR code.
    public static func update(_ group: GroupState, for member: Member, coordinator: DeviceIdentity) throws -> Welcome {
        let box = try seal(pack(group.copy(for: member.role)), to: member.publicKey, from: coordinator, context: group.secrets.groupID)
        return Welcome(groupID: group.secrets.groupID, memberNumber: member.number, sealed: box)
    }

    /// Opens an update with the group this phone already has. Only the first coordinator of that
    /// group can have sealed it, and an update can never take the group back to older secrets.
    /// `primarySilent` is whether this phone has not heard from its first coordinator for
    /// `GroupState.takeoverSilence`, for an update from a coordinator who took over (decision 20).
    public static func openUpdate(_ welcome: Welcome, current: GroupState, me: DeviceIdentity, primarySilent: Bool = false) throws -> GroupState {
        guard welcome.groupID == current.secrets.groupID else { throw Failure.wrongGroup }
        // Only the first coordinator changes the keys, so the group can never be split onto two:
        // the one this phone knows, or one who took over from them with proof this phone accepts.
        for c in current.members where c.role == .coordinator {
            guard let plain = try? unseal(welcome.sealed, from: c.publicKey, me: me, context: current.secrets.groupID),
                  let g = try? unpack(plain) else { continue }
            guard g.secrets.generation > current.secrets.generation else { throw Failure.cannotOpen }
            if c.number == current.primaryCoordinator { return g }
            if let t = g.takeover, t.to == c.number, current.accepts(t, silent: primarySilent) { return g }
            throw Failure.cannotOpen
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
    public static let prefix = "HELPA1:"
    /// A welcome or key update in its compact form: the group compressed before sealing, and the
    /// code itself binary rather than text inside text, about half the length of the first form.
    public static let welcomePrefix = "HELPA2:"

    public static func code<T: Encodable>(_ value: T) throws -> String {
        prefix + (try JSONEncoder().encode(value)).base64EncodedString()
    }

    public static func code(_ welcome: Welcome) throws -> String {
        var d = welcome.groupID
        withUnsafeBytes(of: welcome.memberNumber.bigEndian) { d.append(contentsOf: $0) }
        return welcomePrefix + (d + welcome.sealed).base64EncodedString()
    }

    /// The group as it goes inside a welcome: compressed, since keys and names repeat a lot.
    static func pack(_ group: GroupState) throws -> Data {
        try (JSONEncoder().encode(group) as NSData).compressed(using: .zlib) as Data
    }

    /// Reads either form: compressed, or plain from a phone before compression.
    static func unpack(_ plain: Data) throws -> GroupState {
        if plain.first == UInt8(ascii: "{") { return try JSONDecoder().decode(GroupState.self, from: plain) }
        return try JSONDecoder().decode(GroupState.self, from: (plain as NSData).decompressed(using: .zlib) as Data)
    }

    /// Reads a code wherever it sits in the text, as a message app may add words around it or
    /// break it across lines.
    public static func decode<T: Decodable>(_ type: T.Type, from code: String) throws -> T {
        if T.self == Welcome.self, let w = payload(after: welcomePrefix, in: code, { d -> Welcome? in
            guard d.count > 18 else { return nil }
            return Welcome(groupID: Data(d.prefix(16)), memberNumber: UInt16(d[d.startIndex + 16]) << 8 | UInt16(d[d.startIndex + 17]), sealed: Data(d.dropFirst(18)))
        }) {
            return w as! T
        }
        guard code.range(of: prefix) != nil else {
            throw code.contains(":") && code.uppercased().contains("HELPANDI") ? Failure.otherVersion : Failure.badCode
        }
        if let value = payload(after: prefix, in: code, { try? JSONDecoder().decode(type, from: $0) }) { return value }
        throw Failure.badCode
    }

    /// The code may be broken across lines and followed by other words: tries the longest run of
    /// pieces after the prefix that reads as one.
    private static func payload<V>(after prefix: String, in code: String, _ make: (Data) -> V?) -> V? {
        guard let start = code.range(of: prefix) else { return nil }
        let isCode: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }
        var pieces: [Substring] = []
        for piece in code[start.upperBound...].split(whereSeparator: \.isWhitespace) {
            let usable = piece.prefix(while: isCode)
            if !usable.isEmpty { pieces.append(usable) }
            if usable.count < piece.count { break }
        }
        for n in stride(from: pieces.count, through: 1, by: -1) {
            if let data = Data(base64Encoded: pieces.prefix(n).joined()), let value = make(data) { return value }
        }
        return nil
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
