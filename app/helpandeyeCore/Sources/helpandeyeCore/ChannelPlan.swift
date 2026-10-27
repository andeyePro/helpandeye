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
}
