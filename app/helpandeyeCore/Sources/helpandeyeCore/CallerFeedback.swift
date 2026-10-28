import Foundation

/// What a caller hears as their call changes, on the phone and on the watch: words when it went,
/// a sound and words when nothing got out, and a reassuring sound and words only when a responder
/// has acknowledged (AGENTS.md: help is confirmed by a human). Sent has no sound, so it can never
/// be mistaken for being seen.
public struct CallerFeedback: Equatable, Sendable {
    public enum Sound: Sendable { case notSent, seen }

    public let sound: Sound?
    public let spoken: String

    public init(sound: Sound?, spoken: String) {
        self.sound = sound
        self.spoken = spoken
    }

    /// What a responder's acknowledge button says, and so what the caller hears they said.
    public static let acknowledgeWords = "I'm dealing with it"

    /// Follows one device's latest call, so each change is heard once. A call already there when
    /// the app starts is not heard again.
    public struct Tracker: Sendable {
        private var last: (unit: UInt32, number: UInt16, status: CallerStatus)?

        public init(_ current: OutgoingRequest?) {
            last = current.map { ($0.unit, $0.number, $0.status) }
        }

        public mutating func update(_ current: OutgoingRequest?, words: String, note: String? = nil, name: (UInt16) -> String) -> CallerFeedback? {
            guard let r = current else { last = nil; return nil }
            let before = last.flatMap { $0.unit == r.unit && $0.number == r.number ? $0.status : nil }
            last = (r.unit, r.number, r.status)
            return CallerFeedback.change(from: before, to: r.status, words: words, note: note, name: name)
        }
    }

    /// Nil when there is nothing new to say. `words` are the pressed button's words; `note` is
    /// said after them once the call has gone (`ButtonWords.amberNote`).
    public static func change(from old: CallerStatus?, to new: CallerStatus, words: String, note: String? = nil,
                              name: (UInt16) -> String) -> CallerFeedback? {
        guard new != old else { return nil }
        switch new {
        case .sending:
            return nil
        case .notSent:
            return .init(sound: .notSent, spoken: "Your \(words) message has not been sent. Try again, or call 999.")
        case .waitingForResponder:
            // Said once, as it goes; not again if a later route also gets it out.
            guard old == nil || old == .sending || old == .notSent else { return nil }
            return .init(sound: nil, spoken: (["Your \(words) message has been sent."] + [note].compactMap { $0 }).joined(separator: " "))
        case let .closed(who):
            return .init(sound: nil, spoken: "\(name(who)) closed your \(words) call.")
        case let .seen(who):
            if case .seen = old { return nil }
            return .init(sound: .seen, spoken: "\(name(who)) has seen your \(words) message, and says: \(acknowledgeWords).")
        }
    }
}
