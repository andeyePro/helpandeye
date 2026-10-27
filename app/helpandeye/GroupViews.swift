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
            Button { mode = .join } label: { Text("Join a group").frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.borderedProminent)
            Button { mode = .create } label: { Text("Start a group").frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.bordered)
            Spacer()
            NotA999Notice()
        }
        .padding()
        .sheet(item: $mode) { m in
            NavigationStack { m == .create ? AnyView(CreateGroupView()) : AnyView(JoinGroupView()) }
        }
    }
}

struct CreateGroupView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var myName = ""
    @State private var call = false
    @State private var phone = ""

    var body: some View {
        Form {
            Section("Group") { TextField("Group name, such as your street", text: $name) }
            Section("You") {
                TextField("Your name, as the group will see it", text: $myName)
                TextField("Mobile number (optional)", text: $phone).keyboardType(.phonePad)
                Toggle("I may also call for help", isOn: $call)
            }
            Section {
                Text("You will coordinate this group: invite people, and be told when nobody is available to respond.")
                    .font(.footnote)
                Button("Start the group") { model.createGroup(name: name, myName: myName, call: call, phone: phone.isEmpty ? nil : phone) }
                    .disabled(name.isEmpty || myName.isEmpty)
            }
        }
        .navigationTitle("Start a group")
    }
}

/// The new member's side of the three-scan join (Joining in helpandeyeCore).
struct JoinGroupView: View {
    @EnvironmentObject var model: AppModel
    @State private var invite: Joining.Invitation?
    @State private var name = ""
    @State private var phone = ""
    @State private var call = true
    @State private var respond = false
    @State private var requestCode: String?
    @State private var error: String?

    var body: some View {
        Form {
            if invite == nil {
                CodeReader(prompt: "Scan the code on the coordinator's phone") { code in
                    do { invite = try Joining.decode(Joining.Invitation.self, from: code); error = nil } catch { self.error = "That is not a Help&I joining code." }
                }
            } else if requestCode == nil, let invite {
                Section("Joining \(invite.groupName)") {
                    TextField("Your name, as the group will see it", text: $name)
                    TextField("Mobile number (optional)", text: $phone).keyboardType(.phonePad)
                    Toggle("I may call for help", isOn: $call)
                    Toggle("I can respond to others", isOn: $respond)
                    Button("Next") {
                        let r = Joining.request(invite, name: name, call: call, respond: respond, phone: phone.isEmpty ? nil : phone, me: model.identity)
                        requestCode = try? Joining.code(r)
                    }
                    .disabled(name.isEmpty || !(call || respond))
                }
            } else if let invite, let requestCode {
                Section("Show this to the coordinator") {
                    QRCode(text: requestCode).frame(maxWidth: 260).frame(maxWidth: .infinity)
                    ShareLink(item: requestCode) { Label("Send it as a message instead", systemImage: "square.and.arrow.up") }
                    Text("If you are not together, read this number to each other on a call: \(Joining.safetyNumber(invite.coordinatorKey, model.identity.publicKey)). It must match on both phones.")
                        .font(.footnote)
                }
                CodeReader(prompt: "Then scan the welcome code they show you") { code in
                    do {
                        let w = try Joining.decode(Joining.Welcome.self, from: code)
                        let group = try Joining.open(w, invite: invite, me: model.identity)
                        model.joined(group, as: w.memberNumber, invitedBy: group.members.first { $0.publicKey == invite.coordinatorKey }?.number)
                    } catch { self.error = "That welcome code could not be opened. Ask the coordinator to make a new one." }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Join a group")
    }
}

struct GroupView: View {
    @EnvironmentObject var model: AppModel
    @State private var inviting = false

    var body: some View {
        NavigationStack {
            List {
                if let me = model.me, me.canRespond {
                    Section("Your availability") {
                        let available = model.rota.isAvailable(me.number, at: Date())
                        Text(available ? "You are available to respond." : "You are not available.")
                        Button(available ? "I'm not available for the next 12 hours" : "I'm available for the next 12 hours") {
                            model.setAvailable(!available)
                        }
                    }
                }
                MyPhoneSection()
                if model.me?.canCall == true { CheckInSection() }
                if model.me?.role == .coordinator {
                    Section("Gaps in the next 24 hours") {
                        if model.gaps.isEmpty { Text("Someone is available all the time.") }
                        ForEach(model.gaps, id: \.start) { g in
                            Text("\(g.start.formatted(date: .omitted, time: .shortened)) to \(g.end.formatted(date: .omitted, time: .shortened)): nobody available")
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Members") {
                    ForEach(model.group?.members ?? []) { m in
                        VStack(alignment: .leading) {
                            Text(m.name + (m.number == model.saved?.me ? " (you)" : "")).font(.headline)
                            Text(roleText(m)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            // Only the group's first coordinator removes people or makes coordinators.
                            if model.engine.isPrimaryCoordinator, m.number != model.saved?.me {
                                Button("Remove", role: .destructive) { model.engine.removeMember(m.number) }
                                if m.role == .responder || m.role == .both {
                                    Button("Make coordinator") { model.engine.promote(m.number) }.tint(.blue)
                                }
                            }
                        }
                    }
                    if model.me?.role == .coordinator {
                        Button("Invite someone") { inviting = true }
                    }
                }
                if model.me?.role == .coordinator {
                    RelaySection()
                }
                if model.engine.isPrimaryCoordinator {
                    if model.group?.previousSecrets != nil { KeyUpdatesSection() }
                } else {
                    // Everyone but the first coordinator, other coordinators included, takes in new keys.
                    ReceiveUpdateSection()
                }
                Section {
                    Button("Leave this group", role: .destructive) { model.leave() }
                }
            }
            .navigationTitle(model.group?.name ?? "Group")
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
            if let invite, let code = try? Joining.code(invite), request == nil {
                Section("Ask them to scan this") {
                    QRCode(text: code).frame(maxWidth: 260).frame(maxWidth: .infinity)
                    ShareLink(item: code) { Label("Send it as a message instead", systemImage: "square.and.arrow.up") }
                }
                CodeReader(prompt: "Then scan the code on their phone") { c in
                    do { request = try Joining.decode(Joining.JoinRequest.self, from: c); error = nil } catch { self.error = "That is not their joining code." }
                }
            } else if let invite, let request, welcomeCode == nil {
                Section("Add \(request.name)?") {
                    Text(request.wantsToCall && request.wantsToRespond ? "Calls for help and responds" : (request.wantsToCall ? "Calls for help" : "Responds"))
                    Text("If you are not together, the number on their phone must be \(Joining.safetyNumber(model.identity.publicKey, request.publicKey)).")
                        .font(.footnote)
                    Button("Add them") {
                        var made: Joining.Welcome?
                        model.updateGroup { g in made = try? Joining.admit(request, to: &g, invite: invite, coordinator: model.identity) }
                        welcomeCode = made.flatMap { try? Joining.code($0) }
                        if welcomeCode == nil { error = "Could not add them. Start the invitation again." }
                    }
                }
            } else if let welcomeCode {
                Section("Ask them to scan this welcome code") {
                    QRCode(text: welcomeCode).frame(maxWidth: 320).frame(maxWidth: .infinity)
                    ShareLink(item: welcomeCode) { Label("Send it as a message instead", systemImage: "square.and.arrow.up") }
                    Button("Done") { dismiss() }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Invite someone")
        .onAppear { if invite == nil, let g = model.group { invite = Joining.invitation(for: g, coordinator: model.identity) } }
    }
}

/// After a phone is removed, every remaining member needs the new secrets.
struct KeyUpdatesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var shown: Member?

    var body: some View {
        Section("New keys to hand out") {
            Text("A phone was removed, so the group has new keys. Show each member their update code.").font(.footnote)
            ForEach((model.group?.members ?? []).filter { $0.number != model.saved?.me }) { m in
                Button("Update code for \(m.name)") { shown = m }
            }
        }
        .sheet(item: $shown) { m in
            if let g = model.group, let w = try? Joining.update(g, for: m, coordinator: model.identity), let code = try? Joining.code(w) {
                VStack(spacing: 16) {
                    Text("Update for \(m.name)").font(.headline)
                    QRCode(text: code).frame(maxWidth: 320)
                    ShareLink(item: code) { Label("Send it as a message instead", systemImage: "square.and.arrow.up") }
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
        Section("Key update") {
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

/// The number a caller's ready-written text goes to, if nothing else got through.
struct MyPhoneSection: View {
    @EnvironmentObject var model: AppModel
    @State private var phone = ""
    @State private var saved = false

    var body: some View {
        Section("Your mobile number") {
            TextField("Mobile number", text: $phone).keyboardType(.phonePad)
            Button("Save") { model.setMyPhone(phone); saved = true }
            Text(saved ? "Saved. Members with the internet route get it now; others when they next scan a code."
                       : "If a call cannot go any other way, the caller can send it to responders as a text.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { phone = model.me?.phone ?? "" }
    }
}

struct RelaySection: View {
    @EnvironmentObject var model: AppModel
    @State private var url = ""

    var body: some View {
        Section("Internet route") {
            TextField("Relay address, starting https://", text: $url).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("Save") { model.setRelay(url) }
            Text(model.relay.isConfigured ? "Calls also go over the internet." : "Not set up: calls go over the local radio only.")
                .font(.footnote)
            Text("Members get the address the next time they join or scan a key update.").font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { url = model.group?.relayURL ?? "" }
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
        Section("Check-ins") {
            Toggle("Check in at set times", isOn: $on)
            if on {
                DatePicker("First check-in", selection: $morning, displayedComponents: .hourAndMinute)
                Toggle("A second check-in", isOn: $twice)
                if twice { DatePicker("Second check-in", selection: $evening, displayedComponents: .hourAndMinute) }
                Text("Press I'm OK now within half an hour of each time. If you do not, your responders get a come-when-convenient call.")
                    .font(.footnote)
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
