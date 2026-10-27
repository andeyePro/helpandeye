import CoreBluetooth
import helpandeyeCore
import SwiftUI

/// Pairing and checking the Help&I box: a Heltec board on MeshCore's companion firmware.
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
