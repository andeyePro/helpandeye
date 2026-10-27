import Foundation

/// An opt-in check-in schedule (decision 16): the caller presses green at agreed times, and a
/// missed check-in raises an amber request to the responders. It is off unless the caller turns
/// it on. Responders' phones watch the schedule too, so a check-in is missed even if the caller's
/// phone is flat.
public struct CheckInSchedule: Codable, Equatable, Sendable {
    /// Minutes after local midnight, such as 540 for 09:00.
    public var times: [Int]
    /// How long after each time a green press still counts.
    public var grace: TimeInterval

    /// At most four a day: each takes a reminder from the 64 notifications iOS allows.
    public static let maxTimes = 4

    public init(times: [Int], grace: TimeInterval = 30 * 60) {
        self.times = Array(Array(Set(times.filter { (0..<1440).contains($0) })).sorted().prefix(Self.maxTimes))
        self.grace = max(grace, 60)
    }

    /// The scheduled moments in [from, until), in the given calendar's time zone.
    public func moments(from: Date, until: Date, calendar: Calendar) -> [Date] {
        guard !times.isEmpty, from < until else { return [] }
        var out: [Date] = []
        var day = calendar.startOfDay(for: from.addingTimeInterval(-grace))
        while day < until {
            for t in times {
                // Set the wall-clock time rather than adding minutes, so 09:00 stays 09:00 on the
                // days the clocks change.
                if let m = calendar.date(bySettingHour: t / 60, minute: t % 60, second: 0, of: day),
                   m >= from.addingTimeInterval(-grace), m < until { out.append(m) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// The most recent check-in that was due by `now`, its grace has run out, and no green press
    /// came within its window. A green earlier than the window does not count for it.
    public func missed(greens: [Date], since: Date, now: Date, calendar: Calendar) -> Date? {
        moments(from: since, until: now, calendar: calendar).last { m in
            m.addingTimeInterval(grace) <= now && m >= since &&
                !greens.contains { $0 >= m.addingTimeInterval(-grace) && $0 <= m.addingTimeInterval(grace) }
        }
    }
}

/// A responder's phone watches every caller's check-ins as well, so a missed one is raised even if
/// the caller's own phone is flat or off.
public struct CheckInWatch: Codable, Equatable, Sendable {
    public struct Caller: Codable, Equatable, Sendable {
        public var schedule: CheckInSchedule
        public var since: Date
        public var greens: [Date] = []
        /// Missed check-ins this phone has already raised or heard about, so each is raised once.
        public var handled: [Date] = []
    }

    public private(set) var callers: [UInt32: Caller] = [:]
    /// How long after a check-in's grace runs out to wait for the caller's own phone to raise it,
    /// before this phone raises it instead.
    public static let wait: TimeInterval = 5 * 60

    public init() {}

    /// Stops watching anyone no longer in the group.
    public mutating func keepOnly(units: Set<UInt32>) {
        callers = callers.filter { units.contains($0.key) }
    }

    public mutating func apply(_ frame: HelpFrame) {
        switch frame {
        case let .checkIns(unit, since, grace, times):
            if times.isEmpty { callers[unit] = nil; return }
            let schedule = CheckInSchedule(times: times.map(Int.init), grace: TimeInterval(grace) * 60)
            callers[unit] = Caller(schedule: schedule, since: Date(timeIntervalSince1970: TimeInterval(since)),
                                   greens: callers[unit]?.greens ?? [])
        case let .call(unit, _, .green, sentAt):
            callers[unit]?.greens.append(Date(timeIntervalSince1970: TimeInterval(sentAt)))
            callers[unit]?.greens.removeAll { $0 < Date(timeIntervalSince1970: TimeInterval(sentAt)).addingTimeInterval(-3 * 86_400) }
        default: break
        }
    }

    /// The caller's own phone raised this missed check-in (an amber call with the missed-check-in
    /// category), so this phone need not.
    public mutating func heardRaised(unit: UInt32, at now: Date, calendar: Calendar) {
        guard let c = callers[unit], let m = c.schedule.missed(greens: c.greens, since: c.since, now: now, calendar: calendar) else { return }
        callers[unit]?.handled.append(m)
    }

    /// Missed check-ins to raise now: past their grace and the wait, not covered by a green, and
    /// not raised by the caller's phone.
    public mutating func due(at now: Date, calendar: Calendar) -> [(unit: UInt32, missed: Date)] {
        var out: [(UInt32, Date)] = []
        for (unit, c) in callers {
            guard let m = c.schedule.missed(greens: c.greens, since: c.since, now: now.addingTimeInterval(-Self.wait), calendar: calendar),
                  !c.handled.contains(m) else { continue }
            callers[unit]?.handled.append(m)
            out.append((unit, m))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
