import Foundation

/// The watch complication's countdown (app spec, Watch app): 60 seconds shown in the red button,
/// a tap on the wrist every 10, spoken words at 30 seconds left, and Help sent at 0 unless the
/// wearer presses I'm OK. It is for someone who may not manage a press: they need do nothing.
public struct HelpCountdown: Equatable, Sendable {
    public enum Event: Equatable, Sendable { case vibrate, warn, send }

    public static let length: TimeInterval = 60
    public let startedAt: Date

    public init(startedAt: Date) { self.startedAt = startedAt }

    /// Whole seconds left, as shown in the red button.
    public func remaining(at now: Date) -> Int {
        max(0, Int((Self.length - now.timeIntervalSince(startedAt)).rounded(.up)))
    }

    /// What is due in (from, to], in order: a tap at each 10-second mark, the warning at 30
    /// seconds left, and the call at the end. A late wake does them all, the call last.
    public func events(from: Date, to: Date) -> [Event] {
        let a = from.timeIntervalSince(startedAt), b = to.timeIntervalSince(startedAt)
        var out: [Event] = []
        for mark in stride(from: 10.0, to: Self.length, by: 10) where a < mark && mark <= b {
            out.append(.vibrate)
            if mark == Self.length - 30 { out.append(.warn) }
        }
        if a < Self.length && Self.length <= b { out.append(.send) }
        return out
    }

    /// What the wearer hears at 30 seconds left, in their own button words.
    public static func warning(in profile: Profile?) -> String {
        "Calling for help in 30 seconds. Press \(ButtonWords.words(.green, in: profile)) to stop, or \(ButtonWords.words(.red, in: profile)) to ask for help now."
    }
}
