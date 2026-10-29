import Foundation

/// What a caller is told about their call, on the phone and on the watch. Kept here so a test can
/// show that only a responder's acknowledgement is ever put as being seen, and that whenever
/// nothing was sent the cross shows and 999 is mentioned (AGENTS.md: help is confirmed by a
/// human; no false reassurance).
public enum StatusWords {
    public struct Words: Equatable, Sendable {
        public let headline: String
        /// The cross: nothing got out.
        public let cross: Bool
        public let call999: Bool
    }

    /// Not sent means no route confirmed it, which is not proof that nobody has it, so it is never
    /// put as "nobody has been told".
    public static func phone(_ status: CallerStatus, name: (UInt16) -> String) -> Words {
        switch status {
        case .sending: .init(headline: "Sending…", cross: false, call999: false)
        case .waitingForResponder: .init(headline: "Sent. Waiting for a responder to see it.", cross: false, call999: false)
        case let .seen(who): .init(headline: "\(name(who)) has seen your call.", cross: false, call999: false)
        case .notSent: .init(headline: "Not sent. Nobody may know you need help.", cross: true, call999: true)
        case let .closed(who): .init(headline: "\(name(who)) closed this call.", cross: false, call999: false)
        }
    }

    public static func watch(_ status: CallerStatus, name: (UInt16) -> String) -> Words {
        switch status {
        case .sending: .init(headline: "Sending…", cross: false, call999: false)
        case .waitingForResponder: .init(headline: "Sent. Waiting for a responder.", cross: false, call999: false)
        case let .seen(who): .init(headline: "\(name(who)) has seen it.", cross: false, call999: false)
        case .notSent: .init(headline: "Not sent. Use your phone, or call 999.", cross: true, call999: true)
        case let .closed(who): .init(headline: "\(name(who)) closed it.", cross: false, call999: false)
        }
    }
}
