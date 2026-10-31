import helpandeyeCore
import NetworkExtension
import UserNotifications

/// Keeps the home Wi-Fi route listening while Help&I is not running (decision 19). iOS runs this
/// local push provider whenever the phone is on the home Wi-Fi network its owner named, with the
/// phone locked or the app closed. It joins the group's phones on the network as the app does, and
/// turns a call it hears into an alert; opening Help&I does the rest, as the caller's phone keeps
/// sending until someone acknowledges. It confirms only the calls it alerts for: anything else
/// (a note, a position, an acknowledgement) it does not keep, so the sender does not count it as
/// sent here and carries on by its other routes. It reads the group afresh with each frame and
/// once a minute, so a change made in the app since it started counts, and a phone whose owner
/// left or was removed stops. Needs signing, with the shared keychain group (as the notification
/// extension does) and the local push entitlement.
final class LocalPushProvider: NEAppPushProvider {
    private var home: HomeWiFi?
    private var recheck: Task<Void, Never>?

    override func start() {
        Task { @MainActor [weak self] in
            let home = HomeWiFi()
            home.keeps = { frame in
                guard case let .call(unit, _, colour, _) = frame, colour != .green, let me = Self.current()?.me else { return false }
                return me.canRespond && unit != me.unit
            }
            home.onFrame = { frame in
                if let saved = SharedStore.saved() { self?.alert(for: frame, saved: saved) }
                self?.follow()
            }
            self?.home = home
            self?.follow()
            self?.recheck = Task { @MainActor in
                while !Task.isCancelled, self != nil {
                    try? await Task.sleep(for: .seconds(60))
                    self?.follow()
                }
            }
        }
    }

    override func stop(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            recheck?.cancel()
            recheck = nil
            if let identity = SharedStore.identity() { self.home?.configure(group: nil, me: nil, identity: identity) }
            self.home = nil
            completionHandler()
        }
    }

    /// The group as the app last saved it, and this phone in it; nothing for a phone whose owner
    /// is no longer a member, which must not go on joining the group's phones as one.
    private static func current() -> (saved: SavedState, me: Member)? {
        guard let s = SharedStore.saved(), let me = s.group.member(s.me) else { return nil }
        return (s, me)
    }

    /// Joins the group's phones as the app saved it last, or stops: the link restarts only when
    /// the keys, the member list or this phone's place changed.
    @MainActor private func follow() {
        guard let home, let identity = SharedStore.identity() else { return }
        let now = Self.current()
        home.configure(group: now?.saved.group, me: now?.saved.me, identity: identity)
    }

    /// A call alerts again with each resend heard, at most once a minute, named as the app would
    /// name it, for a responder only, until someone acknowledges or closes it: one missed alert is
    /// not the end of it. A caller who says they are OK after it gets one calm alert instead; the
    /// app, once opened, follows the coordinator's reminders. Never says help is coming: it asks
    /// them to open Help&I.
    private var alerted: [IncomingRequest.Key: Date] = [:]
    private var calmed: Set<IncomingRequest.Key> = []
    private var done: Set<IncomingRequest.Key> = []
    /// When each call was pressed: the same numbers with another press time are a new call (a new
    /// watch, or a restored phone), so what was known of the old one goes.
    private var pressed: [IncomingRequest.Key: UInt32] = [:]

    @MainActor private func alert(for frame: HelpFrame, saved: SavedState) {
        guard let me = saved.group.member(saved.me), me.canRespond else { return }
        let center = UNUserNotificationCenter.current()
        switch frame {
        case let .call(unit, request, colour, sentAt) where colour != .green && unit != me.unit:
            let key = IncomingRequest.Key(unit: unit, request: request)
            if let before = pressed[key], before != sentAt { alerted[key] = nil; calmed.remove(key); done.remove(key) }
            pressed[key] = sentAt
            guard !done.contains(key), !calmed.contains(key), Date().timeIntervalSince(alerted[key] ?? .distantPast) >= 60 else { return }
            alerted[key] = Date()
            let who = saved.group.member(unit: unit)?.name ?? "Unit \(unit)"
            post("\(who): \(ButtonWords.words(colour, in: saved.group.profile(ofUnit: unit)))", "Open Help&I to acknowledge.", key: key, urgent: true)
        case let .ack(unit, request, _, _, _) where saved.group.acceptsAck(frame):
            let key = IncomingRequest.Key(unit: unit, request: request)
            done.insert(key)
            center.removeDeliveredNotifications(withIdentifiers: [Self.id(key)])
        case let .signed(signer, _, _):
            guard let sender = saved.group.member(signer),
                  case let .callState(unit, request, state, _, _)? = frame.verifiedInner(signedBy: sender.signingKey, group: saved.group.secrets.groupID),
                  state == .callerOK ? sender.unit == unit
                  : state == .closedByCaller ? sender.unit == unit && saved.group.profile(ofUnit: unit).callerMayEnd
                  : sender.role == .coordinator else { return }
            let key = IncomingRequest.Key(unit: unit, request: request)
            if state.closes {
                done.insert(key)
                center.removeDeliveredNotifications(withIdentifiers: [Self.id(key)])
            } else if alerted[key] != nil, !done.contains(key), calmed.insert(key).inserted {
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
