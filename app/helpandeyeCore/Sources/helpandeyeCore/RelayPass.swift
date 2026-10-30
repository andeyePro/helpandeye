import Foundation

/// A relay pass: Help&I's say-so that a group may use its relay until a date (relay/src/pass.js),
/// issued by Help&I and pasted in by a coordinator. Only the relay can check its signature, and
/// only the relay need; the phone reads the group and expiry, to refuse a pass for another group
/// when it is pasted and to say until when the group's pass is good.
public struct RelayPass: Equatable, Sendable {
    public let groupID: String
    public let expiry: Date
    public let token: String

    /// A pass has no spaces, so any in a pasted one were put there on the way (a message wrapping a
    /// long line) and are dropped. The form is the relay's (pass.js, FORM).
    public init?(_ token: String) {
        let parts = token.filter { !$0.isWhitespace }.components(separatedBy: ".")
        guard parts.count == 4, parts[0] == "1", parts[1].range(of: #"^[A-Za-z0-9_-]{16,64}$"#, options: .regularExpression) != nil,
              parts[3].range(of: #"^[A-Za-z0-9_-]{86}$"#, options: .regularExpression) != nil,
              parts[2].range(of: #"^[0-9]{1,12}$"#, options: .regularExpression) != nil, let seconds = Int64(parts[2]) else { return nil }
        groupID = parts[1]
        expiry = Date(timeIntervalSince1970: TimeInterval(seconds))
        self.token = parts.joined(separator: ".")
    }

    public func isFor(_ group: GroupSecrets) -> Bool { groupID == RelayProtocol.id(of: group.groupID) }

    /// Whether a group's pass is good at `now`, in words a coordinator can act on.
    public enum State: Equatable, Sendable {
        case none
        case valid(until: Date)
        case expired(on: Date)
    }
}

extension GroupState {
    /// The group's pass, if it holds one that reads as a pass for this group.
    public var pass: RelayPass? { relayPass.flatMap(RelayPass.init).flatMap { $0.isFor(secrets) ? $0 : nil } }

    public func passState(at now: Date) -> RelayPass.State {
        guard let pass else { return .none }
        return pass.expiry > now ? .valid(until: pass.expiry) : .expired(on: pass.expiry)
    }
}
