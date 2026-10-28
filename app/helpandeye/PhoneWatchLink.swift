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
        if model.engines.contains(where: { $0.me?.canRespond == true }) {
            // Every group's open calls together, most urgent first, then the first five.
            let open = model.engines.filter { $0.me?.canRespond == true }.flatMap { e in
                e.activity.inbox.requests.values.filter(\.isOpen).map { (e, $0) }
            }
            context["open"] = open.sorted { ResponderInbox.moreUrgent($0.1, $1.1) }.prefix(5).map { e, r -> [String: Any] in
                ["unit": Int(r.key.unit), "request": Int(r.key.request), "colour": Int(r.colour?.rawValue ?? 1),
                 "who": e.name(ofUnit: r.key.unit), "group": e.group?.tag ?? ""]
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
        let others = model.others.compactMap(\.engine.saved)
        let data = model.saved.flatMap { try? JSONEncoder().encode(WatchHandover(saved: $0, identity: model.identity, others: others)) } ?? Data()
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
    /// Another watch was paired: it has none of what the old one was given, so it gets it all.
    nonisolated func sessionDidDeactivate(_ s: WCSession) {
        Task { @MainActor in self.handedOver = nil }
        s.activate()
    }

    nonisolated func session(_ s: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let unit = message["ackUnit"] as? Int, let request = message["ackRequest"] as? Int {
            // A person pressed Acknowledge on the watch: the same as pressing it on the phone.
            Task { @MainActor in
                guard let u = UInt32(exactly: unit), let r = UInt16(exactly: request) else { replyHandler(["ok": false]); return }
                let key = IncomingRequest.Key(unit: u, request: r)
                // In the group the watch named, or, from an older watch, the only group with that
                // call open; never a guess.
                let engines = self.model?.engines ?? []
                let holding = engines.filter { $0.activity.inbox.requests[key]?.isOpen == true }.compactMap(\.group?.tag)
                let tag = AckRouting.group(named: message["group"] as? String, holding: holding)
                let engine = engines.first { tag != nil && $0.group?.tag == tag }
                // The watch is told whether an acknowledgement was really made.
                replyHandler(["ok": engine?.acknowledge(key) == true])
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
