import AppIntents
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

    @Test("Image exports are unique, readable and revoked together")
    func imageExports() throws {
      defer { IntentImageExports.removeAll() }
      let data = Data("test image".utf8)
      let first = try IntentImageExports.write(data)
      let second = try IntentImageExports.write(data)
      #expect(first != second)
      #expect(try Data(contentsOf: first) == data)
      #expect(try Data(contentsOf: second) == data)
      #expect(first.path.hasPrefix(FileManager.default.temporaryDirectory.path))
      IntentImageExports.removeAll()
      #expect(!FileManager.default.fileExists(atPath: first.path))
      #expect(!FileManager.default.fileExists(atPath: second.path))
      IntentImageExports.removeAll()
    }
  }
}
