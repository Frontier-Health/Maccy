import AppKit
import Defaults
import Foundation
import SwiftData
import Testing
@testable import Maccy

// Records removal failures instead of showing an alert.
@MainActor
final class RecordingRemovalFailureReporter: HistoryRemovalFailureReporting {
  private(set) var failures: [HistoryRemoval] = []

  func removalFailed(_ removal: HistoryRemoval, error: any Error) {
    failures.append(removal)
  }
}

private struct InjectedSaveFailure: Error {}

// The clock History measures expiry with, moved by the test.
@MainActor
final class TestClock {
  var now: Date
  init(_ now: Date) { self.now = now }
}

// A raw preference value of any type, so a test can restore it exactly.
struct SavedRawPreference: @unchecked Sendable {
  let defaults: UserDefaults
  let key: String
  let value: Any?

  init(_ key: String, in defaults: UserDefaults) {
    self.defaults = defaults
    self.key = key
    value = defaults.object(forKey: key)
  }

  func restore() {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

extension SharedStateTests {
  // Finding A6: removals that fail are reported and change nothing; the
  // history size is clamped; expiry; compaction; launch maintenance.
  @MainActor
  final class HistoryRetentionTests { // swiftlint:disable:this type_body_length
    let history = History.shared
    let reporter = RecordingRemovalFailureReporter()
    let client = RecordingNotificationClient()
    let savedClient = Notifier.client
    let savedReporter = History.removalFailureReporter
    let savedStoragePreference = SavedStoragePreference()
    let preferences = Defaults.Keys.size.suite
    let savedRawSize = SavedRawPreference(HistorySize.preferenceKey, in: Defaults.Keys.size.suite)
    let savedClearOnQuit = Defaults[.clearOnQuit]
    let savedSortBy = Defaults[.sortBy]
    let savedPinTo = Defaults[.pinTo]
    let savedSuppressClearAlert = Defaults[.suppressClearAlert]
    let savedIntentsEnabled = Defaults[.intentsEnabled]
    // Expiry is read from a scratch domain, so no test depends on, or leaves
    // behind, a real expiry preference.
    let expirySuiteName = "\(AppIdentity.bundleIdentifier).tests.expiry.\(UUID().uuidString)"
    let expiryDefaults: UserDefaults
    // The injected clock.
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let clock: TestClock

    init() {
      expiryDefaults = UserDefaults(suiteName: expirySuiteName)!
      clock = TestClock(start)

      Storage.shared.saveFailureForTesting = nil
      Defaults.Keys.enabledPasteboardTypes.suite.removeObject(forKey: StoragePolicy.preferenceKey)
      try? Storage.shared.context.save()
      history.clearAll()
      history.storageSettingChanged()
      Defaults[.size] = 10
      Defaults[.clearOnQuit] = false
      Defaults[.sortBy] = .lastCopiedAt
      Defaults[.pinTo] = .bottom
      Defaults[.suppressClearAlert] = true
      Defaults[.intentsEnabled] = true

      Notifier.client = client
      History.removalFailureReporter = reporter
      history.expiryPreferences = expiryDefaults
      history.now = { [clock] in clock.now }
      history.resetAutomaticRemovalFailuresForTesting()
    }

    deinit {
      savedStoragePreference.restore()
      savedRawSize.restore()
      Defaults[.clearOnQuit] = savedClearOnQuit
      Defaults[.sortBy] = savedSortBy
      Defaults[.pinTo] = savedPinTo
      Defaults[.suppressClearAlert] = savedSuppressClearAlert
      Defaults[.intentsEnabled] = savedIntentsEnabled
      UserDefaults.standard.removePersistentDomain(forName: expirySuiteName)
    }

    // Main-actor state the next suite must not inherit. Every test calls it
    // when it ends (deinit can't reach main-actor state).
    private func restoreHistory() {
      Storage.shared.saveFailureForTesting = nil
      Notifier.client = savedClient
      History.removalFailureReporter = savedReporter
      history.expiryPreferences = Defaults.Keys.historyExpiryHours.suite
      history.now = { Date.now }
      history.resetAutomaticRemovalFailuresForTesting()
    }

    // MARK: Failed removals change nothing

    @Test("A failing save leaves history, notifications and exports unchanged",
          arguments: ["delete", "deleteSelection", "clear", "clearAll", "clearOnQuit"])
    func failedRemovalChangesNothing(path: String) throws {
      defer { restoreHistory() }
      let pinned = history.added(historyItem("pinned survivor"))
      history.togglePin(pinned)
      let older = history.added(historyItem("older secret"))
      let newer = history.added(historyItem("newer secret"))
      client.resolvePermissions()
      client.resolveAdds()
      let identifier = newer.item.notificationID
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: newer.item)
      try Storage.shared.save()
      let shown = history.items.toArray()

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      let removed: Bool
      let expected: HistoryRemoval
      switch path {
      case "delete":
        removed = history.delete(newer)
        expected = .delete
      case "deleteSelection":
        removed = history.delete([older, newer])
        expected = .delete
      case "clear":
        removed = history.clear()
        expected = .clear
      case "clearAll":
        removed = history.clearAll()
        expected = .clearAll
      default:
        removed = history.clearOnQuit()
        expected = .clearOnQuit
      }
      Storage.shared.saveFailureForTesting = nil

      #expect(!removed)
      #expect(reporter.failures == [expected])
      #expect(history.items.toArray() == shown)
      #expect(newer.item.contents.first?.value == Data("newer secret".utf8))
      try assertStored(["pinned survivor", "older secret", "newer secret"])
      #expect(FileManager.default.fileExists(atPath: export.path))
      #expect(!client.removed.contains(identifier))
      #expect(client.removeAllCount == 0)
      #expect(Notifier.isActive(identifier))

      // The same removal works once saving does.
      switch path {
      case "delete": #expect(history.delete(newer))
      case "deleteSelection": #expect(history.delete([older, newer]))
      case "clear": #expect(history.clear())
      case "clearAll": #expect(history.clearAll())
      default: #expect(history.clearOnQuit())
      }
      #expect(!FileManager.default.fileExists(atPath: export.path))
      #expect(client.removed.contains(identifier) || client.removeAllCount > 0)
      #expect(reporter.failures == [expected])
    }

    @Test("The Delete and Clear intents throw when the store can't be changed", arguments: ["delete", "clear"])
    func intentsReportStorageFailure(path: String) async throws {
      defer { restoreHistory() }
      history.added(historyItem("first"))
      history.added(historyItem("second"))
      try Storage.shared.save()
      let shown = history.items.toArray()

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      if path == "delete" {
        var intent = Delete()
        intent.number = 1
        let first = intent
        await #expect(throws: AppIntentError.storageFailure) { _ = try await first.perform() }
      } else {
        await #expect(throws: AppIntentError.storageFailure) { _ = try await Clear().perform() }
      }
      Storage.shared.saveFailureForTesting = nil

      #expect(history.items.toArray() == shown)
      try assertStored(["first", "second"])
      #expect(reporter.failures == [path == "delete" ? .delete : .clear])
    }

    @Test("A failing trim keeps the items, in the list and the store, and alerts once per run of failures")
    func failedTrimIsReportedOnce() async throws {
      defer { restoreHistory() }
      Defaults[.size] = 2
      history.added(historyItem("one"))
      history.added(historyItem("two"))
      try Storage.shared.save()
      let shown = history.items.toArray()

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      Defaults[.size] = 1
      try await history.load()
      try await history.load()
      Storage.shared.saveFailureForTesting = nil

      #expect(history.items.toArray() == shown)
      try assertStored(["one", "two"])
      #expect(reporter.failures == [.trim])
      #expect(history.automaticRemovalFailedAt == start)

      try await history.load()
      #expect(history.items.count == 1)
      try assertStored(["two"])
      #expect(history.automaticRemovalFailedAt == nil)
    }

    // MARK: History size

    @Test("The history size is clamped to 1...999 whatever is stored", arguments: [
      (nil, 200), (0, 1), (-5, 1), (Int.min, 1), (1_000_000, 999), (Int.max, 999), (12, 12)
    ] as [(Int?, Int)])
    func historySizeIsClamped(stored: Int?, expected: Int) {
      defer { restoreHistory() }
      let defaults = scratchDefaults()
      defaults.set(stored, forKey: HistorySize.preferenceKey)
      #expect(HistorySize.effective(in: defaults) == expected)
    }

    @Test("A history size of the wrong type reads as a number or the default")
    func historySizeOfWrongType() {
      defer { restoreHistory() }
      let defaults = scratchDefaults()
      let cases: [(Any, Int)] = [
        ("abc", 200), ("", 200), ("12", 12), (" 7 ", 7), ("-3", 1), (true, 200), (false, 200),
        (3.9, 3), (0.2, 1), (1e300, 999), (-1e300, 1), ([5], 200), (["historySize": 5], 200),
        (Date(), 200), (Data([1]), 200)
      ]
      for (value, expected) in cases {
        defaults.set(value, forKey: HistorySize.preferenceKey)
        #expect(HistorySize.effective(in: defaults) == expected, "\(type(of: value))")
      }
    }

    @Test("A history size forced by a profile is clamped and reported as forced")
    func forcedHistorySize() throws {
      defer { restoreHistory() }
      let defaults = try #require(ManagedDefaults(
        suiteName: "\(AppIdentity.bundleIdentifier).tests.size.\(UUID().uuidString)",
        forced: [HistorySize.preferenceKey: 0]
      ))
      #expect(HistorySize.effective(in: defaults) == 1)
      #expect(HistorySize.isForced(in: defaults))
      #expect(!HistorySize.isForced(in: scratchDefaults()))
    }

    @Test("Adding with a stored history size of 0, negative, huge or wrong type doesn't crash",
          arguments: [0, -1, Int.min, Int.max, "abc", true] as [any Sendable])
    func addingWithInvalidHistorySize(stored: any Sendable) async throws {
      defer { restoreHistory() }
      preferences.set(stored, forKey: HistorySize.preferenceKey)
      for index in 0..<3 {
        history.added(historyItem("item \(index)"))
      }
      try await history.load()
      let expected = min(3, HistorySize.current)
      #expect(history.items.count == expected)
      #expect(try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>()) == expected)
    }

    // MARK: CloudKit

    @Test("History never syncs to CloudKit")
    func cloudKitIsDisabled() throws {
      defer { restoreHistory() }
      let none = String(reflecting: ModelConfiguration.CloudKitDatabase.none)
      #expect(none != String(reflecting: ModelConfiguration.CloudKitDatabase.automatic))
      #expect(String(reflecting: Storage.shared.configuration.cloudKitDatabase) == none)

      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let onDisk = Storage(storeURL: directory.appending(path: "Storage.sqlite"))
      #expect(String(reflecting: onDisk.configuration.cloudKitDatabase) == none)
      #expect(onDisk.configuration.cloudKitContainerIdentifier == nil)
    }

    // MARK: Expiry setting

    @Test("The expiry preference is read fail-closed")
    func expiryPreferenceIsRead() {
      defer { restoreHistory() }
      let cases: [(Any?, HistoryExpiry.State)] = [
        (nil, .off), (0, .off), ("0", .off), (24, .hours(24)), ("48", .hours(48)), (0.5, .hours(1)),
        (36.9, .hours(36)), (1_000_000, .hours(HistoryExpiry.maximumHours)), (1e300, .hours(HistoryExpiry.maximumHours)),
        (-1, .invalid), ("-24", .invalid), ("abc", .invalid), ("", .invalid), (true, .invalid), (false, .invalid),
        ([24], .invalid), (["hours": 24], .invalid), (Date(), .invalid)
      ]
      for (value, expected) in cases {
        #expect(HistoryExpiry.state(of: value) == expected, "\(String(describing: value))")
      }
      #expect(HistoryExpiry(state: .invalid, isForced: false).hours == HistoryExpiry.invalidValueHours)
      #expect(HistoryExpiry(state: .off, isForced: true).hours == nil)
    }

    @Test("Expiry is off by default")
    func expiryIsOffByDefault() throws {
      defer { restoreHistory() }
      let expiry = HistoryExpiry.effective(in: expiryDefaults)
      #expect(!expiry.isOn)
      #expect(!expiry.isForced)

      let old = history.added(historyItem("a year old", lastCopied: -24 * 365))
      try Storage.shared.save()
      #expect(history.purgeExpiredItems() == 0)
      #expect(history.items.toArray() == [old])
    }

    @Test("Items last copied more than N hours ago are purged; newer ones and user-set pins are kept")
    func expiryPurgesOldItems() throws {
      defer { restoreHistory() }
      expiryDefaults.set(24, forKey: HistoryExpiry.preferenceKey)
      let old = history.added(historyItem("old secret", lastCopied: -25))
      let recent = history.added(historyItem("recent", lastCopied: -23))
      let oldPinned = history.added(historyItem("old pinned", lastCopied: -48))
      history.togglePin(oldPinned)
      client.resolvePermissions()
      client.resolveAdds()
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: old.item)
      let identifier = old.item.notificationID
      try Storage.shared.save()

      #expect(history.purgeExpiredItems() == 1)
      #expect(Set(history.items.toArray()) == [recent, oldPinned])
      try assertStored(["recent", "old pinned"])
      #expect(!FileManager.default.fileExists(atPath: export.path))
      #expect(client.removed.contains(identifier))

      // Two more hours: the recent item expires too.
      clock.now = start.addingTimeInterval(2 * 3600)
      #expect(history.purgeExpiredItems() == 1)
      #expect(history.items.toArray() == [oldPinned])
      #expect(reporter.failures.isEmpty)
    }

    @Test("A profile-forced expiry wins over the user's value and removes pinned items too")
    func forcedExpiryWins() throws {
      defer { restoreHistory() }
      // The user's own value is off; the profile forces one hour.
      expiryDefaults.set(0, forKey: HistoryExpiry.preferenceKey)
      let defaults = try #require(ManagedDefaults(suiteName: expirySuiteName, forced: [HistoryExpiry.preferenceKey: 1]))
      history.expiryPreferences = defaults
      let expiry = HistoryExpiry.effective(in: defaults)
      #expect(expiry.state == .hours(1))
      #expect(expiry.isForced)
      #expect(expiry.expiresPinnedItems)

      let pinned = history.added(historyItem("pinned past retention", lastCopied: -2))
      history.togglePin(pinned)
      let recent = history.added(historyItem("recent", lastCopied: 0))
      try Storage.shared.save()

      #expect(history.purgeExpiredItems() == 1)
      #expect(history.items.toArray() == [recent])
      try assertStored(["recent"])
    }

    @Test("A wrong-type or negative expiry fails closed to the shortest expiry", arguments: [
      "abc", "-5", "true"
    ])
    func invalidExpiryFailsClosed(stored: String) throws {
      defer { restoreHistory() }
      let value: Any = switch stored {
      case "-5": -5
      case "true": true
      default: stored
      }
      expiryDefaults.set(value, forKey: HistoryExpiry.preferenceKey)
      #expect(HistoryExpiry.effective(in: expiryDefaults).isInvalid)

      history.added(historyItem("two hours old", lastCopied: -2))
      let recent = history.added(historyItem("half an hour old", lastCopied: -0.5))
      let pinned = history.added(historyItem("pinned", lastCopied: -2))
      history.togglePin(pinned)
      try Storage.shared.save()

      #expect(history.purgeExpiredItems() == 1)
      // Not forced: the user's pins are kept.
      #expect(Set(history.items.toArray()) == [recent, pinned])
    }

    @Test("Items stamped in the future after the clock moved backwards still expire")
    func clockMovedBackwards() throws {
      defer { restoreHistory() }
      expiryDefaults.set(24, forKey: HistoryExpiry.preferenceKey)
      // Copied at a time 30 days ahead of the clock now: the clock was set back.
      let future = history.added(historyItem("copied before the clock went back", lastCopied: 24 * 30))
      // Within the tolerance: left as it is.
      let slightlyAhead = history.added(historyItem("slightly ahead", lastCopied: 0.05))
      try Storage.shared.save()

      #expect(history.purgeExpiredItems() == 0)
      #expect(future.item.lastCopiedAt == start)
      #expect(slightlyAhead.item.lastCopiedAt == start.addingTimeInterval(0.05 * 3600))

      // Without restamping this would be kept for another 30 days.
      clock.now = start.addingTimeInterval(25 * 3600)
      #expect(history.purgeExpiredItems() == 2)
      #expect(history.items.toArray().isEmpty)
    }

    @Test("A failing purge keeps the items and alerts once per run of failures")
    func failedPurgeIsReportedOnce() throws {
      defer { restoreHistory() }
      expiryDefaults.set(1, forKey: HistoryExpiry.preferenceKey)
      let old = history.added(historyItem("expired", lastCopied: -3))
      try Storage.shared.save()

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      #expect(history.purgeExpiredItems() == nil)
      history.runExpiry()
      #expect(history.purgeExpiredItems() == nil)
      Storage.shared.saveFailureForTesting = nil

      #expect(history.items.toArray() == [old])
      try assertStored(["expired"])
      #expect(reporter.failures == [.expiry])
      #expect(history.automaticRemovalFailedAt == start)

      #expect(history.purgeExpiredItems() == 1)
      #expect(history.automaticRemovalFailedAt == nil)
      // A new run of failures alerts again.
      history.added(historyItem("expired later", lastCopied: -3))
      try Storage.shared.save()
      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      #expect(history.purgeExpiredItems() == nil)
      #expect(reporter.failures == [.expiry, .expiry])
    }

    @Test("The expiry timer and observers are not installed in unit tests")
    func noExpiryScheduleInUnitTests() {
      defer { restoreHistory() }
      history.startExpirySchedule()
      #expect(!history.isExpiryScheduled)
    }

    // MARK: Launch

    @Test("Launch clears unpinned history when clear-on-quit is on, and keeps pins")
    func launchClearsWhenClearOnQuit() throws {
      defer { restoreHistory() }
      Defaults[.clearOnQuit] = true
      let pinned = history.added(historyItem("pinned"))
      history.togglePin(pinned)
      history.added(historyItem("left by a crash"))
      client.resolvePermissions()
      client.resolveAdds()
      try Storage.shared.save()

      history.performLaunchMaintenance()

      #expect(history.items.toArray() == [pinned])
      try assertStored(["pinned"])
      #expect(reporter.failures.isEmpty)
    }

    @Test("Launch leaves history when clear-on-quit is off, but expires and trims it")
    func launchExpiresAndTrims() throws {
      defer { restoreHistory() }
      expiryDefaults.set(24, forKey: HistoryExpiry.preferenceKey)
      Defaults[.size] = 2
      // Stored directly, as left by an earlier session with a larger size.
      for (index, hours) in [-48.0, -3, -2, -1].enumerated() {
        let item = historyItem("stored \(index)", lastCopied: hours)
        item.firstCopiedAt = item.lastCopiedAt
      }
      try Storage.shared.save()

      history.performLaunchMaintenance()

      try assertStored(["stored 2", "stored 3"])
      #expect(history.items.count == 2)
    }

    @Test("A failing clear at launch keeps history and is reported once")
    func failedLaunchClear() throws {
      defer { restoreHistory() }
      Defaults[.clearOnQuit] = true
      history.added(historyItem("still stored"))
      try Storage.shared.save()

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      history.performLaunchMaintenance()
      Storage.shared.saveFailureForTesting = nil

      try assertStored(["still stored"])
      #expect(history.items.count == 1)
      #expect(reporter.failures == [.clearOnLaunch])
      #expect(history.automaticRemovalFailedAt != nil)
    }

    // MARK: Compaction

    @Test("Deleted content is gone from the database file and the WAL after compaction; pins survive",
          arguments: ["clear", "clearAll", "clearOnQuit", "clearOnLaunch", "expiry"])
    func compactionRemovesDeletedBytes(path: String) async throws {
      defer { restoreHistory() }
      let directory = try temporaryDirectory()
      let url = directory.appending(path: "Storage.sqlite")
      let previous = Storage.replaceSharedForTesting(with: Storage(storeURL: url))
      var failure: (any Error)?
      do {
        try await compactAndCheck(path: path, directory: directory, url: url)
      } catch {
        failure = error
      }
      Storage.replaceSharedForTesting(with: previous)
      try await history.load()
      try? FileManager.default.removeItem(at: directory)
      if let failure {
        throw failure
      }
    }

    private func compactAndCheck(path: String, directory: URL, url: URL) async throws {
      let wal = URL(fileURLWithPath: url.path + "-wal")
      try await history.load()

      let secret = "A6-DELETED-MARKER-\(UUID().uuidString)"
      let kept = "A6-PINNED-MARKER-\(UUID().uuidString)"
      expiryDefaults.set(path == "expiry" ? 1 : 0, forKey: HistoryExpiry.preferenceKey)
      let pinned = history.added(historyItem(kept, lastCopied: 0))
      history.togglePin(pinned)
      for index in 0..<5 {
        history.added(historyItem("\(secret)-\(index)", lastCopied: -2))
      }
      try Storage.shared.save()
      #expect(contains(url, secret) || contains(wal, secret), "the marker must be on disk before removal")

      switch path {
      case "clear": #expect(history.clear())
      case "clearAll": #expect(history.clearAll())
      case "clearOnQuit": #expect(history.clearOnQuit())
      case "clearOnLaunch":
        Defaults[.clearOnQuit] = true
        history.performLaunchMaintenance()
      default:
        history.runExpiry()
      }

      #expect(!contains(url, secret))
      #expect(!contains(wal, secret))
      #expect(reporter.failures.isEmpty)
      // Only the store and SQLite's own sidecar files: no external-storage
      // blobs that could keep deleted content.
      let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(Set(files).isSubset(of: ["Storage.sqlite", "Storage.sqlite-wal", "Storage.sqlite-shm"]))

      // What remains is intact, in this store and when opened afresh.
      let stored = try Storage(storeURL: url).allItems()
      if path == "clearAll" {
        #expect(stored.isEmpty)
        #expect(!contains(url, kept) && !contains(wal, kept))
        return
      }
      #expect(history.items.toArray() == [pinned])
      #expect(stored.count == 1)
      #expect(stored.first?.pin == pinned.item.pin)
      #expect(stored.first?.contents.first?.value == Data(kept.utf8))
      // The shared store keeps working after compaction.
      history.added(historyItem("after compaction"))
      try Storage.shared.save()
      #expect(try Storage(storeURL: url).allItems().count == 2)
    }

    @Test("Compaction leaves an in-memory store alone")
    func compactionOfInMemoryStore() throws {
      defer { restoreHistory() }
      #expect(Storage.shared.storeURL == nil)
      try Storage.shared.compact()
    }

    // MARK: Helpers

    private func historyItem(_ value: String, lastCopied hoursFromStart: Double? = nil) -> HistoryItem {
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(value.utf8))]
      item.numberOfCopies = 1
      if let hoursFromStart {
        item.lastCopiedAt = start.addingTimeInterval(hoursFromStart * 3600)
        item.firstCopiedAt = item.lastCopiedAt
      }
      item.regenerateTitle()
      return item
    }

    // The values of every stored item, compared as a set.
    private func assertStored(_ values: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) throws {
      let items = try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
      let stored = Set(items.compactMap { $0.contents.first?.value }.map { String(decoding: $0, as: UTF8.self) })
      #expect(stored == values, sourceLocation: sourceLocation)
    }

    private func scratchDefaults() -> UserDefaults {
      let name = "\(AppIdentity.bundleIdentifier).tests.scratch.\(UUID().uuidString)"
      UserDefaults.standard.removePersistentDomain(forName: name)
      return UserDefaults(suiteName: name)!
    }

    private func temporaryDirectory() throws -> URL {
      let directory = FileManager.default.temporaryDirectory.appending(path: "A6-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }

    private func contains(_ url: URL, _ marker: String) -> Bool {
      guard let data = try? Data(contentsOf: url) else { return false }
      return data.range(of: Data(marker.utf8)) != nil
    }
  }
}
