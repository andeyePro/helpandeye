import HelpAndICore
import SwiftUI

@main
struct HelpAndIApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup { RootView().environmentObject(AppModel.shared) }
    }
}

/// Creates the model and the watch link at launch, before any screen, so that a launch in the
/// background (a watch button, or Bluetooth restoring the box connection) finds them ready.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let watch = PhoneWatchLink()

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { watch.attach(AppModel.shared) }
        app.registerForRemoteNotifications()
        return true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { AppModel.shared.relay.pushToken = token }
    }

    /// A push from the relay: fetch what is waiting, which schedules this phone's own alerts.
    func application(_ app: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any],
                     fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await AppModel.shared.relay.poll()
            AppModel.shared.tick()
            done(.newData)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let me = model.me {
            VStack(spacing: 0) {
                NoticeBanner()
                tabs(me)
            }
        } else {
            WelcomeView()
        }
    }

    @ViewBuilder private func tabs(_ me: Member) -> some View {
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
    }
}

/// A notice someone must acknowledge: a gap in the rota, or the free relay allowance running low.
/// It widens from the coordinator to everyone until someone acknowledges it.
struct NoticeBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(spacing: 0) {
                ForEach(Notice.allCases.filter(model.showing), id: \.self) { n in
                    HStack {
                        Text(text(n)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Acknowledge") { model.acknowledge(n) }.buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.2))
                }
            }
        }
    }

    private func text(_ n: Notice) -> String {
        switch n {
        case .rotaGap: "Nobody is available to respond for part of the next 24 hours. See Group."
        case .allowanceLow: "The free internet relay is nearly used up for today. Calls will still go over the local radio."
        case .unconfirmed: "The coordinator who invited you has left the group, and the others may not know you are in it. Ask another coordinator to check, and to invite you again if needed."
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
        case .powerCut: "Power cut"; case .needCompany: "I'd like company"; case .missedCheckIn: "Missed a check-in"
        case .other: "Something else"
        }
    }
}
