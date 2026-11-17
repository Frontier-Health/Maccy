import Defaults
import Foundation

@MainActor
enum HistoryIntentAccess {
  static func requireEnabled() throws {
    let defaults = UserDefaults.standard
    let enabled = defaults.objectIsForced(forKey: "intentsEnabled")
      ? defaults.bool(forKey: "intentsEnabled")
      : Defaults[.intentsEnabled]
    guard enabled else {
      throw AppIntentError.disabled
    }
  }

  static func item<Items: RandomAccessCollection>(number: Int, in items: Items) throws -> Items.Element {
    guard number >= 1, number <= items.count else {
      throw AppIntentError.notFound
    }
    return items[items.index(items.startIndex, offsetBy: number - 1)]
  }
}

/// Image files handed to Shortcuts by the Get intent.
///
/// Exports are tracked per history item, so deleting one item (which also happens on every copy
/// once history is full) does not pull files out from under a shortcut that is still using another
/// item's export. Clearing history removes all of them.
@MainActor
enum IntentImageExports {
  private static var directory: URL {
    FileManager.default.temporaryDirectory.appending(path: "MaccyIntentImages", directoryHint: .isDirectory)
  }

  /// Where versions before the per-export temp files wrote every exported image.
  static var legacyExport: URL {
    URL.documentsDirectory.appending(path: "image.png")
  }

  private static var exports: [ObjectIdentifier: [URL]] = [:]
  private static var didRemoveLeftovers = false

  static func write(_ data: Data, for item: HistoryItem) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let file = directory.appending(path: "\(UUID().uuidString).png")
    try data.write(to: file, options: [.atomic, .completeFileProtection])
    exports[ObjectIdentifier(item), default: []].append(file)
    return file
  }

  static func remove(for item: HistoryItem) {
    guard let files = exports.removeValue(forKey: ObjectIdentifier(item)) else { return }
    for file in files {
      try? FileManager.default.removeItem(at: file)
    }
  }

  /// Keeps exports alive when a re-copied item replaces its duplicate in history.
  static func transfer(from old: HistoryItem, to new: HistoryItem) {
    guard let files = exports.removeValue(forKey: ObjectIdentifier(old)) else { return }
    exports[ObjectIdentifier(new), default: []].append(contentsOf: files)
  }

  // Revoke every outstanding export on clear, including exports from previous app launches.
  static func removeAll() {
    exports.removeAll()
    try? FileManager.default.removeItem(at: directory)
  }

  /// Once per launch: removes exports left by a crash or a quit without clearing, and the single
  /// `Documents/image.png` that earlier versions wrote and never deleted.
  static func removeLeftoversOnce() {
    guard !didRemoveLeftovers else { return }
    didRemoveLeftovers = true
    removeLeftovers(legacyExport: legacyExport)
  }

  static func removeLeftovers(legacyExport: URL) {
    removeAll()
    try? FileManager.default.removeItem(at: legacyExport)
  }
}
