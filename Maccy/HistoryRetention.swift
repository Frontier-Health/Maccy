import AppKit
import Defaults

// The history size preference ("historySize"), clamped to 1...999. Every
// reader goes through `effective(in:)`, so a value of 0, a negative or huge
// number, or a value of the wrong type (whether written by `defaults write` or
// forced by a configuration profile) can never reach the code that slices
// history by it.
nonisolated enum HistorySize {
  static let preferenceKey = "historySize"
  static let range = 1...999
  static let defaultValue = 200

  // A number (or a string holding one) is rounded down and clamped into
  // `range`. Anything else, including a Boolean, reads as the default.
  static func effective(in defaults: UserDefaults) -> Int {
    guard let number = PreferenceNumber.read(defaults.object(forKey: preferenceKey)), !number.isNaN else {
      return defaultValue
    }
    let clamped = min(max(number.rounded(.down), Double(range.lowerBound)), Double(range.upperBound))
    return Int(clamped)
  }

  static func isForced(in defaults: UserDefaults) -> Bool {
    defaults.objectIsForced(forKey: preferenceKey)
  }

  static var current: Int { effective(in: Defaults.Keys.size.suite) }
  static var isForced: Bool { isForced(in: Defaults.Keys.size.suite) }
}

// Optional time-based expiry ("historyExpiryHours"): items not copied for
// this many hours are removed. Copying an item from Maccy counts as a copy, so
// the age is measured from `HistoryItem.lastCopiedAt`.
//
// How the stored value is read (including a value forced by a profile):
// - absent, or 0: off;
// - a positive number, or a string holding one: that many hours, rounded down,
//   at least 1 and at most `maximumHours`;
// - anything else (negative, not a number, a Boolean, a list, ...): invalid.
//   An invalid value fails closed: it is treated as the shortest expiry,
//   `invalidValueHours`, because it may be an administrator's retention limit
//   written wrongly, and must not silently turn expiry off.
//
// Pinned items expire only while the value is forced by a configuration
// profile: an administrator's retention limit must not be bypassed by pinning.
// A value the user set keeps pinned items.
nonisolated struct HistoryExpiry: Equatable, Sendable {
  static let preferenceKey = "historyExpiryHours"
  // One year.
  static let maximumHours = 8760
  static let invalidValueHours = 1

  enum State: Equatable, Sendable {
    case off
    case hours(Int)
    case invalid
  }

  let state: State
  let isForced: Bool

  static func effective(in defaults: UserDefaults) -> HistoryExpiry {
    HistoryExpiry(
      state: state(of: defaults.object(forKey: preferenceKey)),
      isForced: defaults.objectIsForced(forKey: preferenceKey)
    )
  }

  static func state(of value: Any?) -> State {
    guard let value else {
      return .off
    }
    guard let number = PreferenceNumber.read(value), !number.isNaN, number >= 0 else {
      return .invalid
    }
    guard number > 0 else {
      return .off
    }
    let hours = min(number.rounded(.down), Double(maximumHours))
    return .hours(max(1, Int(hours)))
  }

  static var current: HistoryExpiry { effective(in: Defaults.Keys.historyExpiryHours.suite) }

  // The expiry in effect, or nil when off.
  var hours: Int? {
    switch state {
    case .off: nil
    case .hours(let hours): hours
    case .invalid: Self.invalidValueHours
    }
  }

  var isOn: Bool { hours != nil }
  var isInvalid: Bool { state == .invalid }
  var expiresPinnedItems: Bool { isOn && isForced }

  // Items last copied before this are expired.
  func cutoff(now: Date) -> Date? {
    hours.map { now.addingTimeInterval(-Double($0) * 3600) }
  }
}

// Reads a preference value as a number: an NSNumber that isn't a Boolean, or a
// string that parses as one. Anything else is nil.
nonisolated enum PreferenceNumber {
  static func read(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
      }
      return number.doubleValue
    }
    if let string = value as? String {
      return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }
}

// A removal from history. Each one either completes (the store and the list
// shown both lose the items) or changes nothing.
nonisolated enum HistoryRemoval: String, Sendable {
  case delete
  case clear
  case clearAll
  case clearOnQuit
  case clearOnLaunch
  case trim
  case expiry

  // Removals the user asked for are reported every time they fail. Automatic
  // ones (trimming to the history size, expiry, and the clear-on-quit run at
  // launch) run from timers and on every copy, so a store that keeps failing
  // would show an alert each time: they show one alert per run of failures
  // (until one succeeds), and are logged and shown in the Storage settings.
  var alertsEveryTime: Bool {
    switch self {
    case .delete, .clear, .clearAll, .clearOnQuit: true
    case .clearOnLaunch, .trim, .expiry: false
    }
  }

  private static func localized(_ key: String, _ value: String) -> String {
    NSLocalizedString(key, tableName: "StorageSettings", value: value, comment: "")
  }

  var failureTitle: String {
    switch self {
    case .delete:
      Self.localized("RemovalFailedDeleteTitle", "The item was NOT deleted")
    case .clear, .clearAll, .clearOnQuit, .clearOnLaunch:
      Self.localized("RemovalFailedClearTitle", "History was NOT cleared")
    case .trim:
      Self.localized("RemovalFailedTrimTitle", "Old items were NOT removed")
    case .expiry:
      Self.localized("RemovalFailedExpiryTitle", "Expired items were NOT removed")
    }
  }

  var failureMessage: String {
    switch self {
    case .delete:
      Self.localized(
        "RemovalFailedDeleteMessage",
        "Maccy could not delete the item from its database. It is still stored and still in history. " +
          "Try again. If this keeps happening, quit and reopen Maccy."
      )
    case .clear, .clearAll:
      Self.localized(
        "RemovalFailedClearMessage",
        "Maccy could not delete history from its database. Nothing was removed: every item is still stored " +
          "and still in history. Try again. If this keeps happening, quit and reopen Maccy."
      )
    case .clearOnQuit:
      Self.localized(
        "RemovalFailedClearOnQuitMessage",
        "Maccy could not delete history from its database before quitting. Every item is still stored. " +
          "Maccy will try again the next time it opens."
      )
    case .clearOnLaunch:
      Self.localized(
        "RemovalFailedClearOnLaunchMessage",
        "History was set to be cleared when Maccy quits, but Maccy could not delete it from its database. " +
          "Every item is still stored. Use Clear in the Maccy window to try again."
      )
    case .trim:
      Self.localized(
        "RemovalFailedTrimMessage",
        "Maccy could not remove items beyond the history size from its database. They are still stored. " +
          "Maccy will try again; this alert is not shown again until removal works."
      )
    case .expiry:
      Self.localized(
        "RemovalFailedExpiryMessage",
        "Maccy could not remove items older than the expiry time from its database. They are still stored. " +
          "Maccy will keep trying; this alert is not shown again until removal works."
      )
    }
  }
}

// Tells the user that a removal failed. Tests replace it.
@MainActor
protocol HistoryRemovalFailureReporting: AnyObject {
  func removalFailed(_ removal: HistoryRemoval, error: any Error)
}

// Shows a modal alert with the operation and the error's domain and code only:
// never its description, which could quote stored content.
@MainActor
final class AlertHistoryRemovalFailureReporter: HistoryRemovalFailureReporting {
  private var isPresenting = false

  func removalFailed(_ removal: HistoryRemoval, error: any Error) {
    #if DEBUG
    guard !History.isRunningUnitTests else { return }
    #endif
    // One alert at a time; a failure while one is open is only logged.
    guard !isPresenting else { return }
    isPresenting = true
    defer { isPresenting = false }

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = removal.failureTitle
    alert.informativeText = removal.failureMessage + "\n\n" + Notifier.redacted(error)
    NSApp.activate()
    alert.runModal()
  }
}
