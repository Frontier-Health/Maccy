import AppIntents

struct Select: AppIntent, CustomIntentMigratedAppIntent {
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  static let intentClassName = "SelectIntent"

  static let title: LocalizedStringResource = "Select Item in Clipboard History"
  static let description = IntentDescription("""
  Selects an item in Maccy clipboard history.
  Depending on Maccy settings, it might trigger pasting of the selected item.
  """)

  static var parameterSummary: some ParameterSummary {
    Summary("Select \(\.$number) Item in Clipboard History")
  }

  @Parameter(title: "Number", default: 1, requestValueDialog: "What is the number of the item?")
  var number: Int

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    try await MainActor.run { try HistoryIntentAccess.requireEnabled() }
    try await HistoryIntentAccess.waitUntilReady()
    let value = try await MainActor.run { () -> String in
      try HistoryIntentAccess.requireEnabled()
      AppState.shared.history.enforceStoragePolicy()
      AppState.shared.history.runExpiryIfDue()
      let item = try HistoryIntentAccess.item(number: number, in: AppState.shared.history.items)

      let value = Self.value(of: item)
      AppState.shared.history.select(item, flags: .currentModifierFlags)

      return value
    }

    return .result(value: value)
  }

  // What the intent returns for an item: its title that may be shown under
  // the current storage policy.
  @MainActor
  static func value(of item: HistoryItemDecorator) -> String {
    item.item.displayTitle
  }
}
