import helpandeyeCore
import NetworkExtension
import UserNotifications

/// Keeps the home Wi-Fi route listening while Help&I is not running (decision 19). iOS runs this
/// local push provider whenever the phone is on the home Wi-Fi network its owner named, with the
/// phone locked or the app closed. It joins the group's phones on the network as the app does, and
/// turns a call it hears into an alert; opening Help&I does the rest, as the caller's phone keeps
/// sending until someone acknowledges. Needs signing, with the shared keychain group (as the
/// notification extension does) and the local push entitlement.
final class LocalPushProvider: NEAppPushProvider {
    private var home: HomeWiFi?

    override func start() {
        Task { @MainActor in
            guard let saved = SharedStore.saved() else { return }
            let home = HomeWiFi()
            home.onFrame = { frame in Self.alert(for: frame, saved: saved) }
            home.configure(group: saved.group)
            self.home = home
        }
    }

    override func stop(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.home?.configure(group: nil)
            self.home = nil
            completionHandler()
        }
    }

    /// One alert per call, named as the app would name it, for a responder only. Never says help is
    /// coming: it asks them to open Help&I.
    private static func alert(for frame: HelpFrame, saved: SavedState) {
        guard case let .call(unit, request, colour, _) = frame, colour != .green, unit != saved.group.member(saved.me)?.unit,
              saved.group.member(saved.me)?.canRespond == true else { return }
        let content = UNMutableNotificationContent()
        let who = saved.group.member(unit: unit)?.name ?? "Unit \(unit)"
        content.title = "\(who): \(ButtonWords.words(colour, in: saved.group.profile(ofUnit: unit)))"
        content.body = "Open Help&I to acknowledge."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wifi-\(unit)-\(request)", content: content, trigger: nil))
    }
}
