import Foundation

/// The words on the caller's buttons. A coordinator can set their own in each profile (decision
/// 15: button labels are set per deployment); any left blank keep the app's.
public enum ButtonWords {
    public static let longest = 40
    /// What a caller is told, shown and spoken, after asking for a hand: longer than a button's words.
    public static let amberNoteKey = "amber.note"
    public static let longestNote = 160

    public static func key(_ colour: Colour) -> String {
        switch colour { case .red: "red"; case .amber: "amber"; case .green: "green" }
    }

    public static func key(_ category: CallCategory) -> String { "category.\(category.rawValue)" }

    public static func standard(_ colour: Colour) -> String {
        switch colour { case .red: "Help"; case .amber: "Need a hand"; case .green: "I'm OK" }
    }

    public static func standard(_ category: CallCategory) -> String {
        switch category {
        case .fallen: "I've fallen"; case .unwell: "I feel unwell"; case .lockedOut: "I'm locked out"
        case .powerCut: "Power cut"; case .needCompany: "I'd like company"; case .missedCheckIn: "Missed a check-in"
        case .other: "Something else"; case .withdrawn: ""
        }
    }

    public static func words(_ colour: Colour, in profile: Profile?) -> String {
        chosen(key(colour), in: profile) ?? standard(colour)
    }

    public static func amberNote(in profile: Profile?) -> String {
        chosen(amberNoteKey, in: profile)
            ?? "You have requested non-urgent assistance. If you need help sooner, please press \(words(.red, in: profile))."
    }

    public static func words(_ category: CallCategory, in profile: Profile?) -> String {
        chosen(key(category), in: profile) ?? standard(category)
    }

    /// Sets or, with blank words, clears one button's words. Words are trimmed and cut to fit.
    public static func set(_ words: String, for key: String, in profile: inout Profile) {
        let trimmed = String(words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(key == amberNoteKey ? longestNote : longest))
        profile.buttonWords[key] = trimmed.isEmpty ? nil : trimmed
    }

    /// Words such as SOS can be read as an emergency service, so the coordinator is warned to make
    /// doubly clear that Help&I does not replace 999.
    public static func soundsLikeEmergencyService(_ words: String) -> Bool {
        let w = words.lowercased()
        return ["sos", "999", "112", "911", "emergency", "ambulance"].contains { w.contains($0) }
    }

    private static func chosen(_ key: String, in profile: Profile?) -> String? {
        profile?.buttonWords[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}
