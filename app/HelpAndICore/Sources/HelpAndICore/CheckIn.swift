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

    public init(times: [Int], grace: TimeInterval = 30 * 60) {
        self.times = Array(Set(times.filter { (0..<1440).contains($0) })).sorted()
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
