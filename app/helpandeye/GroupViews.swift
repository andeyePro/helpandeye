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
    @State private var choosingNextFirst = false

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
                HomeWiFiSection()
                MyPhoneSection()
                if model.me?.canCall == true {
                    YourSettingsSection()
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
                        let row = VStack(alignment: .leading) {
                            Text(m.name + (m.number == model.saved?.me ? " (you)" : "")).font(.headline)
                            Text(memberWords(m) + standIn(m))
                        }
                        // A coordinator opens a member to set the antenna on their box.
                        Group {
                            if model.me?.role == .coordinator { NavigationLink { MemberView(number: m.number) } label: { row } } else { row }
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
                        NavigationLink("Profiles") { ProfilesView() }
                        NavigationLink("Log") { LogView() }
                        NavigationLink("Advanced settings") { AdvancedSettingsView() }
                        if model.engine.isPrimaryCoordinator {
                            NavigationLink("If your phone is lost") { DeputyView() }
                        } else if let first = model.group?.primaryCoordinator {
                            NavigationLink("If \(model.name(ofMember: first))'s phone is lost") { TakeoverView() }
                            if let heard = model.saved?.primaryHeardAt, Date().timeIntervalSince(heard) > 2 * 86_400 {
                                Text("Nothing heard from \(model.name(ofMember: first))'s phone since \(heard.formatted(date: .long, time: .omitted)).")
                                    .foregroundStyle(Color.warning)
                            }
                        }
                        ForEach(model.engine.activity.changeRequests, id: \.at) { r in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(model.name(ofMember: r.member)) asks to change \(r.setting?.words ?? "a setting")" + (r.text.isEmpty ? "." : ": \(r.text)"))
                                Button("Done") { model.engine.dismiss(r) }.buttonStyle(.secondaryAction)
                            }
                        }
                        if let c = model.engine.activity.lastSettingsChange {
                            Text("Latest settings change, \(c.at.formatted(date: .abbreviated, time: .shortened)): \(c.text).")
                        }
                        if model.group?.needsSecondCoordinator == true {
                            Text("Someone here sees only the three buttons, and the group has one coordinator. Consider making a second coordinator, so their settings can still be changed if your phone is lost.")
                        }
                    }
                }
                if model.engine.isPrimaryCoordinator {
                    if model.group?.previousSecrets != nil { KeyUpdatesSection() }
                } else {
                    // Everyone but the first coordinator, other coordinators included, takes in new keys.
                    ReceiveUpdateSection()
                }
                DisplaySection()
                Section {
                    Button("Leave this group", role: .destructive) {
                        if model.others.isEmpty { model.leave() } else { choosingNextFirst = true }
                    }
                    .foregroundStyle(Color.warning)
                    // Still in other groups: one of them takes this one's place as the first group.
                    if choosingNextFirst {
                        Text("Which group should become your first group? You will call for help in it, if you may, and its check-ins and settings will be yours. You still respond in the others.")
                        ForEach(model.others) { o in
                            Button("Make \(o.engine.group?.name ?? "that group") my first group and leave \(model.group?.name ?? "this one")") {
                                choosingNextFirst = false
                                model.leave(becoming: o)
                            }
                        }
                        Button("Stay in this group") { choosingNextFirst = false }
                    }
                }
            }
            .navigationTitle(model.group?.name ?? "Group")
            .keyboardDismissable()
            .sheet(isPresented: $inviting) { NavigationStack { InviteView() } }
        }
    }

    /// Who stands in for whom if the first coordinator's phone is lost, shown to everyone.
    private func standIn(_ m: Member) -> String {
        if m.number == model.group?.primaryCoordinator { return ", first coordinator" }
        if m.number == model.group?.currentDeputy { return ", deputy to the first coordinator" }
        return ""
    }
}

func memberWords(_ m: Member) -> String {
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

/// A coordinator's view of one member: what they do, and the antenna on their box, from which the
/// box's transmit-power cap follows (decision 8).
struct MemberView: View {
    @EnvironmentObject var model: AppModel
    let number: UInt16

    var body: some View {
        let m = model.group?.member(number)
        Form {
            if let m {
                Section { Text(memberWords(m)) }
                if let unit = m.unit {
                    let antenna = model.group?.antenna(of: number) ?? .standardWhip
                    Section(header: Header("Antenna on their box")) {
                        Picker("Antenna", selection: Binding(get: { antenna.isExternal ? 2 : antenna == .higherGainWhip ? 1 : 0 },
                                                             set: { set($0 == 0 ? nil : $0 == 1 ? .higherGainWhip : .external(gainDBi: 3)) })) {
                            Text(Antenna.standardWhip.words).tag(0)
                            Text(Antenna.higherGainWhip.words).tag(1)
                            Text(Antenna.external(gainDBi: 3).words).tag(2)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        if antenna.isExternal {
                            Stepper("Its gain: \(gainWords(antenna.gainDBi))", value: Binding(get: { antenna.gainDBi }, set: { set(.external(gainDBi: $0)) }),
                                    in: 0...Antenna.maxGainDBi, step: 0.5)
                        }
                        PowerLimits(unit: unit)
                        Text("The box keeps its radio under this limit once it is set up with Help&I's firmware. The antenna goes to every member with the group's settings.")
                    }
                    Section(header: Header("Power cuts")) {
                        Toggle("Tell responders about a power cut at their home", isOn: Binding(
                            get: { model.group?.policy.reportsPowerCut.contains(number) == true },
                            set: { on in model.updateGroup { if on { $0.policy.reportsPowerCut.insert(number) } else { $0.policy.reportsPowerCut.remove(number) } } }))
                        Text("Only if they want it. A Help&I box then tells responders when its power goes, how long its battery will last, and when the power is back.")
                    }
                }
            }
        }
        .navigationTitle(m?.name ?? "Member")
    }

    private func set(_ antenna: Antenna?) { model.updateGroup { $0.setAntenna(antenna, of: number) } }
}

func gainWords(_ dBi: Double) -> String { String(format: "%g dBi", dBi) }

/// The transmit-power cap a unit's antenna gives in each band Help&I uses (Airtime.swift).
struct PowerLimits: View {
    @EnvironmentObject var model: AppModel
    let unit: UInt32

    var body: some View {
        ForEach(Band.all, id: \.name) { band in
            LabeledContent(band.name, value: model.group?.maxRadioSetting(ofUnit: unit, in: band).map { "up to \($0) dBm from the radio" } ?? "must not send")
        }
        if let g = model.group, Band.all.allSatisfy({ g.maxRadioSetting(ofUnit: unit, in: $0) == nil }) {
            Text("With this antenna the box must not send at all, so its buttons cannot call for help. It needs an antenna with less gain.")
                .foregroundStyle(Color.warning)
        }
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
/// The first coordinator names the coordinator who may take over at once if their phone is lost
/// (decision 20).
struct DeputyView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let others = (model.group?.members ?? []).filter { $0.role == .coordinator && $0.number != model.saved?.me }
        Form {
            Section {
                Text("If your phone is lost or broken, another coordinator can take over running the group. The one you name here can do it straight away. Otherwise it takes two coordinators together, or one after a week without word from your phone.")
            }
            Section(header: Header("Your deputy")) {
                if others.isEmpty {
                    Text("Make someone a coordinator first, under Members.")
                } else {
                    Picker("Deputy", selection: Binding(get: { model.group?.currentDeputy ?? 0 }, set: { model.engine.nameDeputy($0 == 0 ? nil : $0) })) {
                        Text("No one").tag(UInt16(0))
                        ForEach(others) { m in Text(m.name).tag(m.number) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text("Everyone in the group sees who your deputy is.")
                }
            }
        }
        .navigationTitle("If your phone is lost")
    }
}

/// A coordinator takes over from a first coordinator whose phone is lost (decision 20): how long
/// it has been silent, which way is open, and what taking over does.
struct TakeoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming = false

    var body: some View {
        let first = model.group?.primaryCoordinator.map { model.name(ofMember: $0) } ?? "The first coordinator"
        let others = (model.group?.members ?? []).filter {
            $0.role == .coordinator && $0.number != model.saved?.me && $0.number != model.group?.primaryCoordinator
        }
        Form {
            Section {
                if let heard = model.saved?.primaryHeardAt {
                    Text("Last heard from \(first)'s phone: \(heard.formatted(.relative(presentation: .named))).")
                }
                Text(model.group?.currentDeputy.map { "\(first)'s deputy is \(model.name(ofMember: $0))." } ?? "\(first) has not named a deputy.")
            }
            Section(header: Header("Taking over")) {
                Text("If \(first)'s phone is lost or broken, you can take over running the group. Their phone is removed from the group, and the group gets new keys. You then show each member their update code, as after any removal.")
                switch model.engine.takeoverPath {
                case .deputy:
                    Text("\(first) named you as deputy, so you can take over now.")
                case let .agreed(by):
                    Text("\(model.name(ofMember: by)) agreed, so you can take over now.")
                case .silence:
                    Text("Nothing has been heard from \(first)'s phone for a week, so you can take over now, once the relay confirms it has not heard from it either.")
                case nil:
                    if model.relay.isConfigured {
                        Text("You can take over once another coordinator agrees"
                             + (model.engine.takeoverOpensAt.map { ", or on your own from \($0.formatted(date: .long, time: .shortened))." } ?? "."))
                    } else {
                        Text("You can take over once another coordinator agrees. This group has no relay to confirm that \(first)'s phone has been silent, so you cannot do it on your own.")
                    }
                }
                if model.engine.askingRelayToTakeOver {
                    Text("Checking with the relay.")
                } else if model.engine.takeoverPath != nil {
                    Button("Take over from \(first)") { confirming = true }
                }
                if let problem = model.engine.takeoverProblem { Text(problem) }
            }
            if !others.isEmpty {
                Section(header: Header("Agree to another coordinator taking over")) {
                    Text("If you know \(first)'s phone is lost, you can agree that another coordinator takes over. They can then do it straight away.")
                    ForEach(others) { m in
                        if model.engine.activity.takeoverAgreed.contains(m.number) {
                            Text("You agreed that \(m.name) may take over.")
                        } else {
                            Button("Agree that \(m.name) may take over") { model.engine.agreeToTakeover(by: m.number) }
                        }
                    }
                }
            }
        }
        .navigationTitle("If \(first)'s phone is lost")
        .confirmationDialog("Take over from \(first)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Take over") { model.engine.takeOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if \(first)'s phone is lost or broken. It is removed from the group, and you show everyone a new code.")
        }
    }
}

struct KeyUpdatesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var shown: Member?

    var body: some View {
        Section(header: Header("New keys to hand out")) {
            Text("A phone was removed, so the group has new keys. Show each member their update code"
                 + (model.group?.previousUntil.map { " by \($0.formatted(date: .long, time: .omitted)). After that, a member who has not scanned it can no longer reach the group." } ?? "."))
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
        Section(header: Header("New code from your coordinator")) {
            if let first = model.engine.activity.tookOverFirst {
                Text("\(model.name(ofMember: first)) also took over as first coordinator, and the group follows them rather than you. They will show you a new code to scan here.")
            }
            if model.keyProblem != nil {
                Text("Your coordinator has a new code for you. Until you scan it, anything you type, choose or share is not sent.")
                    .foregroundStyle(Color.warning)
            }
            CodeReader(prompt: "If your coordinator shows you a new code, scan it here") { code in
                guard let g = model.group, let w = try? Joining.decode(Joining.Welcome.self, from: code),
                      let updated = try? Joining.openUpdate(w, current: g, me: model.identity, primarySilent: model.engine.primaryIsSilent,
                                                         relayOwner: model.engine.activity.relayOwner) else {
                    message = "That code did not work. Ask your coordinator to show it again."; return
                }
                model.engine.applyKeyUpdate(updated)
                message = "Done. What you type, choose or share is sent again from now on."
            }
            if let message { Text(message) }
        }
    }
}

/// Whether red and amber calls also send where the caller is.
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
    @State private var pass = ""
    @State private var passMessage: String?

    var body: some View {
        Section(header: Header("Internet route")) {
            let usesOurs = model.group?.relayURL == RelayProtocol.defaultRelay
            Text(usesOurs ? "Calls also go over the internet, through Help&I's relay. It passes on only what is sealed with the group's key, so it cannot read calls."
                 : model.relay.isConfigured ? "Calls also go over the internet, through your own relay." : "Not set up: calls go over the local radio only.")
            // What the relay last said when it turned this phone away, so a coordinator sees why
            // the route is not working without waiting for a call to show it.
            if let problem = model.relay.lastProblem { Text(problem).foregroundStyle(Color.warning) }
            if usesOurs, let group = model.group {
                Text("Help&I's relay is a paid service. A group uses it with a pass from Help&I.")
                Text(passWords(group.passState(at: Date())))
                Text("Group ID, to get a pass: \(RelayProtocol.id(of: group.secrets.groupID))").textSelection(.enabled)
                LabeledField(label: "Paste the pass here", text: $pass, keyboard: .URL)
                Button("Save pass") {
                    if model.setRelayPass(pass) {
                        passMessage = "Saved. Members get the pass at once, over the internet or the local radio, or when they next join."
                        pass = ""
                    } else {
                        passMessage = model.engine.settingsProblem ?? "That is not a pass for this group. Check it was copied in full."
                    }
                }
                if let passMessage { Text(passMessage) }
            }
            if !usesOurs { Button("Use Help&I's relay") { url = RelayProtocol.defaultRelay; model.setRelay(url) } }
            LabeledField(label: "Or your own relay's address, starting https://", text: $url, keyboard: .URL)
            Button("Save") { model.setRelay(url) }
            if model.group?.relayURL != nil { Button("No internet route") { url = ""; model.setRelay("") } }
            Text("Members get the new address at once, over the old address or the local radio, or when they next join.")
        }
        .onAppear { url = model.group?.relayURL ?? "" }
    }

    private func passWords(_ state: RelayPass.State) -> String {
        switch state {
        case .none: return "This group has no pass yet."
        // With the time: a pass runs out at the hour it was issued, not at midnight.
        case let .valid(until): return "This group's pass is good until \(until.formatted(date: .long, time: .shortened))."
        case let .expired(on): return "This group's pass ran out on \(on.formatted(date: .long, time: .shortened))."
        }
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

/// Settings most groups never change: the internet route, and first names on Help&I boxes.
struct AdvancedSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            RelaySection()
            Section(header: Header("Help&I boxes")) {
                Toggle("Responders' first names on boxes", isOn: Binding(get: { model.group?.policy.namesOnBox == true },
                                                                         set: { on in model.updateGroup { $0.policy.namesOnBox = on } }))
                Text("A box then says “Pat has seen your call.” rather than “A responder has seen your call.” The names stay on the box, where someone who takes it could read them.")
            }
        }
        .navigationTitle("Advanced settings")
        .keyboardDismissable()
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
            // In the caller's own button words, which a coordinator may have changed.
            let checkInRule = "Press \(ButtonWords.words(.green, in: model.profile)) within half an hour of each time. If you do not, your responders get a \(ButtonWords.words(.amber, in: model.profile)) call."
            let mayChange = model.group.map { $0.profile(of: model.saved?.me).mayChange(.checkIns) } ?? true
            if !mayChange {
                // Set by the coordinator: said in words, not shown as controls that do nothing.
                let times = (model.checkIn?.times ?? []).map { date($0).formatted(date: .omitted, time: .shortened) }
                Text(times.isEmpty ? "No check-ins. \(SetByCoordinator.text)" : "Check in at \(times.joined(separator: " and ")). \(SetByCoordinator.text)")
                if !times.isEmpty { Text(checkInRule) }
            } else {
                Toggle("Check in at set times", isOn: $on)
                if on {
                    DatePicker("First check-in", selection: $morning, displayedComponents: .hourAndMinute)
                    Toggle("A second check-in", isOn: $twice)
                    if twice { DatePicker("Second check-in", selection: $evening, displayedComponents: .hourAndMinute) }
                    Text(checkInRule)
                }
                Button("Save") { model.setCheckIn(on ? CheckInSchedule(times: [minutes(morning)] + (twice ? [minutes(evening)] : [])) : nil) }
            }
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

/// The group's log, on a coordinator's phone: newest first, and exportable as text.
struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let log = model.engine.activity.log
        List {
            Section {
                Toggle("Keep a log for this group", isOn: Binding(get: { model.group?.policy.keepsLog ?? true },
                                                                  set: { on in model.updateGroup { $0.policy.keepsLog = on } }))
                Text("Each coordinator's phone keeps its own log of calls, acknowledgements, closes and settings changes, encrypted on the phone. Settings changes are always shown to coordinators.")
                if !log.entries.isEmpty {
                    ShareLink(item: log.text()) { WrappingLabel("Export the log", systemImage: "square.and.arrow.up") }
                }
            }
            Section(header: Header("Newest first")) {
                if log.entries.isEmpty { Text("Nothing logged yet.") }
                ForEach(Array(log.entries.reversed().enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading) {
                        Text(e.at.formatted(date: .abbreviated, time: .standard)).font(.callout)
                        Text(e.text)
                    }
                }
            }
        }
        .navigationTitle("Log")
    }
}
