import CoreBluetooth
import helpandeyeCore
import SwiftUI

/// Pairing and checking the Help&I box: a Heltec board on MeshCore's companion firmware, stock or
/// Help&I's own build (firmware/DESIGN.md), which is a member of the group in its own right.
struct BoxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let pin = model.board.boxPin {
                    Section(header: Header("Bluetooth code")) {
                        Text("Your box's Bluetooth code is \(String(pin)). You need it to pair a phone with this box. It takes effect the next time the box is switched on.")
                    }
                }
                Section(header: Header("Status")) {
                    Text(statusText)
                    if let device = model.board.deviceInfo {
                        LabeledContent("Firmware", value: device.isHelpBox ? "Help&I box" : "MeshCore box")
                    }
                    if let info = model.board.selfInfo {
                        LabeledContent("Name", value: info.name)
                        LabeledContent("Frequency", value: String(format: "%.3f MHz", info.radio.frequencyMHz))
                        if let band = info.radio.band {
                            LabeledContent("Band", value: "\(band.name), \(Int(band.dutyCycle * 100))% of the time")
                        } else {
                            Text("This box is on a frequency outside the UK licence-exempt bands Help&I uses, so Help&I will not send on it.")
                                .foregroundStyle(Color.warning)
                        }
                    }
                    if let mv = model.board.batteryMillivolts {
                        LabeledContent("Box battery", value: String(format: "%.2f V", Double(mv) / 1000))
                    }
                }
                if model.board.isHelpBox { HelpBoxSection() }
                // A Help&I box has its own unit and antenna; a stock box is the radio of this phone's.
                if let m = model.boxMember ?? model.me, let unit = m.unit {
                    let antenna = model.group?.antenna(of: m.number) ?? .standardWhip
                    Section(header: Header("Antenna")) {
                        LabeledContent("On this box", value: antenna.words + (antenna.isExternal ? ", \(gainWords(antenna.gainDBi))" : ""))
                        PowerLimits(unit: unit)
                        Text("Set by your coordinator. The box keeps its radio under this limit once it is set up with Help&I's firmware.")
                    }
                }
                Section(header: Header("Boxes nearby")) {
                    Button(model.board.searching ? "Looking…" : "Look for boxes") { model.board.startSearch() }
                        .disabled(model.board.searching)
                    ForEach(model.board.found, id: \.identifier) { p in
                        Button {
                            model.board.connect(p)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(p.name ?? "MeshCore box")
                                if let pin = model.board.pin(for: p.identifier) { Text("Bluetooth code \(String(pin))") }
                            }
                        }
                    }
                }
                if Store.boardID != nil {
                    Section { Button("Forget this box", role: .destructive) { model.board.forget() } }
                }
            }
            .navigationTitle("Box")
            .keyboardDismissable()
        }
    }

    private var statusText: String {
        switch model.board.state {
        case .off: "No box connected. Calls can still go over the internet when it is set up."
        case .unauthorised: "Help&I is not allowed to use Bluetooth. Turn it on in Settings."
        case .connecting: "Connecting to your box…"
        case .ready: "Connected. Calls can go over the local radio."
        case let .failed(why): "Problem with the box: \(why)"
        }
    }
}

/// A box on Help&I's own firmware: whether it is in the group, its mains and battery, and its own
/// calls as it shows them. A coordinator adds it as a member of its own here; anyone else is told
/// what to ask their coordinator.
struct HelpBoxSection: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var home: UInt16?
    @State private var problem: String?

    var body: some View {
        Section(header: Header("Help&I box")) {
            if let member = model.boxMember {
                LabeledContent("In the group as", value: member.name)
                if let unit = member.unit { LabeledContent("Unit", value: String(unit)) }
                if model.me?.role == .coordinator {
                    BoxHomePicker(box: member.number, home: Binding(get: { model.group.flatMap { g in g.policy.boxHome[member.number].flatMap { g.member($0)?.number } } },
                                                                    set: { h in if let h { model.setHome(ofBox: member.number, to: h) } }))
                } else if let h = model.group?.policy.boxHome[member.number], let who = model.group?.member(h) {
                    LabeledContent("In the home of", value: who.name)
                }
                if let info = model.board.boxInfo {
                    Text(info.provisioned ? "Set up. Its buttons call for help with or without this phone." : "Setting up the box…")
                    LabeledContent("Power", value: powerWords(info))
                    if info.clockAhead { Text("This box's clock is ahead of its responders' phones. It takes its time from this phone, so check this phone's date and time.") }
                }
                Text(model.group?.policy.reportsPowerCut.contains(member.number) == true
                     ? "It tells your responders about a power cut at home. Your coordinator can change this."
                     : "It does not tell your responders about a power cut. Your coordinator can change this.")
                ForEach(model.board.boxCalls.reversed(), id: \.request) { call in
                    Text("\(call.colour.label), \(Date(timeIntervalSince1970: TimeInterval(call.pressedAt)).formatted(date: .omitted, time: .shortened)): \(words(call.status))")
                }
            } else if let group = model.group, model.me?.role == .coordinator {
                Text("This box is not in \(group.name) yet. Add it as a member of its own, so its buttons can call for help without a phone.")
                LabeledField(label: "Its name in the group, such as Kitchen box at no. 4", text: $name)
                BoxHomePicker(box: nil, home: $home)
                Button("Add this box to the group") {
                    if let home { problem = model.addBox(name: name.trimmingCharacters(in: .whitespacesAndNewlines), home: home) }
                }
                .buttonStyle(.action)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || home == nil)
                if let problem { Text(problem).foregroundStyle(Color.warning) }
            } else if let group = model.group {
                Text("This box is not in \(group.name) yet, so its buttons cannot call for help. Ask your coordinator to pair their phone with it once, here on the Box screen, and add it to the group.")
            } else {
                Text("Join a group first. Then your coordinator can add this box to it.")
            }
        }
    }

    private func powerWords(_ info: MeshCore.BoxInfo) -> String {
        let hours = info.hoursLeft == 0 ? "less than an hour of battery left" : "about \(info.hoursLeft) hours of battery left"
        switch (info.mains, info.mainsEstimated) {
        case (.on, false): return "On mains"
        case (.on, true): return "Probably on mains"
        case (.off, false): return "Power cut: on its battery, \(hours)"
        case (.off, true): return "Probably a power cut: its battery is falling, \(hours)"
        case (.unknown, _): return "Not known yet"
        }
    }

    /// What the box itself shows for its call. It knows only that a responder has seen it, not who.
    private func words(_ status: CallerStatus) -> String {
        switch status {
        case .sending: "Sending…"
        case .waitingForResponder: "Sent. Waiting for a responder to see it."
        case .seen: "A responder has seen it."
        case .notSent: "Not sent."
        case .closed: "Closed."
        }
    }
}

/// Whose home a Help&I box is in. Only that person's phone, connected to the box, carries its calls
/// and is not alerted for them; every other responder's phone is, the coordinator's included.
struct BoxHomePicker: View {
    @EnvironmentObject var model: AppModel
    let box: UInt16?
    @Binding var home: UInt16?

    var body: some View {
        Picker("In the home of", selection: $home) {
            if home == nil { Text("Choose someone").tag(UInt16?.none) }
            ForEach(model.group.map { g in g.members.filter { $0.number != box && !g.isBox($0) } } ?? []) { m in
                Text(m.name).tag(Optional(m.number))
            }
        }
        Text("Their phone, when connected to the box, also sends its calls over the internet and home Wi-Fi, and is not alerted for them. Everyone else who responds is alerted as usual.")
    }
}
