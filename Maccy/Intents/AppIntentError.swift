import Foundation

enum AppIntentError: Swift.Error, Equatable, CustomLocalizedStringResourceConvertible {
  case notFound
  case disabled

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notFound: return "Clipboard item not found"
    case .disabled: return "Maccy App Intents are disabled by your organisation or in settings"
    }
  }
}
