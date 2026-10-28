import Foundation

/// The group's log (app spec, The log): every press, delivery, acknowledgement, close and settings
/// change a coordinator's phone learns of, with who and when. Each coordinator's phone keeps its
/// own, in its protected storage; nothing about it goes on air. On by default; a coordinator can
/// switch it off for the group.
public struct GroupLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let at: Date
        public let text: String
    }

    /// The newest this many are kept.
    public static let limit = 2000

    public private(set) var entries: [Entry] = []

    public init() {}

    mutating func add(_ text: String, at: Date) {
        entries.append(Entry(at: at, text: text))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The log as plain text, oldest first, for exporting.
    public func text(in zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = zone
        return entries.map { "\(f.string(from: $0.at))  \($0.text)" }.joined(separator: "\n")
    }
}

extension GroupSettings {
    /// What changed, in words, for the log and the other coordinators.
    public func changes(from old: GroupSettings) -> [String] {
        var out: [String] = []
        let before = Dictionary(old.policy.profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in policy.profiles {
            if let o = before[p.id] {
                if o != p { out.append(o.name == p.name ? "changed the profile \(p.name)" : "changed the profile \(o.name), now called \(p.name)") }
            } else {
                out.append("added the profile \(p.name)")
            }
        }
        let now = Set(policy.profiles.map(\.id))
        for p in old.policy.profiles where !now.contains(p.id) { out.append("deleted the profile \(p.name)") }
        if policy.profileOf != old.policy.profileOf { out.append("changed who has which profile") }
        if policy.keepsLog != old.policy.keepsLog { out.append(policy.keepsLog ? "switched the log on" : "switched the log off") }
        if policy.useDistance != old.policy.useDistance { out.append("changed whether distance counts") }
        if relayURL != old.relayURL { out.append("changed the relay address") }
        return out
    }
}
