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

  // How long an intent that arrives while Maccy is still starting waits for
  // history to be ready before it is refused. Tests shorten it.
  static var readinessTimeout: Duration = .seconds(10)

  // Waits until launch maintenance has finished and history is loaded (see
  // `LaunchSequence`), or throws `notReady`. History is never read before.
  static func waitUntilReady() async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: readinessTimeout)
    while !History.shared.isReady {
      guard clock.now < deadline else {
        throw AppIntentError.notReady
      }
      try await Task.sleep(for: .milliseconds(100))
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
///
/// A path is forgotten only once its file is gone (a file already absent counts as gone). A file
/// that could not be deleted is kept in `pendingRemovals` and tried again by every later removal,
/// clear, the launch sweep and the periodic maintenance. Every removal returns whether no export is
/// left behind, so History can tell the user.
@MainActor
enum IntentImageExports {
  #if DEBUG
  // Tests point exports at a directory they control.
  static var directoryForTesting: URL?
  #endif

  static var directory: URL {
    #if DEBUG
    if let directoryForTesting {
      return directoryForTesting
    }
    #endif
    return FileManager.default.temporaryDirectory.appending(path: "MaccyIntentImages", directoryHint: .isDirectory)
  }

  /// Where versions before the per-export temp files wrote every exported image.
  static var legacyExport: URL {
    URL.documentsDirectory.appending(path: "image.png")
  }

  private static var exports: [ObjectIdentifier: [URL]] = [:]
  /// Files whose owner was removed but which could not be deleted yet.
  private(set) static var pendingRemovals: Set<URL> = []
  private static var didRemoveLeftovers = false

  static var hasPendingRemovals: Bool { !pendingRemovals.isEmpty }

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

  /// Deletes the item's exports, and retries every earlier failure. Returns whether no export
  /// is left to delete.
  @discardableResult
  static func remove(for item: HistoryItem) -> Bool {
    if let files = exports.removeValue(forKey: ObjectIdentifier(item)) {
      pendingRemovals.formUnion(files)
    }
    return retryPendingRemovals()
  }

  /// Keeps exports alive when a re-copied item replaces its duplicate in history.
  static func transfer(from old: HistoryItem, to new: HistoryItem) {
    guard let files = exports.removeValue(forKey: ObjectIdentifier(old)) else { return }
    exports[ObjectIdentifier(new), default: []].append(contentsOf: files)
  }

  /// Revokes every outstanding export, including exports from previous app launches. Returns
  /// whether none is left.
  @discardableResult
  static func removeAll() -> Bool {
    for files in exports.values {
      pendingRemovals.formUnion(files)
    }
    exports.removeAll()

    let fileManager = FileManager.default
    do {
      let leftovers = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      pendingRemovals.formUnion(leftovers)
    } catch {
      // A directory that can't be listed is removed as a whole; one that doesn't exist is fine.
      if fileManager.fileExists(atPath: directory.path) {
        pendingRemovals.insert(directory)
      }
    }

    guard retryPendingRemovals() else {
      return false
    }
    // Only an empty directory is left.
    try? fileManager.removeItem(at: directory)
    return true
  }

  /// Tries again to delete every file that could not be deleted before. Returns whether none is
  /// left.
  @discardableResult
  static func retryPendingRemovals() -> Bool {
    for file in pendingRemovals where removeFile(file) {
      pendingRemovals.remove(file)
    }
    return pendingRemovals.isEmpty
  }

  /// Once per launch: removes exports left by a crash or a quit without clearing, and the single
  /// `Documents/image.png` that earlier versions wrote and never deleted. Returns whether none is
  /// left.
  @discardableResult
  static func removeLeftoversOnce() -> Bool {
    guard !didRemoveLeftovers else { return retryPendingRemovals() }
    didRemoveLeftovers = true
    return removeLeftovers(legacyExport: legacyExport)
  }

  @discardableResult
  static func removeLeftovers(legacyExport: URL) -> Bool {
    pendingRemovals.insert(legacyExport)
    return removeAll()
  }

  /// Whether the file is gone: deleted now, or already absent.
  private static func removeFile(_ file: URL) -> Bool {
    let fileManager = FileManager.default
    do {
      try fileManager.removeItem(at: file)
      return true
    } catch {
      return !fileManager.fileExists(atPath: file.path) && !isSymbolicLink(file)
    }
  }

  private static func isSymbolicLink(_ file: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeSymbolicLink
  }
}
