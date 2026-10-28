import Foundation

/// A named set of caller settings that a coordinator gives people, such as "Living alone" or
/// "Lone worker" (app spec, Profiles). For each setting the coordinator chooses whether the person
/// may change it on their own phone. The safety rules are not settings: nothing here can close a
/// call on its own, hide the cross or remove the 999 notice.
public struct Profile: Codable, Equatable, Sendable, Identifiable {
    /// What a person may be allowed to change for themselves.
    public enum Setting: String, Codable, Sendable, CaseIterable {
        case buttons, sounds, afterOK, shareWhere, textFallback, checkIns
    }

    /// What each button shows.
    public enum Face: String, Codable, Sendable, CaseIterable { case wordsAndSymbol, words, symbol }

    /// The sound when a call could not be sent: a soft "eeh-ooh", high then low, by default.
    public enum NotSentSound: String, Codable, Sendable, CaseIterable { case eehOoh, buzzer, none }

    /// The sound when a responder has seen the call.
    public enum SeenSound: String, Codable, Sendable, CaseIterable { case chime, none }

    /// What I'm OK does while Help or Need a hand is open (decision 6).
    public enum AfterOK: String, Codable, Sendable, CaseIterable {
        /// The caller closes the call.
        case closesCall
        /// The urgent repeats stop, but the call stays open until a responder has checked.
        case stopsRepeats
    }

    public var id: UInt8
    public var name: String
    public var face = Face.wordsAndSymbol
    /// The coordinator's own words, by `ButtonWords` key; the app's own otherwise.
    public var buttonWords: [String: String] = [:]
    /// Apple symbol names, by `ButtonWords` colour key; the app's own otherwise.
    public var symbols: [String: String] = [:]
    public var soundsAndSpeech = true
    public var notSent = NotSentSound.eehOoh
    public var seen = SeenSound.chime
    public var afterOK = AfterOK.stopsRepeats
    /// What the caller hears after I'm OK closes or calms a call; the app's own when empty.
    public var okWords = ""
    public var shareWhere = false
    /// Offer a ready-written text to responders when nothing else got through.
    public var textFallback = true
    /// The check-ins this profile asks for, if the person may not choose their own.
    public var checkIns: CheckInSchedule?
    /// How long before the next responder is alerted, for Help and for Need a hand.
    public var redInterval: TimeInterval = 120
    public var amberInterval: TimeInterval = 900
    /// Whether the caller may close their own call (decision 6).
    public var callerMayClose = false
    /// Show the caller only the three buttons, with no settings page.
    public var hidesSettings = false
    public var personMayChange: Set<Setting> = [.sounds, .shareWhere, .textFallback, .checkIns]

    public init(id: UInt8, name: String) { self.id = id; self.name = name }

    public static let standard = Profile(id: 0, name: "Standard")

    public static func standardSymbol(_ colour: Colour) -> String {
        switch colour { case .red: "hand.raised.fill"; case .amber: "hands.and.sparkles.fill"; case .green: "checkmark" }
    }

    /// Symbols a coordinator can choose from.
    public static let symbolChoices = ["hand.raised.fill", "hands.and.sparkles.fill", "checkmark", "sos", "exclamationmark.triangle.fill",
                                       "bell.fill", "phone.fill", "house.fill", "heart.fill", "hand.thumbsup.fill", "figure.wave"]

    public func symbol(_ colour: Colour) -> String {
        symbols[ButtonWords.key(colour)].flatMap { $0.isEmpty ? nil : $0 } ?? Self.standardSymbol(colour)
    }

    public var showsWords: Bool { face != .symbol }
    public var showsSymbol: Bool { face != .words }

    public func mayChange(_ setting: Setting) -> Bool { personMayChange.contains(setting) }

    /// This profile with the person's own choices taken in, for each setting they may change.
    /// Their check-ins are the engine's (`SavedState.checkIn`), so are not taken from `own`.
    public func applying(_ own: Profile?) -> Profile {
        guard let own else { return self }
        var p = self
        if mayChange(.buttons) { p.face = own.face; p.buttonWords = own.buttonWords; p.symbols = own.symbols }
        if mayChange(.sounds) { p.soundsAndSpeech = own.soundsAndSpeech; p.notSent = own.notSent; p.seen = own.seen }
        if mayChange(.afterOK) { p.afterOK = own.afterOK; p.okWords = own.okWords }
        if mayChange(.shareWhere) { p.shareWhere = own.shareWhere }
        if mayChange(.textFallback) { p.textFallback = own.textFallback }
        return p
    }

    /// What the caller hears after pressing I'm OK while a call was open.
    public var okSpoken: String { okWords.isEmpty ? okSpokenStandard : okWords }

    public var okSpokenStandard: String {
        switch afterOK {
        case .closesCall: return "Your call is closed. Thank you for letting us know you're OK."
        case .stopsRepeats: return "Your responders have been told you're OK. One of them will still check on you."
        }
    }

    // Read tolerantly, so a profile from an older or newer phone still loads.
    enum CodingKeys: String, CodingKey {
        case id, name, face, buttonWords, symbols, soundsAndSpeech, notSent, seen, afterOK, okWords, shareWhere, textFallback
        case checkIns, redInterval, amberInterval, callerMayClose, hidesSettings, personMayChange
    }

    /// Only what differs from the app's own, so codes and settings frames stay short.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let s = Profile(id: id, name: name)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        func put<T: Encodable & Equatable>(_ value: T, _ standard: T, _ key: CodingKeys) throws {
            if value != standard { try c.encode(value, forKey: key) }
        }
        try put(face, s.face, .face)
        try put(buttonWords, s.buttonWords, .buttonWords)
        try put(symbols, s.symbols, .symbols)
        try put(soundsAndSpeech, s.soundsAndSpeech, .soundsAndSpeech)
        try put(notSent, s.notSent, .notSent)
        try put(seen, s.seen, .seen)
        try put(afterOK, s.afterOK, .afterOK)
        try put(okWords, s.okWords, .okWords)
        try put(shareWhere, s.shareWhere, .shareWhere)
        try put(textFallback, s.textFallback, .textFallback)
        try c.encodeIfPresent(checkIns, forKey: .checkIns)
        try put(redInterval, s.redInterval, .redInterval)
        try put(amberInterval, s.amberInterval, .amberInterval)
        try put(callerMayClose, s.callerMayClose, .callerMayClose)
        try put(hidesSettings, s.hidesSettings, .hidesSettings)
        try put(personMayChange.map(\.rawValue).sorted(), s.personMayChange.map(\.rawValue).sorted(), .personMayChange)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = Profile(id: try c.decode(UInt8.self, forKey: .id), name: try c.value(.name, or: ""))
        id = s.id; name = s.name
        face = (try? c.decodeIfPresent(Face.self, forKey: .face)) ?? s.face
        buttonWords = try c.value(.buttonWords, or: [:])
        symbols = try c.value(.symbols, or: [:])
        soundsAndSpeech = try c.value(.soundsAndSpeech, or: s.soundsAndSpeech)
        notSent = (try? c.decodeIfPresent(NotSentSound.self, forKey: .notSent)) ?? s.notSent
        seen = (try? c.decodeIfPresent(SeenSound.self, forKey: .seen)) ?? s.seen
        afterOK = (try? c.decodeIfPresent(AfterOK.self, forKey: .afterOK)) ?? s.afterOK
        okWords = try c.value(.okWords, or: "")
        shareWhere = try c.value(.shareWhere, or: s.shareWhere)
        textFallback = try c.value(.textFallback, or: s.textFallback)
        checkIns = try c.decodeIfPresent(CheckInSchedule.self, forKey: .checkIns)
        redInterval = try c.value(.redInterval, or: s.redInterval)
        amberInterval = try c.value(.amberInterval, or: s.amberInterval)
        callerMayClose = try c.value(.callerMayClose, or: s.callerMayClose)
        hidesSettings = try c.value(.hidesSettings, or: s.hidesSettings)
        let settings = (try? c.decodeIfPresent([String].self, forKey: .personMayChange)).flatMap { $0 }
        personMayChange = settings.map { Set($0.compactMap(Setting.init)) } ?? s.personMayChange
    }
}

extension GroupState {
    /// The profile a member has: the one their coordinator gave them, or the group's first.
    public func profile(of member: UInt16?) -> Profile {
        let id = member.flatMap { policy.profileOf[$0] }
        return policy.profiles.first { $0.id == id } ?? policy.profiles.first ?? .standard
    }

    public func profile(ofUnit unit: UInt32?) -> Profile { profile(of: unit.flatMap { member(unit: $0) }?.number) }

    /// The number for a new profile.
    public var nextProfileID: UInt8? {
        let used = Set(policy.profiles.map(\.id))
        return (0...UInt8.max).first { !used.contains($0) }
    }

    /// Whether a profile that hides the settings page is given to someone while the group has only
    /// one coordinator, so a second should be suggested.
    public var needsSecondCoordinator: Bool {
        members.filter { $0.role == .coordinator }.count < 2
            && members.contains { m in m.canCall && profile(of: m.number).hidesSettings }
    }
}
