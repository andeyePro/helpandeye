import helpandeyeCore
import SwiftUI

@main
struct HelpAApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup { SizedRoot().environmentObject(AppModel.shared) }
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
        MainActor.assumeIsolated { AppModel.shared.setPushToken(token) }
    }

    /// A push from the relay: fetch what is waiting, which schedules this phone's own alerts.
    func application(_ app: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any],
                     fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await AppModel.shared.wake()
            done(.newData)
        }
    }
}

/// Applies the reader's chosen text size to every screen.
struct SizedRoot: View {
    @AppStorage(TextSize.key) private var size = TextSize.asPhone
    @Environment(\.scenePhase) private var phase
    var body: some View {
        // Left alone unless a larger size is chosen, so the phone's own setting applies directly.
        Group {
            if size == .asPhone { RootView().tint(.link) } else { RootView().dynamicTypeSize(size.sizes).tint(.link) }
        }
        .onChange(of: phase) { _, now in if now == .active { AppModel.shared.resumeHomeWiFi() } }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let me = model.me {
            VStack(spacing: 0) {
                NoticeBanner()
                // A profile can leave a caller only the three buttons (app spec, Profiles).
                if me.role == .caller && model.profile.hidesSettings { CallView() } else { tabs(me) }
            }
        } else if !model.others.isEmpty {
            // Removed from the first group but still in others: still respond in those.
            TabView {
                RespondView().tabItem { Label("Respond", systemImage: "bell.fill") }
                    .badge(model.engines.reduce(0) { $0 + $1.activity.inbox.requests.values.filter(\.isOpen).count })
                WelcomeView().tabItem { Label("Group", systemImage: "person.3.fill") }
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
                if me.canRespond || !model.others.isEmpty {
                    RespondView().tabItem { Label("Respond", systemImage: "bell.fill") }
                        .badge(model.engines.reduce(0) { $0 + $1.activity.inbox.requests.values.filter(\.isOpen).count })
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
                        Button("Acknowledge") { model.acknowledge(n) }.buttonStyle(.action)
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
        case .unconfirmed: "The group's first coordinator has not confirmed you yet, so the others may not know you are in the group. Ask a coordinator to check."
        case .inviterLeft: "The coordinator who invited you has left the group, and the others may not know you are in it. Ask another coordinator to check, and to invite you again if needed."
        }
    }
}

/// Shown wherever someone might rely on Help&I (decision 13). Do not remove or soften it.
struct NotA999Notice: View {
    var body: some View {
        Text("Help&I does not replace 999 or telecare. In an emergency, call 999 first if you can.")
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
    }
}

extension Colour {
    /// This caller's words for the button, from their profile.
    @MainActor var label: String { ButtonWords.words(self, in: AppModel.shared.profile) }
}

extension CallCategory {
    @MainActor var label: String { ButtonWords.words(self, in: AppModel.shared.profile) }
}
