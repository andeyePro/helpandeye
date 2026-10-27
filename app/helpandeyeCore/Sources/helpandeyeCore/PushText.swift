import Foundation

/// What a notification says when a relay push arrives, worked out on the phone: the relay cannot
/// read who called, so its push says only that the group has a call. A notification service
/// extension opens the sealed message the push carries and names the caller. It never says help
/// is coming.
public enum PushText {
    public struct Text: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    /// Nil when the message cannot be opened or is not a call, so the generic text stays.
    public static func describe(sealed: String, group: GroupState, at now: Date) -> Text? {
        guard let frame = RelayProtocol.open(sealed, with: group.listening(at: now)),
              case let .call(unit, _, colour, _) = frame else { return nil }
        let who = group.member(unit: unit)?.name ?? "Unit \(unit)"
        let what = switch colour {
        case .red: "come now"
        case .amber: "come when convenient"
        case .green: "I'm OK now"
        }
        return Text(title: "\(who): \(what)", body: "Open Help&I to acknowledge.")
    }
}
