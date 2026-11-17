import Foundation

nonisolated enum AppIdentity {
  static let bundleIdentifier: String = {
    guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
      preconditionFailure("The app bundle must have a configured bundle identifier")
    }
    return identifier
  }()

  static let pinReorderTypeIdentifier = bundleIdentifier + ".pin-reorder"

  static func shellScript(_ key: String) -> String {
    NSLocalizedString(key, tableName: "AdvancedSettings", comment: "")
      .replacingOccurrences(of: "<BUNDLE_ID>", with: bundleIdentifier)
  }
}
