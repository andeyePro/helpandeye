import Foundation

/// A Help&I box: a Heltec WiFi LoRa 32 V4 on Help&I's own build of MeshCore's companion firmware,
/// a member of its group in its own right with its own unit (decision 8; firmware/DESIGN.md,
/// section 6). The phone gives it the group and the member list over Bluetooth, in the bytes the
/// firmware's `core/provision.hpp` reads; the box signs with its MeshCore identity, which is the
/// member's signing key, and seals with the X25519 key it reports in its info reply (0xA0).
public enum HelpBox {
    /// The body of set group (0x71) after the command byte.
    public static let groupBodyBytes = 94
    /// Member number, role and signing key, in a set members (0x72) page.
    public static let memberBytes = 35
    public static let membersPerPage = 4
    /// The most members a box keeps; those who can respond come first, so a crowded group's
    /// callers are the ones left off.
    public static let maxMembers = 32
    /// Responders' first names in a set names (0x76) page, and the longest name in UTF-8 bytes.
    public static let namesPerPage = 8
    public static let maxNameBytes = 16

    /// The firmware's codes for a unit's antenna, from which the box works out its own
    /// transmit-power cap with the same arithmetic as `Band.maxRadioSetting(antenna:)`.
    public enum AntennaCode: UInt8, Sendable { case whip = 0, stub = 1, external3dBi = 2, external5dBi = 3 }

    /// The code whose gain is at or above the antenna's, so the cap the box works out is never
    /// looser than the app's. The firmware has no code above 5 dBi, so no higher-gain antenna can
    /// be set (`GroupState.setAntenna`).
    public static func antennaCode(_ antenna: Antenna) -> AntennaCode {
        switch antenna {
        case .standardWhip: .whip
        case .higherGainWhip: .external5dBi
        case let .external(g): g <= 0 ? .stub : g <= 2 ? .whip : g <= 3 ? .external3dBi : .external5dBi
        }
    }

    /// Everything the phone gives a box: the set group body, the set members pages, and the set
    /// names pages when the group puts responders' first names on its boxes (nil when it does
    /// not). Sent whenever any of it changes, and whenever the box says it holds nothing.
    public struct Setup: Equatable, Sendable {
        public let member: UInt16
        public let unit: UInt32
        public let group: Data
        public let members: [Data]
        public let names: [Data]?
    }

    /// The set-up for the box with this MeshCore public key, if it is a member of the group with
    /// a unit. `now` decides whether a changeover's old channel still goes.
    public static func setup(for g: GroupState, box key: Data, at now: Date) -> Setup? {
        guard key.count == 32, let box = g.members.first(where: { $0.signingKey == key }), let unit = box.unit else { return nil }
        let profile = g.profile(of: box.number)
        var w = ByteWriter()
        w.bytes(g.secrets.groupID.count == 16 ? g.secrets.groupID : Data(count: 16))
        w.u16(box.number); w.u32(unit)
        w.u8((profile.afterOK == .closesCall ? 1 : 0) | (profile.callerMayClose ? 2 : 0) | (g.policy.reportsPowerCut.contains(box.number) ? 4 : 0))
        w.u8(antennaCode(g.antenna(of: box.number)).rawValue)
        w.bytes(g.secrets.responderPublicKey.flatMap { $0.count == 32 ? $0 : nil } ?? Data(count: 32))
        w.bytes(g.secrets.channelSecret)
        let changeover = g.listening(at: now).count > 1 ? g.previousSecrets : nil
        w.bytes(changeover?.channelSecret ?? Data(count: 16))
        w.u32(changeover.flatMap { _ in g.previousUntil }.map { UInt32(clamping: Int($0.timeIntervalSince1970)) } ?? 0)
        w.u16(g.primaryCoordinator ?? 0)
        let order: [Member.Role] = [.coordinator, .both, .responder, .caller]
        let members = order.flatMap { role in g.members.filter { $0.role == role && $0.signingKey?.count == 32 } }.prefix(maxMembers)
        var pages: [Data] = []
        for start in stride(from: 0, to: max(members.count, 1), by: membersPerPage) {
            var p = ByteWriter()
            p.u32(g.membershipVersion); p.u8(UInt8(start)); p.u8(UInt8(members.count))
            for m in members.dropFirst(start).prefix(membersPerPage) {
                p.u16(m.number); p.u8(m.role.code); p.bytes(m.signingKey!)
            }
            pages.append(p.data)
        }
        let names = g.policy.namesOnBox ? namePages(members.filter(\.canRespond), version: g.membershipVersion) : nil
        return Setup(member: box.number, unit: unit, group: w.data, members: pages, names: names)
    }

    /// Each responder's first name, so the box can say "Pat has seen your call." (firmware/DESIGN.md,
    /// section 6): the first word of their name, cut to 16 bytes at a whole character.
    static func namePages(_ responders: [Member], version: UInt32) -> [Data] {
        let names: [(UInt16, Data)] = responders.compactMap { m in
            guard let first = m.name.split(whereSeparator: \.isWhitespace).first else { return nil }
            var name = ""
            for c in first {
                guard name.utf8.count + String(c).utf8.count <= maxNameBytes else { break }
                name.append(c)
            }
            return name.isEmpty ? nil : (m.number, Data(name.utf8))
        }
        var pages: [Data] = []
        for start in stride(from: 0, to: max(names.count, 1), by: namesPerPage) {
            var p = ByteWriter()
            p.u32(version); p.u8(UInt8(start)); p.u8(UInt8(names.count))
            for (number, name) in names.dropFirst(start).prefix(namesPerPage) {
                p.u16(number); p.u8(UInt8(name.count)); p.bytes(name)
            }
            pages.append(p.data)
        }
        return pages
    }

    /// A set names page with none in it: the box forgets the names it holds and says "A responder".
    public static let noNames = namePages([], version: 0)

    /// What a box has been sent, so only a part that changed goes again, and every part goes again
    /// once the box says it holds nothing.
    public struct Sync: Equatable, Sendable {
        public enum Part: Hashable, Sendable { case group, members, names }
        /// A part to send, whole: its pages, each one command.
        public struct Due: Equatable, Sendable {
            public let part: Part
            public let pages: [Data]
            public var commands: [MeshCore.Command] {
                pages.map { page in
                    switch part {
                    case .group: .boxSetGroup(body: page)
                    case .members: .boxSetMembers(page: page)
                    case .names: .boxSetNames(page: page)
                    }
                }
            }
        }

        private var sent: [Part: [Data]] = [:]
        public init() {}

        /// The parts that differ from what the box was last sent, in the order they go. With names
        /// off, a box that still holds some is told to forget them; one that holds none is sent
        /// nothing, so its wording stays as before names.
        public func due(_ setup: Setup, namesHeld: Int) -> [Due] {
            let names = setup.names ?? (namesHeld > 0 ? HelpBox.noNames : nil)
            return [Due(part: .group, pages: [setup.group]), Due(part: .members, pages: setup.members), names.map { Due(part: .names, pages: $0) }]
                .compactMap { $0 }.filter { sent[$0.part] != $0.pages }
        }

        /// Every page of the part was taken.
        public mutating func done(_ due: Due) { sent[due.part] = due.pages }

        /// The box holds nothing (reset, or never set up): everything goes again.
        public mutating func boxHoldsNothing() { sent = [:] }
    }

    /// The note a Help&I box without the mains wire sends after its power-cut report, and the one a
    /// caller is offered to send when a stock box's battery suggests a power cut (`BatteryWatch`):
    /// a guess, so it says so (firmware/DESIGN.md, section 10).
    public static let probablePowerCutNote = "Power probably cut: the battery is falling."
}

extension GroupState {
    /// Adds a Help&I box as a member of its own: a caller with its own unit, its MeshCore identity
    /// as its signing key and the sealing key from its info reply, in the home of member `home`.
    /// Returns the box's member number, or nil if a key is not one, `home` is not a member, the box
    /// is a member already, or this coordinator's numbers are used up.
    public mutating func addBox(key: Data, sealKey seal: Data, name: String, home: UInt16, by coordinator: UInt16?) -> UInt16? {
        guard key.count == 32, seal.count == 32, seal != Data(count: 32), boxMember(key: key) == nil, let person = member(home), !isBox(person),
              let number = nextMemberNumber(by: coordinator) else { return nil }
        membershipVersion += 1
        highestMember = max(highestMember, number)
        members.append(Member(number: number, name: name, role: .caller, publicKey: seal, unit: nextUnit(by: coordinator), signingKey: key))
        policy.boxHome[number] = home
        return number
    }

    /// The member whose box has this MeshCore key: a Help&I box added as a member, or nil for a
    /// stock box or one not in the group.
    public func boxMember(key: Data?) -> Member? {
        guard let key, key.count == 32 else { return nil }
        return members.first { $0.signingKey == key }
    }

    /// Whether this box is in `member`'s home: it calls under their unit, or a coordinator chose
    /// them for it. Merely having set it up, or being connected to it, never makes it anyone's,
    /// and another box is no one's home, whatever an older phone chose.
    public func box(_ box: Member, isHomeOf member: Member) -> Bool {
        (box.unit != nil && box.unit == member.unit) || (policy.boxHome[box.number] == member.number && !isBox(member))
    }

    /// Whether this member is a Help&I box: every box added is given a home. Only people are homes.
    public func isBox(_ member: Member) -> Bool { policy.boxHome[member.number] != nil }

    /// Whether this box is in anyone's home. One added before its home had to be chosen, or whose
    /// person has left the group, is in no one's.
    public func hasHome(_ box: Member) -> Bool {
        members.contains { $0.number != box.number && self.box(box, isHomeOf: $0) }
    }

    /// Whether `member` is the caller on `unit` or the household of the Help&I box calling on it.
    /// Their own phone carries such a call and is never alerted for it, so every phone leaves them
    /// out of its escalation order alike.
    public func isHousehold(_ member: Member, ofUnit unit: UInt32) -> Bool {
        member.unit == unit || self.member(unit: unit).map { box($0, isHomeOf: member) } == true
    }
}
