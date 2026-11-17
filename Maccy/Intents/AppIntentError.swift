import Foundation

enum AppIntentError: Swift.Error, Equatable, CustomLocalizedStringResourceConvertible {
  case notFound
  case disabled
  case storageFailure
  case notReady

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notFound: return "Clipboard item not found"
    case .disabled: return "Maccy App Intents are disabled by your organisation or in settings"
    case .storageFailure: return "Maccy could not change its history database. Nothing was removed."
    case .notReady: return "Maccy is still starting. Try again in a moment."
    }
  }
}
