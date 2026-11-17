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
    let value = try await MainActor.run { () -> String in
      try HistoryIntentAccess.requireEnabled()
      let item = try HistoryIntentAccess.item(number: number, in: AppState.shared.history.items)

      let value = item.title
      AppState.shared.history.select(item, flags: .currentModifierFlags)

      return value
    }

    return .result(value: value)
  }
}
