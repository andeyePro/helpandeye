import NetworkExtension
import SwiftUI

/// Lets iOS keep the home Wi-Fi route listening with the phone locked (decision 19): a local push
/// configuration for the home network the owner names, run by the LocalPush extension.
@MainActor final class HomeWiFiSetup: ObservableObject {
    @Published private(set) var network: String?
    @Published private(set) var problem: String?

    func load() async {
        network = (try? await NEAppPushManager.loadAllFromPreferences())?.first?.matchSSIDs.first
    }

    func listen(on ssid: String) async {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let manager = (try? await NEAppPushManager.loadAllFromPreferences())?.first ?? NEAppPushManager()
        manager.localizedDescription = "Help&I home Wi-Fi"
        manager.providerBundleIdentifier = "com.andeye.help.localpush"
        manager.matchSSIDs = [name]
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            network = name
            problem = nil
        } catch {
            problem = "Could not set it up: \(error.localizedDescription). This needs a signed copy of Help&I."
        }
    }

    func stop() async {
        guard let manager = (try? await NEAppPushManager.loadAllFromPreferences())?.first else { return }
        try? await manager.removeFromPreferences()
        network = nil
    }
}

/// Under Group: the home Wi-Fi route, and keeping it listening with the phone locked.
struct HomeWiFiSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var setup = HomeWiFiSetup()
    @State private var ssid = ""

    var body: some View {
        Section(header: Header("Home Wi-Fi")) {
            let n = model.home.peerCount
            Text(n == 0 ? "No other phones of the group on this Wi-Fi now."
                 : "\(n) other phone\(n == 1 ? "" : "s") of the group on this Wi-Fi: calls reach them directly, with no internet.")
            if let network = setup.network {
                Text("Listening on \(network), even with this phone locked.")
                Button("Stop listening when locked") { Task { await setup.stop() } }
            } else {
                LabeledField(label: "Your home Wi-Fi's name, to keep listening when locked", text: $ssid)
                Button("Keep listening on this Wi-Fi") { Task { await setup.listen(on: ssid) } }
                Text("Without it, only while Help&I is open.")
            }
            if let problem = setup.problem { Text(problem).foregroundStyle(Color.warning) }
        }
        .task { await setup.load() }
    }
}
