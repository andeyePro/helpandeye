import Foundation
import HelpAndICore
import UserNotifications

/// Responder alerts and check-in reminders as local notifications, so they fire with the app in
/// the background.
@MainActor final class NotificationAlerts: AlertScheduler {
    private let center = UNUserNotificationCenter.current()

    private func ids(_ key: IncomingRequest.Key) -> [String] { (0..<64).map { "req-\(key.unit)-\(key.request)-\($0)" } }

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

    func cancelAll() { center.removeAllPendingNotificationRequests() }

    func setCheckInReminders(_ minutes: [Int]) {
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
