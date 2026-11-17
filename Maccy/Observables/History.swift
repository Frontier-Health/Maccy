// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: AppIdentity.bundleIdentifier)

  var pasteStack: PasteStack?

  var items: ConcatenatedCollection<HistoryItemDecorator> {
    switch Defaults[.pinTo] {
    case .top:
      ConcatenatedCollection(pinnedItems, unpinnedItems)
    case .bottom:
      ConcatenatedCollection(unpinnedItems, pinnedItems)
    }
  }
  var pinnedItems: [HistoryItemDecorator] {
    searchQuery.isEmpty ? allPinnedItems : filteredPinnedItems
  }
  var unpinnedItems: [HistoryItemDecorator] {
    searchQuery.isEmpty ? allUnpinnedItems : filteredUnpinnedItems
  }
  var availablePins: [String] { pinManager.availablePins }

  var firstPinnedItem: HistoryItemDecorator? { pinnedItems.first }
  var firstUnpinnedItem: HistoryItemDecorator? { unpinnedItems.first }

  var searchQuery: String = "" {
    didSet(previousSearchQuery) {
      guard searchQuery != previousSearchQuery else { return }
      throttler.throttle { [self] in
        guard isReady else { return }
        updateSearchResults()

        if searchQuery.isEmpty {
          AppState.shared.navigator.select(item: firstUnpinnedItem)
        } else {
          AppState.shared.navigator.highlightFirst()
        }

        AppState.shared.popup.needsResize = true
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)
  private let pinManager = PinManager()
  private var allPinnedItems: [HistoryItemDecorator] { pinManager.pinnedItems }
  private var allUnpinnedItems: [HistoryItemDecorator] = []
  private var filteredPinnedItems: [HistoryItemDecorator] = []
  private var filteredUnpinnedItems: [HistoryItemDecorator] = []

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The storage policy the store was last brought in line with.
  @ObservationIgnored
  private var enforcedStoragePolicy: StoragePolicy?
  // The policy whose clean-up failed in the current attempt. Loads, searches
  // and intents don't retry it; the next settings-change event (any value,
  // including one back to an earlier policy) or the next launch does.
  @ObservationIgnored
  private var failedStoragePolicy: StoragePolicy?

  // Shows failures to the user. Tests replace it.
  @ObservationIgnored
  static var removalFailureReporter: any HistoryRemovalFailureReporting = AlertHistoryRemovalFailureReporter()
  // Automatic operations that failed and haven't succeeded since, with when
  // each last failed. Listed in the Storage settings. Each is cleared only by
  // its own operation succeeding.
  private(set) var failingOperations: [MaintenanceOperation: Date] = [:]
  // The failing operations whose current run of failures was already shown.
  @ObservationIgnored
  private var alertedOperations: Set<MaintenanceOperation> = []
  // While launching, failures are collected here and shown once launch
  // maintenance has finished (see `LaunchSequence`).
  @ObservationIgnored
  private var deferredFailures: [HistoryFailure]?
  @ObservationIgnored
  private var deferredErrorCode: String?

  // When an automatic operation last failed, or nil if none is failing.
  var automaticRemovalFailedAt: Date? { failingOperations.values.max() }

  // Whether launch maintenance has finished and history was loaded. Nothing
  // reads or shows history before (popup, intents, search).
  @ObservationIgnored
  private(set) var isReady = false

  // Where the expiry setting is read from, the clocks it is measured with,
  // and where maintenance keeps state across launches. Tests replace them.
  @ObservationIgnored
  var expiryPreferences: UserDefaults = Defaults.Keys.historyExpiryHours.suite
  @ObservationIgnored
  var maintenanceState: UserDefaults = Defaults.Keys.historyExpiryHours.suite
  @ObservationIgnored
  var now: () -> Date = { Date.now }
  @ObservationIgnored
  var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  @ObservationIgnored
  private var maintenanceTimer: Timer?
  @ObservationIgnored
  private var maintenanceObservers: [any NSObjectProtocol] = []
  // When the expiry purge last ran, by both clocks, for `runExpiryIfDue`.
  @ObservationIgnored
  private var lastExpiryRun: (date: Date, uptime: TimeInterval)?

  // Unpinned items left by the last session that the clear at launch must
  // still remove (nil when none is pending), and the launch time, used if
  // they could not even be listed.
  @ObservationIgnored
  private var launchClearItems: [HistoryItem]?
  @ObservationIgnored
  private var launchClearPending = false
  @ObservationIgnored
  private var launchTime: Date?
  // Copies the storage settings refused whose removal failed.
  @ObservationIgnored
  private var refusedItems: [HistoryItem] = []

  // Compaction: due at this system uptime (nil when none is pending), when it
  // last succeeded, how many attempts failed in a row, and the run in
  // progress. A request made while one runs is counted by `generation`, so
  // that run doesn't clear it.
  @ObservationIgnored
  private var compactionDueAt: TimeInterval?
  @ObservationIgnored
  private var lastCompaction: TimeInterval?
  @ObservationIgnored
  private var compactionFailures = 0
  @ObservationIgnored
  private var compactionGeneration = 0
  @ObservationIgnored
  private(set) var compactionTask: Task<Void, Never>?

  // How often maintenance (expiry, retries, compaction) runs while Maccy is
  // running; how often at most a purge compacts the store; how long a
  // purge is skipped at the point of access after the last one.
  static let expiryCheckInterval: TimeInterval = 5 * 60
  static let expiryCompactionInterval: TimeInterval = 60 * 60
  static let expiryAccessInterval: TimeInterval = 30
  // Retry delays after a failed compaction: doubling from the first, up to
  // the last.
  static let compactionRetryDelay: TimeInterval = 60
  static let compactionMaximumRetryDelay: TimeInterval = 60 * 60
  // How long an interrupted compaction waits before it starts again.
  static let compactionResumeDelay: TimeInterval = 30
  // An item last copied later than this ahead of the clock was stamped before
  // the clock was set back.
  static let futureTimestampTolerance: TimeInterval = 10 * 60
  static let compactionPendingKey = "historyCompactionPending"
  static let redatedItemsKey = "historyRedatedItems"

#if DEBUG
  static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#endif

  init() {
    #if DEBUG
    // Tests drive launch themselves (see `beginLaunchForTesting`).
    guard !Self.isRunningUnitTests else {
      isReady = true
      return
    }
    #endif

    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    // Turning a storage type off removes it from existing history too.
    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes, initial: false) {
        storageSettingChanged()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        updateTitlesForSpecialSymbols()
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    guard isReady else { return }
    noteExportRemoval(IntentImageExports.removeLeftoversOnce(), userInitiated: false)
    enforceStoragePolicy(reloadingItems: false)
    try reloadItems()
  }

  @MainActor
  private func reloadItems() throws {
    let results = try Storage.shared.allItems()
    let decorators = sorter.sort(results).map { HistoryItemDecorator($0) }
    pinManager.load(from: decorators)
    allUnpinnedItems = decorators.filter(\.isUnpinned)
    filteredPinnedItems = allPinnedItems
    filteredUnpinnedItems = allUnpinnedItems

    limitHistorySize(to: HistorySize.current)

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  // A new attempt to apply the storage setting: after any change of the
  // setting, whatever its value. A failed earlier attempt doesn't hold this
  // one back. Decorators are rebuilt either way, so every title shown is
  // checked against the policy now in effect. Returns whether stored history
  // changed.
  @MainActor
  @discardableResult
  func storageSettingChanged() -> Bool {
    failedStoragePolicy = nil
    let changed = enforceStoragePolicy(reloadingItems: false)
    try? reloadItems()
    return changed
  }

  // Brings stored history in line with the current storage policy. Runs at
  // launch, on every load, after every change of the setting (see
  // `storageSettingChanged`) and before the Get and Select intents read
  // history. It does work only when the policy differs from the last one
  // applied and hasn't already failed in this attempt.
  //
  // An invalid policy leaves history exactly as it is: nothing is deleted.
  // Capture stops separately (see Clipboard).
  //
  // A valid policy strips what it doesn't allow, whether the change came from
  // the settings (which confirm first), a configuration profile or an outside
  // write. If that fails, history is left as it was; what may be shown is
  // still decided by the policy when it is read (`HistoryItem.displayTitle`
  // and the content accessors), so nothing it excludes is shown meanwhile.
  // Returns whether stored history changed.
  @MainActor
  @discardableResult
  func enforceStoragePolicy(reloadingItems: Bool = true) -> Bool {
    let policy = StoragePolicy.current
    guard policy != enforcedStoragePolicy, policy != failedStoragePolicy else {
      return false
    }

    guard let allowList = policy.allowList else {
      enforcedStoragePolicy = policy
      failedStoragePolicy = nil
      logger.warning("Storage setting is invalid: not saving new copies, stored history left unchanged")
      if reloadingItems {
        try? reloadItems()
      }
      return false
    }

    // Revoke files already handed out under an older policy, even if clean-up fails.
    IntentImageExports.removeAll()
    // Text recognition of an image type no longer stored stops before Vision.
    if !StorageType.images.types.allSatisfy(allowList.allows) {
      HistoryItem.cancelAllTextRecognition()
    }

    let result: StorageCleanUpResult
    do {
      result = try Storage.shared.cleanUp(to: allowList)
    } catch {
      failedStoragePolicy = policy
      logger.error("""
        Failed to apply storage settings to history (\(Storage.errorCategory(error))). \
        History is unchanged; disallowed data stays hidden. Retrying on next launch or setting change.
        """)
      if reloadingItems {
        try? reloadItems()
      }
      return false
    }

    enforcedStoragePolicy = policy
    failedStoragePolicy = nil
    logger.notice("\(result.logMessage)")

    for decorator in allPinnedItems + allUnpinnedItems
    where result.changedItems.contains(where: { $0 === decorator.item }) {
      decorator.cleanupImages()
    }
    if reloadingItems {
      try? reloadItems()
    }
    return result.hasChanges
  }

  // Removes the unpinned items beyond `maxSize` (at least 0). If that fails
  // they stay, in the store and in the list.
  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let maxSize = max(0, maxSize)
    guard allUnpinnedItems.count > maxSize else {
      resolve(.trim)
      return
    }
    remove(allUnpinnedItems[maxSize...].map(\.item), as: .trim)
  }

  // The same, on the store alone, before the list is built at launch.
  @MainActor
  private func limitStoredHistorySize() {
    do {
      let unpinned = sorter.sort(try Storage.shared.unpinnedItems())
      guard unpinned.count > HistorySize.current else {
        resolve(.trim)
        return
      }
      remove(Array(unpinned[HistorySize.current...]), as: .trim)
    } catch {
      reportRemovalFailure(.trim, error)
    }
  }

  // Applies the storage policy, read now, to a new item and only then inserts
  // and saves it. An item left with no allowed content, or any item while the
  // policy is invalid, is not stored (and is removed if it already was).
  // Every path that adds a copy to history goes through here, including the
  // early insertion macOS 14 needs. If the save fails the item is removed
  // from the context, so nothing of it stays pending for a later save, and
  // this returns false.
  @MainActor
  @discardableResult
  func insertIntoStorage(_ item: HistoryItem) -> Bool {
    let storage = Storage.shared
    let context = storage.context
    let allowList = StoragePolicy.current.allowList
    let changed = allowList.map { storage.sanitize(item, to: $0) } ?? false
    guard let allowList,
          allowList.hasStorableContent(item.contents.map { NSPasteboard.PasteboardType($0.type) }) else {
      if item.modelContext != nil {
        removeRefused(item)
      }
      return false
    }

    item.reconcileTitle(readableBy: allowList, contentsChanged: changed)

    if item.modelContext == nil {
      context.insert(item)
    }
    context.processPendingChanges()
    do {
      try storage.save()
    } catch {
      logger.error("Failed to save a new history item (\(Storage.errorCategory(error)))")
      deleteFromStorage(item)
      context.processPendingChanges()
      return false
    }
    logger.info("Inserted history item \(item.notificationID)")
    return true
  }

  // Removes a copy the storage policy refuses. One never saved is only taken
  // out of the context. One already saved (macOS 14 inserts copies early) is
  // removed from the store through the same path as every other removal; if
  // that fails it is reported, kept out of the list, and retried by
  // maintenance.
  @MainActor
  private func removeRefused(_ item: HistoryItem) {
    let context = Storage.shared.context
    if context.insertedModelsArray.contains(where: { ($0 as AnyObject) === item }) {
      deleteFromStorage(item)
      context.processPendingChanges()
      return
    }
    if !remove([item], as: .refusedByStoragePolicy) {
      refusedItems.append(item)
    }
  }

  @MainActor
  private func retryRefusedRemovals() {
    guard !refusedItems.isEmpty else {
      return
    }
    do {
      let stored = Set(try Storage.shared.allItems().map { ObjectIdentifier($0) })
      refusedItems.removeAll { !stored.contains(ObjectIdentifier($0)) }
    } catch {
      reportRemovalFailure(.refusedByStoragePolicy, error)
      return
    }
    if remove(refusedItems, as: .refusedByStoragePolicy) {
      refusedItems.removeAll()
    }
  }

  // Adds a copy to history. Returns nil when the storage policy doesn't let it
  // be stored.
  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator? {
    guard insertIntoStorage(item) else {
      return nil
    }

    var replacedPinnedItem: HistoryItemDecorator?
    if let existingHistoryItem = findSimilarItem(item) {
      let transfersContents = isModified(item) == nil
      var contentsChanged = false
      if transfersContents {
        transferContents(from: existingHistoryItem, to: item)
        // The older contents may predate the current policy.
        if let allowList = StoragePolicy.current.allowList {
          contentsChanged = Storage.shared.sanitize(item, to: allowList)
        }
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      if contentsChanged {
        IntentImageExports.remove(for: existingHistoryItem)
      } else {
        IntentImageExports.transfer(from: existingHistoryItem, to: item)
      }
      // An alias is kept. With the older contents comes their title, with the
      // source it recorded; it is kept only while that source survives here.
      // A modified copy keeps the title of its own contents.
      if transfersContents || existingHistoryItem.titleSource == .user {
        item.adoptTitle(of: existingHistoryItem)
        item.reconcileTitle(readableBy: StoragePolicy.currentReadAllowList, contentsChanged: contentsChanged)
      }
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate of history item \(item.notificationID)")
      // The surviving item takes over the duplicate's notification, so a notification already
      // submitted for the duplicate (for example when copying from history) stays removable.
      item.notificationID = existingHistoryItem.notificationID
      if let existingDecorator = firstStoredItem(where: { $0.item == existingHistoryItem }) {
        existingDecorator.cleanupImages()
        allUnpinnedItems.removeAll { $0 == existingDecorator }
        if existingDecorator.isPinned {
          replacedPinnedItem = existingDecorator
        }
      }
      deleteFromStorage(existingHistoryItem)
    } else {
      Notifier.notify(for: item, sound: .write)
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    let size = HistorySize.current
    limitHistorySize(to: item.pin == nil ? size - 1 : size)

    sessionLog[Clipboard.shared.changeCount] = item

    let itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      if let replacedPinnedItem {
        pinManager.replace(replacedPinnedItem, with: itemDecorator)
      } else {
        pinManager.add(itemDecorator)
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)
      insertUnpinned(itemDecorator)
    }

    if searchQuery.isEmpty {
      updateUnpinnedShortcuts()
    } else {
      updateSearchResults()
    }
    AppState.shared.popup.needsResize = true
    return itemDecorator
  }

  // MARK: Removal
  //
  // Every removal (delete, clear, clear all, clear on quit or at launch,
  // trimming to the history size, expiry, a refused copy) goes through
  // `remove(_:as:)`: the store is changed first, all or nothing
  // (`Storage.delete`), and only once that save succeeded are the items taken
  // out of the list and their notifications and intent image exports revoked.
  // If it fails, the store, the list, notifications and exports are all left
  // as they were, and the failure is reported (see
  // `HistoryRemoval.alertsEveryTime`).

  // Clears unpinned items. Returns whether history was cleared.
  @MainActor
  @discardableResult
  func clear() -> Bool {
    clearUnpinned(as: .clear)
  }

  // Clears unpinned items when Maccy quits with "Clear history on quit" on.
  // With `alerting` off a failure is only logged: the quit dialog tells the
  // user instead (see `QuitClearDecision`).
  @MainActor
  @discardableResult
  func clearOnQuit(alerting: Bool = true) -> Bool {
    clearUnpinned(as: .clearOnQuit, alerting: alerting)
  }

  @MainActor
  @discardableResult
  private func clearUnpinned(as removal: HistoryRemoval, alerting: Bool = true) -> Bool {
    let cleared: Bool
    do {
      cleared = remove(
        try Storage.shared.unpinnedItems(),
        includingOrphanedContents: true,
        revokingAllExports: true,
        as: removal,
        alerting: alerting
      )
    } catch {
      reportRemovalFailure(removal, error, alerting: alerting)
      cleared = false
    }

    if cleared {
      requestCompaction(after: removal)
    }
    Clipboard.shared.clear()
    AppState.shared.popup.close()
    return cleared
  }

  // Clears every item, pinned ones included. Returns whether history was
  // cleared.
  @MainActor
  @discardableResult
  func clearAll() -> Bool {
    let cleared: Bool
    do {
      cleared = remove(
        try Storage.shared.allItems(),
        includingOrphanedContents: true,
        revokingAllExports: true,
        as: .clearAll
      )
    } catch {
      reportRemovalFailure(.clearAll, error)
      cleared = false
    }

    if cleared {
      pinManager.removeAll()
      sessionLog.removeAll()
      Notifier.removeAllDelivered()
      requestCompaction(after: .clearAll)
    }
    Clipboard.shared.clear()
    AppState.shared.popup.close()
    return cleared
  }

  // Deletes one item. Returns whether it was deleted.
  @MainActor
  @discardableResult
  func delete(_ item: HistoryItemDecorator?) -> Bool {
    guard let item else { return false }
    return delete([item])
  }

  // Deletes several items in one save, so a failure is reported once.
  @MainActor
  @discardableResult
  func delete(_ items: [HistoryItemDecorator]) -> Bool {
    guard !items.isEmpty else { return true }
    return remove(items.map(\.item), as: .delete)
  }

  // Returns whether the items were removed from history. An export file that
  // could not be deleted afterwards doesn't change that: it is reported
  // separately and retried (see `noteExportRemoval`).
  @MainActor
  @discardableResult
  private func remove(
    _ items: [HistoryItem],
    includingOrphanedContents: Bool = false,
    revokingAllExports: Bool = false,
    as removal: HistoryRemoval,
    alerting: Bool = true
  ) -> Bool {
    let removedIDs = Set(items.map { ObjectIdentifier($0) })
    func isRemoved(_ decorator: HistoryItemDecorator) -> Bool {
      removedIDs.contains(ObjectIdentifier(decorator.item))
    }
    let decorators = (allPinnedItems + allUnpinnedItems).filter(isRemoved)

    do {
      try Storage.shared.delete(items, includingOrphanedContents: includingOrphanedContents)
    } catch {
      reportRemovalFailure(removal, error, alerting: alerting)
      return false
    }

    if let operation = removal.maintenanceOperation {
      resolve(operation)
    }

    let pendingBefore = IntentImageExports.pendingRemovals
    for item in items {
      IntentImageExports.remove(for: item)
      Notifier.removeDelivered(for: item)
    }
    if revokingAllExports {
      IntentImageExports.removeAll()
    }
    noteExportRemoval(
      !IntentImageExports.hasPendingRemovals,
      newFailure: !IntentImageExports.pendingRemovals.isSubset(of: pendingBefore),
      userInitiated: removal.alertsEveryTime && alerting
    )

    for decorator in decorators {
      decorator.cleanupImages()
      pinManager.remove(decorator)
    }
    allUnpinnedItems.removeAll(where: isRemoved)
    filteredPinnedItems.removeAll(where: isRemoved)
    filteredUnpinnedItems.removeAll(where: isRemoved)
    sessionLog.removeValues { removedIDs.contains(ObjectIdentifier($0)) }

    if !items.isEmpty {
      logger.info("Removed \(items.count) history items (\(removal.rawValue))")
    }
    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
    return true
  }

  // Logs the failure by domain and code only, records it, and tells the user:
  // every time for a removal they asked for, once per run of failures of the
  // same operation for an automatic one.
  @MainActor
  private func reportRemovalFailure(_ removal: HistoryRemoval, _ error: any Error, alerting: Bool = true) {
    logger.error("""
      Failed to remove history items (\(removal.rawValue)): \(Notifier.redacted(error)). \
      Nothing was removed; history is unchanged.
      """)
    if let operation = removal.maintenanceOperation {
      recordFailure(operation, showing: .removal(removal), error: error)
    } else if alerting {
      present([.removal(removal)], error: error)
    }
  }

  // After a removal, whether every exported image file is gone. One that is
  // left is kept for retrying (`IntentImageExports.pendingRemovals`); the
  // user is told plainly that history was deleted but a file remains: each
  // time a removal they asked for leaves a new file behind, and otherwise once
  // per run of failures.
  @MainActor
  private func noteExportRemoval(_ allRemoved: Bool, newFailure: Bool = false, userInitiated: Bool) {
    guard !allRemoved else {
      resolve(.exportRemoval)
      return
    }
    logger.error("""
      \(IntentImageExports.pendingRemovals.count) exported image files could not be deleted. \
      Keeping them for retrying.
      """)
    if userInitiated && newFailure {
      failingOperations[.exportRemoval] = now()
      alertedOperations.insert(.exportRemoval)
      present([.exportRemoval], error: nil)
    } else {
      recordFailure(.exportRemoval, showing: .exportRemoval, error: nil)
    }
  }

  @MainActor
  private func recordFailure(_ operation: MaintenanceOperation, showing failure: HistoryFailure?, error: (any Error)?) {
    failingOperations[operation] = now()
    guard let failure, alertedOperations.insert(operation).inserted else {
      return
    }
    present([failure], error: error)
  }

  @MainActor
  private func resolve(_ operation: MaintenanceOperation) {
    if failingOperations.removeValue(forKey: operation) != nil {
      logger.notice("History maintenance recovered (\(operation.rawValue))")
    }
    alertedOperations.remove(operation)
  }

  // Shows failures now, or collects them while launching.
  @MainActor
  private func present(_ failures: [HistoryFailure], error: (any Error)?) {
    let errorCode = error.map(Notifier.redacted)
    if deferredFailures != nil {
      deferredFailures?.append(contentsOf: failures)
      deferredErrorCode = deferredErrorCode ?? errorCode
      return
    }
    Self.removalFailureReporter.report(failures, errorCode: errorCode)
  }

  // MARK: Compaction
  //
  // See `Storage.compact()`: not secure erasure. Every removal that clears
  // (clear, clear all, clear on quit, clear at launch) asks for compaction
  // straight away; a purge asks for it at most once per
  // `expiryCompactionInterval`. A request stays pending until a compaction
  // succeeds: the pending flag is also kept in `maintenanceState`, so one
  // still pending at quit runs at the next launch. A failure is logged,
  // listed in the settings, and retried by maintenance after a doubling delay;
  // history itself was already removed.

  @MainActor
  private func requestCompaction(after removal: HistoryRemoval) {
    let current = uptime()
    var due = current
    if removal == .expiry, let lastCompaction {
      due = max(current, lastCompaction + Self.expiryCompactionInterval)
    }
    compactionDueAt = min(compactionDueAt ?? due, due)
    compactionGeneration += 1
    maintenanceState.set(true, forKey: Self.compactionPendingKey)
    compactIfDue()
  }

  @MainActor
  var isCompactionPending: Bool { compactionDueAt != nil }

  // Starts a compaction in the background if one is due and none is running.
  @MainActor
  func compactIfDue() {
    guard let due = compactionDueAt, compactionTask == nil, uptime() >= due else {
      return
    }
    let storage = Storage.shared
    let generation = compactionGeneration
    compactionTask = Task { [self] in
      let result: Result<Void, any Error>
      do {
        try await storage.compact()
        result = .success(())
      } catch {
        result = .failure(error)
      }
      compactionTask = nil
      compactionFinished(result, generation: generation, storage: storage)
    }
  }

  // Waits until no compaction is in progress, including one started when the
  // previous one finished. For tests.
  @MainActor
  func waitForCompaction() async {
    while let compactionTask {
      await compactionTask.value
    }
  }

  @MainActor
  private func compactionFinished(_ result: Result<Void, any Error>, generation: Int, storage: Storage) {
    // Changes made while autosave was off for the compaction.
    if storage === Storage.shared, storage.context.hasChanges {
      do {
        try storage.save()
      } catch {
        logger.error("Could not save history after compacting: \(Notifier.redacted(error))")
      }
    }

    switch result {
    case .success:
      logger.info("Compacted the history database")
      lastCompaction = uptime()
      compactionFailures = 0
      resolve(.compaction)
      if generation == compactionGeneration {
        compactionDueAt = nil
        maintenanceState.set(false, forKey: Self.compactionPendingKey)
      }
    case .failure(let error as StorageCompactionError) where error.isInterrupted:
      // A save stopped it; not a failure. Started again shortly.
      logger.info("Compaction was interrupted by a save; it runs again later")
      compactionDueAt = uptime() + Self.compactionResumeDelay
    case .failure(let error):
      compactionFailures += 1
      let delay = min(
        Self.compactionRetryDelay * pow(2, Double(compactionFailures - 1)),
        Self.compactionMaximumRetryDelay
      )
      compactionDueAt = uptime() + delay
      logger.error("""
        Could not compact the history database: \(Notifier.redacted(error)). \
        History was removed; compaction is retried in \(Int(delay)) s.
        """)
      recordFailure(.compaction, showing: nil, error: error)
    }
    // A request made while this one ran (it can't start while one runs).
    compactIfDue()
  }

  // At quit: runs a pending compaction on this thread, giving up after
  // `timeLimit` (SQLite rolls an unfinished vacuum back). If it doesn't
  // finish, it stays pending for the next launch.
  @MainActor
  func compactBeforeQuit(timeLimit: TimeInterval) {
    guard compactionDueAt != nil else {
      return
    }
    do {
      try Storage.shared.compactNow(deadline: ProcessInfo.processInfo.systemUptime + timeLimit)
      compactionDueAt = nil
      maintenanceState.set(false, forKey: Self.compactionPendingKey)
      logger.info("Compacted the history database before quitting")
    } catch {
      logger.error("""
        Could not compact the history database before quitting: \(Notifier.redacted(error)). \
        It runs at the next launch.
        """)
    }
  }

  // MARK: Launch and maintenance

  // Launch step 2 (see `LaunchSequence`), after the storage-policy clean-up
  // and before history is loaded or shown, capture starts or any alert is
  // shown: removes exports left by the last session, clears unpinned items
  // if "Clear history on quit" is on (so a crash, force quit or session end
  // doesn't leave history behind), purges expired items and trims the store
  // to the history size. Failures are collected and shown by
  // `presentDeferredFailures` once launch has finished.
  @MainActor
  func performLaunchMaintenance() {
    beginCollectingFailures()
    launchTime = now()
    noteExportRemoval(IntentImageExports.removeLeftoversOnce(), userInitiated: false)
    if maintenanceState.bool(forKey: Self.compactionPendingKey) {
      compactionDueAt = uptime()
    }
    if Defaults[.clearOnQuit] {
      do {
        launchClearItems = try Storage.shared.unpinnedItems()
      } catch {
        launchClearItems = nil
      }
      launchClearPending = true
      retryLaunchClear()
    }
    runExpiry()
    limitStoredHistorySize()
  }

  // Launch step 3: builds the list. A failure is reported (with the others
  // collected at launch), not swallowed; opening the window tries again.
  @MainActor
  func finishLaunch() {
    beginCollectingFailures()
    do {
      try reloadItems()
    } catch {
      logger.error("Could not load history: \(Notifier.redacted(error))")
      present([.load], error: error)
    }
    isReady = true
  }

  // Launch step 7: shows every failure collected at launch, in one alert.
  @MainActor
  func presentDeferredFailures() {
    let failures = deferredFailures ?? []
    let errorCode = deferredErrorCode
    deferredFailures = nil
    deferredErrorCode = nil
    guard !failures.isEmpty else {
      return
    }
    Self.removalFailureReporter.report(failures, errorCode: errorCode)
  }

  // Launch step 1: from here until `presentDeferredFailures`, failures are
  // collected instead of shown.
  @MainActor
  func beginLaunch() {
    beginCollectingFailures()
  }

  @MainActor
  private func beginCollectingFailures() {
    if deferredFailures == nil {
      deferredFailures = []
    }
  }

  // The clear at launch, or a retry of it: removes the unpinned items left by
  // the last session (those listed at launch, or if they couldn't be listed,
  // unpinned items last copied before launch). Items copied since are kept.
  @MainActor
  private func retryLaunchClear() {
    guard launchClearPending else {
      return
    }
    let items: [HistoryItem]
    do {
      let unpinned = try Storage.shared.unpinnedItems()
      if let launchClearItems {
        let left = Set(launchClearItems.map { ObjectIdentifier($0) })
        items = unpinned.filter { left.contains(ObjectIdentifier($0)) }
      } else {
        let cutoff = launchTime ?? now()
        items = unpinned.filter { $0.lastCopiedAt < cutoff }
      }
    } catch {
      reportRemovalFailure(.clearOnLaunch, error)
      return
    }

    if remove(items, includingOrphanedContents: true, revokingAllExports: true, as: .clearOnLaunch) {
      launchClearPending = false
      launchClearItems = nil
      requestCompaction(after: .clearOnLaunch)
    }
  }

  #if DEBUG
  // Tests start each case with no earlier failure, retry or compaction
  // state.
  func resetAutomaticRemovalFailuresForTesting() {
    failingOperations = [:]
    alertedOperations = []
    deferredFailures = nil
    deferredErrorCode = nil
    compactionDueAt = nil
    lastCompaction = nil
    compactionFailures = 0
    lastExpiryRun = nil
    launchClearItems = nil
    launchClearPending = false
    launchTime = nil
    refusedItems = []
    isReady = true
  }

  // Tests replay a launch: history is not ready until `finishLaunch`.
  func beginLaunchForTesting() {
    isReady = false
  }

  var isExpiryScheduled: Bool { maintenanceTimer != nil || !maintenanceObservers.isEmpty }
  #endif

  // Runs `runMaintenance` every `expiryCheckInterval` while Maccy runs,
  // whether or not the window is ever opened, and straight away after the Mac
  // wakes, after the system clock changes and after the expiry setting
  // changes. Timers can be deferred by App Nap, so expiry is also checked
  // when history is shown or read (`runExpiryIfDue`).
  @MainActor
  func startExpirySchedule() {
    #if DEBUG
    // Tests run maintenance themselves, with their own clock and preferences.
    guard !Self.isRunningUnitTests else { return }
    #endif

    maintenanceTimer?.invalidate()
    let timer = Timer(timeInterval: Self.expiryCheckInterval, repeats: true) { _ in
      MainActor.assumeIsolated {
        History.shared.runMaintenance()
      }
    }
    timer.tolerance = 30
    RunLoop.main.add(timer, forMode: .common)
    maintenanceTimer = timer

    maintenanceObservers.forEach {
      NSWorkspace.shared.notificationCenter.removeObserver($0)
      NotificationCenter.default.removeObserver($0)
    }
    maintenanceObservers = [
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          History.shared.runMaintenance()
        }
      },
      NotificationCenter.default.addObserver(
        forName: .NSSystemClockDidChange, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          History.shared.runMaintenance()
        }
      }
    ]
    Task {
      for await _ in Defaults.updates(.historyExpiryHours, initial: false) {
        runMaintenance()
      }
    }
  }

  // One periodic run: retries a failed clear at launch, refused copies and
  // trim, purges expired items, retries exported files that could not be
  // deleted, and starts a compaction that is due.
  @MainActor
  func runMaintenance() {
    guard isReady else { return }
    retryLaunchClear()
    retryRefusedRemovals()
    if failingOperations[.trim] != nil {
      limitHistorySize(to: HistorySize.current)
    }
    runExpiry()
    if IntentImageExports.hasPendingRemovals || failingOperations[.exportRemoval] != nil {
      noteExportRemoval(IntentImageExports.retryPendingRemovals(), userInitiated: false)
    }
    compactIfDue()
  }

  // Purges expired items, and asks for compaction if that removed something.
  @MainActor
  func runExpiry() {
    if let removed = purgeExpiredItems(), removed > 0 {
      requestCompaction(after: .expiry)
    }
  }

  // Before history is shown or read (popup, Get and Select intents): purges
  // expired items unless a purge ran within `expiryAccessInterval` by both
  // clocks. Cheap: one fetch when nothing has expired.
  @MainActor
  func runExpiryIfDue() {
    guard HistoryExpiry.effective(in: expiryPreferences).isOn else {
      return
    }
    if let lastExpiryRun,
       abs(now().timeIntervalSince(lastExpiryRun.date)) < Self.expiryAccessInterval,
       uptime() - lastExpiryRun.uptime < Self.expiryAccessInterval {
      return
    }
    runExpiry()
  }

  // Whether history may be shown now: launch has finished. Purges expired
  // items first.
  @MainActor
  func prepareForDisplay() -> Bool {
    guard isReady else {
      return false
    }
    runExpiryIfDue()
    return true
  }

  // Removes items last copied more than the expiry ago (see `HistoryExpiry`
  // for how the setting is read and when pinned items expire). Returns how
  // many were removed, or nil if that failed.
  //
  // Measured against `now()`. A clock set forwards purges early, the safe
  // direction. A clock set backwards would leave items stamped "in the
  // future" unexpired for as long as it was moved, so an item last copied
  // more than `futureTimestampTolerance` ahead of the clock is re-dated as
  // copied now: it then expires after the expiry time at the latest. Each
  // item is re-dated at most once (recorded in `maintenanceState`): one found
  // ahead of the clock again is treated as expired, so repeated backward
  // clock changes can't keep extending its retention.
  @MainActor
  @discardableResult
  func purgeExpiredItems() -> Int? {
    let expiry = HistoryExpiry.effective(in: expiryPreferences)
    let currentTime = now()
    lastExpiryRun = (currentTime, uptime())
    guard let cutoff = expiry.cutoff(now: currentTime) else {
      resolve(.expiry)
      return 0
    }

    let expired: [HistoryItem]
    do {
      let aheadAgain = try redateFutureItems(now: currentTime)
      let old = try Storage.shared.items(lastCopiedBefore: cutoff)
      let candidates = old + aheadAgain.filter { item in !old.contains { $0 === item } }
      expired = candidates.filter { expiry.expiresPinnedItems || $0.pin == nil }
    } catch {
      reportRemovalFailure(.expiry, error)
      return nil
    }

    guard !expired.isEmpty else {
      resolve(.expiry)
      return 0
    }
    guard remove(expired, as: .expiry) else {
      return nil
    }
    return expired.count
  }

  // Re-dates items stamped ahead of the clock that were never re-dated, and
  // returns those that were already re-dated once.
  @MainActor
  private func redateFutureItems(now: Date) throws -> [HistoryItem] {
    let future = try Storage.shared.items(lastCopiedAfter: now.addingTimeInterval(Self.futureTimestampTolerance))
    var redated = Set(maintenanceState.array(forKey: Self.redatedItemsKey) as? [Data] ?? [])
    guard !future.isEmpty || !redated.isEmpty else {
      return []
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    func key(_ item: HistoryItem) -> Data? { try? encoder.encode(item.persistentModelID) }
    let aheadAgain = future.filter { key($0).map(redated.contains) ?? false }
    let toRedate = future.filter { item in !aheadAgain.contains { $0 === item } }

    if !toRedate.isEmpty {
      let stamps = toRedate.map(\.lastCopiedAt)
      toRedate.forEach { $0.lastCopiedAt = now }
      do {
        Storage.shared.context.processPendingChanges()
        try Storage.shared.save()
      } catch {
        zip(toRedate, stamps).forEach { $0.lastCopiedAt = $1 }
        throw error
      }
      redated.formUnion(toRedate.compactMap(key))
      logger.notice("Re-dated \(toRedate.count) history items copied after the current time")
      resortUnpinnedItems()
    }

    // Forget items that are gone.
    let stored = Set(try Storage.shared.allItems().compactMap(key))
    redated.formIntersection(stored)
    maintenanceState.set(Array(redated), forKey: Self.redatedItemsKey)
    return aheadAgain
  }

  // Puts the unpinned list back in sort order after items were re-dated.
  @MainActor
  private func resortUnpinnedItems() {
    let decorators = Dictionary(
      allUnpinnedItems.map { (ObjectIdentifier($0.item), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    allUnpinnedItems = sorter.sort(allUnpinnedItems.map(\.item)).compactMap { decorators[ObjectIdentifier($0)] }
    if searchQuery.isEmpty {
      filteredUnpinnedItems = allUnpinnedItems
      updateUnpinnedShortcuts()
    } else {
      updateSearchResults()
    }
  }

  @MainActor
  private func transferContents(from existingItem: HistoryItem, to newItem: HistoryItem) {
    deleteContents(of: newItem)
    newItem.contents = existingItem.contents
    existingItem.contents = []
  }

  @MainActor
  private func deleteFromStorage(_ item: HistoryItem) {
    deleteContents(of: item)
    Storage.shared.context.delete(item)
  }

  @MainActor
  private func deleteContents(of item: HistoryItem) {
    item.contents.forEach(Storage.shared.context.delete)
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?, flags modifierFlags: NSEvent.ModifierFlags) {
    guard let item else {
      return
    }

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>, flags modifierFlags: NSEvent.ModifierFlags) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying item 1 of \(stack.items.count) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard !stack.items.isEmpty else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted an item")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying next item from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          Clipboard.shared.copy(item.item)
        case .paste:
          Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    let wasPinned = item.isPinned
    pinManager.toggle(item)
    guard item.isPinned != wasPinned else { return }

    if wasPinned {
      insertUnpinned(item)
    } else {
      allUnpinnedItems.removeAll { $0 == item }
    }

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  func movePin(from source: IndexSet, to destination: Int) {
    guard searchQuery.isEmpty else { return }
    pinManager.move(from: source, to: destination)
  }

  @MainActor
  func updatePin(_ item: HistoryItem, to pin: String) {
    guard let itemDecorator = firstStoredItem(where: { $0.item.id == item.id }) else { return }

    let wasPinned = itemDecorator.isPinned
    pinManager.updatePin(of: itemDecorator, to: pin)
    if !wasPinned && itemDecorator.isPinned {
      allUnpinnedItems.removeAll { $0 == itemDecorator }
    }
    updateShortcuts()
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let duplicate = firstStoredItem(where: { $0.item != item && $0.item.supersedes(item) }) {
      return duplicate.item
    }

    return isModified(item)
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func updateSearchResults() {
    filteredPinnedItems = filteredItems(
      from: search.search(string: searchQuery, within: allPinnedItems)
    )
    filteredUnpinnedItems = filteredItems(
      from: search.search(string: searchQuery, within: allUnpinnedItems)
    )

    updateUnpinnedShortcuts()
  }

  private func filteredItems(from results: [Search.SearchResult]) -> [HistoryItemDecorator] {
    results.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }
  }

  private func firstStoredItem(
    where predicate: (HistoryItemDecorator) -> Bool
  ) -> HistoryItemDecorator? {
    allPinnedItems.first(where: predicate) ?? allUnpinnedItems.first(where: predicate)
  }

  private func insertUnpinned(_ item: HistoryItemDecorator) {
    let sortedItems = sorter.sort(allUnpinnedItems.map(\.item) + [item.item])
    guard let index = sortedItems.firstIndex(of: item.item) else { return }
    allUnpinnedItems.insert(item, at: index)
  }

  private func updateShortcuts() {
    for item in pinManager.pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitlesForSpecialSymbols() {
    for item in items {
      item.item.regenerateTitleForSpecialSymbols()
      item.refreshTitle()
    }
  }

  private func updateUnpinnedShortcuts() {
    let shortcutItems = unpinnedItems.filter(\.isVisible)
    for item in shortcutItems {
      item.shortcuts = []
    }

    var index = 1
    for item in shortcutItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
