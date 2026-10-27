import Foundation

/// The group's rota: each responder's stated availability. Every phone keeps a copy and works out
/// gaps for itself, so a coordinator learns of a gap with no network (app spec, "Rota gaps").
public struct Rota: Equatable, Sendable, Codable {
    public struct Entry: Equatable, Sendable, Codable {
        public let responder: UInt16
        public let interval: DateInterval
        public let available: Bool
    }

    /// Later entries override earlier ones where they overlap, so "not available after all" can be
    /// sent as a short mesh message without resending the whole rota.
    public private(set) var entries: [Entry] = []
    /// Everyone who can respond. A responder with no entry covering a moment counts as
    /// `defaultAvailable` then, so a small group works before anyone has filled in a rota.
    public var responders: [UInt16]
    public var defaultAvailable: Bool

    public init(responders: [UInt16] = [], defaultAvailable: Bool = false) {
        self.responders = responders; self.defaultAvailable = defaultAvailable
    }

    public mutating func add(responder: UInt16, from: Date, until: Date, available: Bool) {
        guard from < until else { return }
        entries.append(Entry(responder: responder, interval: DateInterval(start: from, end: until), available: available))
    }

    public mutating func apply(_ frame: HelpFrame) {
        guard case let .availability(who, from, until, available) = frame else { return }
        add(responder: who, from: Date(timeIntervalSince1970: TimeInterval(from)),
            until: Date(timeIntervalSince1970: TimeInterval(until)), available: available)
    }

    public func isAvailable(_ responder: UInt16, at t: Date) -> Bool {
        entries.last { $0.responder == responder && $0.interval.start <= t && t < $0.interval.end }?.available ?? defaultAvailable
    }

    public func available(at t: Date) -> [UInt16] {
        Set(entries.map(\.responder) + responders).filter { isAvailable($0, at: t) }.sorted()
    }

    /// Stretches in the window when nobody is available.
    public func gaps(from start: Date, horizon: TimeInterval = 24 * 3600) -> [DateInterval] {
        let end = start.addingTimeInterval(horizon)
        var points = Set([start, end])
        for e in entries {
            if e.interval.start > start && e.interval.start < end { points.insert(e.interval.start) }
            if e.interval.end > start && e.interval.end < end { points.insert(e.interval.end) }
        }
        let sorted = points.sorted()
        var gaps: [DateInterval] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where available(at: a).isEmpty {
            if let last = gaps.last, last.end == a {
                gaps[gaps.count - 1] = DateInterval(start: last.start, end: b)
            } else {
                gaps.append(DateInterval(start: a, end: b))
            }
        }
        return gaps
    }
}

/// An alert a coordinator must acknowledge, such as a rota gap or the free relay allowance running
/// low. If they do not, it widens: other coordinators, then responders. Like a call for help, it
/// only ever widens and is closed only by a person.
public struct CoordinatorAlert: Equatable, Sendable {
    public enum Audience: Equatable, Sendable { case firstCoordinator, allCoordinators, wholeGroup }
    public let raisedAt: Date
    public let interval: TimeInterval
    public private(set) var acknowledgedBy: UInt16?

    public init(raisedAt: Date, interval: TimeInterval = 3600) {
        self.raisedAt = raisedAt; self.interval = max(interval, 1)
    }

    public mutating func acknowledge(by member: UInt16) { acknowledgedBy = acknowledgedBy ?? member }

    public func audience(at now: Date) -> Audience? {
        guard acknowledgedBy == nil else { return nil }
        switch Int(max(now.timeIntervalSince(raisedAt), 0) / interval) {
        case 0: return .firstCoordinator
        case 1: return .allCoordinators
        default: return .wholeGroup
        }
    }
}
