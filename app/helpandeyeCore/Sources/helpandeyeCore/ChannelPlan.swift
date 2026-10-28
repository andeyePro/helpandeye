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

    public struct Result: Equatable, Sendable {
        /// Slots to write, in order.
        public let writes: [Write]
        /// Where the current and previous channels will be once the writes are done.
        public let current: UInt8?
        public let previous: UInt8?
    }

    /// `secrets` is the current channel secret first, then the previous one during a changeover.
    /// A slot is free if it is empty, or was written by Help&I for a key the group no longer uses.
    public static func plan(slots: [Slot], secrets: [Data]) -> Result {
        var free = slots.filter { s in
            let empty = s.name.isEmpty && !s.secret.contains(where: { $0 != 0 })
            let stale = s.name.hasPrefix("Help&I") && !secrets.contains(s.secret)
            return empty || stale
        }.map(\.index).sorted()
        var writes: [Write] = []
        var placed: [UInt8?] = []
        for (n, secret) in secrets.prefix(2).enumerated() {
            if let found = slots.first(where: { $0.secret == secret })?.index {
                placed.append(found)
            } else if !free.isEmpty {
                let i = free.removeFirst()
                writes.append(Write(index: i, name: n == 0 ? "Help&I" : "Help&I old", secret: secret))
                placed.append(i)
            } else {
                placed.append(nil)
            }
        }
        return Result(writes: writes, current: placed.first ?? nil, previous: placed.count > 1 ? placed[1] : nil)
    }

    /// For one box serving several groups (MeshHub): `groups` is each group's current secret, then
    /// its previous one during a changeover, in order of group. Current channels are placed before
    /// any previous one, so a full box keeps every group able to call. Returns the slots to write
    /// and where each secret will be.
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
        for (group, n, secret) in order where channels[secret] == nil {
            if let found = slots.first(where: { $0.secret == secret })?.index {
                channels[secret] = found
            } else if !free.isEmpty {
                let i = free.removeFirst()
                let base = group == 0 ? "Help&I" : "Help&I \(group + 1)"
                writes.append(Write(index: i, name: n == 0 ? base : base + " old", secret: secret))
                channels[secret] = i
            }
        }
        return (writes, channels)
    }
}
