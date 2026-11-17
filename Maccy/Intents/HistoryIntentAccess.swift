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

  // Waits until launch maintenance has finished (see `LaunchSequence`), or
  // throws `notReady`. History is never read before. If history could not be
  // loaded, it is tried once more; if that fails too, `notReady` at once.
  static func waitUntilReady() async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: readinessTimeout)
    while !History.shared.isLaunched {
      guard clock.now < deadline else {
        throw AppIntentError.notReady
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    try requireLoaded()
  }

  // Throws `notReady` unless history is loaded (tried again if it isn't), so
  // an intent never answers from a list that wasn't loaded.
  static func requireLoaded() throws {
    guard History.shared.loadIfNeeded() else {
      throw AppIntentError.notReady
    }
  }

  static func item<Items: RandomAccessCollection>(number: Int, in items: Items) throws -> Items.Element {
    try requireLoaded()
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
/// A path is forgotten only after its file was deleted, or after an error that shows it is absent:
/// "no such file" from the delete itself, or from `lstat`. Any other error (no permission on the
/// file or on a parent directory, busy, I/O) proves nothing about the file, so the path is kept in
/// `pendingRemovals` and tried again by every later removal, clear, the launch sweep and the
/// periodic maintenance. Every removal returns whether no export is
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
      // A directory that can't be listed is removed as a whole; one shown to be absent is fine.
      if !isAbsent(directory) {
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

  /// Whether the file is gone: deleted now, or shown to be absent.
  private static func removeFile(_ file: URL) -> Bool {
    do {
      try FileManager.default.removeItem(at: file)
      return true
    } catch {
      return reportsNoSuchFile(error) || isAbsent(file)
    }
  }

  /// Whether a failed delete says the file does not exist. `fileExists(atPath:)` can't tell: it is
  /// also false when a parent directory denies search permission.
  static func reportsNoSuchFile(_ error: any Error) -> Bool {
    let error = error as NSError
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
      return underlying.code == Int(ENOENT)
    }
    return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) ||
      (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
  }

  /// Whether `lstat` says nothing is at `url` (not even a symbolic link). Any other outcome,
  /// including "permission denied", counts as present.
  static func isAbsent(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) != 0 && errno == ENOENT
  }
}
