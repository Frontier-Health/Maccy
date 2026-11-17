import AppKit

// Whether Maccy records new copies.
//
// Stored as a string under the `captureMode` defaults key, so it can be set from
// a script, e.g. `defaults write <BUNDLE_ID> captureMode paused`.
//
// Everything that needs to know whether Maccy is capturing (the clipboard
// watcher, the menu bar icon and its accessibility label, the Option-click
// handler and the settings toggle) reads `effective(in:)`, and every change made
// from the UI goes through `perform(_:in:)`. When the stored state is unclear,
// the answer is "don't capture": a malformed value means `paused`, and the old
// `ignoreEvents` / `ignoreOnlyNextEvent` keys can only make Maccy capture less.
nonisolated enum CaptureMode: String, CaseIterable, Sendable {
  // Record every copy.
  case capturing
  // Ignore every copy until resumed.
  case paused
  // Ignore exactly one copy that would otherwise be recorded, then go back to
  // `capturing`.
  case skipNext

  static let defaultsKey = "captureMode"
  static let legacyIgnoreEventsKey = "ignoreEvents"
  static let legacyIgnoreOnlyNextEventKey = "ignoreOnlyNextEvent"
  static let migrationMarkerKey = "captureModeMigratedFromLegacyKeys"

  var capturesCopies: Bool { self == .capturing }

  // The more restrictive of the two modes: paused > skipNext > capturing.
  func atLeast(_ other: CaptureMode) -> CaptureMode {
    other.restrictiveness > restrictiveness ? other : self
  }

  private var restrictiveness: Int {
    switch self {
    case .capturing: 0
    case .skipNext: 1
    case .paused: 2
    }
  }

  // MARK: - Reading

  // The `captureMode` value as stored. Only an absent key means `capturing`; a
  // value that is present but isn't exactly one of the case names (a typo, other
  // capitalisation, a boolean, an array) means `paused`. This is decoded by hand
  // because the Defaults bridge silently falls back to the key's default for
  // values it can't decode.
  static func stored(in defaults: UserDefaults) -> CaptureMode {
    guard let object = defaults.object(forKey: defaultsKey) else {
      return .capturing
    }

    guard let string = object as? String, let mode = CaptureMode(rawValue: string) else {
      return .paused
    }

    return mode
  }

  // The mode Maccy acts on.
  // - Starts from `stored(in:)`. A `skipNext` forced by a configuration profile
  //   can never be consumed, so it counts as `paused`.
  // - A legacy `ignoreEvents` that reads true (written by an old script, or
  //   forced by a profile) makes it `paused`.
  // - A legacy `ignoreOnlyNextEvent` that reads true makes it at least
  //   `skipNext` until the watcher moves it into `captureMode` (see
  //   `absorbLegacyOneShot(in:)`). It counts as `paused` if it can't be moved
  //   there: a profile forces it, so it can't be removed, or a profile forces
  //   `captureMode`, so the skip could never be stored or spent.
  static func effective(in defaults: UserDefaults) -> CaptureMode {
    var mode = stored(in: defaults)
    if mode == .skipNext && defaults.objectIsForced(forKey: defaultsKey) {
      mode = .paused
    }

    if legacyFlag(legacyIgnoreEventsKey, in: defaults) == true {
      mode = .paused
    }

    if legacyFlag(legacyIgnoreOnlyNextEventKey, in: defaults) == true {
      mode = mode.atLeast(legacyOneShotCanBeAbsorbed(in: defaults) ? .skipNext : .paused)
    }

    return mode
  }

  // True when a configuration profile pins capture state, so the user must not
  // change it from Maccy: `captureMode` is forced, or a forced legacy key reads
  // true. The settings toggle is disabled and Option-clicks do nothing.
  //
  // A forced legacy key that reads false doesn't lock anything, since it doesn't
  // pause Maccy and locking would only stop the user from pausing.
  static func isLockedByProfile(in defaults: UserDefaults) -> Bool {
    if defaults.objectIsForced(forKey: defaultsKey) {
      return true
    }

    return [legacyIgnoreEventsKey, legacyIgnoreOnlyNextEventKey].contains { key in
      defaults.objectIsForced(forKey: key) && legacyFlag(key, in: defaults) == true
    }
  }

  // Whether a legacy `ignoreOnlyNextEvent` can be turned into a `skipNext` that
  // Maccy is able to spend: neither it nor `captureMode` is pinned by a profile.
  static func legacyOneShotCanBeAbsorbed(in defaults: UserDefaults) -> Bool {
    !defaults.objectIsForced(forKey: legacyIgnoreOnlyNextEventKey) && !defaults.objectIsForced(forKey: defaultsKey)
  }

  // A legacy boolean key: nil if absent; false for a boolean false or the strings
  // "false", "no" and "0"; true for anything else, so a malformed value pauses
  // rather than captures. `defaults write … ignoreEvents true` stores the string
  // "true".
  static func legacyFlag(_ key: String, in defaults: UserDefaults) -> Bool? {
    guard let object = defaults.object(forKey: key) else {
      return nil
    }

    if let string = object as? String {
      return !["false", "no", "0"].contains(string.trimmingCharacters(in: .whitespaces).lowercased())
    }

    if let number = object as? NSNumber {
      return number.boolValue
    }

    return true
  }

  // MARK: - Changing

  // A change requested from the UI. Every request sets the whole mode, so a
  // one-shot skip can't linger behind a later pause or resume.
  @discardableResult
  static func perform(_ request: CaptureModeRequest, in defaults: UserDefaults) -> CaptureMode {
    let current = effective(in: defaults)
    guard !isLockedByProfile(in: defaults) else {
      return current
    }

    let target: CaptureMode
    switch request {
    case .togglePause:
      target = current == .capturing ? .paused : .capturing
    case .toggleSkipNext:
      target = current == .capturing ? .skipNext : .capturing
    case .pause:
      target = .paused
    case .resume:
      target = .capturing
    }

    if target == .capturing {
      // Resuming also clears a pause or one-shot written to the old keys.
      defaults.removeObject(forKey: legacyIgnoreEventsKey)
      defaults.removeObject(forKey: legacyIgnoreOnlyNextEventKey)
    }
    defaults.set(target.rawValue, forKey: defaultsKey)

    return effective(in: defaults)
  }

  // Called by the watcher instead of recording a copy while in `skipNext`.
  static func consumeSkip(in defaults: UserDefaults) {
    if stored(in: defaults) == .skipNext {
      defaults.set(CaptureMode.capturing.rawValue, forKey: defaultsKey)
    }
  }

  // An `ignoreOnlyNextEvent` written after migration (by an old script) arms a
  // one-shot skip and is then removed, so it skips one copy and not every copy.
  // If it or `captureMode` is forced, it is left alone and `effective(in:)`
  // treats it as paused; if it is still there after removal (it lives in another
  // domain, such as the global one), `captureMode` is set to `paused`.
  static func absorbLegacyOneShot(in defaults: UserDefaults) {
    guard legacyFlag(legacyIgnoreOnlyNextEventKey, in: defaults) == true,
          legacyOneShotCanBeAbsorbed(in: defaults) else {
      return
    }

    let current = stored(in: defaults)
    defaults.removeObject(forKey: legacyIgnoreOnlyNextEventKey)
    let stillThere = legacyFlag(legacyIgnoreOnlyNextEventKey, in: defaults) == true
    let target = current.atLeast(stillThere ? .paused : .skipNext)
    if target != current {
      defaults.set(target.rawValue, forKey: defaultsKey)
    }
  }

  // MARK: - Watching

  // Whether the watcher may record a pasteboard change (or spend a one-shot skip
  // on it) under `mode`. It may not if the effective mode at the previous check
  // was different, or if a capture setting was written since then: the change
  // could have happened before the switch, e.g. pause, copy and resume all
  // between two checks.
  static func changeIsAttributable(to mode: CaptureMode, previousMode: CaptureMode?, settingsChanged: Bool) -> Bool {
    mode != .paused && previousMode == mode && !settingsChanged
  }

  // MARK: - Migration

  // Maps the pre-`captureMode` booleans to a mode. Both true is either an armed
  // one-shot or the stale flag left behind by the original bug, so it maps to
  // `paused`. A lone `ignoreOnlyNextEvent = true` was ignored by older versions
  // but is the documented "ignore next copy" command, so it maps to `skipNext`.
  static func fromLegacy(ignoreEvents: Bool, ignoreOnlyNextEvent: Bool) -> CaptureMode {
    if ignoreEvents {
      return .paused
    }

    return ignoreOnlyNextEvent ? .skipNext : .capturing
  }

  // One-time migration from `ignoreEvents` / `ignoreOnlyNextEvent`, guarded by
  // `migrationMarkerKey`. `captureMode` becomes the more restrictive of what is
  // stored there and what the old keys say, so an explicit `paused` is never
  // downgraded to a one-shot. The old keys are then removed (a no-op for keys a
  // profile forces).
  //
  // If a profile forces `captureMode`, the migrated value can't be stored, so
  // the old keys are kept: removing them would drop a pause or one-shot that
  // nothing replaces. They keep restricting capture through `effective(in:)`.
  //
  // The old keys are still honoured after migration, through `effective(in:)`
  // and `absorbLegacyOneShot(in:)`.
  //
  // Returns the migrated mode, or nil if the migration had already run.
  @discardableResult
  static func migrateLegacyDefaults(in defaults: UserDefaults) -> CaptureMode? {
    guard !defaults.bool(forKey: migrationMarkerKey) else {
      return nil
    }

    let legacy = fromLegacy(
      ignoreEvents: legacyFlag(legacyIgnoreEventsKey, in: defaults) == true,
      ignoreOnlyNextEvent: legacyFlag(legacyIgnoreOnlyNextEventKey, in: defaults) == true
    )
    let current = stored(in: defaults)
    let migrated = current.atLeast(legacy)
    if !defaults.objectIsForced(forKey: defaultsKey) {
      if migrated != current {
        defaults.set(migrated.rawValue, forKey: defaultsKey)
      }
      defaults.removeObject(forKey: legacyIgnoreEventsKey)
      defaults.removeObject(forKey: legacyIgnoreOnlyNextEventKey)
    }
    defaults.set(true, forKey: migrationMarkerKey)

    return migrated
  }
}

nonisolated enum CaptureModeRequest: Equatable, Sendable {
  // Option-click on the menu icon: capturing -> paused; otherwise -> capturing.
  case togglePause
  // Option-Shift-click: capturing -> skipNext; otherwise -> capturing.
  case toggleSkipNext
  // The settings toggle.
  case pause
  case resume

  // Nil for a click that should open the history panel.
  init?(statusItemClickWith modifierFlags: NSEvent.ModifierFlags) {
    guard modifierFlags.contains(.option) else {
      return nil
    }

    self = modifierFlags.contains(.shift) ? .toggleSkipNext : .togglePause
  }
}

// Set by a key-value observer whenever a capture setting is written, possibly
// from another thread, and taken by the watcher at each check.
nonisolated final class CaptureSettingsChangeFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false

  func set() {
    lock.withLock { changed = true }
  }

  func take() -> Bool {
    lock.withLock {
      defer { changed = false }
      return changed
    }
  }
}
