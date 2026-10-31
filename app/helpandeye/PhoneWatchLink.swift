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
        // The signed acknowledgements of the watch's own calls, for the watch to check as if heard
        // on air: one that came over the box alone otherwise leaves the watch resending, and
        // saying "waiting" once out of reach, for a call already seen.
        context["mine"] = model.engines.flatMap { e in
            e.activity.outgoing.filter { $0.number >= 0x8000 && !$0.acks.isEmpty }.suffix(5).map { r -> [String: Any] in
                ["group": e.group?.tag ?? "", "acks": r.acks.values.map { $0.encoded() }]
            }
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
            // Calls a person has settled here (acknowledged or closed, decision 6), newest first:
            // the watch's own copy of the group settles the same way, so it never alerts for a
            // call already in hand. The signed acknowledgements held go with them, for the watch
            // to check as if heard on air; a close has no frame it could check, so its key alone goes.
            let settled = model.engines.flatMap { e in e.activity.inbox.requests.values.filter { !$0.isOpen }.map { (e, $0) } }
            context["settled"] = settled.sorted { $0.1.firstHeardAt > $1.1.firstHeardAt }.prefix(20).map { e, r -> [String: Any] in
                ["unit": Int(r.key.unit), "request": Int(r.key.request), "group": e.group?.tag ?? "", "acks": r.acks.values.map { $0.encoded() }]
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
        // Each change replaces the last: a handover still waiting to go is stale now, and a watch
        // away for a day should not be given every state its phone passed through.
        for t in WCSession.default.outstandingUserInfoTransfers where !t.isTransferring { t.cancel() }
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
    /// Help&I was installed on the watch after the phone had its group: the watch has none of it.
    nonisolated func sessionWatchStateDidChange(_ s: WCSession) {
        Task { @MainActor in self.handedOver = nil; self.pushStatus() }
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
