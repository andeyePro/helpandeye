import CoreBluetooth
import HelpAndICore
import SwiftUI

/// Pairing and checking the Help&I box: a Heltec board on MeshCore's companion firmware.
struct BoxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(statusText)
                    if let info = model.board.selfInfo {
                        LabeledContent("Name", value: info.name)
                        LabeledContent("Frequency", value: String(format: "%.3f MHz", info.radio.frequencyMHz))
                        if let band = info.radio.band {
                            LabeledContent("Band", value: "\(band.name), \(Int(band.dutyCycle * 100))% of the time")
                        } else {
                            Text("This box is on a frequency outside the UK licence-exempt bands Help&I uses, so Help&I will not send on it.")
                                .foregroundStyle(.red)
                        }
                    }
                    if let mv = model.board.batteryMillivolts {
                        LabeledContent("Box battery", value: String(format: "%.2f V", Double(mv) / 1000))
                    }
                }
                Section("Boxes nearby") {
                    Button("Look for boxes") { model.board.startSearch() }
                    ForEach(model.board.found, id: \.identifier) { p in
                        Button(p.name ?? "MeshCore box") { model.board.connect(p) }
                    }
                }
                if Store.boardID != nil {
                    Section { Button("Forget this box", role: .destructive) { model.board.forget() } }
                }
            }
            .navigationTitle("Box")
        }
    }

    private var statusText: String {
        switch model.board.state {
        case .off: "No box connected. Calls can still go over the internet when it is set up."
        case .unauthorised: "Help&I is not allowed to use Bluetooth. Turn it on in Settings."
        case .searching: "Looking for boxes…"
        case .connecting: "Connecting to your box…"
        case .ready: "Connected. Calls can go over the local radio."
        case let .failed(why): "Problem with the box: \(why)"
        }
    }
}
