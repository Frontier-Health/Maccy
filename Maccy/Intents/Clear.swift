import AppIntents
import Defaults

struct Clear: AppIntent, CustomIntentMigratedAppIntent {
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  static let intentClassName = "ClearIntent"

  static let title: LocalizedStringResource = "Clear Clipboard History"
  static let description = IntentDescription("Clears all Maccy clipboard history except for pinned items.")

  static var parameterSummary: some ParameterSummary {
    Summary("Clear Clipboard History")
  }

  func perform() async throws -> some IntentResult {
    try await MainActor.run { try HistoryIntentAccess.requireEnabled() }

    if !Defaults[.suppressClearAlert] {
      try await requestConfirmation()
    }

    try await MainActor.run {
      try HistoryIntentAccess.requireEnabled()
      AppState.shared.history.clear()
    }
    return .result()
  }
}
