import SwiftUI
import WatchConnectivity

@main
struct HelpAWatchApp: App {
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
                ForEach(link.open) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.who).font(.headline)
                        Text(r.colour == 2 ? "Come when convenient" : (r.colour == 3 ? "I'm OK now" : "Come now")).font(.caption)
                        Button("Acknowledge") { link.acknowledge(r) }.tint(.blue)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(r.colour == 2 ? .orange : (r.colour == 3 ? .green : .red)))
                }
                if let status = link.status {
                    HStack(alignment: .firstTextBaseline) {
                        if link.failed { Image(systemName: "xmark").foregroundStyle(.red).accessibilityLabel("Not sent") }
                        Text(status).font(.footnote)
                    }
                }
                Button { link.press(1) } label: { Text("Come now").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 70) }
                    .tint(.red)
                    .accessibilityHint("Asks your responders to come now")
                HStack {
                    Button { link.press(2) } label: { Text("When convenient").font(.caption2.bold()).frame(maxWidth: .infinity, minHeight: 44) }
                        .tint(.orange)
                    Button { link.press(3) } label: { Text("I'm OK").font(.caption2.bold()).frame(maxWidth: .infinity, minHeight: 44) }
                        .tint(.green)
                }
                Text("Not a replacement for 999.").font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
final class WatchLink: NSObject, ObservableObject {
    struct Open: Identifiable, Equatable {
        let unit: Int, request: Int, colour: Int, who: String
        var id: String { "\(unit)-\(request)" }
    }

    @Published var status: String?
    @Published var failed = false
    @Published var open: [Open] = []

    /// Acknowledging needs the phone, which sends the signed acknowledgement.
    func acknowledge(_ r: Open) {
        guard WCSession.default.isReachable else { status = "Not acknowledged: your phone is out of reach."; failed = true; return }
        WCSession.default.sendMessage(["ackUnit": r.unit, "ackRequest": r.request], replyHandler: { reply in
            let ok = reply["ok"] as? Bool == true
            Task { @MainActor in
                if ok { self.open.removeAll { $0 == r } } else { self.status = "Not acknowledged. Use your phone."; self.failed = true }
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.status = "Not acknowledged: your phone did not answer."; self.failed = true }
        })
    }

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
        open = (context["open"] as? [[String: Any]] ?? []).compactMap { d in
            guard let u = d["unit"] as? Int, let r = d["request"] as? Int, let c = d["colour"] as? Int, let w = d["who"] as? String else { return nil }
            return Open(unit: u, request: r, colour: c, who: w)
        }
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
