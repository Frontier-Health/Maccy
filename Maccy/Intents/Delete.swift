import AppIntents

struct Delete: AppIntent, CustomIntentMigratedAppIntent {
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  static let intentClassName = "DeleteIntent"

  static let title: LocalizedStringResource = "Delete Item from Clipboard History"
  static let description = IntentDescription("Deletes an item from Maccy clipboard history.")

  @Parameter(title: "Number", default: 1)
  var number: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Delete \(\.$number) Item from Clipboard History")
  }

  func perform() async throws -> some IntentResult {
    try await MainActor.run {
      try HistoryIntentAccess.requireEnabled()
      let item = try HistoryIntentAccess.item(number: number, in: AppState.shared.history.items)

      guard AppState.shared.history.delete(item) else {
        throw AppIntentError.storageFailure
      }
    }

    return .result()
  }
}
