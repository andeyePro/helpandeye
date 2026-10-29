import helpandeyeCore
import SwiftUI
import UserNotifications
import WatchKit

@main
struct HelpAWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchDelegate
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchCallView().environmentObject(model)
                .onOpenURL { if $0.host == "countdown" { model.startCountdown() } }
        }
    }
}

/// Lets the relay wake the watch when its phone is out of reach, so calls are heard with the app
/// closed.
final class WatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
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

    /// An alert still sounds and shows with Help&I open, as it does with it closed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
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
                // Whatever the watch has to say about a call is shown at once, except while counting
                // down to Help, when the page with the stop control stays in view.
                .onChange(of: model.status?.text) { _, new in if new != nil && model.countdown == nil { page = .details } }
                .onChange(of: model.open.count) { old, new in if new > old && model.countdown == nil { page = .details } }
                .onChange(of: model.countdown != nil) { _, counting in if counting { page = .buttons } }
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
    @ViewBuilder private var buttons: some View {
        // With no group of its own and no phone, these could reach nobody; other groups' calls are on the next page.
        if model.cannotCall {
            setUp
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    callButton(.amber, shape: RoundedRectangle(cornerRadius: 12))
                    callButton(.green, shape: RoundedRectangle(cornerRadius: 12))
                }
                callButton(.red, shape: screenCorners)
            }
            .ignoresSafeArea(edges: .bottom)
        }
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
                if let note = model.amberNote ?? model.okNote { Text(note) }
                ForEach(model.open) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.who).font(.headline)
                        Text(model.words(r))
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func callButton(_ colour: Colour, shape: some Shape) -> some View {
        let counting = colour == .red && model.countdown != nil
        return Button { model.press(colour) } label: {
            Group {
                if counting {
                    VStack(spacing: 0) {
                        Text("\(model.words(.red)) in").font(.headline)
                        Text("\(model.secondsLeft)").font(.system(.largeTitle, design: .rounded).bold()).monospacedDigit()
                    }
                } else {
                    label(colour).font(.headline)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(colour.onColor)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colour.color, in: shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(counting ? "\(model.words(.red)) in \(model.secondsLeft) seconds. Press to call now." : model.words(colour))
    }

    /// Words, a symbol, or both, as on the phone; the symbol is left out when both will not fit.
    @ViewBuilder private func label(_ colour: Colour) -> some View {
        let p = model.profile
        let symbol = Image(systemName: p.symbol(colour))
        switch p.face {
        case .words: Text(model.words(colour))
        case .symbol: symbol.font(.title2)
        case .wordsAndSymbol:
            ViewThatFits(in: .vertical) {
                VStack(spacing: 2) { symbol; Text(model.words(colour)) }
                Text(model.words(colour))
            }
        }
    }
}
