import AppKit
import Defaults

// The content types Maccy can store, grouped the way the Storage settings
// toggles show them. This is the only list of storable content types: the
// toggles, the default preference value, the clipboard watcher's filter and the
// history store's clean-up are all derived from it, so a type cannot be offered
// by a toggle without being covered by the filter.
nonisolated struct StorageType: Sendable, Identifiable {
  static let files = StorageType(id: "Files", types: [.fileURL])
  static let images = StorageType(id: "Images", types: [.png, .tiff, .jpeg, .heic])
  static let text = StorageType(id: "Text", types: [.html, .rtf, .string])

  // The Storage settings toggles, in display order. `id` is the toggle's label
  // key in StorageSettings.strings.
  static let toggles: [StorageType] = [files, images, text]
  static let all = StorageType(id: "All", types: toggles.flatMap(\.types))

  let id: String
  let types: [NSPasteboard.PasteboardType]
}

// What Maccy may write to clipboard history: the enabled content types plus a
// fixed set of metadata markers. Every other pasteboard representation (custom
// app types, `dyn.` types, Microsoft OLE/link types, PDF, RTFD, web archives…)
// is never stored, even when it is copied together with an enabled type.
nonisolated struct StoragePolicy: Sendable, Equatable {
  static let preferenceKey = "enabledPasteboardTypes"

  // Used when the preference is absent.
  static let defaultEnabledTypes = Set(StorageType.all.types)

  // Metadata Maccy needs to work. None of them is stored with the bytes the
  // copying app supplied (see `admission(of:value:)`):
  // - `org.p0deje.Maccy` marks a copy Maccy made from its own history, so the
  //   duplicate keeps its original application. Stored empty.
  // - `com.apple.is-remote-clipboard` marks a Universal Clipboard copy, which
  //   changes how file URLs and images are read. Stored empty.
  // - `x.nspasteboard.ModifiedType` carries the change count of the copy an app
  //   modified, so the edit replaces that history item. Stored only as a
  //   decimal integer.
  static let metadataTypes: Set<NSPasteboard.PasteboardType> = [.fromMaccy, .universalClipboard, .modified]

  enum Admission: Equatable {
    case store(Data?)
    case drop
  }

  // Content types allowed by the preference. Always a subset of
  // `StorageType.all`.
  let enabledTypes: Set<NSPasteboard.PasteboardType>
  // The stored preference could not be read as a list of type names, so
  // nothing is stored until it is replaced.
  let isMalformed: Bool
  // The preference is set by a configuration profile.
  let isForced: Bool

  init(enabledTypes: Set<NSPasteboard.PasteboardType>, isMalformed: Bool = false, isForced: Bool = false) {
    self.enabledTypes = enabledTypes.intersection(Self.defaultEnabledTypes)
    self.isMalformed = isMalformed
    self.isForced = isForced
  }

  // The effective policy, read from every domain macOS layers into `defaults`,
  // including managed preferences. Absent means every content type. A list of
  // type names enables the listed content types and ignores any other name.
  // Anything else is malformed and enables nothing.
  static func effective(in defaults: UserDefaults) -> StoragePolicy {
    let isForced = defaults.objectIsForced(forKey: preferenceKey)
    guard let value = defaults.object(forKey: preferenceKey) else {
      return StoragePolicy(enabledTypes: defaultEnabledTypes, isForced: isForced)
    }

    guard let names = value as? [String] else {
      return StoragePolicy(enabledTypes: [], isMalformed: true, isForced: isForced)
    }

    return StoragePolicy(
      enabledTypes: Set(names.map(NSPasteboard.PasteboardType.init(rawValue:))),
      isForced: isForced
    )
  }

  static var current: StoragePolicy {
    effective(in: Defaults.Keys.enabledPasteboardTypes.suite)
  }

  var storesAnything: Bool { !enabledTypes.isEmpty }

  var allowedTypes: Set<NSPasteboard.PasteboardType> { enabledTypes.union(Self.metadataTypes) }

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

  // The preference value after turning `toggle` on or off. Starting from a
  // malformed value this starts from nothing, never from the default.
  func enabledTypes(setting toggle: StorageType, to isOn: Bool) -> Set<NSPasteboard.PasteboardType> {
    isOn ? enabledTypes.union(toggle.types) : enabledTypes.subtracting(toggle.types)
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
