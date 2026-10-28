import Foundation

/// Which group an acknowledgement made on the watch belongs to: the group it names, or, from a
/// watch too old to name one, the only group holding that call open. Never a guess: with two
/// groups holding the same unit and request numbers, none.
public enum AckRouting {
    public static func group(named tag: String?, holding: [String]) -> String? {
        if let tag, !tag.isEmpty { return tag }
        return holding.count == 1 ? holding[0] : nil
    }
}

/// What a phone gives its paired watch so the watch can call for help and respond when the phone
/// is out of reach: the group, the owner's member number, and the owner's keys, so the watch acts
/// as the same member. It goes only to the owner's own paired watch, which keeps it as the phone
/// does (decision 12; a lost watch is removed from the group like a lost phone).
public struct WatchHandover: Codable, Equatable, Sendable {
    public let group: GroupState
    public let me: UInt16
    public let keys: Data
    /// Other groups the owner responds in, so the watch hears their calls too.
    public var others: [Part] = []
    /// The owner's own choices for their profile, so the watch looks and sounds as the phone does.
    public var own: Profile?
    public var ownChosen: Set<Profile.Setting> = []

    public struct Part: Codable, Equatable, Sendable {
        public let group: GroupState
        public let me: UInt16
    }

    public init(saved: SavedState, identity: DeviceIdentity, others: [SavedState] = []) {
        group = saved.group; me = saved.me; keys = identity.rawRepresentation; own = saved.own; ownChosen = saved.ownChosen
        self.others = others.map { Part(group: $0.group, me: $0.me) }
    }

    /// One handover per group, the first group's first, each as if it were the only one.
    public var each: [WatchHandover] {
        var first = WatchHandover(group: group, me: me, keys: keys)
        first.own = own
        first.ownChosen = ownChosen
        return [first] + others.map { WatchHandover(group: $0.group, me: $0.me, keys: keys) }
    }

    init(group: GroupState, me: UInt16, keys: Data) { self.group = group; self.me = me; self.keys = keys }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decode(GroupState.self, forKey: .group)
        me = try c.decode(UInt16.self, forKey: .me)
        keys = try c.decode(Data.self, forKey: .keys)
        others = try c.decodeIfPresent([Part].self, forKey: .others) ?? []
        own = try c.decodeIfPresent(Profile.self, forKey: .own)
        ownChosen = try c.decodeIfPresent(Set<Profile.Setting>.self, forKey: .ownChosen) ?? []
    }

    public var identity: DeviceIdentity? { try? DeviceIdentity(rawRepresentation: keys) }

    /// The watch's state after taking in a handover: the phone's group and place, with the watch's
    /// own call numbering kept so a repeated or newer handover never reuses a number.
    public func state(keeping current: SavedState?) -> SavedState {
        var s = SavedState(group: group, me: me)
        s.own = own
        s.ownChosen = ownChosen
        if let current, current.me == me, current.group.secrets.groupID == group.secrets.groupID {
            s.lastRequest = current.lastRequest
        }
        return s
    }
}
