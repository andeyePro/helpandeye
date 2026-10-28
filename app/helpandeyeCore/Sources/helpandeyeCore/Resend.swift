import Foundation

/// A call goes out again and again until a responder's signed acknowledgement comes back, because
/// one lost radio packet or a responder's box being off for a moment must never mean nobody is
/// alerted. Resends back off, then settle at every ten minutes, and never stop on a timer.
public enum Resend {
    /// Gaps before each resend, in order; after the last, every `steady` seconds.
    public static let gaps: [TimeInterval] = [30, 60, 120, 240]
    public static let steady: TimeInterval = 600

    /// When resend number `n` (1 for the first) is due, counted from the press.
    public static func due(_ n: Int, after press: Date) -> Date {
        guard n > 0 else { return press }
        let early = gaps.prefix(n).reduce(0, +)
        let later = TimeInterval(max(n - gaps.count, 0)) * steady
        return press.addingTimeInterval(early + later)
    }
}

extension OutgoingRequest {
    /// True when the call should go out again now: nobody has acknowledged or closed it, and its
    /// next resend time has come. Only a person ends resending. A caller who said they are OK is
    /// still sent, with that news, so a responder who missed both still comes to check.
    public func resendDue(at now: Date) -> Bool {
        if case .seen = status { return false }
        if case .closed = status { return false }
        // "I'm OK" is repeated a few times against lost packets, then left: it asks for no one.
        if colour == .green && resends >= Resend.gaps.count { return false }
        return now >= Resend.due(resends + 1, after: createdAt)
    }

    public var nextResend: Date? {
        if case .seen = status { return nil }
        if case .closed = status { return nil }
        return Resend.due(resends + 1, after: createdAt)
    }
}

/// When a responder's phone alerts its own person: from their turn in the escalation, then again
/// every `every` seconds, so one dismissed or missed notification does not end their part. The
/// phone cancels them all when it hears an acknowledgement, and tops them up whenever it runs.
public func alertTimes(turnAt: Date, every: TimeInterval, from now: Date, count: Int) -> [Date] {
    guard count > 0, every > 0 else { return [] }
    let skipped = now > turnAt ? Int(ceil(now.timeIntervalSince(turnAt) / every)) : 0
    return (skipped..<(skipped + count)).map { turnAt.addingTimeInterval(TimeInterval($0) * every) }
}

/// Alert times that last for hours from a fixed number of notifications: `quick` at `every`,
/// then the rest every `later`. iOS keeps at most 64 pending notifications, and with the app
/// asleep nothing can top them up, so the tail must stretch.
public func alertTimes(turnAt: Date, every: TimeInterval, quick: Int, later: TimeInterval, from now: Date, count: Int) -> [Date] {
    guard count > 0, every > 0, later > 0 else { return [] }
    let early = (0..<quick).map { turnAt.addingTimeInterval(TimeInterval($0) * every) }.filter { $0 >= now.addingTimeInterval(-1) }
    let tailStart = turnAt.addingTimeInterval(TimeInterval(quick) * every)
    let skipped = now > tailStart ? Int(ceil(now.timeIntervalSince(tailStart) / later)) : 0
    let tail = (skipped..<(skipped + count)).map { tailStart.addingTimeInterval(TimeInterval($0) * later) }
    return Array((early + tail).prefix(count))
}
