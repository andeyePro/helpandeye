import helpandeyeCore
import SwiftUI

enum SetByCoordinator {
    static let text = "Set by your coordinator."
}

extension Profile.Face {
    var label: String {
        switch self { case .wordsAndSymbol: "Words and a symbol"; case .words: "Words only"; case .symbol: "A symbol only" }
    }
}

extension Profile.NotSentSound {
    var label: String { switch self { case .eehOoh: "A soft eeh-ooh"; case .buzzer: "A buzzer"; case .none: "No sound" } }
}

extension Profile.SeenSound {
    var label: String { switch self { case .chime: "A chime"; case .none: "No sound" } }
}

extension Profile.AfterOK {
    var label: String {
        switch self {
        case .closesCall: "Trust it: the call closes"
        case .stopsRepeats: "Always check: a responder still checks"
        }
    }
}

/// Plays the chosen sounds, so they can be heard before a call needs them.
struct HearSounds: View {
    let profile: Profile

    var body: some View {
        Button("Hear the not-sent sound") { CallerVoice.shared.play(CallerVoice.file(.notSent, in: profile)) }
        Button("Hear the seen sound") { CallerVoice.shared.play(CallerVoice.file(.seen, in: profile)) }
    }
}

/// The caller's own settings. Those their profile lets them change can be changed here; the
/// others are shown, as set by their coordinator.
struct YourSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var asking = false

    var body: some View {
        let given = model.group?.profile(of: model.saved?.me) ?? .standard
        Section(header: Header("Your settings")) {
            Text("Your profile: \(given.name)")
            if given.mayChange(.buttons) {
                Picker("Your buttons show", selection: own(\.face)) {
                    ForEach(Profile.Face.allCases, id: \.self) { Text($0.label) }
                }
            } else {
                fixed("Your buttons show", model.profile.face.label)
            }
            if given.mayChange(.sounds) {
                Toggle("Sounds and spoken words", isOn: own(\.soundsAndSpeech))
                    .accessibilityHint("Says out loud whether your call went, and when someone has seen it")
                Picker("When a call has not gone", selection: own(\.notSent)) {
                    ForEach(Profile.NotSentSound.allCases, id: \.self) { Text($0.label) }
                }
                Picker("When someone has seen it", selection: own(\.seen)) {
                    ForEach(Profile.SeenSound.allCases, id: \.self) { Text($0.label) }
                }
            } else {
                fixed("Sounds and spoken words", model.profile.soundsAndSpeech ? "On" : "Off")
                fixed("When a call has not gone", model.profile.notSent.label)
                fixed("When someone has seen it", model.profile.seen.label)
            }
            HearSounds(profile: model.profile)
            if given.mayChange(.afterOK) {
                Picker("I'm OK after Help or Need a hand", selection: own(\.afterOK)) {
                    ForEach(Profile.AfterOK.allCases, id: \.self) { Text($0.label) }
                }
            } else {
                fixed("I'm OK after Help or Need a hand", model.profile.afterOK.label)
            }
            let share = "Send where I am with every \(Colour.red.label) or \(Colour.amber.label)"
            if given.mayChange(.shareWhere) { Toggle(share, isOn: own(\.shareWhere)) } else { fixed(share, model.profile.shareWhere ? "On" : "Off") }
            let text = "Offer a text to my responders if nothing else got through"
            if given.mayChange(.textFallback) { Toggle(text, isOn: own(\.textFallback)) } else { fixed(text, model.profile.textFallback ? "On" : "Off") }
            Text("Where you are goes only to your responders, encrypted, after the call itself.")
            if Profile.Setting.allCases.contains(where: { !given.mayChange($0) }) {
                Text("Settings you cannot change are set by your coordinator.")
                Button("Ask the coordinator to change one") { asking = true }
            }
        }
        .sheet(isPresented: $asking) { NavigationStack { AskCoordinatorView(locked: Profile.Setting.allCases.filter { !given.mayChange($0) }) } }
    }

    private func own<T>(_ path: WritableKeyPath<Profile, T>) -> Binding<T> {
        Binding(get: { model.profile[keyPath: path] }, set: { v in model.setOwn { $0[keyPath: path] = v } })
    }

    /// A setting the coordinator has set: shown in words, not as a control that does nothing.
    private func fixed(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text("\(value). \(SetByCoordinator.text)").font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A request to the coordinators to change a setting. Only ever from the settings page, never the
/// call screen, so it cannot be mistaken for a call.
struct AskCoordinatorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let locked: [Profile.Setting]
    @State private var setting: Profile.Setting?
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        Form {
            Section(header: Header("What would you like changed?")) {
                Picker("Setting", selection: $setting) {
                    ForEach(locked, id: \.self) { Text($0.words.prefix(1).uppercased() + $0.words.dropFirst()).tag(Optional($0)) }
                    Text("Something else").tag(Profile.Setting?.none)
                }
                LabeledField(label: "What to change, in a few words", text: $text)
                Button("Send to the coordinators") {
                    Task {
                        let problem = await model.engine.askCoordinator(about: setting, text)
                        result = problem.map { "Not sent: \($0)." } ?? "Sent. A coordinator will see it under Group."
                    }
                }
                .buttonStyle(.action)
                if let result { Text(result) }
            }
        }
        .navigationTitle("Ask the coordinator")
        .keyboardDismissable()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear { setting = locked.first }
    }
}

/// The coordinator's list of the group's profiles.
struct ProfilesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            if let problem = model.engine.settingsProblem { Label(problem, systemImage: "exclamationmark.triangle.fill") }
            Section(header: Header("Profiles")) {
                ForEach(model.group?.policy.profiles ?? []) { p in
                    NavigationLink { ProfileEditor(id: p.id) } label: {
                        VStack(alignment: .leading) {
                            Text(p.name).font(.headline)
                            Text(holders(p))
                        }
                    }
                }
                Button("Add a profile") {
                    model.updateGroup { g in
                        guard let id = g.nextProfileID else { return }
                        var p = g.policy.profiles.first ?? .standard
                        p.id = id
                        p.name = "New profile"
                        g.policy.profiles.append(p)
                    }
                }
                Text("Each person who calls for help has a profile: how their buttons look and sound, and what they may change. Everyone starts on the first.")
            }
        }
        .navigationTitle("Profiles")
        #if DEBUG && targetEnvironment(simulator)
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-HelpAOversizedSettings") { model.tryOversizedSettings() } }
        #endif
    }

    private func holders(_ p: Profile) -> String {
        guard let g = model.group else { return "" }
        let names = g.members.filter { $0.canCall && g.profile(of: $0.number).id == p.id }.map(\.name)
        return names.isEmpty ? "Nobody has it yet" : names.joined(separator: ", ")
    }
}

/// Everything in one profile, and who has it. Nothing here can change the safety rules: nothing
/// closes a call on its own, the cross shows when a call did not go, and the 999 notice stays.
struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: UInt8
    @State private var p = Profile.standard
    @State private var holders: Set<UInt16> = []
    @State private var saved = false

    private var isFirst: Bool { model.group?.policy.profiles.first?.id == id }
    private var callers: [Member] { model.group?.members.filter(\.canCall) ?? [] }

    var body: some View {
        Form {
            if let problem = model.engine.settingsProblem { Label(problem, systemImage: "exclamationmark.triangle.fill") }
            Section(header: Header("Name")) {
                LabeledField(label: "Profile name, such as Living alone", text: $p.name)
            }
            Section(header: Header("Who has it")) {
                if isFirst {
                    Text("Everyone not given another profile has this one.")
                } else {
                    ForEach(callers) { m in
                        Toggle(m.name, isOn: Binding(get: { holders.contains(m.number) },
                                                     set: { if $0 { holders.insert(m.number) } else { holders.remove(m.number) } }))
                    }
                    if callers.isEmpty { Text("Nobody in the group calls for help yet.") }
                }
            }
            buttons
            Section(header: Header("Sounds")) {
                Toggle("Sounds and spoken words", isOn: $p.soundsAndSpeech)
                Picker("When a call has not gone", selection: $p.notSent) {
                    ForEach(Profile.NotSentSound.allCases, id: \.self) { Text($0.label) }
                }
                Picker("When someone has seen it", selection: $p.seen) {
                    ForEach(Profile.SeenSound.allCases, id: \.self) { Text($0.label) }
                }
                HearSounds(profile: p)
                mayChange(.sounds)
            }
            Section(header: Header("I'm OK after Help or Need a hand")) {
                Picker("I'm OK", selection: $p.afterOK) {
                    ForEach(Profile.AfterOK.allCases, id: \.self) { Text($0.label) }
                }
                LabeledField(label: "What they hear, or leave empty for: \(p.okSpokenStandard)", text: $p.okWords)
                if p.afterOK == .stopsRepeats {
                    Stepper("Calm reminders every \(Int(p.calmEvery / 60)) minutes", value: minutes(\.calmEvery), in: 5...240, step: 5)
                    Picker("How many", selection: $p.calmReminders) {
                        Text("Until someone acknowledges").tag(Int?.none)
                        ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                }
                Toggle("They may close their own call", isOn: $p.callerMayClose)
                mayChange(.afterOK)
            }
            Section(header: Header("Where they are, and texts")) {
                Toggle("Send where they are with every Help or Need a hand", isOn: $p.shareWhere)
                mayChange(.shareWhere)
                Toggle("Offer a text to responders if nothing else got through", isOn: $p.textFallback)
                mayChange(.textFallback)
            }
            checkIns
            Section(header: Header("Alerting the next responder")) {
                Stepper("For Help, after \(Int(p.redInterval / 60)) minutes", value: minutes(\.redInterval), in: 1...30)
                Stepper("For Need a hand, after \(Int(p.amberInterval / 60)) minutes", value: minutes(\.amberInterval), in: 5...120, step: 5)
            }
            Section(header: Header("Settings page")) {
                Toggle("For people who only call: show only the three buttons", isOn: $p.hidesSettings)
                Text("They will not see their settings, so cannot change any. Someone with this profile who also responds keeps the Respond and Group screens.")
            }
            Section {
                Button("Save") { save() }.buttonStyle(.action)
                if saved { Text("Saved. It goes to every member now.") }
                if !isFirst {
                    Button("Delete this profile", role: .destructive) {
                        model.updateGroup { g in
                            g.policy.profiles.removeAll { $0.id == id }
                            g.policy.profileOf = g.policy.profileOf.filter { $0.value != id }
                        }
                        dismiss()
                    }
                    .foregroundStyle(Color.warning)
                    Text("Anyone who has it goes back to \(model.group?.policy.profiles.first?.name ?? "the first profile").")
                }
            }
        }
        .navigationTitle(p.name)
        .keyboardDismissable()
        .onAppear {
            guard let g = model.group, let found = g.policy.profiles.first(where: { $0.id == id }) else { return }
            p = found
            holders = Set(g.policy.profileOf.filter { $0.value == id }.map(\.key))
        }
    }

    private var buttons: some View {
        Section(header: Header("Buttons")) {
            Picker("Each button shows", selection: $p.face) {
                ForEach(Profile.Face.allCases, id: \.self) { Text($0.label) }
            }
            ForEach(Colour.allCases, id: \.self) { c in
                LabeledField(label: ButtonWords.standard(c), text: words(ButtonWords.key(c)))
                Picker("Symbol for \(ButtonWords.words(c, in: p))", selection: symbol(c)) {
                    ForEach(Profile.symbolChoices, id: \.self) { name in Label(symbolWords(name), systemImage: name).tag(name) }
                }
            }
            if Colour.allCases.contains(where: { ButtonWords.soundsLikeEmergencyService(ButtonWords.words($0, in: p)) }) {
                Text("Words such as SOS can sound like an emergency service. Make doubly clear to the people with this profile that Help&I does not replace 999.")
                    .foregroundStyle(Color.warning)
            }
            ForEach(CallCategory.choices, id: \.self) { c in
                LabeledField(label: ButtonWords.standard(c), text: words(ButtonWords.key(c)))
            }
            LabeledField(label: "After \(ButtonWords.standard(.amber)): " + ButtonWords.amberNote(in: nil), text: words(ButtonWords.amberNoteKey))
            Text("Leave a box empty to keep the words shown above it. At most \(ButtonWords.longest) letters each, or \(ButtonWords.longestNote) for what is said after \(ButtonWords.standard(.amber)).")
            mayChange(.buttons)
        }
    }

    private var checkIns: some View {
        Section(header: Header("Check-ins")) {
            Toggle("Ask them to check in at set times", isOn: Binding(get: { p.checkIns != nil },
                                                                     set: { p.checkIns = $0 ? CheckInSchedule(times: [540]) : nil }))
            if let s = p.checkIns {
                DatePicker("First check-in", selection: time(0, s), displayedComponents: .hourAndMinute)
                Toggle("A second check-in", isOn: Binding(get: { s.times.count > 1 },
                                                          set: { p.checkIns = CheckInSchedule(times: $0 ? [s.times[0], 1260] : [s.times[0]]) }))
                if s.times.count > 1 { DatePicker("Second check-in", selection: time(1, s), displayedComponents: .hourAndMinute) }
            }
            Toggle("They may set their own check-ins instead", isOn: allowed(.checkIns))
        }
    }

    /// What each symbol is, for the picker and VoiceOver.
    private func symbolWords(_ name: String) -> String {
        switch name {
        case "hand.raised.fill": "Raised hand"
        case "hands.and.sparkles.fill": "Hands"
        case "checkmark": "Tick"
        case "sos": "SOS"
        case "exclamationmark.triangle.fill": "Warning sign"
        case "bell.fill": "Bell"
        case "phone.fill": "Phone"
        case "house.fill": "House"
        case "heart.fill": "Heart"
        case "hand.thumbsup.fill": "Thumbs up"
        case "figure.wave": "Waving figure"
        default: name
        }
    }

    private func mayChange(_ setting: Profile.Setting) -> some View {
        Toggle("They may change this", isOn: allowed(setting))
    }

    private func allowed(_ setting: Profile.Setting) -> Binding<Bool> {
        Binding(get: { p.mayChange(setting) },
                set: { if $0 { p.personMayChange.insert(setting) } else { p.personMayChange.remove(setting) } })
    }

    private func words(_ key: String) -> Binding<String> {
        Binding(get: { p.buttonWords[key] ?? "" }, set: { ButtonWords.set($0, for: key, in: &p) })
    }

    private func symbol(_ c: Colour) -> Binding<String> {
        Binding(get: { p.symbol(c) }, set: { p.symbols[ButtonWords.key(c)] = $0 == Profile.standardSymbol(c) ? nil : $0 })
    }

    private func minutes(_ path: WritableKeyPath<Profile, TimeInterval>) -> Binding<Int> {
        Binding(get: { Int(p[keyPath: path] / 60) }, set: { p[keyPath: path] = TimeInterval($0 * 60) })
    }

    private func time(_ i: Int, _ s: CheckInSchedule) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: s.times[i] / 60, minute: s.times[i] % 60, second: 0, of: Date())! },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    var times = s.times
                    times[i] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                    p.checkIns = CheckInSchedule(times: times)
                })
    }

    private func save() {
        let edited = p
        let mine = holders
        let callers = callers.map(\.number)
        model.updateGroup { g in
            guard let i = g.policy.profiles.firstIndex(where: { $0.id == edited.id }) else { return }
            g.policy.profiles[i] = edited
            guard i > 0 else { return }
            for n in callers {
                if mine.contains(n) { g.policy.profileOf[n] = edited.id } else if g.policy.profileOf[n] == edited.id { g.policy.profileOf[n] = nil }
            }
        }
        // Settings too big to send are not kept: the editor keeps the edit and shows why instead.
        saved = model.engine.settingsProblem == nil
    }
}
