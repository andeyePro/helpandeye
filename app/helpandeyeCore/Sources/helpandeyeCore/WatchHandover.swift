import Foundation

/// What a phone gives its paired watch so the watch can call for help and respond when the phone
/// is out of reach: the group, the owner's member number, and the owner's keys, so the watch acts
/// as the same member. It goes only to the owner's own paired watch, which keeps it as the phone
/// does (decision 12; a lost watch is removed from the group like a lost phone).
public struct WatchHandover: Codable, Equatable, Sendable {
    public let group: GroupState
    public let me: UInt16
    public let keys: Data

    public init(saved: SavedState, identity: DeviceIdentity) {
        group = saved.group; me = saved.me; keys = identity.rawRepresentation
    }

    public var identity: DeviceIdentity? { try? DeviceIdentity(rawRepresentation: keys) }

    /// The watch's state after taking in a handover: the phone's group and place, with the watch's
    /// own call numbering kept so a repeated or newer handover never reuses a number.
    public func state(keeping current: SavedState?) -> SavedState {
        var s = SavedState(group: group, me: me)
        if let current, current.me == me, current.group.secrets.groupID == group.secrets.groupID {
            s.lastRequest = current.lastRequest
        }
        return s
    }
}
