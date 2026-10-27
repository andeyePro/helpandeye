import HelpAndICore
import SwiftUI

@main
struct HelpAndIApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var watch = PhoneWatchLink()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { watch.attach(model) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let me = model.me {
            TabView {
                if me.canCall {
                    CallView().tabItem { Label("Help", systemImage: "cross.fill") }
                }
                if me.canRespond {
                    RespondView().tabItem { Label("Respond", systemImage: "bell.fill") }
                        .badge(model.inbox.requests.values.filter { !$0.isAcknowledged }.count)
                }
                GroupView().tabItem { Label("Group", systemImage: "person.3.fill") }
                BoxView().tabItem { Label("Box", systemImage: "antenna.radiowaves.left.and.right") }
            }
        } else {
            WelcomeView()
        }
    }
}

/// Shown wherever someone might rely on Help&I (decision 13). Do not remove or soften it.
struct NotA999Notice: View {
    var body: some View {
        Text("Help&I does not replace 999 or telecare. In an emergency, call 999 first if you can.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }
}

extension Colour {
    var color: Color {
        switch self { case .red: .red; case .amber: .orange; case .green: Color(red: 0, green: 0.6, blue: 0.27) }
    }
    var label: String {
        switch self { case .red: "Come now"; case .amber: "Come when convenient"; case .green: "I'm OK now" }
    }
}

extension CallCategory {
    var label: String {
        switch self {
        case .fallen: "I've fallen"; case .unwell: "I feel unwell"; case .lockedOut: "I'm locked out"
        case .powerCut: "Power cut"; case .needCompany: "I'd like company"; case .other: "Something else"
        }
    }
}
