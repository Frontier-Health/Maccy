import AppIntents

struct Select: AppIntent, CustomIntentMigratedAppIntent {
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

  private let positionOffset = 1

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let value = try await MainActor.run { () -> String in
      // Titles reflect the current storage policy before one is returned.
      AppState.shared.history.enforceStoragePolicy()
      let items = AppState.shared.history.items
      let index = number - positionOffset
      guard items.count >= index else {
        throw AppIntentError.notFound
      }

      let value = Self.value(of: items[index])
      AppState.shared.history.select(items[index], flags: .currentModifierFlags)

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
