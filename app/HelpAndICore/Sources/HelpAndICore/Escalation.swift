import Foundation

/// What the app knows about one responder when deciding whom to alert.
public struct ResponderInfo: Equatable, Sendable {
    public let member: UInt16
    public var availableNow: Bool
    /// Straight-line distance to the caller in metres, if the group uses distance and it is known.
    public var distance: Double?
    public var lastAnsweredAt: Date?

    public init(member: UInt16, availableNow: Bool, distance: Double? = nil, lastAnsweredAt: Date? = nil) {
        self.member = member; self.availableNow = availableNow; self.distance = distance; self.lastAnsweredAt = lastAnsweredAt
    }
}

public struct EscalationPolicy: Equatable, Sendable {
    public var useDistance: Bool
    /// Responders within this many metres of each other count as equally close, so that fairness
    /// decides between them.
    public var similarDistance: Double
    public var redInterval: TimeInterval
    public var amberInterval: TimeInterval

    public init(useDistance: Bool = false, similarDistance: Double = 500, redInterval: TimeInterval = 120, amberInterval: TimeInterval = 900) {
        self.useDistance = useDistance; self.similarDistance = similarDistance
        self.redInterval = redInterval; self.amberInterval = amberInterval
    }

    public static let standard = EscalationPolicy()

    public func interval(for colour: Colour) -> TimeInterval { colour == .red ? redInterval : amberInterval }

    /// The order in which available responders are alerted (app spec, "Who is alerted"):
    /// closest first when the group uses distance, then whoever answered least recently.
    public func order(_ responders: [ResponderInfo]) -> [UInt16] {
        let available = responders.filter(\.availableNow)
        func band(_ r: ResponderInfo) -> Int {
            guard useDistance, let d = r.distance, similarDistance > 0 else { return useDistance ? Int.max : 0 }
            return Int(d / similarDistance)
        }
        return available.sorted { a, b in
            let ba = band(a), bb = band(b)
            if ba != bb { return ba < bb }
            switch (a.lastAnsweredAt, b.lastAnsweredAt) {
            case (nil, nil): return a.member < b.member
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x == y ? a.member < b.member : x < y
            }
        }.map(\.member)
    }
}

/// Who should be alerting at a given moment. Escalation only ever adds people; it never stops on
/// its own. It stops only when the app sees an acknowledgement.
public struct Escalation: Equatable, Sendable {
    public let order: [UInt16]
    public let interval: TimeInterval

    public init(order: [UInt16], interval: TimeInterval) {
        self.order = order; self.interval = max(interval, 1)
    }

    public init(colour: Colour, responders: [ResponderInfo], policy: EscalationPolicy = .standard) {
        self.init(order: policy.order(responders), interval: policy.interval(for: colour))
    }

    public struct Stage: Equatable, Sendable {
        public let alerted: [UInt16]
        /// True once the list has run out (or nobody was available): alert the whole group and
        /// its coordinators.
        public let wholeGroup: Bool
    }

    public func stage(after elapsed: TimeInterval) -> Stage {
        guard !order.isEmpty else { return Stage(alerted: [], wholeGroup: true) }
        let step = Int(max(elapsed, 0) / interval)
        if step >= order.count { return Stage(alerted: order, wholeGroup: true) }
        return Stage(alerted: Array(order.prefix(step + 1)), wholeGroup: false)
    }

    /// When the next person is added, or nil once the whole group is already alerted.
    public func nextStep(after elapsed: TimeInterval) -> TimeInterval? {
        guard !order.isEmpty, !stage(after: elapsed).wholeGroup else { return nil }
        return (floor(max(elapsed, 0) / interval) + 1) * interval
    }
}
