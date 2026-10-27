import SwiftUI
import WatchConnectivity

@main
struct HelpAndIWatchApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup { WatchCallView().environmentObject(link) }
    }
}

/// The help button on the wrist. It sends through the paired phone. It does not replace the
/// watch's own fall detection or emergency calling.
struct WatchCallView: View {
    @EnvironmentObject var link: WatchLink

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let status = link.status {
                    HStack(alignment: .firstTextBaseline) {
                        if link.failed { Image(systemName: "xmark").foregroundStyle(.red).accessibilityLabel("Not sent") }
                        Text(status).font(.footnote)
                    }
                }
                Button { link.press(1) } label: { Text("Come now").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 70) }
                    .tint(.red)
                HStack {
                    Button { link.press(2) } label: { Text("When convenient").font(.caption2.bold()).frame(maxWidth: .infinity, minHeight: 44) }
                        .tint(.orange)
                    Button { link.press(3) } label: { Text("I'm OK").font(.caption2.bold()).frame(maxWidth: .infinity, minHeight: 44) }
                        .tint(.green)
                }
                Text("Not a replacement for 999.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
final class WatchLink: NSObject, ObservableObject {
    @Published var status: String?
    @Published var failed = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func press(_ colour: Int) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            status = "Not sent: your phone is out of reach. Use your phone, or call 999."; failed = true; return
        }
        status = "Sending…"; failed = false
        WCSession.default.sendMessage(["press": colour], replyHandler: { reply in
            let ok = reply["ok"] as? Bool == true
            Task { @MainActor in
                if !ok { self.status = "Not sent: set up Help&I on your phone first."; self.failed = true }
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.status = "Not sent: your phone did not answer. Use your phone, or call 999."; self.failed = true }
        })
    }

    fileprivate func apply(_ context: [String: Any]) {
        if let s = context["status"] as? String { status = s }
        failed = context["failed"] as? Bool ?? false
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = s.receivedApplicationContext
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ s: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context) }
    }
}
