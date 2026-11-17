import AppIntents
import AppKit
import Defaults
import Foundation
import Testing
@testable import Maccy

extension SharedStateTests {
  @MainActor
  struct AppIntentTests {
    @Test("Invalid history numbers throw notFound", arguments: [0, -1, Int.min, 4, Int.max])
    func invalidNumbers(number: Int) {
      #expect(throws: AppIntentError.notFound) {
        try HistoryIntentAccess.item(number: number, in: ["first", "middle", "last"])
      }
    }

    @Test("Default number on empty history throws notFound")
    func emptyHistory() {
      #expect(throws: AppIntentError.notFound) {
        try HistoryIntentAccess.item(number: 1, in: [String]())
      }
    }

    @Test("Valid numbers resolve to the right item", arguments: [1, 2, 3])
    func validNumbers(number: Int) throws {
      let items = ["first", "middle", "last"]
      #expect(try HistoryIntentAccess.item(number: number, in: items) == items[number - 1])
    }

    @Test("History numbers also work across pinned and unpinned collections")
    func concatenatedItems() throws {
      let items = ConcatenatedCollection(["pinned"], ["recent"])
      #expect(try HistoryIntentAccess.item(number: 1, in: items) == "pinned")
      #expect(try HistoryIntentAccess.item(number: 2, in: items) == "recent")
    }

    @Test("Every intent refuses when intentsEnabled is false")
    func disabledIntents() async {
      let savedEnabled = Defaults[.intentsEnabled]
      Defaults[.intentsEnabled] = false
      defer { Defaults[.intentsEnabled] = savedEnabled }

      await #expect(throws: AppIntentError.disabled) { _ = try await Get().perform() }
      await #expect(throws: AppIntentError.disabled) { _ = try await Select().perform() }
      await #expect(throws: AppIntentError.disabled) { _ = try await Delete().perform() }
      await #expect(throws: AppIntentError.disabled) { _ = try await Clear().perform() }
    }

    @Test("Enabled intents pass the settings gate")
    func enabledIntents() throws {
      let savedEnabled = Defaults[.intentsEnabled]
      Defaults[.intentsEnabled] = true
      defer { Defaults[.intentsEnabled] = savedEnabled }
      try HistoryIntentAccess.requireEnabled()
    }

    @Test("Every history intent requires authentication")
    func authenticationPolicies() {
      #expect(Get.authenticationPolicy == .requiresAuthentication)
      #expect(Select.authenticationPolicy == .requiresAuthentication)
      #expect(Delete.authenticationPolicy == .requiresAuthentication)
      #expect(Clear.authenticationPolicy == .requiresAuthentication)
    }

    @Test("Disabled intents leave history untouched")
    func disabledIntentsDoNotTouchHistory() async {
      let savedEnabled = Defaults[.intentsEnabled]
      let history = AppState.shared.history
      let decorator = history.added(historyItem("kept while intents are disabled"))
      let countBefore = history.items.count
      Defaults[.intentsEnabled] = false
      defer {
        Defaults[.intentsEnabled] = savedEnabled
        history.delete(decorator)
      }

      await #expect(throws: AppIntentError.disabled) { _ = try await Delete().perform() }
      await #expect(throws: AppIntentError.disabled) { _ = try await Clear().perform() }

      #expect(history.items.count == countBefore)
      #expect(history.items.contains { $0 == decorator })
    }

    @Test("Image exports are unique, readable and revoked together")
    func imageExports() throws {
      defer { IntentImageExports.removeAll() }
      let item = HistoryItem()
      let data = Data("test image".utf8)
      let first = try IntentImageExports.write(data, for: item)
      let second = try IntentImageExports.write(data, for: item)
      #expect(first != second)
      #expect(try Data(contentsOf: first) == data)
      #expect(try Data(contentsOf: second) == data)
      #expect(first.path.hasPrefix(FileManager.default.temporaryDirectory.path))
      IntentImageExports.removeAll()
      #expect(!FileManager.default.fileExists(atPath: first.path))
      #expect(!FileManager.default.fileExists(atPath: second.path))
      IntentImageExports.removeAll()
    }

    @Test("Deleting an item removes only that item's exports")
    func deleteRemovesOnlyOwnExports() throws {
      defer { IntentImageExports.removeAll() }
      let history = AppState.shared.history
      let deleted = history.added(historyItem("export owner that is deleted"))
      let kept = history.added(historyItem("export owner that is kept"))
      defer { history.delete(kept) }
      let data = Data("test image".utf8)
      let deletedExport = try IntentImageExports.write(data, for: deleted.item)
      let keptExport = try IntentImageExports.write(data, for: kept.item)

      history.delete(deleted)

      #expect(!FileManager.default.fileExists(atPath: deletedExport.path))
      #expect(FileManager.default.fileExists(atPath: keptExport.path))
    }

    @Test("Exports survive a re-copy that replaces the item, and go when the replacement is deleted")
    func exportsFollowDuplicateReplacement() throws {
      defer { IntentImageExports.removeAll() }
      let history = AppState.shared.history
      let original = history.added(historyItem("exported then copied again"))
      let export = try IntentImageExports.write(Data("test image".utf8), for: original.item)

      let replacement = history.added(historyItem("exported then copied again"))

      #expect(FileManager.default.fileExists(atPath: export.path))

      history.delete(replacement)

      #expect(!FileManager.default.fileExists(atPath: export.path))
    }

    @Test("Clearing history removes every export")
    func clearRemovesExports() throws {
      let history = AppState.shared.history
      let decorator = history.added(historyItem("export owner that is cleared"))
      let export = try IntentImageExports.write(Data("test image".utf8), for: decorator.item)

      history.clear()

      #expect(!FileManager.default.fileExists(atPath: export.path))
    }

    @Test("Launch sweep removes leftover exports and the legacy Documents export")
    func launchSweepRemovesLeftovers() throws {
      let data = Data("test image".utf8)
      let leftover = try IntentImageExports.write(data, for: HistoryItem())
      let legacy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-image.png")
      try data.write(to: legacy)

      IntentImageExports.removeLeftovers(legacyExport: legacy)

      #expect(!FileManager.default.fileExists(atPath: leftover.path))
      #expect(!FileManager.default.fileExists(atPath: legacy.path))
      #expect(IntentImageExports.legacyExport.lastPathComponent == "image.png")
    }

    @Test("Disabled read intents do not clean history or revoke existing exports")
    func disabledReadsDoNotApplyStoragePolicy() async throws {
      let savedStorage = SavedStoragePreference()
      let savedEnabled = Defaults[.intentsEnabled]
      let history = AppState.shared.history
      let decorator = history.added(historyItem("intent gate precedes cleanup"))
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: decorator.item)
      defer {
        savedStorage.restore()
        Defaults[.intentsEnabled] = savedEnabled
        history.delete(decorator)
      }
      Defaults[.enabledPasteboardTypes] = []
      Defaults[.intentsEnabled] = false
      await #expect(throws: AppIntentError.disabled) { _ = try await Get().perform() }
      await #expect(throws: AppIntentError.disabled) { _ = try await Select().perform() }
      #expect(decorator.item.contents.count == 1)
      #expect(FileManager.default.fileExists(atPath: export.path))
      Defaults[.intentsEnabled] = true
      var get = Get()
      get.selected = false
      get.number = 1
      // Other items may exist, but an empty allow-list removes all content first.
      await #expect(throws: AppIntentError.notFound) { _ = try await get.perform() }
      #expect(!FileManager.default.fileExists(atPath: export.path))
    }

    private func historyItem(_ value: String) -> HistoryItem {
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        )
      ]
      item.numberOfCopies = 1
      item.regenerateTitle()
      return item
    }
  }
}
