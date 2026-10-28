import helpandeyeCore
import SwiftUI
import UserNotifications
import WatchKit

@main
struct HelpAWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchDelegate
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup { WatchCallView().environmentObject(model) }
    }
}

/// Lets the relay wake the watch when its phone is out of reach, so calls are heard with the app
/// closed.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func didRegisterForRemoteNotifications(withDeviceToken token: Data) {
        MainActor.assumeIsolated { WatchModel.shared.setPushToken(token) }
    }

    func didReceiveRemoteNotification(_ info: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        await WatchModel.shared.wake()
        return .newData
    }
}

/// The help buttons on the wrist. With the phone in reach they send through it; out of reach the
/// watch sends over its own internet. It does not replace the watch's own fall detection or
/// emergency calling, nor 999.
struct WatchCallView: View {
    @EnvironmentObject var model: WatchModel
    @State private var page = Page.buttons

    private enum Page { case buttons, details }

    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.needsSetUp {
                setUp
            } else {
                // The buttons fill the first page; what happened to a call, and others' calls, are on the next.
                TabView(selection: $page) {
                    buttons.tag(Page.buttons)
                    details.tag(Page.details)
                }
                .tabViewStyle(.verticalPage)
                // Whatever the watch has to say about a call is shown at once.
                .onChange(of: model.status?.text) { _, new in if new != nil { page = .details } }
                .onChange(of: model.open.count) { old, new in if new > old { page = .details } }
            }
        }
        .task(id: phase) { await model.checkAlerts() }
    }

    /// Buttons that could reach nobody are not shown: the wearer is told what to do instead.
    private var setUp: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Help&I is not set up on this watch yet.").font(.headline)
                Text("To set it up, open Help&I on your iPhone with this watch nearby.")
                Text("Until then, use your phone, or call 999.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Three clear buttons: the most urgent takes the bottom half, as on the phone.
    private var buttons: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                callButton(.amber, shape: RoundedRectangle(cornerRadius: 12))
                callButton(.green, shape: RoundedRectangle(cornerRadius: 12))
            }
            callButton(.red, shape: screenCorners)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// Lower corners that follow the screen's own, where the watch can draw them.
    private var screenCorners: AnyShape {
        if #available(watchOS 26, *) {
            AnyShape(ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: false))
        } else {
            AnyShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let status = model.status {
                    HStack(alignment: .firstTextBaseline) {
                        if status.cross { Image(systemName: "xmark").foregroundStyle(Colour.red.color).accessibilityLabel("Not sent") }
                        Text(status.text)
                    }
                }
                if let note = model.amberNote { Text(note) }
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
                if model.alertsOff {
                    Text("Alerts for Help&I are off on this watch, so it cannot tell you when someone calls. To turn them on, open the Watch app on your iPhone, then Notifications, then Help&I.")
                        .foregroundStyle(Colour.amber.color)
                }
                Text("Not a replacement for 999.")
                CallerVoiceToggle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func callButton(_ colour: Colour, shape: some Shape) -> some View {
        Button { model.press(colour) } label: {
            Text(model.words(colour)).font(.headline).multilineTextAlignment(.center)
                .foregroundStyle(colour.onColor)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colour.color, in: shape)
        }
        .buttonStyle(.plain)
    }
}
