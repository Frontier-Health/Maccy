import Foundation
import Defaults

// Whether Maccy records new copies. This is the single source of truth for
// pausing: the menu bar icon, the Option-click handler, the settings toggle and
// the clipboard watcher all read and write this one value, so a one-shot skip
// can never outlive a permanent pause or resume.
//
// Stored as a string under the `captureMode` defaults key, so it can be set from
// a script, e.g. `defaults write org.p0deje.Maccy captureMode paused`.
nonisolated enum CaptureMode: String, CaseIterable, Defaults.Serializable {
  // Record every copy.
  case capturing
  // Ignore every copy until resumed.
  case paused
  // Ignore exactly one copy, then go back to `capturing`.
  case skipNext

  static let defaultsKey = "captureMode"
  static let legacyIgnoreEventsKey = "ignoreEvents"
  static let legacyIgnoreOnlyNextEventKey = "ignoreOnlyNextEvent"

  var capturesCopies: Bool { self == .capturing }

  // The mode after a copy has been observed. A copy seen in `capturing` is
  // recorded; in any other mode it is ignored.
  var afterCopy: CaptureMode {
    self == .skipNext ? .capturing : self
  }

  // Option-click on the menu icon, and the "Turn off" setting:
  // capturing -> paused; paused or skipNext -> capturing.
  func togglingPause() -> CaptureMode {
    self == .capturing ? .paused : .capturing
  }

  // Option-Shift-click on the menu icon:
  // capturing -> skipNext; paused or skipNext -> capturing.
  func togglingSkipNext() -> CaptureMode {
    self == .capturing ? .skipNext : .capturing
  }

  // Maps the pre-`captureMode` booleans to a mode. Before this key existed,
  // `ignoreOnlyNextEvent` was only honoured while `ignoreEvents` was true, but a
  // lone `ignoreOnlyNextEvent = true` was either the documented "ignore next copy"
  // command or a stale flag. Both map to `skipNext`: at worst one copy the user
  // wanted is not recorded, which is the safe direction.
  static func fromLegacy(ignoreEvents: Bool, ignoreOnlyNextEvent: Bool) -> CaptureMode {
    if ignoreOnlyNextEvent {
      return .skipNext
    }

    return ignoreEvents ? .paused : .capturing
  }

  // One-time migration from `ignoreEvents` / `ignoreOnlyNextEvent`.
  //
  // Runs once per preferences domain, guarded by `migrationMarkerKey`. If the
  // old keys say Maccy was paused or skipping the next copy, that mode is
  // written to `captureMode`; otherwise `captureMode` is left as it is. The old
  // keys are then removed. After the marker is set the old keys are never read
  // again, so anything that still writes them (an old script, an MDM profile)
  // has no effect and must be changed to write `captureMode` instead.
  //
  // The marker is needed because whether `captureMode` "exists" can't be told
  // from `object(forKey:)`: the Defaults package registers every key's default
  // value, so `captureMode` always reads as at least "capturing".
  //
  // Returns the mode derived from the old keys, or nil if the migration had
  // already run.
  static let migrationMarkerKey = "captureModeMigratedFromLegacyKeys"

  @discardableResult
  static func migrateLegacyDefaults(in defaults: UserDefaults, key: String = defaultsKey) -> CaptureMode? {
    guard !defaults.bool(forKey: migrationMarkerKey) else {
      return nil
    }

    // `bool(forKey:)` also accepts the string "true" that a plain
    // `defaults write … ignoreEvents true` stores.
    let mode = fromLegacy(
      ignoreEvents: defaults.bool(forKey: legacyIgnoreEventsKey),
      ignoreOnlyNextEvent: defaults.bool(forKey: legacyIgnoreOnlyNextEventKey)
    )
    if mode != .capturing {
      defaults.set(mode.rawValue, forKey: key)
    }
    defaults.removeObject(forKey: legacyIgnoreEventsKey)
    defaults.removeObject(forKey: legacyIgnoreOnlyNextEventKey)
    defaults.set(true, forKey: migrationMarkerKey)

    return mode
  }
}
