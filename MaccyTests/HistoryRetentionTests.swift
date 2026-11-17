import AppKit
import Defaults
import Foundation
import SQLite3
import SwiftData
import Testing
@testable import Maccy

// Records failures instead of showing an alert. Each call is one alert.
@MainActor
final class RecordingRemovalFailureReporter: HistoryRemovalFailureReporting {
  private(set) var reports: [[HistoryFailure]] = []

  // Every failed removal reported, in order.
  var failures: [HistoryRemoval] {
    reports.joined().compactMap { failure in
      switch failure {
      case .removal(let removal): removal
      default: nil
      }
    }
  }

  var exportFailures: Int { reports.joined().filter { $0 == .exportRemoval }.count }

  func report(_ failures: [HistoryFailure], errorCode: String?) {
    reports.append(failures)
  }
}

private struct InjectedSaveFailure: Error {}

// The clocks History measures expiry and compaction delays with, moved by the
// test.
@MainActor
final class TestClock {
  var now: Date
  var uptime: TimeInterval = 10_000
  init(_ now: Date) { self.now = now }

  func advance(by interval: TimeInterval) {
    now = now.addingTimeInterval(interval)
    uptime += interval
  }
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
      history.maintenanceState = expiryDefaults
      history.now = { [clock] in clock.now }
      history.uptime = { [clock] in clock.uptime }
      history.resetAutomaticRemovalFailuresForTesting()
      HistoryIntentAccess.readinessTimeout = .milliseconds(300)
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
      Storage.shared.fetchFailureForTesting = nil
      Notifier.client = savedClient
      History.removalFailureReporter = savedReporter
      history.expiryPreferences = Defaults.Keys.historyExpiryHours.suite
      history.maintenanceState = Defaults.Keys.historyExpiryHours.suite
      history.now = { Date.now }
      history.uptime = { ProcessInfo.processInfo.systemUptime }
      history.resetAutomaticRemovalFailuresForTesting()
      HistoryIntentAccess.readinessTimeout = .seconds(10)
      IntentImageExports.directoryForTesting = nil
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
      let shown = shownItems()

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
      #expect(shownItems() == shown)
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
      let shown = shownItems()

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

      #expect(shownItems() == shown)
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
      let shown = shownItems()

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      Defaults[.size] = 1
      try await history.load()
      try await history.load()
      Storage.shared.saveFailureForTesting = nil

      #expect(shownItems() == shown)
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
      #expect(shownItems() == [old.item])
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
      #expect(Set(shownItems()) == [recent.item, oldPinned.item])
      try assertStored(["recent", "old pinned"])
      #expect(!FileManager.default.fileExists(atPath: export.path))
      #expect(client.removed.contains(identifier))

      // Two more hours: the recent item expires too.
      clock.now = start.addingTimeInterval(2 * 3600)
      #expect(history.purgeExpiredItems() == 1)
      #expect(shownItems() == [oldPinned.item])
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
      #expect(shownItems() == [recent.item])
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
      #expect(Set(shownItems()) == [recent.item, pinned.item])
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
      #expect(shownItems().isEmpty)
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

      #expect(shownItems() == [old.item])
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

      relaunch()

      #expect(shownItems() == [pinned.item])
      try assertStored(["pinned"])
      #expect(reporter.reports.isEmpty)
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

      relaunch()

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
      relaunch()
      Storage.shared.saveFailureForTesting = nil

      try assertStored(["still stored"])
      #expect(history.items.count == 1)
      #expect(reporter.reports == [[.removal(.clearOnLaunch)]])
      #expect(history.failingOperations.keys.sorted() == [.clearOnLaunch])
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
      // Drop every reference History holds to this store's models (the
      // session log included) before the store goes away.
      Storage.shared.saveFailureForTesting = nil
      history.clearAll()
      Storage.replaceSharedForTesting(with: previous)
      try await history.load()
      try? FileManager.default.removeItem(at: directory)
      if let failure {
        throw failure
      }
    }

    private func compactAndCheck(path: String, directory: URL, url: URL) async throws {
      try await history.load()

      let secret = "A6-DELETED-MARKER-\(UUID().uuidString)"
      let kept = "A6-PINNED-MARKER-\(UUID().uuidString)"
      expiryDefaults.set(path == "expiry" ? 1 : 0, forKey: HistoryExpiry.preferenceKey)
      let pinned = history.added(historyItem(kept, lastCopied: 0))
      history.togglePin(pinned)
      let removedMarkers = try addRemovableContent(secret: secret)
      try Storage.shared.save()
      for marker in [Data(secret.utf8)] + removedMarkers {
        #expect(try !filesContaining(marker, in: directory).isEmpty, "the marker must be on disk before removal")
      }

      switch path {
      case "clear": #expect(history.clear())
      case "clearAll": #expect(history.clearAll())
      case "clearOnQuit": #expect(history.clearOnQuit())
      case "clearOnLaunch":
        Defaults[.clearOnQuit] = true
        relaunch()
      default:
        history.runExpiry()
      }
      await history.waitForCompaction()

      #expect(reporter.reports.isEmpty)
      #expect(!history.isCompactionPending)
      try assertNoSidecarFiles(in: directory)
      for marker in [Data(secret.utf8)] + removedMarkers {
        #expect(try filesContaining(marker, in: directory).isEmpty, "a removed marker is still on disk")
      }

      // What remains is intact, in this store and when opened afresh.
      // Kept alive while its models are read: they become unusable once
      // their container is released.
      let reopened = Storage(storeURL: url)
      let stored = try reopened.allItems()
      if path == "clearAll" {
        #expect(stored.isEmpty)
        #expect(try filesContaining(kept, in: directory).isEmpty)
        return
      }
      #expect(shownItems() == [pinned.item])
      #expect(stored.count == 1)
      #expect(stored.first?.pin == pinned.item.pin)
      #expect(stored.first?.contents.first?.value == Data(kept.utf8))
      // The shared store keeps working after compaction.
      history.added(historyItem("after compaction"))
      try Storage.shared.save()
      let reopenedAgain = Storage(storeURL: url)
      #expect(try reopenedAgain.allItems().count == 2)
      withExtendedLifetime(reopened) {}
    }

    @Test("Compaction leaves an in-memory store alone")
    func compactionOfInMemoryStore() async throws {
      defer { restoreHistory() }
      #expect(Storage.shared.storeURL == nil)
      try await Storage.shared.compact()
    }

    // MARK: Export removal

    @Test("An exported image that can't be deleted is reported, kept and retried until it is gone",
          arguments: ["delete", "clear", "expiry"])
    func failedExportRemoval(path: String) throws {
      defer { restoreHistory() }
      let directory = try temporaryDirectory()
      IntentImageExports.directoryForTesting = directory
      defer {
        chmod(directory.path, 0o700)
        IntentImageExports.retryPendingRemovals()
        try? FileManager.default.removeItem(at: directory)
      }
      expiryDefaults.set(path == "expiry" ? 1 : 0, forKey: HistoryExpiry.preferenceKey)
      let owner = history.added(historyItem("export owner", lastCopied: -3))
      let kept = history.added(historyItem("kept", lastCopied: 0))
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: owner.item)
      try Storage.shared.save()

      // The directory is read-only: its files can't be unlinked.
      #expect(chmod(directory.path, 0o500) == 0)
      switch path {
      case "delete": #expect(history.delete(owner))
      case "clear": #expect(history.clear())
      default: #expect(history.purgeExpiredItems() == 1)
      }

      // History was deleted; the file is still there, remembered and reported.
      try assertStored(path == "delete" || path == "expiry" ? ["kept"] : [])
      #expect(FileManager.default.fileExists(atPath: export.path))
      #expect(IntentImageExports.pendingRemovals.contains(export))
      #expect(reporter.exportFailures == 1)
      #expect(reporter.failures.isEmpty)
      #expect(history.failingOperations[.exportRemoval] != nil)

      // Still failing: retried, not reported again.
      history.runMaintenance()
      #expect(FileManager.default.fileExists(atPath: export.path))
      #expect(reporter.exportFailures == 1)

      // Once the file can be deleted, maintenance deletes it and the failure clears.
      #expect(chmod(directory.path, 0o700) == 0)
      history.runMaintenance()
      #expect(!FileManager.default.fileExists(atPath: export.path))
      #expect(!IntentImageExports.hasPendingRemovals)
      #expect(history.failingOperations[.exportRemoval] == nil)
      withExtendedLifetime(kept) {}
    }

    @Test("An export that is already gone counts as removed")
    func absentExportIsRemoved() throws {
      defer { restoreHistory() }
      let directory = try temporaryDirectory()
      IntentImageExports.directoryForTesting = directory
      defer { try? FileManager.default.removeItem(at: directory) }
      let owner = history.added(historyItem("export owner"))
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: owner.item)
      try FileManager.default.removeItem(at: export)

      #expect(history.delete(owner))
      #expect(!IntentImageExports.hasPendingRemovals)
      #expect(reporter.reports.isEmpty)
      #expect(history.failingOperations.isEmpty)
    }

    // MARK: Per-operation failures

    @Test("A failed clear at launch stays reported after expiry succeeds, and is retried by maintenance")
    func launchClearFailureIsTrackedSeparately() throws {
      defer { restoreHistory() }
      Defaults[.clearOnQuit] = true
      expiryDefaults.set(1, forKey: HistoryExpiry.preferenceKey)
      // Left by the last session.
      _ = historyItem("left, expired", lastCopied: -3)
      _ = historyItem("left, recent", lastCopied: -0.5)
      try Storage.shared.save()

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      relaunch()
      Storage.shared.saveFailureForTesting = nil
      // One alert, after launch, for everything that failed.
      #expect(reporter.reports == [[.removal(.clearOnLaunch), .removal(.expiry)]])
      #expect(Set(history.failingOperations.keys) == [.clearOnLaunch, .expiry])

      // Expiry works again and removes the expired leftover; the clear at
      // launch is still unresolved.
      #expect(history.purgeExpiredItems() == 1)
      #expect(history.failingOperations.keys.sorted() == [.clearOnLaunch])
      let warning = try #require(StorageSettingsPane.maintenanceFailing(history.failingOperations))
      #expect(warning.contains(MaintenanceOperation.clearOnLaunch.label))
      #expect(!warning.contains(MaintenanceOperation.expiry.label))
      try assertStored(["left, recent"])

      // A copy made in this session is kept when maintenance retries the clear.
      history.added(historyItem("copied this session", lastCopied: 0))
      history.runMaintenance()
      try assertStored(["copied this session"])
      #expect(history.failingOperations.isEmpty)
      #expect(StorageSettingsPane.maintenanceFailing(history.failingOperations) == nil)
      #expect(reporter.reports.count == 1)
    }

    @Test("The settings warning lists every failing operation")
    func settingsListFailingOperations() throws {
      defer { restoreHistory() }
      let warning = try #require(StorageSettingsPane.maintenanceFailing([
        .compaction: start, .exportRemoval: start.addingTimeInterval(60), .trim: start
      ]))
      for operation in [MaintenanceOperation.compaction, .exportRemoval, .trim] {
        #expect(warning.contains(operation.label))
      }
      #expect(!warning.contains(MaintenanceOperation.expiry.label))
    }

    // MARK: Launch order

    @Test("Launch runs the storage policy and maintenance before history is loaded, shown or captured")
    func launchOrder() {
      defer { restoreHistory() }
      var steps: [LaunchSequence.Step] = []
      LaunchSequence { steps.append($0) }.run()
      #expect(steps == [
        .applyStoragePolicy, .maintain, .loadHistory, .createInterface, .startCapture,
        .startMaintenanceSchedule, .presentFailures
      ])
    }

    @Test("Failures before and during launch maintenance are shown once, after it; history is not readable before")
    func launchDefersAlertsAndAccess() async throws {
      defer { restoreHistory() }
      Defaults[.clearOnQuit] = true
      Defaults[.size] = 1
      _ = historyItem("left by the last session", lastCopied: -2)
      _ = historyItem("also left", lastCopied: -1)
      try Storage.shared.save()

      history.beginLaunchForTesting()
      #expect(!history.prepareForDisplay())
      await #expect(throws: AppIntentError.notReady) { _ = try await Get().perform() }
      await #expect(throws: AppIntentError.notReady) { _ = try await Clear().perform() }

      // Saving fails from before the storage-policy step.
      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      var readyBeforeLoad = true
      var alertsBeforeEnd = -1
      LaunchSequence { step in
        switch step {
        case .applyStoragePolicy:
          history.beginLaunch()
          history.enforceStoragePolicy(reloadingItems: false)
        case .maintain:
          history.performLaunchMaintenance()
        case .loadHistory:
          readyBeforeLoad = history.isReady || history.prepareForDisplay()
          Storage.shared.saveFailureForTesting = nil
          history.finishLaunch()
        case .createInterface, .startCapture, .startMaintenanceSchedule:
          break
        case .presentFailures:
          alertsBeforeEnd = reporter.reports.count
          history.presentDeferredFailures()
        }
      }.run()

      #expect(!readyBeforeLoad)
      #expect(alertsBeforeEnd == 0)
      #expect(reporter.reports == [[.removal(.clearOnLaunch), .removal(.trim)]])
      #expect(history.isReady)
      #expect(history.prepareForDisplay())

      // Trimming works again on load; the clear is retried by maintenance.
      history.runMaintenance()
      try assertStored([])
      #expect(history.failingOperations.isEmpty)
    }

    @Test("A history that can't be loaded at launch is reported")
    func launchLoadFailureIsReported() throws {
      defer { restoreHistory() }
      Storage.shared.fetchFailureForTesting = InjectedSaveFailure()
      relaunch()
      Storage.shared.fetchFailureForTesting = nil
      #expect(reporter.reports == [[.load]])
      #expect(history.isReady)
    }

    // MARK: Refused copies

    @Test("A saved copy the storage settings refuse is removed through the reported path")
    func refusedSavedCopy() throws {
      defer { restoreHistory() }
      let item = historyItem("saved before the setting changed")
      try Storage.shared.save()
      Defaults[.enabledPasteboardTypes] = [.png]

      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      #expect(!history.insertIntoStorage(item))
      Storage.shared.saveFailureForTesting = nil

      #expect(reporter.failures == [.refusedByStoragePolicy])
      #expect(history.failingOperations[.storagePolicyRemoval] != nil)
      #expect(try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>()) == 1)

      history.runMaintenance()
      #expect(try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>()) == 0)
      #expect(history.failingOperations[.storagePolicyRemoval] == nil)
      #expect(reporter.failures == [.refusedByStoragePolicy])
    }

    // MARK: Quit

    @Test("Quitting with clear on quit: what happens for each outcome", arguments: [
      // clearOnQuit, cleared, sessionEnding, quitAnyway, reply, asked
      (false, false, false, false, NSApplication.TerminateReply.terminateNow, false),
      (true, true, false, false, .terminateNow, false),
      (true, false, true, false, .terminateNow, false),
      (true, false, false, true, .terminateNow, true),
      (true, false, false, false, .terminateCancel, true)
    ])
    func quitDecision(
      clearOnQuit: Bool, cleared: Bool, sessionEnding: Bool, quitAnyway: Bool,
      reply: NSApplication.TerminateReply, asked: Bool
    ) {
      defer { restoreHistory() }
      var clearCalls = 0
      var askCalls = 0
      let result = QuitClearDecision.reply(
        clearOnQuit: clearOnQuit,
        sessionEnding: sessionEnding,
        clear: {
          clearCalls += 1
          return cleared
        },
        quitAnyway: {
          askCalls += 1
          return quitAnyway
        }
      )
      #expect(result == reply)
      #expect(clearCalls == (clearOnQuit ? 1 : 0))
      #expect(askCalls == (asked ? 1 : 0))
    }

    @Test("The clear run by the quit dialog doesn't show its own alert")
    func quitClearDoesNotAlert() throws {
      defer { restoreHistory() }
      history.added(historyItem("still stored"))
      try Storage.shared.save()
      Storage.shared.saveFailureForTesting = InjectedSaveFailure()
      #expect(!history.clearOnQuit(alerting: false))
      Storage.shared.saveFailureForTesting = nil
      #expect(reporter.reports.isEmpty)
      try assertStored(["still stored"])
    }

    // MARK: Expiry at the point of access

    @Test("Expiry runs before history is shown when due, and not again straight away")
    func expiryBeforeDisplay() throws {
      defer { restoreHistory() }
      expiryDefaults.set(1, forKey: HistoryExpiry.preferenceKey)
      history.added(historyItem("expired", lastCopied: -2))
      let fresh = history.added(historyItem("fresh", lastCopied: 0))
      try Storage.shared.save()

      #expect(history.prepareForDisplay())
      #expect(shownItems() == [fresh.item])

      clock.advance(by: 10)
      history.added(historyItem("expired too", lastCopied: -3))
      #expect(history.prepareForDisplay())
      #expect(shownItems().count == 2)

      clock.advance(by: History.expiryAccessInterval)
      #expect(history.prepareForDisplay())
      #expect(shownItems() == [fresh.item])
    }

    @Test("The Get and Select intents purge expired items before reading")
    func intentsExpireBeforeReading() async throws {
      defer { restoreHistory() }
      expiryDefaults.set(1, forKey: HistoryExpiry.preferenceKey)
      history.added(historyItem("expired", lastCopied: -3))
      history.added(historyItem("fresh", lastCopied: 0))
      try Storage.shared.save()
      #expect(history.items.count == 2)

      var get = Get()
      get.selected = false
      get.number = 2
      let second = get
      await #expect(throws: AppIntentError.notFound) { _ = try await second.perform() }
      #expect(history.items.count == 1)
      try assertStored(["fresh"])
    }

    @Test("A re-dated item takes its place in the list at once, and is re-dated only once")
    func redatingOrderAndOnce() throws {
      defer { restoreHistory() }
      expiryDefaults.set(24, forKey: HistoryExpiry.preferenceKey)
      let older = history.added(historyItem("an hour old", lastCopied: -1))
      let ahead = history.added(historyItem("five minutes ahead", lastCopied: 5.0 / 60))
      let future = history.added(historyItem("a month ahead", lastCopied: 24 * 30))
      try Storage.shared.save()
      #expect(shownItems() == [future.item, ahead.item, older.item])

      #expect(history.purgeExpiredItems() == 0)
      #expect(future.item.lastCopiedAt == start)
      // Sorted by last copy: now below the item still slightly ahead.
      #expect(shownItems() == [ahead.item, future.item, older.item])

      // The clock goes back a month again: the re-dated item is ahead once
      // more. It is not re-dated a second time but expires.
      clock.now = start.addingTimeInterval(-24 * 30 * 3600)
      let newlyAhead = history.added(historyItem("ahead for the first time", lastCopied: 0))
      try Storage.shared.save()
      #expect(history.purgeExpiredItems() == 1)
      #expect(!shownItems().contains(future.item))
      #expect(newlyAhead.item.lastCopiedAt == clock.now)
    }

    // MARK: Compaction failures

    @Test("A compaction blocked by a reader is retried with a delay and succeeds without another deletion",
          arguments: ["clear", "clearAll", "clearOnLaunch", "expiry"])
    func compactionRecoversAfterFailure(path: String) async throws {
      defer { restoreHistory() }
      let directory = try temporaryDirectory()
      let url = directory.appending(path: "Storage.sqlite")
      let previous = Storage.replaceSharedForTesting(with: Storage(storeURL: url))
      var failure: (any Error)?
      do {
        try await failThenRecover(path: path, directory: directory, url: url)
      } catch {
        failure = error
      }
      await history.waitForCompaction()
      Storage.shared.saveFailureForTesting = nil
      history.clearAll()
      await history.waitForCompaction()
      Storage.replaceSharedForTesting(with: previous)
      try await history.load()
      try? FileManager.default.removeItem(at: directory)
      if let failure {
        throw failure
      }
    }

    private func failThenRecover(path: String, directory: URL, url: URL) async throws {
      try await history.load()
      let secret = "A6-BUSY-MARKER-\(UUID().uuidString)"
      expiryDefaults.set(path == "expiry" ? 1 : 0, forKey: HistoryExpiry.preferenceKey)
      let pinned = history.added(historyItem("pinned", lastCopied: 0))
      history.togglePin(pinned)
      for index in 0..<3 {
        history.added(historyItem("\(secret)-\(index)", lastCopied: -2))
      }
      try Storage.shared.save()

      // Another connection keeps a read transaction open: the WAL can't be
      // truncated.
      var reader: OpaquePointer?
      #expect(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
      defer { sqlite3_close_v2(reader) }
      #expect(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK)

      switch path {
      case "clear": #expect(history.clear())
      case "clearAll": #expect(history.clearAll())
      case "clearOnLaunch":
        Defaults[.clearOnQuit] = true
        relaunch()
      default:
        history.runExpiry()
      }
      await history.waitForCompaction()

      // History was removed; compaction failed and stays pending.
      #expect(try Storage.shared.allItems().allSatisfy { $0.pin != nil })
      #expect(history.isCompactionPending)
      #expect(history.failingOperations[.compaction] != nil)
      #expect(reporter.reports.isEmpty)

      // Not retried before the delay.
      history.runMaintenance()
      #expect(history.compactionTask == nil)

      // The reader goes away; after the delay maintenance compacts.
      #expect(sqlite3_exec(reader, "COMMIT", nil, nil, nil) == SQLITE_OK)
      clock.advance(by: History.compactionRetryDelay + 1)
      Defaults[.clearOnQuit] = false
      history.runMaintenance()
      await history.waitForCompaction()

      #expect(!history.isCompactionPending)
      #expect(history.failingOperations[.compaction] == nil)
      #expect(try filesContaining(secret, in: directory).isEmpty)
      try assertNoSidecarFiles(in: directory)
    }

    @Test("A save during a compaction interrupts it; the save succeeds and compaction runs again")
    func saveInterruptsCompaction() async throws {
      defer { restoreHistory() }
      let directory = try temporaryDirectory()
      let url = directory.appending(path: "Storage.sqlite")
      let previous = Storage.replaceSharedForTesting(with: Storage(storeURL: url))
      var failure: (any Error)?
      do {
        try await history.load()
        let secret = "A6-INTERRUPT-MARKER-\(UUID().uuidString)"
        for index in 0..<3 {
          history.added(historyItem("\(secret)-\(index)"))
        }
        try Storage.shared.save()
        // Blocks the compaction so it is still running when the save comes.
        var reader: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        #expect(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK)
        #expect(history.clear())
        for _ in 0..<200 where !Storage.shared.isCompacting {
          try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Storage.shared.isCompacting)

        history.added(historyItem("saved during compaction"))
        try Storage.shared.save()
        #expect(!Storage.shared.isCompacting)
        await history.waitForCompaction()
        sqlite3_exec(reader, "COMMIT", nil, nil, nil)
        sqlite3_close_v2(reader)

        // Interrupted, not failed; runs again shortly.
        #expect(history.failingOperations[.compaction] == nil)
        #expect(history.isCompactionPending)
        clock.advance(by: History.compactionResumeDelay + 1)
        history.runMaintenance()
        await history.waitForCompaction()
        #expect(!history.isCompactionPending)
        #expect(try filesContaining(secret, in: directory).isEmpty)
        let reopened = Storage(storeURL: url)
        #expect(try reopened.allItems().count == 1)
        withExtendedLifetime(reopened) {}
      } catch {
        failure = error
      }
      await history.waitForCompaction()
      history.clearAll()
      await history.waitForCompaction()
      Storage.replaceSharedForTesting(with: previous)
      try await history.load()
      try? FileManager.default.removeItem(at: directory)
      if let failure {
        throw failure
      }
    }

    // MARK: Helpers

    // The items shown, in order. Compared by item, since loading history
    // rebuilds the decorators.
    private func shownItems() -> [HistoryItem] {
      history.items.map(\.item)
    }

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

    // Every file under `directory` (hidden ones included) whose bytes contain
    // `marker`. A file that can't be read fails the test rather than counting
    // as clean.
    private func filesContaining(_ marker: String, in directory: URL) throws -> [String] {
      try filesContaining(Data(marker.utf8), in: directory)
    }

    private func filesContaining(_ marker: Data, in directory: URL) throws -> [String] {
      let enumerator = try #require(FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [],
        errorHandler: { url, error in
          Issue.record("Could not list \(url.lastPathComponent): \(error)")
          return true
        }
      ))
      var hits: [String] = []
      for case let file as URL in enumerator
      where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        if data.range(of: marker) != nil {
          hits.append(file.lastPathComponent)
        }
      }
      return hits
    }

    // Only the store and SQLite's own sidecar files, no directories: no
    // external-storage blobs (`.Storage_SUPPORT`) that could keep deleted
    // content.
    private func assertNoSidecarFiles(in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
      let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(Set(files).isSubset(of: ["Storage.sqlite", "Storage.sqlite-wal", "Storage.sqlite-shm"]),
              "\(files)", sourceLocation: sourceLocation)
      #expect(!files.contains(".Storage_SUPPORT"), sourceLocation: sourceLocation)
    }

    // Short text items, a real PNG image and a multi-megabyte text payload,
    // all unpinned and last copied two hours ago. Returns markers found in
    // their stored bytes.
    private func addRemovableContent(secret: String) throws -> [Data] {
      for index in 0..<5 {
        history.added(historyItem("\(secret)-\(index)", lastCopied: -2))
      }

      let png = try noisePNG(width: 800, height: 800)
      let image = HistoryItem()
      Storage.shared.context.insert(image)
      image.contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: png)]
      image.numberOfCopies = 1
      image.lastCopiedAt = start.addingTimeInterval(-2 * 3600)
      image.firstCopiedAt = image.lastCopiedAt
      image.regenerateTitle()
      history.added(image)
      // A slice of the image's random pixels is as unique as a marker.
      let imageMarker = png.subdata(in: (png.count / 2)..<(png.count / 2 + 48))

      let bigMarker = "A6-BIG-MARKER-\(UUID().uuidString)"
      var big = bigMarker
      while big.utf8.count < 3 * 1024 * 1024 {
        big += UUID().uuidString
      }
      big += bigMarker
      history.added(historyItem(big, lastCopied: -2))

      return [Data(bigMarker.utf8), imageMarker]
    }

    private func noisePNG(width: Int, height: Int) throws -> Data {
      let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
      ))
      let pixels = try #require(rep.bitmapData)
      for index in 0..<(width * height * 4) {
        pixels[index] = UInt8.random(in: 0...255)
      }
      return try #require(rep.representation(using: .png, properties: [:]))
    }

    // Replays a launch: maintenance, load, then the failures collected.
    private func relaunch() {
      history.beginLaunchForTesting()
      history.beginLaunch()
      history.performLaunchMaintenance()
      history.finishLaunch()
      history.presentDeferredFailures()
    }
  }
}
