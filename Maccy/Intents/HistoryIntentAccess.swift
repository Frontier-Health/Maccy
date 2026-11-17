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

@MainActor
enum IntentImageExports {
  private static var directory: URL {
    FileManager.default.temporaryDirectory.appending(path: "MaccyIntentImages", directoryHint: .isDirectory)
  }

  static func write(_ data: Data) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let file = directory.appending(path: "\(UUID().uuidString).png")
    try data.write(to: file, options: [.atomic, .completeFileProtection])
    return file
  }

  // Revoke every outstanding export on clear/delete, including exports from previous app launches.
  static func removeAll() {
    try? FileManager.default.removeItem(at: directory)
  }
}
