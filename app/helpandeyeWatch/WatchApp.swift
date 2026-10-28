import helpandeyeCore
import SwiftUI

@main
struct HelpAWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup { WatchCallView().environmentObject(model) }
    }
}

/// The help buttons on the wrist. With the phone in reach they send through it; out of reach the
/// watch sends over its own internet. It does not replace the watch's own fall detection or
/// emergency calling, nor 999.
struct WatchCallView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // On the wrist the most urgent button comes first, where it is seen without scrolling.
                callButton(.red, minHeight: 70)
                HStack {
                    callButton(.amber, minHeight: 50)
                    callButton(.green, minHeight: 50)
                }
                if let status = model.status {
                    HStack(alignment: .firstTextBaseline) {
                        if status.cross { Image(systemName: "xmark").foregroundStyle(Colour.red.color).accessibilityLabel("Not sent") }
                        Text(status.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.open) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.who).font(.headline)
                        Text(model.words(r.colour))
                        Button("Acknowledge") { model.acknowledge(r) }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0, green: 0x55 / 255, blue: 0xD4 / 255))
                    }
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(r.colour.color, lineWidth: 2))
                }
                if !model.phoneInReach {
                    Text(model.engine?.me == nil ? "Your phone is out of reach. Open Help&I on your phone once, with this watch nearby, so it can call without the phone."
                                                 : "Your phone is out of reach: calls go over this watch's own internet.")
                }
                Text("Not a replacement for 999.")
            }
        }
    }

    private func callButton(_ colour: Colour, minHeight: CGFloat) -> some View {
        Button { model.press(colour) } label: {
            Text(model.words(colour)).font(.headline).multilineTextAlignment(.center)
                .foregroundStyle(colour.onColor)
                .frame(maxWidth: .infinity, minHeight: minHeight)
        }
        .buttonStyle(.borderedProminent)
        .tint(colour.color)
    }
}
