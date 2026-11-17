import AppKit
import Defaults

// The content types Maccy can store, grouped the way the Storage settings
// toggles show them. This is the only list of storable content types: the
// toggles, the default preference value, the clipboard watcher's filter and the
// history store's clean-up are all derived from it, so a type cannot be offered
// by a toggle without being covered by the filter.
nonisolated struct StorageType: Sendable, Identifiable, Equatable {
  static let files = StorageType(id: "Files", types: [.fileURL])
  static let images = StorageType(id: "Images", types: [.png, .tiff, .jpeg, .heic])
  static let text = StorageType(id: "Text", types: [.html, .rtf, .string])

  // The Storage settings toggles, in display order. `id` is the toggle's label
  // key in StorageSettings.strings.
  static let toggles: [StorageType] = [files, images, text]
  static let all = StorageType(id: "All", types: toggles.flatMap(\.types))

  // Storable types whose contents the ignore rules (`IgnoreRules.inspectedTypes`)
  // do not read, and why. Every storable type is either inspected or listed
  // here; a test enforces that, so a new text-bearing type cannot be stored
  // without deciding how ignore rules treat it.
  static let notInspectedByIgnoreRules: [NSPasteboard.PasteboardType: String] = [
    .png: "image pixels; OCR text is derived after capture and not matched",
    .tiff: "image pixels; OCR text is derived after capture and not matched",
    .jpeg: "image pixels; OCR text is derived after capture and not matched",
    .heic: "image pixels; OCR text is derived after capture and not matched",
    .fromMaccy: "metadata marker, always stored empty",
    .universalClipboard: "metadata marker, always stored empty",
    .modified: "metadata marker, stored only as a decimal integer"
  ]

  let id: String
  let types: [NSPasteboard.PasteboardType]
}

// A valid set of content types Maccy may store, plus the fixed metadata
// markers. Every other pasteboard representation (custom app types, `dyn.`
// types, Microsoft OLE/link types, PDF, RTFD, web archives…) is never stored,
// even when it is copied together with an enabled type.
nonisolated struct StorageAllowList: Sendable, Equatable {
  // Every content type in the definition.
  static let everything = StorageAllowList(enabledTypes: StoragePolicy.defaultEnabledTypes)

  enum Admission: Equatable {
    case store(Data?)
    case drop
  }

  // Content types allowed. Always a subset of `StorageType.all`.
  let enabledTypes: Set<NSPasteboard.PasteboardType>

  init(enabledTypes: Set<NSPasteboard.PasteboardType>) {
    self.enabledTypes = enabledTypes.intersection(StoragePolicy.defaultEnabledTypes)
  }

  var storesAnything: Bool { !enabledTypes.isEmpty }

  var allowedTypes: Set<NSPasteboard.PasteboardType> { enabledTypes.union(StoragePolicy.metadataTypes) }

  func allows(_ type: NSPasteboard.PasteboardType) -> Bool {
    allowedTypes.contains(type)
  }

  // Whether a history item with these representations has any content to keep.
  func hasStorableContent(_ types: some Sequence<NSPasteboard.PasteboardType>) -> Bool {
    types.contains(where: enabledTypes.contains)
  }

  // A toggle shows as on when any of its types is stored, so "off" always means
  // none of them is.
  func isEnabled(_ toggle: StorageType) -> Bool {
    !enabledTypes.isDisjoint(with: toggle.types)
  }

  // What to store for one representation. `value` is only evaluated when the
  // copied bytes are needed, so the data of a dropped type is never read.
  func admission(of type: NSPasteboard.PasteboardType, value: @autoclosure () -> Data?) -> Admission {
    guard allows(type) else {
      return .drop
    }

    switch type {
    case .fromMaccy, .universalClipboard:
      return .store(Data())
    case .modified:
      guard let data = value(),
            let string = String(data: data, encoding: .utf8),
            let changeCount = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return .drop
      }
      return .store(Data(String(changeCount).utf8))
    default:
      return .store(value())
    }
  }
}

// The effective storage setting. A valid setting is an allow-list. An invalid
// one (a value that isn't a list of type names) is a distinct state, not an
// empty allow-list: while it lasts nothing is captured and nothing already in
// history is deleted, so a broken profile or a corrupt preference never wipes
// history. Callers have to say which of the two cases they handle.
nonisolated struct StoragePolicy: Sendable, Equatable {
  static let preferenceKey = "enabledPasteboardTypes"

  // Used when the preference is absent.
  static let defaultEnabledTypes = Set(StorageType.all.types)

  // Metadata Maccy needs to work. None of them is stored with the bytes the
  // copying app supplied (see `StorageAllowList.admission(of:value:)`):
  // - The runtime app bundle ID marks a copy Maccy made from its own history, so the
  //   duplicate keeps its original application. Stored empty.
  // - `com.apple.is-remote-clipboard` marks a Universal Clipboard copy, which
  //   changes how file URLs and images are read. Stored empty.
  // - `x.nspasteboard.ModifiedType` carries the change count of the copy an app
  //   modified, so the edit replaces that history item. Stored only as a
  //   decimal integer.
  static let metadataTypes: Set<NSPasteboard.PasteboardType> = [.fromMaccy, .universalClipboard, .modified]

  enum State: Sendable, Equatable {
    case valid(StorageAllowList)
    // The stored value could not be read as a list of type names.
    case invalid
  }

  let state: State
  // The preference is set by a configuration profile.
  let isForced: Bool

  init(_ state: State, isForced: Bool = false) {
    self.state = state
    self.isForced = isForced
  }

  init(enabledTypes: Set<NSPasteboard.PasteboardType>, isForced: Bool = false) {
    self.init(.valid(StorageAllowList(enabledTypes: enabledTypes)), isForced: isForced)
  }

  static func invalid(isForced: Bool = false) -> StoragePolicy {
    StoragePolicy(.invalid, isForced: isForced)
  }

  // The effective policy, read from every domain macOS layers into `defaults`,
  // including managed preferences. Absent means every content type. A list of
  // type names enables the listed content types and ignores any other name.
  // Anything else is invalid.
  static func effective(in defaults: UserDefaults) -> StoragePolicy {
    StoragePolicy(state(in: defaults), isForced: defaults.objectIsForced(forKey: preferenceKey))
  }

  static func state(in defaults: UserDefaults) -> State {
    guard let value = defaults.object(forKey: preferenceKey) else {
      return .valid(.everything)
    }

    guard let names = value as? [String] else {
      return .invalid
    }

    return .valid(StorageAllowList(enabledTypes: Set(names.map(NSPasteboard.PasteboardType.init(rawValue:)))))
  }

  static var current: StoragePolicy {
    effective(in: Defaults.Keys.enabledPasteboardTypes.suite)
  }

  // What may be read back out of history right now (see `readAllowList`),
  // without checking whether the value is managed.
  static var currentReadAllowList: StorageAllowList {
    StoragePolicy(state(in: Defaults.Keys.enabledPasteboardTypes.suite)).readAllowList
  }

  // The allow-list when the setting is valid; nil when it is invalid.
  var allowList: StorageAllowList? {
    guard case .valid(let allowList) = state else {
      return nil
    }
    return allowList
  }

  var isInvalid: Bool { state == .invalid }

  // Whether a copy can be recorded at all. Never while invalid.
  var storesAnything: Bool { allowList?.storesAnything ?? false }

  // What stored data may be shown, pasted or handed to an intent. A valid
  // policy allows exactly its types, so data stored under an earlier policy is
  // not read even before (or if) the clean-up removes it. While the setting is
  // invalid history is left as it was, and so is access to it: every type in
  // the definition can be read.
  var readAllowList: StorageAllowList { allowList ?? .everything }

  func isEnabled(_ toggle: StorageType) -> Bool {
    allowList?.isEnabled(toggle) ?? false
  }

  // The preference value after turning `toggle` on or off. Starting from an
  // invalid value this starts from nothing, never from the default.
  func enabledTypes(setting toggle: StorageType, to isOn: Bool) -> Set<NSPasteboard.PasteboardType> {
    let enabledTypes = allowList?.enabledTypes ?? []
    return isOn ? enabledTypes.union(toggle.types) : enabledTypes.subtracting(toggle.types)
  }
}

// How many stored items a new allow-list would change. Counted from type
// names only; no stored data is read.
nonisolated struct StorageCleanUpImpact: Sendable, Equatable {
  // Items that keep some content but lose at least one representation.
  var itemsLosingData = 0
  // Items left with no allowed content, which are deleted. Pins included.
  var itemsRemoved = 0

  var affectsHistory: Bool { itemsLosingData > 0 || itemsRemoved > 0 }
}

// What happens when the user flips a Storage toggle in settings.
nonisolated enum StorageToggleChange: Equatable {
  // The value is managed by a configuration profile; nothing is written.
  case refused
  // Write the new value. Stored history is not affected.
  case apply(Set<NSPasteboard.PasteboardType>)
  // Writing the new value would remove stored data. Ask first. A nil impact
  // means it could not be counted.
  case confirm(Set<NSPasteboard.PasteboardType>, StorageCleanUpImpact?)

  static func change(
    from policy: StoragePolicy,
    setting toggle: StorageType,
    to isOn: Bool,
    impact: (StorageAllowList) throws -> StorageCleanUpImpact
  ) -> StorageToggleChange {
    guard !policy.isForced else {
      return .refused
    }

    let enabledTypes = policy.enabledTypes(setting: toggle, to: isOn)
    // Going from an invalid value to a valid one can remove data too: the
    // types still off are stripped once the value is valid again.
    guard let impact = try? impact(StorageAllowList(enabledTypes: enabledTypes)) else {
      return .confirm(enabledTypes, nil)
    }

    return impact.affectsHistory ? .confirm(enabledTypes, impact) : .apply(enabledTypes)
  }

  // What confirming `pending` does now. The dialog asked about an operation
  // (one toggle, on or off), not a resulting value, so it is worked out again
  // from the setting as it is now:
  // - a value a configuration profile now forces is not written over;
  // - if turning the toggle now removes nothing, the new value is written,
  //   as flipping the toggle would;
  // - if the new value or the counts differ from what the dialog showed, it
  //   is shown again with the new ones rather than applied;
  // - otherwise the new value is written.
  static func confirming(
    _ pending: PendingStorageToggleChange,
    from policy: StoragePolicy,
    impact: (StorageAllowList) throws -> StorageCleanUpImpact
  ) -> StorageToggleConfirmation {
    switch change(from: policy, setting: pending.toggle, to: pending.isOn, impact: impact) {
    case .refused:
      return .refused
    case .apply(let enabledTypes):
      return .apply(enabledTypes)
    case .confirm(let enabledTypes, let impact):
      let current = PendingStorageToggleChange(
        toggle: pending.toggle, isOn: pending.isOn, enabledTypes: enabledTypes, impact: impact
      )
      return current == pending ? .apply(enabledTypes) : .reconfirm(current)
    }
  }
}

// A toggle change waiting for confirmation: the operation the user asked for,
// and the new value and counts the dialog showed for it.
nonisolated struct PendingStorageToggleChange: Equatable {
  let toggle: StorageType
  let isOn: Bool
  let enabledTypes: Set<NSPasteboard.PasteboardType>
  // nil when it could not be counted.
  let impact: StorageCleanUpImpact?
}

// What confirming a pending toggle change does.
nonisolated enum StorageToggleConfirmation: Equatable {
  // The value is now managed by a configuration profile; nothing is written.
  case refused
  // Write this value.
  case apply(Set<NSPasteboard.PasteboardType>)
  // The setting changed meanwhile: ask again about this.
  case reconfirm(PendingStorageToggleChange)
}
