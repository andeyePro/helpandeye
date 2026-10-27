import Foundation

/// Reading the group's messages from the relay: where to start, which messages to act on, and
/// where to carry on next time (relay/src/relay.js `since`). Kept here so it can be tested: a
/// mistake loses calls on the internet route without a sound.
public enum RelayPoll {
    public struct Message: Decodable, Equatable, Sendable {
        public let seq: Int
        /// Milliseconds since 1970, when the relay stored it.
        public let at: Double
        public let sealed: String
    }

    public struct Page: Decodable, Equatable, Sendable {
        public let latest: Int
        /// The last sequence number the relay looked at, kept or expired.
        public let next: Int
        /// The log's name; a different one means the relay was reset.
        public let epoch: String?
        public let messages: [Message]
    }

    /// Where a phone is in a group's log on the relay.
    public struct Position: Codable, Equatable, Sendable {
        public let epoch: String?
        public let seq: Int
        /// Messages up to this one belong to a first read (after a reset): only recent ones count.
        public var firstUntil: Int?

        public init(epoch: String?, seq: Int, firstUntil: Int? = nil) { self.epoch = epoch; self.seq = seq; self.firstUntil = firstUntil }

        /// A saved place: this form, or the plain number earlier versions saved.
        public static func saved(_ value: Any?) -> Position? {
            if let d = value as? Data { return try? JSONDecoder().decode(Position.self, from: d) }
            if let n = value as? Int { return Position(epoch: nil, seq: n) }
            return nil
        }
    }

    /// A first read asks for this many of the latest messages...
    public static let firstRead = 200
    /// ...and acts only on those this recent. Every open call is sent again at least this often
    /// (`Resend.steady`), so a call still open is heard at once and a week of old ones is not.
    public static let recentWindow: TimeInterval = 15 * 60
    /// The relay returns at most this many messages a time.
    public static let pageSize = 200

    /// What `after` to ask for.
    public static func after(_ position: Position?) -> Int { position?.seq ?? -firstRead }

    public struct Outcome: Equatable, Sendable {
        public let frames: [HelpFrame]
        public let position: Position
        /// More messages are waiting: read again at once.
        public let more: Bool
    }

    public static func read(_ page: Page, from position: Position?, at now: Date, keys: [GroupSecrets]) -> Outcome {
        // The relay was reset (a new log name, or a place past its end): this phone's place means
        // nothing. Start again as a first read, from the beginning of the new log.
        // A log name the relay does not give is unknown, not changed.
        let renamed = position.map { $0.epoch != nil && page.epoch != nil && $0.epoch != page.epoch } ?? false
        let reset = renamed || (position.map { $0.seq > page.latest } ?? false)
        if reset {
            let start = max(page.latest - firstRead, 0)
            return Outcome(frames: [], position: Position(epoch: page.epoch, seq: start, firstUntil: page.latest), more: true)
        }
        let firstUntil = position == nil ? page.latest : position?.firstUntil
        let recent = now.addingTimeInterval(-recentWindow).timeIntervalSince1970 * 1000
        let frames = page.messages.sorted { $0.seq < $1.seq }
            .filter { m in firstUntil.map { m.seq > $0 } ?? true || m.at >= recent }
            .compactMap { RelayProtocol.open($0.sealed, with: keys) }
        let next = max(position?.seq ?? 0, page.next)
        let stillFirst = firstUntil.flatMap { next < $0 ? $0 : nil }
        return Outcome(frames: frames, position: Position(epoch: page.epoch ?? position?.epoch, seq: next, firstUntil: stillFirst),
                       more: next < page.latest)
    }
}
