import Foundation
import helpandeyeCore
import UserNotifications

/// Responder alerts and check-in reminders as local notifications, so they fire with the app in
/// the background.
@MainActor final class NotificationAlerts: AlertScheduler {
    private let center = UNUserNotificationCenter.current()
    /// Empty for the group this person calls in; a short tag for each other group they respond
    /// in, so the same unit and request numbers in two groups never share an alert.
    private let prefix: String
    private let ownsCheckIns: Bool

    init(prefix: String = "", ownsCheckIns: Bool = true) { self.prefix = prefix; self.ownsCheckIns = ownsCheckIns }

    private func ids(_ key: IncomingRequest.Key) -> [String] { (0..<64).map { "req-\(prefix)\(key.unit)-\(key.request)-\($0)" } }

    /// Whether an alert is this group's: another group's tag starts with a letter, this one's
    /// numbers straight away when it has none.
    private func isMine(_ id: String) -> Bool {
        let head = "req-" + prefix
        guard id.hasPrefix(head) else { return ownsCheckIns && id.hasPrefix("checkin-") }
        return !prefix.isEmpty || id.dropFirst(head.count).first?.isNumber == true
    }

    func schedule(_ alert: Alert) {
        center.removePendingNotificationRequests(withIdentifiers: ids(alert.key))
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.calm ? .default : .defaultCritical
        content.interruptionLevel = alert.calm ? .active : .timeSensitive
        for (n, at) in alert.times.prefix(64).enumerated() {
            let due = at.timeIntervalSinceNow
            let trigger = due < 1 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: due, repeats: false)
            center.add(UNNotificationRequest(identifier: ids(alert.key)[n], content: content, trigger: trigger))
        }
    }

    func cancel(_ key: IncomingRequest.Key) {
        center.removePendingNotificationRequests(withIdentifiers: ids(key))
        center.removeDeliveredNotifications(withIdentifiers: ids(key))
    }

    func cancelAll() {
        center.getPendingNotificationRequests { [isMine = self.isMine] pending in
            let mine = pending.map(\.identifier).filter(isMine)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: mine)
        }
    }

    func tellCaller(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: "caller-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func setCheckInReminders(_ minutes: [Int]) {
        // A group this person only responds in has no check-ins of theirs.
        guard ownsCheckIns else { return }
        center.removePendingNotificationRequests(withIdentifiers: (0..<1440).map { "checkin-\($0)" })
        for t in minutes {
            let content = UNMutableNotificationContent()
            content.title = "Time to check in"
            content.body = "Open Help&I and press I'm OK now."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: t / 60, minute: t % 60), repeats: true)
            center.add(UNNotificationRequest(identifier: "checkin-\(t)", content: content, trigger: trigger))
        }
    }
}
