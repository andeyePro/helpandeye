import helpandeyeCore
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: Mode?
    enum Mode: Identifiable { case create, join; var id: Self { self } }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Help&I").font(.largeTitle.bold())
            Text("Get help, even when the power and phones are down.").multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { mode = .join } label: { Text("Join a group").frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.action)
            Button { mode = .create } label: { Text("Start a group").frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.secondaryAction)
            Spacer()
            NotA999Notice()
        }
        .padding()
        .sheet(item: $mode) { m in
            NavigationStack {
                (m == .create ? AnyView(CreateGroupView()) : AnyView(JoinGroupView()))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { mode = nil } } }
            }
        }
    }
}

struct CreateGroupView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @AppStorage(MyDetails.nameKey) private var myName = ""
    @State private var call = false
    @AppStorage(MyDetails.phoneKey) private var phone = ""
    @State private var missing = false

    var body: some View {
        Form {
            Section(header: Header("Group")) { LabeledField(label: "Group name, such as your street", text: $name) }
            Section(header: Header("You")) {
                LabeledField(label: "Your name, as the group will see it", text: $myName)
                LabeledField(label: "Mobile number (optional)", text: $phone, keyboard: .phonePad)
                Toggle(isOn: $call) { Text("I may also call for help").font(.body) }
            }
            Section {
                Text("You will coordinate this group: invite people, and be told when nobody is available to respond.")
                // Never greyed out: a faded button is hard to read and does not say what is missing.
                Button("Start the group") {
                    missing = name.isEmpty || myName.isEmpty
                    if !missing { model.createGroup(name: name, myName: myName, call: call, phone: phone.isEmpty ? nil : phone) }
                }
                .buttonStyle(.action)
                if missing { Text("Please enter the group's name and your name first.").foregroundStyle(Color.warning) }
            }
        }
        .navigationTitle("Start a group")
        .keyboardDismissable()
    }
}

/// The new member's side of the three-scan join (Joining in helpandeyeCore). Where they have got
/// to is kept, so leaving the screen (to fetch a code from Messages, say) does not start it again,
/// and their name and number are kept for next time.
struct JoinGroupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Joining a further group, as a responder only, while already in one.
    var another = false
    @AppStorage("join.invite") private var savedInvite = ""
    @AppStorage("join.request") private var savedRequest = ""
    @AppStorage(MyDetails.nameKey) private var name = ""
    @AppStorage(MyDetails.phoneKey) private var phone = ""
    @State private var missing = false
    @State private var error: String?

    private var invite: Joining.Invitation? { try? Joining.decode(Joining.Invitation.self, from: savedInvite) }
    private var requestCode: String? { savedRequest.isEmpty ? nil : savedRequest }

    var body: some View {
        Form {
            if invite == nil {
                CodeReader(prompt: "Scan the code on the coordinator's phone") { code in
                    if let i = try? Joining.decode(Joining.Invitation.self, from: code) {
                        if another, i.role != .responder {
                            error = "In a further group you can only respond. Ask its coordinator to invite you to respond to others."
                        } else { savedInvite = code; error = nil }
                    } else { error = codeProblem(code, expected: .invitation) }
                }
            } else if requestCode == nil, let invite {
                Section(header: Header("Joining \(invite.groupName)")) {
                    if let role = invite.role { Text("You are invited to \(roleWords(role)).") }
                    LabeledField(label: "Your name, as the group will see it", text: $name)
                    LabeledField(label: "Mobile number (optional)", text: $phone, keyboard: .phonePad)
                    Button("Next") {
                        missing = name.isEmpty
                        guard !missing else { return }
                        let r = Joining.request(invite, name: name, call: true, respond: true, phone: phone.isEmpty ? nil : phone, me: model.identity)
                        savedRequest = (try? Joining.code(r)) ?? ""
                    }
                    .buttonStyle(.action)
                    if missing { Text("Please enter your name.").foregroundStyle(Color.warning) }
                }
            } else if let invite, let requestCode {
                Section(header: Header("Show this to the coordinator")) {
                    QRCode(text: requestCode).frame(maxWidth: 260).frame(maxWidth: .infinity)
                    ShareLink(item: requestCode) { WrappingLabel("Send it as a message instead", systemImage: "square.and.arrow.up") }
                    Text("If you are not together, read this number to each other on a call: \(Joining.safetyNumber(invite.coordinatorKey, model.identity.publicKey)). It must match on both phones.")
                }
                CodeReader(prompt: "Then scan the welcome code they show you") { code in
                    do {
                        let w = try Joining.decode(Joining.Welcome.self, from: code)
                        let group = try Joining.open(w, invite: invite, me: model.identity)
                        savedInvite = ""; savedRequest = ""
                        let by = group.members.first { $0.publicKey == invite.coordinatorKey }?.number
                        if another {
                            if model.joinedAnother(group, as: w.memberNumber, invitedBy: by) { dismiss() }
                            else { self.error = "You are in that group already, or were not invited to respond in it." }
                        } else {
                            model.joined(group, as: w.memberNumber, invitedBy: by)
                        }
                    } catch {
                        self.error = (try? Joining.decode(Joining.Welcome.self, from: code)) != nil
                            ? "That welcome code was made for a different invitation. Ask the coordinator to start again with a new one."
                            : codeProblem(code, expected: .welcome)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Color.warning) }
            if invite != nil {
                Section { Button("Start again") { savedInvite = ""; savedRequest = ""; error = nil }.buttonStyle(.secondaryAction) }
            }
        }
        .navigationTitle("Join a group")
        .keyboardDismissable()
    }
}

/// This phone's owner's name and number, remembered between groups and attempts.
enum MyDetails {
    static let nameKey = "my.name"
    static let phoneKey = "my.phone"
}

func roleWords(_ role: Member.Role) -> String {
    switch role {
    case .caller: "call for help"
    case .responder: "respond to others"
    case .both, .coordinator: "call for help and respond to others"
    }
}

/// Says plainly what went wrong with a code, so nobody goes round the steps again guessing.
func codeProblem(_ code: String, expected: Joining.Kind) -> String {
    if case Joining.Failure.otherVersion? = (Result { try Joining.decode(Joining.Invitation.self, from: code) }).failureError {
        return "That code was made by a different version of Help&I. Update the app on both phones, then start again."
    }
    switch (Joining.kind(of: code), expected) {
    case (.invitation?, .request): return "That is your own invitation code. Scan the code on their phone."
    case (.welcome?, .request): return "That is a welcome code. Scan the code on their phone."
    case (.invitation?, .welcome): return "That is the coordinator's first code again. Scan the welcome code they show after adding you."
    case (.request?, _): return "That is a joining code from a new member. It goes to the coordinator's phone."
    case (.welcome?, .invitation): return "That is a welcome code. First scan the coordinator's invitation code."
    case (.invitation?, _), (.welcome?, _): return "That code is not the one needed here."
    case (nil, _): return "That is not a Help&I code. If you pasted it, copy the whole message and try again."
    }
}

extension Result {
    var failureError: Failure? { if case let .failure(e) = self { e } else { nil } }
}

struct GroupView: View {
    @EnvironmentObject var model: AppModel
    @State private var inviting = false
    @State private var leaveFirstLast = false

    var body: some View {
        NavigationStack {
            List {
                if let me = model.me, me.canRespond {
                    Section(header: Header("Your availability")) {
                        let available = model.rota.isAvailable(me.number, at: Date())
                        Text(available ? "You are available to respond." : "You are not available.")
                        Button(available ? "I'm not available for the next 12 hours" : "I'm available for the next 12 hours") {
                            model.setAvailable(!available)
                        }
                    }
                }
                MyPhoneSection()
                if model.me?.canCall == true {
                    ShareEveryCallSection()
                    CheckInSection()
                }
                if model.me?.role == .coordinator {
                    Section(header: Header("Gaps in the next 24 hours")) {
                        if model.gaps.isEmpty { Text("Someone is available all the time.") }
                        ForEach(model.gaps, id: \.start) { g in
                            Text("\(g.start.formatted(date: .omitted, time: .shortened)) to \(g.end.formatted(date: .omitted, time: .shortened)): nobody available")
                                .foregroundStyle(Color.warning)
                        }
                    }
                }
                Section(header: Header("Members")) {
                    ForEach(model.group?.members ?? []) { m in
                        VStack(alignment: .leading) {
                            Text(m.name + (m.number == model.saved?.me ? " (you)" : "")).font(.headline)
                            Text(roleText(m))
                        }
                        .swipeActions {
                            // Only the group's first coordinator removes people or makes coordinators.
                            if model.engine.isPrimaryCoordinator, m.number != model.saved?.me {
                                Button("Remove", role: .destructive) { model.engine.removeMember(m.number) }
                                if m.role == .responder || m.role == .both {
                                    Button("Make coordinator") { model.engine.promote(m.number) }.tint(.action)
                                }
                            }
                        }
                    }
                    if model.me?.role == .coordinator {
                        Button("Invite someone") { inviting = true }
                    }
                }
                OtherGroupsSection()
                if model.me?.role == .coordinator {
                    Section(header: Header("For coordinators")) {
                        NavigationLink("Advanced settings") { AdvancedSettingsView() }
                    }
                }
                if model.engine.isPrimaryCoordinator {
                    if model.group?.previousSecrets != nil { KeyUpdatesSection() }
                } else {
                    // Everyone but the first coordinator, other coordinators included, takes in new keys.
                    ReceiveUpdateSection()
                }
                DisplaySection()
                if model.me?.canCall == true {
                    Section(header: Header("Sounds")) { CallerVoiceToggle() }
                }
                Section {
                    // The first group goes last: the others' calls are answered from its screens.
                    Button("Leave this group", role: .destructive) {
                        if model.others.isEmpty { model.leave() } else { leaveFirstLast = true }
                    }
                    .foregroundStyle(Color.warning)
                    if leaveFirstLast { Text("Leave your other groups first, under Other groups you respond in.").foregroundStyle(Color.warning) }
                }
            }
            .navigationTitle(model.group?.name ?? "Group")
            .keyboardDismissable()
            .sheet(isPresented: $inviting) { NavigationStack { InviteView() } }
        }
    }

    private func roleText(_ m: Member) -> String {
        var parts: [String] = []
        switch m.role {
        case .coordinator: parts.append("Coordinator")
        case .caller: parts.append("Calls for help")
        case .responder: parts.append("Responds")
        case .both: parts.append("Calls for help and responds")
        }
        if let u = m.unit { parts.append("unit \(u)") }
        if m.canRespond, m.phone == nil { parts.append("no mobile number") }
        return parts.joined(separator: ", ")
    }
}

/// The coordinator's side of the three-scan join.
struct InviteView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var invite: Joining.Invitation?
    @State private var request: Joining.JoinRequest?
    @State private var welcomeCode: String?
    @State private var error: String?

    var body: some View {
        Form {
            if invite == nil, let g = model.group {
                // The coordinator decides what each person does, not the person joining.
                Section(header: Header("What will they do?")) {
                    ForEach([Member.Role.caller, .responder, .both], id: \.self) { role in
                        Button(roleWords(role).prefix(1).uppercased() + roleWords(role).dropFirst()) {
                            invite = Joining.invitation(for: g, coordinator: model.identity, role: role)
                        }
                        .buttonStyle(.secondaryAction)
                    }
                }
            }
            if let invite, let code = try? Joining.code(invite), request == nil {
                Section(header: Header("Ask them to scan this")) {
                    QRCode(text: code).frame(maxWidth: 260).frame(maxWidth: .infinity)
                    ShareLink(item: code) { WrappingLabel("Send it as a message instead", systemImage: "square.and.arrow.up") }
                }
                CodeReader(prompt: "Then scan the code on their phone") { c in
                    do { request = try Joining.decode(Joining.JoinRequest.self, from: c); error = nil } catch { self.error = codeProblem(c, expected: .request) }
                }
            } else if let invite, let request, welcomeCode == nil {
                Section(header: Header("Add \(request.name)?")) {
                    Text("They will \(roleWords(invite.role ?? (request.wantsToCall && request.wantsToRespond ? .both : request.wantsToCall ? .caller : .responder))).")
                    Text("If you are not together, the number on their phone must be \(Joining.safetyNumber(model.identity.publicKey, request.publicKey)).")
                    Button("Add them") {
                        var made: Joining.Welcome?
                        model.updateGroup { g in made = try? Joining.admit(request, to: &g, invite: invite, coordinator: model.identity) }
                        welcomeCode = made.flatMap { try? Joining.code($0) }
                        if welcomeCode == nil { error = "Could not add them. Start the invitation again." }
                    }
                }
            } else if let welcomeCode {
                Section(header: Header("Ask them to scan this welcome code")) {
                    QRCode(text: welcomeCode).frame(maxWidth: 320).frame(maxWidth: .infinity)
                    ShareLink(item: welcomeCode) { WrappingLabel("Send it as a message instead", systemImage: "square.and.arrow.up") }
                    Button("Done") { dismiss() }
                }
            }
            if let error { Text(error).foregroundStyle(Color.warning) }
        }
        .navigationTitle("Invite someone")
        .keyboardDismissable()
        // A plain way out: on iPad, and with VoiceOver, a sheet is not always easy to swipe away.
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }
}

/// After a phone is removed, every remaining member needs the new secrets.
struct KeyUpdatesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var shown: Member?

    var body: some View {
        Section(header: Header("New keys to hand out")) {
            Text("A phone was removed, so the group has new keys. Show each member their update code.")
            ForEach((model.group?.members ?? []).filter { $0.number != model.saved?.me }) { m in
                Button("Update code for \(m.name)") { shown = m }
            }
        }
        .sheet(item: $shown) { m in
            if let g = model.group, let w = try? Joining.update(g, for: m, coordinator: model.identity), let code = try? Joining.code(w) {
                VStack(spacing: 16) {
                    Text("Update for \(m.name)").font(.headline)
                    QRCode(text: code).frame(maxWidth: 320)
                    ShareLink(item: code) { WrappingLabel("Send it as a message instead", systemImage: "square.and.arrow.up") }
                }
                .padding()
            }
        }
    }
}

struct ReceiveUpdateSection: View {
    @EnvironmentObject var model: AppModel
    @State private var message: String?

    var body: some View {
        Section(header: Header("Key update")) {
            CodeReader(prompt: "If your coordinator shows you an update code, scan it here") { code in
                guard let g = model.group, let w = try? Joining.decode(Joining.Welcome.self, from: code),
                      let updated = try? Joining.openUpdate(w, current: g, me: model.identity) else {
                    message = "That update code could not be used."; return
                }
                model.engine.applyKeyUpdate(updated)
                message = "Keys updated."
            }
            if let message { Text(message) }
        }
    }
}

/// Whether red and amber calls also send where the caller is.
struct ShareEveryCallSection: View {
    @AppStorage(ShareEveryCall.key) private var on = false

    var body: some View {
        Section(header: Header("When you call")) {
            Toggle(isOn: $on) { Text("Send where I am with every \(Colour.red.label) or \(Colour.amber.label)").font(.body) }
            Text("It goes only to your responders, encrypted, after the call itself.")
        }
    }
}

/// The number a caller's ready-written text goes to, if nothing else got through.
struct MyPhoneSection: View {
    @EnvironmentObject var model: AppModel
    @State private var phone = ""
    @State private var saved = false

    var body: some View {
        Section(header: Header("Your mobile number")) {
            LabeledField(label: "Mobile number", text: $phone, keyboard: .phonePad)
            Button("Save") { model.setMyPhone(phone); saved = true }
            Text(saved ? "Saved. Members with the internet route get it now; others when they next scan a code."
                       : "If a call cannot go any other way, the caller can send it to responders as a text.")
        }
        .onAppear { phone = model.me?.phone ?? "" }
    }
}

struct RelaySection: View {
    @EnvironmentObject var model: AppModel
    @State private var url = ""

    var body: some View {
        Section(header: Header("Internet route")) {
            LabeledField(label: "Relay address, starting https://", text: $url, keyboard: .URL)
            Button("Save") { model.setRelay(url) }
            Text(model.relay.isConfigured ? "Calls also go over the internet." : "Not set up: calls go over the local radio only.")
            Text("Members get the new address at once, over the old address or the local radio, or when they next join.")
        }
        .onAppear { url = model.group?.relayURL ?? "" }
    }
}

/// The other groups this person responds in, and joining one more.
struct OtherGroupsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var joining = false

    var body: some View {
        Section(header: Header("Other groups you respond in")) {
            ForEach(model.others) { o in
                Text(o.engine.group?.name ?? "A group")
                    .swipeActions { Button("Leave", role: .destructive) { model.leave(o) } }
                    .accessibilityAction(named: "Leave this group") { model.leave(o) }
            }
            Button("Join another group as a responder") { joining = true }
            Text("You call for help in one group only. In others you can respond, with the same box.")
        }
        .sheet(isPresented: $joining) {
            NavigationStack {
                JoinGroupView(another: true)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { joining = false } } }
            }
        }
    }
}

/// Settings most groups never change: the internet route and the words on the buttons.
struct AdvancedSettingsView: View {
    var body: some View {
        Form {
            RelaySection()
            ButtonWordsSection()
        }
        .navigationTitle("Advanced settings")
        .keyboardDismissable()
    }
}

/// The group's own words for each button (decision 15). Blank keeps the app's words.
struct ButtonWordsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var words: [String: String] = [:]
    @State private var saved = false

    private var buttons: [(key: String, standard: String)] {
        Colour.allCases.map { (ButtonWords.key($0), ButtonWords.standard($0)) }
            + CallCategory.choices.map { (ButtonWords.key($0), ButtonWords.standard($0)) }
            + [(ButtonWords.amberNoteKey, "After \(ButtonWords.standard(.amber)): " + ButtonWords.amberNote(in: nil))]
    }

    var body: some View {
        Section(header: Header("Words on the buttons")) {
            ForEach(buttons, id: \.key) { b in
                LabeledField(label: b.standard, text: Binding(get: { words[b.key] ?? "" }, set: { words[b.key] = $0 }))
            }
            Button("Save") {
                model.updateGroup { g in for b in buttons { ButtonWords.set(words[b.key] ?? "", for: b.key, in: &g.policy) } }
                saved = true
            }
            .buttonStyle(.action)
            Text(saved ? "Saved. The new words go to every member now."
                       : "Leave a box empty to keep the words shown above it. At most \(ButtonWords.longest) letters each, or \(ButtonWords.longestNote) for what is said after \(ButtonWords.standard(.amber)).")
        }
        .onAppear { words = model.group?.policy.buttonWords ?? [:] }
    }
}

/// The opt-in check-in schedule (decision 16). Off unless the caller turns it on.
struct CheckInSection: View {
    @EnvironmentObject var model: AppModel
    @State private var on = false
    @State private var morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    @State private var evening = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date())!
    @State private var twice = true

    var body: some View {
        Section(header: Header("Check-ins")) {
            Toggle("Check in at set times", isOn: $on)
            if on {
                DatePicker("First check-in", selection: $morning, displayedComponents: .hourAndMinute)
                Toggle("A second check-in", isOn: $twice)
                if twice { DatePicker("Second check-in", selection: $evening, displayedComponents: .hourAndMinute) }
                Text("Press I'm OK within half an hour of each time. If you do not, your responders get a Need a hand call.")
            }
            Button("Save") { model.setCheckIn(on ? CheckInSchedule(times: [minutes(morning)] + (twice ? [minutes(evening)] : [])) : nil) }
        }
        .onAppear {
            guard let s = model.checkIn else { return }
            on = true
            twice = s.times.count > 1
            if let t = s.times.first { morning = date(t) }
            if s.times.count > 1 { evening = date(s.times[1]) }
        }
    }

    private func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func date(_ m: Int) -> Date { Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date())! }
}
