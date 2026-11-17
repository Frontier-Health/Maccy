import AppKit
import UserNotifications

class Notifier {
  nonisolated private static var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

  static func authorize() {
    center.requestAuthorization(options: [.alert, .sound]) { _, error in
      if error != nil {
        NSLog("Failed to authorize notifications: \(String(describing: error))")
      }
    }
  }

  /// Opaque, per-item notification identifier. It is generated randomly per item and is never
  /// derived from clipboard content, so it is safe to hand to Notification Center.
  static func identifier(for item: HistoryItem) -> String {
    item.notificationID
  }

  /// Builds the notification content. Deliberately takes no clipboard-derived input: clipboard
  /// text (passwords, tokens, patient data) must never reach Notification Center.
  nonisolated static func makeContent(alertEnabled: Bool) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    if alertEnabled {
      content.body = String(localized: "notification_copied_body")
    }
    return content
  }

  static func notify(for item: HistoryItem, sound: NSSound?) {
    let identifier = identifier(for: item)

    authorize()

    center.getNotificationSettings { settings in
      guard (settings.authorizationStatus == .authorized) ||
            (settings.authorizationStatus == .provisional) else { return }

      let isAlertEnabled = settings.alertSetting == .enabled
      let isSoundEnabled = settings.soundSetting == .enabled

      let content = makeContent(alertEnabled: isAlertEnabled)

      let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
      center.add(request) { error in
        if error != nil {
          NSLog("Failed to deliver notification: \(String(describing: error))")
        } else {
          if isSoundEnabled {
            sound?.play()
          }
        }
      }
    }
  }

  static func removeDelivered(for item: HistoryItem) {
    center.removeDeliveredNotifications(withIdentifiers: [identifier(for: item)])
  }

  static func removeAllDelivered() {
    center.removeAllDeliveredNotifications()
  }
}
