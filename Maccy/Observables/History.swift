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

  // Shows removal failures to the user. Tests replace it.
  @ObservationIgnored
  static var removalFailureReporter: any HistoryRemovalFailureReporting = AlertHistoryRemovalFailureReporter()
  // When an automatic removal (trim, expiry, clear at launch) last failed, or
  // nil once one succeeds. Shown in the Storage settings.
  private(set) var automaticRemovalFailedAt: Date?
  // Whether the current run of automatic-removal failures was already shown.
  @ObservationIgnored
  private var automaticRemovalFailureShown = false

  // Where the expiry setting is read from, and the clock it is measured with.
  // Tests replace both.
  @ObservationIgnored
  var expiryPreferences: UserDefaults = Defaults.Keys.historyExpiryHours.suite
  @ObservationIgnored
  var now: () -> Date = { Date.now }
  @ObservationIgnored
  private var expiryTimer: Timer?
  @ObservationIgnored
  private var expiryObservers: [any NSObjectProtocol] = []
  // A purge removed items since the store was last compacted, and when it was
  // (system uptime, so a clock change can't defer it forever).
  @ObservationIgnored
  private var expiryCompactionPending = false
  @ObservationIgnored
  private var lastExpiryCompaction: TimeInterval?

  // How often the expiry purge runs while Maccy is running, and how often at
  // most it compacts the store afterwards.
  static let expiryCheckInterval: TimeInterval = 5 * 60
  static let expiryCompactionInterval: TimeInterval = 60 * 60
  // An item last copied later than this ahead of the clock was stamped before
  // the clock was set back.
  static let futureTimestampTolerance: TimeInterval = 10 * 60

#if DEBUG
  static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#endif

  init() {
    #if DEBUG
    guard !Self.isRunningUnitTests else { return }
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
    IntentImageExports.removeLeftoversOnce()
    enforceStoragePolicy(reloadingItems: false)
    try reloadItems()
  }

  @MainActor
  private func reloadItems() throws {
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
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
      return
    }
    remove(allUnpinnedItems[maxSize...].map(\.item), as: .trim)
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
        deleteFromStorage(item)
        context.processPendingChanges()
        try? storage.save()
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
  // trimming to the history size, expiry) goes through `remove(_:as:)`: the
  // store is changed first, all or nothing (`Storage.delete`), and only once
  // that save succeeded are the items taken out of the list and their
  // notifications and intent image exports revoked. If it fails, the store,
  // the list, notifications and exports are all left as they were, and the
  // failure is reported (see `HistoryRemoval.alertsEveryTime`).

  // Clears unpinned items. Returns whether history was cleared.
  @MainActor
  @discardableResult
  func clear() -> Bool {
    clearUnpinned(as: .clear)
  }

  // Clears unpinned items when Maccy quits with "Clear history on quit" on.
  @MainActor
  @discardableResult
  func clearOnQuit() -> Bool {
    clearUnpinned(as: .clearOnQuit)
  }

  @MainActor
  @discardableResult
  private func clearUnpinned(as removal: HistoryRemoval) -> Bool {
    let cleared: Bool
    do {
      cleared = remove(try Storage.shared.unpinnedItems(), includingOrphanedContents: true, as: removal)
    } catch {
      reportRemovalFailure(removal, error)
      cleared = false
    }

    if cleared {
      IntentImageExports.removeAll()
      compactStore(after: removal)
    }
    if removal != .clearOnLaunch {
      Clipboard.shared.clear()
      AppState.shared.popup.close()
    }
    return cleared
  }

  // Clears every item, pinned ones included. Returns whether history was
  // cleared.
  @MainActor
  @discardableResult
  func clearAll() -> Bool {
    let cleared: Bool
    do {
      cleared = remove(try Storage.shared.allItems(), includingOrphanedContents: true, as: .clearAll)
    } catch {
      reportRemovalFailure(.clearAll, error)
      cleared = false
    }

    if cleared {
      pinManager.removeAll()
      sessionLog.removeAll()
      Notifier.removeAllDelivered()
      IntentImageExports.removeAll()
      compactStore(after: .clearAll)
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

  @MainActor
  @discardableResult
  private func remove(
    _ items: [HistoryItem],
    includingOrphanedContents: Bool = false,
    as removal: HistoryRemoval
  ) -> Bool {
    let removedIDs = Set(items.map { ObjectIdentifier($0) })
    func isRemoved(_ decorator: HistoryItemDecorator) -> Bool {
      removedIDs.contains(ObjectIdentifier(decorator.item))
    }
    let decorators = (allPinnedItems + allUnpinnedItems).filter(isRemoved)

    do {
      try Storage.shared.delete(items, includingOrphanedContents: includingOrphanedContents)
    } catch {
      reportRemovalFailure(removal, error)
      return false
    }

    if !removal.alertsEveryTime {
      automaticRemovalFailedAt = nil
      automaticRemovalFailureShown = false
    }

    for item in items {
      IntentImageExports.remove(for: item)
      Notifier.removeDelivered(for: item)
    }
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
  // every time for a removal they asked for, once per run of failures for an
  // automatic one.
  @MainActor
  private func reportRemovalFailure(_ removal: HistoryRemoval, _ error: any Error) {
    logger.error("""
      Failed to remove history items (\(removal.rawValue)): \(Notifier.redacted(error)). \
      Nothing was removed; history is unchanged.
      """)
    if removal.alertsEveryTime {
      Self.removalFailureReporter.removalFailed(removal, error: error)
      return
    }

    automaticRemovalFailedAt = now()
    if !automaticRemovalFailureShown {
      automaticRemovalFailureShown = true
      Self.removalFailureReporter.removalFailed(removal, error: error)
    }
  }

  // See `Storage.compact()`: not secure erasure. A failure is logged only:
  // history itself was removed.
  @MainActor
  private func compactStore(after removal: HistoryRemoval) {
    do {
      try Storage.shared.compact()
      logger.info("Compacted the history database (\(removal.rawValue))")
    } catch {
      logger.error("Could not compact the history database (\(removal.rawValue)): \(Notifier.redacted(error))")
    }
  }

  // MARK: Expiry and launch

  // Runs once at launch, before the history is first shown: clears unpinned
  // items if "Clear history on quit" is on (so a crash or force quit doesn't
  // leave history behind), purges expired items, then loads history, which
  // trims it to the history size.
  @MainActor
  func performLaunchMaintenance() {
    if Defaults[.clearOnQuit] {
      clearUnpinned(as: .clearOnLaunch)
    }
    runExpiry()
    try? reloadItems()
  }

  #if DEBUG
  // Tests start each case with no earlier automatic-removal failure recorded.
  func resetAutomaticRemovalFailuresForTesting() {
    automaticRemovalFailedAt = nil
    automaticRemovalFailureShown = false
    expiryCompactionPending = false
    lastExpiryCompaction = nil
  }

  var isExpiryScheduled: Bool { expiryTimer != nil || !expiryObservers.isEmpty }
  #endif

  // Runs the expiry purge every `expiryCheckInterval` while Maccy runs,
  // whether or not the window is ever opened, and straight away after the Mac
  // wakes, after the system clock changes and after the setting changes.
  @MainActor
  func startExpirySchedule() {
    #if DEBUG
    // Tests run the purge themselves, with their own clock and preferences.
    guard !Self.isRunningUnitTests else { return }
    #endif

    expiryTimer?.invalidate()
    let timer = Timer(timeInterval: Self.expiryCheckInterval, repeats: true) { _ in
      MainActor.assumeIsolated {
        History.shared.runExpiry()
      }
    }
    timer.tolerance = 30
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer

    expiryObservers.forEach {
      NSWorkspace.shared.notificationCenter.removeObserver($0)
      NotificationCenter.default.removeObserver($0)
    }
    expiryObservers = [
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          History.shared.runExpiry()
        }
      },
      NotificationCenter.default.addObserver(
        forName: .NSSystemClockDidChange, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          History.shared.runExpiry()
        }
      }
    ]
    Task {
      for await _ in Defaults.updates(.historyExpiryHours, initial: false) {
        runExpiry()
      }
    }
  }

  // One scheduled run: purges, then compacts the store if a purge removed
  // something and the last compaction after a purge was at least
  // `expiryCompactionInterval` ago (VACUUM rewrites the whole file).
  @MainActor
  func runExpiry() {
    if let removed = purgeExpiredItems(), removed > 0 {
      expiryCompactionPending = true
    }
    let uptime = ProcessInfo.processInfo.systemUptime
    if expiryCompactionPending,
       lastExpiryCompaction.map({ uptime - $0 >= Self.expiryCompactionInterval }) ?? true {
      expiryCompactionPending = false
      lastExpiryCompaction = uptime
      compactStore(after: .expiry)
    }
  }

  // Compacts the store if a purge removed items since the last compaction.
  @MainActor
  func compactIfExpiryRemovedItems() {
    guard expiryCompactionPending else { return }
    expiryCompactionPending = false
    compactStore(after: .expiry)
  }

  // Removes items last copied more than the expiry ago (see `HistoryExpiry`
  // for how the setting is read and when pinned items expire). Returns how
  // many were removed, or nil if that failed.
  //
  // Measured against `now()`. A clock set forwards purges early, the safe
  // direction. A clock set backwards would leave items stamped "in the
  // future" unexpired for as long as it was moved, so an item last copied
  // more than `futureTimestampTolerance` ahead of the clock is restamped as
  // copied now: it then expires after the expiry time at the latest.
  @MainActor
  @discardableResult
  func purgeExpiredItems() -> Int? {
    let expiry = HistoryExpiry.effective(in: expiryPreferences)
    let currentTime = now()
    guard let cutoff = expiry.cutoff(now: currentTime) else {
      return 0
    }

    let expired: [HistoryItem]
    do {
      try restampFutureItems(now: currentTime)
      expired = try Storage.shared.items(lastCopiedBefore: cutoff)
        .filter { expiry.expiresPinnedItems || $0.pin == nil }
    } catch {
      reportRemovalFailure(.expiry, error)
      return nil
    }

    guard !expired.isEmpty else {
      return 0
    }
    guard remove(expired, as: .expiry) else {
      return nil
    }
    return expired.count
  }

  @MainActor
  private func restampFutureItems(now: Date) throws {
    let future = try Storage.shared.items(lastCopiedAfter: now.addingTimeInterval(Self.futureTimestampTolerance))
    guard !future.isEmpty else {
      return
    }

    let stamps = future.map(\.lastCopiedAt)
    future.forEach { $0.lastCopiedAt = now }
    do {
      Storage.shared.context.processPendingChanges()
      try Storage.shared.save()
    } catch {
      zip(future, stamps).forEach { $0.lastCopiedAt = $1 }
      throw error
    }
    logger.notice("Restamped \(future.count) history items copied after the current time")
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

    // A selection still waiting for a shortcut key is replaced by this one.
    AppState.shared.popup.deferredSelection.cancel()

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
