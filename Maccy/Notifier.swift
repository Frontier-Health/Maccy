import AppKit
import UserNotifications

/// Seam over `UNUserNotificationCenter` so tests can record what is submitted and removed.
/// Completions are always delivered on the main actor.
@MainActor
protocol NotificationClient {
  func requestAuthorization()
  func permissions(
    _ completion: @escaping @MainActor (_ authorized: Bool, _ alertEnabled: Bool, _ soundEnabled: Bool) -> Void
  )
  func add(_ request: UNNotificationRequest, completion: @escaping @MainActor (_ delivered: Bool) -> Void)
  func remove(identifiers: [String])
  func removeAll()
}

final class SystemNotificationClient: NotificationClient {
  nonisolated private static var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

  func requestAuthorization() {
    Self.center.requestAuthorization(options: [.alert, .sound]) { _, error in
      if let error {
        NSLog("Failed to authorize notifications: %@", Notifier.redacted(error))
      }
    }
  }

  func permissions(
    _ completion: @escaping @MainActor (_ authorized: Bool, _ alertEnabled: Bool, _ soundEnabled: Bool) -> Void
  ) {
    Self.center.getNotificationSettings { settings in
      let authorized = (settings.authorizationStatus == .authorized) ||
                       (settings.authorizationStatus == .provisional)
      let alertEnabled = settings.alertSetting == .enabled
      let soundEnabled = settings.soundSetting == .enabled
      Task { @MainActor in
        completion(authorized, alertEnabled, soundEnabled)
      }
    }
  }

  func add(_ request: UNNotificationRequest, completion: @escaping @MainActor (_ delivered: Bool) -> Void) {
    Self.center.add(request) { error in
      if let error {
        NSLog("Failed to deliver notification: %@", Notifier.redacted(error))
      }
      let delivered = error == nil
      Task { @MainActor in
        completion(delivered)
      }
    }
  }

  func remove(identifiers: [String]) {
    Self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
    Self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }

  func removeAll() {
    Self.center.removeAllPendingNotificationRequests()
    Self.center.removeAllDeliveredNotifications()
  }
}

/// Single owner of notification submission and removal.
///
/// Submission is asynchronous (the system reports permissions through a callback), so an item can
/// be deleted or history cleared while its notification is still on the way. `active` records
/// which identifiers are still wanted: a request that was invalidated before submission is
/// dropped, and one invalidated while in flight is removed again once the system accepts it.
class Notifier {
  static var client: NotificationClient = SystemNotificationClient()

  private static var active: Set<String> = []

  static func authorize() {
    client.requestAuthorization()
  }

  /// Opaque, per-item notification identifier. It is generated randomly per item and is never
  /// derived from clipboard content, so it is safe to hand to Notification Center.
  static func identifier(for item: HistoryItem) -> String {
    item.notificationID
  }

  static func isActive(_ identifier: String) -> Bool {
    active.contains(identifier)
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

  /// Error text that is safe to log: domain and code only. Descriptions and `userInfo` can embed
  /// stored values (for example SwiftData validation errors), so they are never logged.
  nonisolated static func redacted(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) code \(nsError.code)"
  }

  static func notify(for item: HistoryItem, sound: NSSound?) {
    let identifier = identifier(for: item)
    active.insert(identifier)

    authorize()

    client.permissions { authorized, alertEnabled, soundEnabled in
      // Dropped if the item was deleted or history cleared while waiting for the callback.
      guard active.contains(identifier) else { return }
      guard authorized else {
        active.remove(identifier)
        return
      }

      let request = UNNotificationRequest(
        identifier: identifier,
        content: makeContent(alertEnabled: alertEnabled),
        trigger: nil
      )
      client.add(request) { delivered in
        guard active.contains(identifier) else {
          // Invalidated while the request was in flight: the earlier removal may have run
          // before the system accepted the request, so remove it again.
          client.remove(identifiers: [identifier])
          return
        }

        if delivered, soundEnabled {
          sound?.play()
        }
      }
    }
  }

  /// Fixed identifier for the "copy too large" notification: a later one replaces it.
  static let copyTooLargeIdentifier = "copy-too-large"

  /// Fixed text, never derived from the copy: says only that a copy was not saved.
  nonisolated static var copyTooLargeBody: String {
    NSLocalizedString("notification_copy_too_large_body", value: "A copy was too large to save", comment: "")
  }

  /// Tells the user a copy was not saved because it was over a size limit
  /// (see ContentLimits), through the same permission check as other
  /// notifications: only when Maccy may post alerts. It never asks for
  /// permission itself.
  static func notifyCopyTooLarge() {
    client.permissions { authorized, alertEnabled, _ in
      guard authorized, alertEnabled else { return }
      let content = UNMutableNotificationContent()
      content.body = copyTooLargeBody
      let request = UNNotificationRequest(identifier: copyTooLargeIdentifier, content: content, trigger: nil)
      client.add(request) { _ in }
    }
  }

  static func removeDelivered(for item: HistoryItem) {
    let identifier = identifier(for: item)
    active.remove(identifier)
    client.remove(identifiers: [identifier])
  }

  static func removeAllDelivered() {
    active.removeAll()
    client.removeAll()
  }
}
