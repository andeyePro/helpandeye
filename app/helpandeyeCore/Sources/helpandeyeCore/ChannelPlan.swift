import Foundation

/// Which of the box's channel slots hold the group's channels, and which to write. Kept free of
/// Bluetooth so it can be tested: a box's slots are few (1, 8 or 40), and a full box during a
/// changeover must recover once the old channel is no longer needed.
public enum ChannelPlan {
    public struct Slot: Equatable, Sendable {
        public let index: UInt8
        public let name: String
        public let secret: Data
        public init(index: UInt8, name: String, secret: Data) { self.index = index; self.name = name; self.secret = secret }
    }

    public struct Write: Equatable, Sendable {
        public let index: UInt8
        public let name: String
        public let secret: Data
    }

    /// Where each group's channels go on a box (several groups can share one, MeshHub): `groups`
    /// is each group's current secret, then its previous one during a changeover, in order of
    /// group. A slot is free if it is empty, or was written by Help&I for a key no group uses.
    /// Current channels come first: if there is no free slot for one, it takes a slot holding a
    /// previous channel, so a group in a changeover never keeps another group off the box. Only
    /// when every slot holds someone else's channel or a current one does a group go without.
    /// Returns the slots to write and where each secret will be.
    public static func plan(slots: [Slot], groups: [[Data]]) -> (writes: [Write], channels: [Data: UInt8]) {
        let wanted = Set(groups.flatMap { $0.prefix(2) })
        var free = slots.filter { s in
            let empty = s.name.isEmpty && !s.secret.contains(where: { $0 != 0 })
            let stale = s.name.hasPrefix("Help&I") && !wanted.contains(s.secret)
            return empty || stale
        }.map(\.index).sorted()
        var writes: [Write] = []
        var channels: [Data: UInt8] = [:]
        // Every group's current channel first, then the old ones.
        let order = groups.enumerated().compactMap { g in g.element.first.map { (g.offset, 0, $0) } }
            + groups.enumerated().compactMap { g in g.element.count > 1 ? (g.offset, 1, g.element[1]) : nil }
        let previous = Set(groups.compactMap { $0.count > 1 ? $0[1] : nil })
        let current = Set(groups.compactMap(\.first))
        var given: Set<Data> = []
        for (group, n, secret) in order where channels[secret] == nil {
            let base = group == 0 ? "Help&I" : "Help&I \(group + 1)"
            let used = Set(channels.values)
            if !given.contains(secret), let found = slots.first(where: { $0.secret == secret })?.index {
                channels[secret] = found
            } else if !free.isEmpty {
                let i = free.removeFirst()
                writes.append(Write(index: i, name: n == 0 ? base : base + " old", secret: secret))
                channels[secret] = i
            } else if n == 0, let taken = slots.first(where: { previous.contains($0.secret) && !current.contains($0.secret) && !used.contains($0.index) }) {
                // A previous channel gives way to a current one.
                given.insert(taken.secret)
                channels[taken.secret] = nil
                writes.append(Write(index: taken.index, name: base, secret: secret))
                channels[secret] = taken.index
            }
        }
        return (writes, channels)
    }
}
