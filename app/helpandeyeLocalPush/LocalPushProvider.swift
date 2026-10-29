import helpandeyeCore
import NetworkExtension
import UserNotifications

/// Keeps the home Wi-Fi route listening while Help&I is not running (decision 19). iOS runs this
/// local push provider whenever the phone is on the home Wi-Fi network its owner named, with the
/// phone locked or the app closed. It joins the group's phones on the network as the app does, and
/// turns a call it hears into an alert; opening Help&I does the rest, as the caller's phone keeps
/// sending until someone acknowledges. It confirms only the calls it alerts for: anything else
/// (a note, a position, an acknowledgement) it does not keep, so the sender does not count it as
/// sent here and carries on by its other routes. It reads the group afresh with each frame, so a
/// change made in the app since it started counts. Needs signing, with the shared keychain group
/// (as the notification extension does) and the local push entitlement.
final class LocalPushProvider: NEAppPushProvider {
    private var home: HomeWiFi?

    override func start() {
        Task { @MainActor in
            guard let saved = SharedStore.saved(), let identity = SharedStore.identity() else { return }
            let home = HomeWiFi()
            home.keeps = { frame in
                guard case let .call(unit, _, colour, _) = frame, colour != .green, let s = SharedStore.saved(),
                      let me = s.group.member(s.me) else { return false }
                return me.canRespond && unit != me.unit
            }
            home.onFrame = { [weak self, weak home] frame in
                guard let saved = SharedStore.saved() else { return }
                self?.alert(for: frame, saved: saved)
                home?.configure(group: saved.group, me: saved.me, identity: identity)
            }
            home.configure(group: saved.group, me: saved.me, identity: identity)
            self.home = home
        }
    }

    override func stop(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if let identity = SharedStore.identity() { self.home?.configure(group: nil, me: nil, identity: identity) }
            self.home = nil
            completionHandler()
        }
    }

    /// Each call is alerted once, named as the app would name it, for a responder only, and its
    /// alert goes when someone acknowledges or closes it. A caller who says they are OK after it gets
    /// one calm alert instead; the app, once opened, follows the coordinator's reminders. Never says
    /// help is coming: it asks them to open Help&I.
    private var alerted: Set<IncomingRequest.Key> = []
    private var calmed: Set<IncomingRequest.Key> = []

    @MainActor private func alert(for frame: HelpFrame, saved: SavedState) {
        guard let me = saved.group.member(saved.me), me.canRespond else { return }
        let center = UNUserNotificationCenter.current()
        switch frame {
        case let .call(unit, request, colour, _) where colour != .green && unit != me.unit:
            let key = IncomingRequest.Key(unit: unit, request: request)
            guard alerted.insert(key).inserted else { return }
            let who = saved.group.member(unit: unit)?.name ?? "Unit \(unit)"
            post("\(who): \(ButtonWords.words(colour, in: saved.group.profile(ofUnit: unit)))", "Open Help&I to acknowledge.", key: key, urgent: true)
        case let .ack(unit, request, _, _, _) where saved.group.acceptsAck(frame):
            center.removeDeliveredNotifications(withIdentifiers: [Self.id(IncomingRequest.Key(unit: unit, request: request))])
        case let .signed(signer, _, _):
            guard let sender = saved.group.member(signer),
                  case let .callState(unit, request, state, _, _)? = frame.verifiedInner(signedBy: sender.signingKey, group: saved.group.secrets.groupID),
                  state == .callerOK ? sender.unit == unit
                  : state == .closedByCaller ? sender.unit == unit && saved.group.profile(ofUnit: unit).callerMayEnd
                  : sender.role == .coordinator else { return }
            let key = IncomingRequest.Key(unit: unit, request: request)
            if state.closes {
                center.removeDeliveredNotifications(withIdentifiers: [Self.id(key)])
            } else if alerted.contains(key), calmed.insert(key).inserted {
                let who = saved.group.member(unit: unit)?.name ?? "Unit \(unit)"
                post("\(who) says they're OK now", "Please check on them, then acknowledge in Help&I.", key: key, urgent: false)
            }
        default: break
        }
    }

    private static func id(_ key: IncomingRequest.Key) -> String { "wifi-\(key.unit)-\(key.request)" }

    private func post(_ title: String, _ body: String, key: IncomingRequest.Key, urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = urgent ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.id(key), content: content, trigger: nil))
    }
}
