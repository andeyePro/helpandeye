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

    /// The first 64 are for alerts to come, the rest for those due at once.
    private func ids(_ key: IncomingRequest.Key) -> [String] { (0..<128).map { "req-\(prefix)\(key.unit)-\(key.request)-\($0)" } }

    /// iOS keeps only 64 pending notifications for the whole app, and drops the rest without a
    /// word, so every group's calls share them: an equal part each, after the check-in reminders
    /// and a few kept for news to the caller. Each call's earliest alerts are the ones kept.
    private struct Plan {
        let ids: [String]
        let content: UNNotificationContent
        let times: [Date]
    }
    private static var plans: [String: Plan] = [:]
    private static var checkIns = 0
    private static let forCaller = 4

    /// Also run whenever the app wakes, so a call whose share has all gone off gets its next ones.
    static func replan() {
        let now = Date()
        plans = plans.filter { $0.value.times.contains { $0 > now } }
        guard !plans.isEmpty else { return }
        // Urgent calls first, then the soonest due, so if there are too few to go round, those keep theirs.
        let order = plans.values.sorted { a, b in
            let ua = a.content.interruptionLevel == .timeSensitive, ub = b.content.interruptionLevel == .timeSensitive
            return ua != ub ? ua : (a.times.first { $0 > now } ?? .distantFuture) < (b.times.first { $0 > now } ?? .distantFuture)
        }
        let shares = shareAlerts(wanted: order.map { min($0.times.filter { $0 > now }.count, 64) }, slots: 64 - checkIns - forCaller)
        let center = UNUserNotificationCenter.current()
        for (plan, each) in zip(order, shares) {
            center.removePendingNotificationRequests(withIdentifiers: Array(plan.ids.prefix(64)))
            for (id, at) in zip(plan.ids, plan.times.filter { $0 > now }.prefix(each)) {
                center.add(UNNotificationRequest(identifier: id, content: plan.content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(at.timeIntervalSinceNow, 1), repeats: false)))
            }
        }
    }

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
        let ids = ids(alert.key)
        let now = Date()
        for (id, at) in zip(ids.dropFirst(64), alert.times) where at.timeIntervalSince(now) < 1 {
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        Self.plans[ids[0]] = Plan(ids: ids, content: content, times: alert.times.filter { $0.timeIntervalSince(now) >= 1 })
        Self.replan()
    }

    func cancel(_ key: IncomingRequest.Key) {
        Self.plans[ids(key)[0]] = nil
        center.removePendingNotificationRequests(withIdentifiers: ids(key))
        center.removeDeliveredNotifications(withIdentifiers: ids(key))
        Self.replan()
    }

    /// Removes this group's pending alerts. It finds them first, so an alert scheduled in the
    /// moment between could go too; it is only used on leaving the group.
    func cancelAll() {
        Self.plans = Self.plans.filter { !isMine($0.key) }
        Self.replan()
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
        Self.checkIns = minutes.count
        Self.replan()
        for t in minutes {
            let content = UNMutableNotificationContent()
            content.title = "Time to check in"
            content.body = "Open Help&I and press I'm OK."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: t / 60, minute: t % 60), repeats: true)
            center.add(UNNotificationRequest(identifier: "checkin-\(t)", content: content, trigger: trigger))
        }
    }
}

/// An alert still sounds and shows with Help&I open, as it does with it closed: iOS keeps them
/// quiet for the open app unless asked.
final class ShowAlertsWhileOpen: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ShowAlertsWhileOpen()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
