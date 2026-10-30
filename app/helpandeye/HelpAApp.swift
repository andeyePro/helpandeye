import helpandeyeCore
import SwiftUI

@main
struct HelpAApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup { LaunchGate() }
    }
}

/// Creates the model and the watch link at launch, before any screen, so that a launch in the
/// background (a watch button, or Bluetooth restoring the box connection) finds them ready.
/// Before the phone's first unlock after a restart, the group and saved calls cannot be read: the
/// model waits for them, rather than start empty and later save the empty state over them.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let watch = PhoneWatchLink()
    private var started = false
    private var token: Data?

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Store.readable { start() } else { Launch.shared.waited = true }
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if Store.readable { self?.start() } }
        }
        app.registerForRemoteNotifications()
        return true
    }

    @MainActor private func start() {
        guard !started else { return }
        started = true
        watch.attach(AppModel.shared)
        if let token { AppModel.shared.setPushToken(token) }
        // A push that came before the first unlock was not fetched then.
        if Launch.shared.waited { Task { await AppModel.shared.wake() } }
        Launch.shared.ready = true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated {
            self.token = token
            if started { AppModel.shared.setPushToken(token) }
        }
    }

    /// A push from the relay: fetch what is waiting, which schedules this phone's own alerts.
    func application(_ app: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any],
                     fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
        guard MainActor.assumeIsolated({ started }) else { done(.noData); return }
        Task { @MainActor in
            await AppModel.shared.wake()
            done(.newData)
        }
    }
}

/// Whether the model has started, which waits for the phone's first unlock after a restart.
@MainActor final class Launch: ObservableObject {
    static let shared = Launch()
    @Published var ready = false
    var waited = false
}

/// The screens, once the model has started; nothing that could create it empty before then.
struct LaunchGate: View {
    @ObservedObject private var launch = Launch.shared
    var body: some View {
        if launch.ready { SizedRoot().environmentObject(AppModel.shared) } else { Text("Unlock this phone to use Help&I.").padding() }
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
        .onChange(of: phase) { _, now in if now == .active { AppModel.shared.resume() } }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let me = model.me {
            VStack(spacing: 0) {
                // Never more than a third of the screen, however large the text, so the call
                // buttons below always show; longer warnings scroll.
                ScrollView {
                    VStack(spacing: 0) {
                        NotificationsBanner()
                        KeysBanner()
                        if model.saveFailed {
                            Text("Help&I could not save its latest changes on this phone, so they could be lost if it closes. Calls still go. Freeing some space on the phone may help.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.orange.opacity(0.2))
                        }
                        NoticeBanner()
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: UIScreen.main.bounds.height / 3)
                .fixedSize(horizontal: false, vertical: true)
                // A profile can leave a caller only the three buttons (app spec, Profiles).
                if me.role == .caller && model.profile.hidesSettings { CallView() } else { tabs(me) }
            }
        } else if !model.others.isEmpty {
            // Removed from the first group but still in others: still respond in those.
            TabView {
                RespondView().tabItem { Label("Respond", systemImage: "bell.fill") }
                    .badge(model.engines.reduce(0) { $0 + $1.activity.inbox.requests.values.filter(\.isOpen).count })
                SurvivingAvailability().tabItem { Label("Available", systemImage: "clock.fill") }
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

/// The availability control for someone removed from their first group: it is otherwise only in the
/// Group view, which they no longer have. It sets it in every group they still respond in.
struct SurvivingAvailability: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let responder = model.engines.first { $0.me?.canRespond == true }
        Form {
            Section(header: Header("Your availability")) {
                if let responder, let me = responder.me {
                    let available = responder.activity.rota.isAvailable(me.number, at: Date())
                    Text(available ? "You are available to respond." : "You are not available.")
                    Button(available ? "I'm not available for the next 12 hours" : "I'm available for the next 12 hours") {
                        model.setAvailable(!available)
                    }
                }
            }
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
                        Text(text(n)).font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
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

/// After a removal, until this phone scans its update code: by when, and once too late, that it
/// can no longer reach the group.
struct KeysBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3600)) { _ in
            if let end = model.keysEndAt {
                Text(model.engine.keysExpired
                     ? "This phone cannot reach your group until you scan the new code from your coordinator, under Group. If you need help now, call 999."
                     : "Please scan the new code from your coordinator, under Group, by \(end.formatted(date: .long, time: .omitted)). After that this phone cannot reach your group until you do.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.orange.opacity(0.2))
            }
        }
    }
}

/// Notifications turned off for Help&I, or Time Sensitive for a responder, until put right.
struct NotificationsBanner: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let problem = model.notificationProblem {
            ViewThatFits(in: .horizontal) {
                HStack { message(problem); settings }
                VStack(alignment: .leading) { message(problem); settings }
            }
            .padding()
            .background(Color.orange.opacity(0.2))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        Button("Open Settings") { URL(string: UIApplication.openNotificationSettingsURLString).map { openURL($0) } }.buttonStyle(.action)
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
