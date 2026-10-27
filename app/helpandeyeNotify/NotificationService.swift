import helpandeyeCore
import UserNotifications

/// Names the caller in a relay push. The relay cannot read who called, so its push says only
/// that the group has a call and carries the sealed message; this extension opens it with the
/// group key from the shared keychain. If anything fails, the relay's generic text stays.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler done: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        if let sealed = request.content.userInfo["sealed"] as? String, let group = SharedStore.group(),
           let text = PushText.describe(sealed: sealed, group: group, at: Date()) {
            content.title = text.title
            content.body = text.body
        }
        done(content)
    }
}
