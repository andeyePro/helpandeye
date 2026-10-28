import Combine
import Foundation
import helpandeyeCore
import WatchConnectivity

/// Lets the watch's buttons send through this phone, and shows the watch what happened.
@MainActor
final class PhoneWatchLink: NSObject, ObservableObject {
    private weak var model: AppModel?
    private var bag: Set<AnyCancellable> = []
    /// The handover last given to the watch, so it is sent again only when it changes.
    private var handedOver: Data?

    func attach(_ model: AppModel) {
        guard self.model == nil, WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.pushStatus() }
        }.store(in: &bag)
    }

    private func pushStatus() {
        guard let model, WCSession.default.activationState == .activated, WCSession.default.isPaired else { return }
        var context: [String: Any] = ["canCall": model.me?.canCall == true]
        if let r = model.current {
            context["colour"] = Int(r.colour.rawValue)
            context["unit"] = Int(r.unit)
            context["request"] = Int(r.number)
            let words = StatusWords.watch(r.status, name: model.name(ofMember:))
            context["status"] = words.headline
            context["failed"] = words.cross
        }
        // Open requests this person can acknowledge from the wrist, most urgent first. Names stay on
        // the paired watch, which is this person's own device.
        if model.me?.canRespond == true {
            context["open"] = model.inbox.sorted.filter { !$0.isAcknowledged }.prefix(5).map { r -> [String: Any] in
                ["unit": Int(r.key.unit), "request": Int(r.key.request), "colour": Int(r.colour?.rawValue ?? 1),
                 "who": model.name(ofUnit: r.key.unit)]
            }
        }
        try? WCSession.default.updateApplicationContext(context)
        handOver()
    }

    /// The group and this person's keys, so the watch can call and respond as them when this phone
    /// is out of reach. They go only to this person's own paired watch, as a one-off transfer that
    /// the watch moves into its keychain, and only when they change. Leaving the group tells the
    /// watch to forget them.
    private func handOver() {
        guard let model, WCSession.default.isWatchAppInstalled else { return }
        let data = model.saved.flatMap { try? JSONEncoder().encode(WatchHandover(saved: $0, identity: model.identity)) } ?? Data()
        guard data != handedOver else { return }
        handedOver = data
        WCSession.default.transferUserInfo(data.isEmpty ? ["left": true] : ["handover": data])
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushStatus() }
    }
    nonisolated func sessionDidBecomeInactive(_ s: WCSession) {}
    nonisolated func sessionDidDeactivate(_ s: WCSession) { s.activate() }

    nonisolated func session(_ s: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let unit = message["ackUnit"] as? Int, let request = message["ackRequest"] as? Int {
            // A person pressed Acknowledge on the watch: the same as pressing it on the phone.
            Task { @MainActor in
                guard let u = UInt32(exactly: unit), let r = UInt16(exactly: request) else { replyHandler(["ok": false]); return }
                let key = IncomingRequest.Key(unit: u, request: r)
                // The watch is told whether an acknowledgement was really made.
                replyHandler(["ok": self.model?.acknowledge(key) == true])
            }
            return
        }
        if let data = message["call"] as? Data {
            // A call the watch made and is sending itself: send it on this phone's routes too,
            // under the watch's number, so it stays one call.
            Task { @MainActor in replyHandler(["ok": HelpFrame(data).map { self.model?.engine.adopt($0) == true } ?? false]) }
            return
        }
        let raw = message["press"] as? Int
        Task { @MainActor in
            guard let raw, let colour = Colour(rawValue: UInt8(raw)), self.model?.me?.canCall == true else {
                replyHandler(["ok": false]); return
            }
            self.model?.press(colour)
            replyHandler(["ok": true])
        }
    }
}
