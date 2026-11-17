import AppKit.NSPasteboard
import Foundation
import SQLite3
import SwiftData

@MainActor
class Storage {
  // Replaced only by tests that need a store on disk (see
  // `replaceSharedForTesting`).
  private(set) static var shared = Storage()
  static let defaultURL = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  let configuration: ModelConfiguration
  var size: String {
    guard let url = storeURL,
          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  // The SQLite file, or nil for a store kept in memory.
  let storeURL: URL?

  // History never syncs to iCloud: CloudKit is turned off explicitly, so it
  // stays off even if the app is later given CloudKit entitlements.
  init(storeURL: URL = Storage.defaultURL) {
    var config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
    var fileURL: URL? = storeURL

    #if DEBUG
    if AppDelegate.isTesting && storeURL == Self.defaultURL {
      config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      fileURL = nil
    }
    #endif

    configuration = config
    self.storeURL = fileURL
    // A copy left by a compaction that never finished (a crash or a forced
    // quit) holds history: it goes before anything else.
    if let fileURL {
      StorageCompaction.removeCopy(of: fileURL)
    }
    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(Notifier.redacted(error)).")
    }
  }

  func allItems() throws -> [HistoryItem] {
    #if DEBUG
    if let fetchFailureForTesting {
      throw fetchFailureForTesting
    }
    #endif
    return try context.fetch(FetchDescriptor<HistoryItem>())
  }

  func unpinnedItems() throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil }))
  }

  func items(lastCopiedBefore date: Date) throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.lastCopiedAt < date }))
  }

  func items(lastCopiedAfter date: Date) throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.lastCopiedAt > date }))
  }

  // Deletes `items` with their contents and, if asked, every content of no
  // item, all in one save. All or nothing: changes already pending are saved
  // first (so a failure can't discard them), then the deletion runs with
  // autosave off. If its save fails, the deleted items get their contents back
  // and the context is rolled back, so the store and the loaded models still
  // hold every item, and the error is thrown. Every removal from history goes
  // through here.
  func delete(_ items: [HistoryItem], includingOrphanedContents: Bool = false) throws {
    context.processPendingChanges()
    if context.hasChanges {
      try save()
    }

    let autosaveEnabled = context.autosaveEnabled
    context.autosaveEnabled = false
    defer { context.autosaveEnabled = autosaveEnabled }

    let undo = CleanUpUndoLog()
    do {
      if includingOrphanedContents {
        try context.fetch(FetchDescriptor<HistoryItemContent>(
          predicate: #Predicate { $0.item == nil }
        )).forEach(context.delete)
      }
      for item in items where item.modelContext != nil {
        undo.recordContents(of: item)
        item.contents.forEach(context.delete)
        context.delete(item)
      }
      context.processPendingChanges()
      if context.hasChanges {
        try save()
      }
    } catch {
      undo.restore()
      context.rollback()
      throw error
    }
  }

  // Asks SQLite to compact the store after history was deleted: the WAL is
  // checkpointed and truncated, the database is rebuilt with a full VACUUM,
  // and the WAL is truncated again. VACUUM writes every live row into a new
  // copy of the database and copies that back over the file, so rows deleted
  // before it are no longer in any page of `Storage.sqlite` (free pages, and
  // the unused parts of pages that still hold other rows) or in the WAL.
  // Whether the deleting connection zeroed them (`secure_delete`) doesn't
  // matter: that connection is SwiftData's, and Maccy can neither set nor
  // reliably read it. An incremental vacuum is not enough: it only releases
  // free pages and leaves deleted bytes in pages that still hold live rows.
  //
  // This is NOT secure erasure. VACUUM rewrites the file in place; the file
  // system decides where the old bytes physically were and when they are
  // overwritten. SQLite's temporary file for the rebuild, SSD wear levelling,
  // APFS snapshots, Time Machine and other backups are out of Maccy's
  // control.
  //
  // Mechanism: a second SQLite connection to the same file. SwiftData
  // exposes neither its connection nor Core Data's store options
  // (`NSSQLitePragmasOption`), and Core Data's supported route
  // (`NSSQLiteManualVacuumOption`) only vacuums when a store is added to a
  // coordinator, which needs the SwiftData container closed; History holds
  // its models for the whole session. Apple advises against using the SQLite
  // API on a Core Data store directly, so this relies on behaviour Apple does
  // not guarantee; the on-disk tests are the tripwire.
  //
  // It runs on a background thread: a full VACUUM takes time in proportion
  // to the size of the store (about 13 s for 1 GB in a measurement). It
  // can't overlap a save of this store: autosave is off while it runs, and
  // every save through `save()` (and the other saves here) first stops it
  // with `stopCompaction()`, which cancels it (a flag and `sqlite3_interrupt`
  // on its connection) and waits until it no longer holds the store. That
  // wait is short at every point of the compaction (measured: at most about
  // 0.4 s for a 1 GB store, see `StorageCompaction` and the PR). A cancelled
  // compaction leaves the database as it was and throws
  // `StorageCompactionError.interrupted`. Readers are not blocked: the store
  // is in WAL mode.
  //
  // Nothing here deletes or rewrites rows, so remaining items, pinned ones
  // included, are kept whether it succeeds or fails.
  func compact() async throws {
    guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else {
      return
    }
    stopCompaction()

    let job = StorageCompaction(url: storeURL, deadline: nil)
    #if DEBUG
    job.phaseHandlerForTesting = compactionPhaseHandlerForTesting
    #endif
    runningCompaction = job
    let autosaveEnabled = context.autosaveEnabled
    context.autosaveEnabled = false
    defer {
      if runningCompaction === job {
        runningCompaction = nil
      }
      context.autosaveEnabled = autosaveEnabled
    }
    try await job.runInBackground()
  }

  // Compacts on the calling thread, giving up (and rolling back) at
  // `deadline` (system uptime). For quitting, when nothing else will save.
  func compactNow(deadline: TimeInterval) throws {
    guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else {
      return
    }
    // One still running in the background is stopped, and waited for until
    // the deadline: a second compaction can't checkpoint while it reads.
    if let job = runningCompaction {
      job.cancel()
      guard job.waitUntilFinished(timeout: deadline - ProcessInfo.processInfo.systemUptime) else {
        throw StorageCompactionError.interrupted
      }
      runningCompaction = nil
    }
    try StorageCompaction(url: storeURL, deadline: deadline).run()
  }

  // Cancels a compaction in progress and waits until it no longer holds the
  // store, so a save can't overlap its rebuild or copy. Once the copy has
  // committed it only checkpoints, which doesn't get in a save's way.
  func stopCompaction() {
    guard let job = runningCompaction else {
      return
    }
    job.cancel()
    job.waitUntilStoreReleased()
    runningCompaction = nil
  }

  var isCompacting: Bool { runningCompaction != nil }

  private var runningCompaction: StorageCompaction?

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    stopCompaction()
    try context.save()

    return count
  }

  // How many stored items the clean-up would change under `allowList`.
  // Decided from type names only; no stored data is read.
  func cleanUpImpact(of allowList: StorageAllowList) throws -> StorageCleanUpImpact {
    try cleanUpPlan(for: allowList).impact
  }

  #if DEBUG
  // Tests set this to make every `save()` throw it.
  var saveFailureForTesting: (any Error)?
  // Tests set this to make `allItems()` throw it.
  var fetchFailureForTesting: (any Error)?
  // Tests set this to act while a background compaction is under way (see
  // `StorageCompaction.phaseHandlerForTesting`).
  var compactionPhaseHandlerForTesting: (@Sendable (StorageCompaction, StorageCompaction.Phase) -> Void)?

  // Makes `storage` the shared store and returns the one it replaces. Tests
  // only: the history must be reloaded afterwards.
  @discardableResult
  static func replaceSharedForTesting(with storage: Storage) -> Storage {
    let previous = shared
    shared = storage
    return previous
  }
  #endif

  // Saves the context. Every save that can carry history content goes
  // through here, so tests can make it fail.
  func save() throws {
    #if DEBUG
    if let saveFailureForTesting {
      throw saveFailureForTesting
    }
    #endif
    stopCompaction()
    try context.save()
  }

  // Brings every stored item in line with `allowList`. It works in two steps
  // with a clear boundary between them:
  //
  // 1. Changes already pending in the context are brought in line with
  //    `allowList` first, then saved. Whatever that save writes is allowed by
  //    `allowList`, so it can never persist data the new policy excludes. If
  //    it fails, the clean-up stops there: what stays pending is already in
  //    line with `allowList`.
  // 2. The clean-up itself, all or nothing: representations `allowList`
  //    doesn't allow are deleted, metadata markers are normalised, items left
  //    without allowed content are deleted (pinned ones too), titles whose
  //    recorded source is gone are made again, and orphaned contents are
  //    deleted. It runs with autosave off and is saved once. If anything
  //    fails, including that save, every value it changed is put back to what
  //    it was before its first change, and the context is rolled back, so
  //    neither the store nor the loaded models keep any of it.
  //
  // `beforeCommit` runs just before step 2's save; tests use it to inject a
  // failure.
  @discardableResult
  func cleanUp(
    to allowList: StorageAllowList,
    beforeCommit: () throws -> Void = {}
  ) throws -> StorageCleanUpResult {
    try savePendingChanges(admittedBy: allowList)

    let autosaveEnabled = context.autosaveEnabled
    context.autosaveEnabled = false
    defer { context.autosaveEnabled = autosaveEnabled }

    let undo = CleanUpUndoLog()
    do {
      let result = try applyCleanUp(to: allowList, undo: undo)
      try beforeCommit()
      if context.hasChanges {
        try save()
      }
      for item in result.removedItems {
        Notifier.removeDelivered(for: item)
        IntentImageExports.remove(for: item)
      }
      for item in result.changedItems {
        IntentImageExports.remove(for: item)
      }
      return result
    } catch {
      undo.restore()
      context.rollback()
      throw error
    }
  }

  // Step 1 of the clean-up: applies `allowList` to every item with pending
  // changes, deletes pending contents of no item, then saves.
  private func savePendingChanges(admittedBy allowList: StorageAllowList) throws {
    context.processPendingChanges()
    guard context.hasChanges else {
      return
    }

    var items: [ObjectIdentifier: HistoryItem] = [:]
    for model in context.insertedModelsArray + context.changedModelsArray {
      if let item = model as? HistoryItem {
        items[ObjectIdentifier(item)] = item
      } else if let content = model as? HistoryItemContent {
        if let item = content.item {
          items[ObjectIdentifier(item)] = item
        } else {
          context.delete(content)
        }
      }
    }

    for item in items.values where !item.isDeleted {
      let changed = sanitize(item, to: allowList)
      if allowList.hasStorableContent(item.contents.map { NSPasteboard.PasteboardType($0.type) }) {
        item.reconcileTitle(readableBy: allowList, contentsChanged: changed)
      } else {
        item.contents.forEach(context.delete)
        context.delete(item)
        Notifier.removeDelivered(for: item)
        IntentImageExports.remove(for: item)
      }
    }

    context.processPendingChanges()
    try save()
  }

  private struct CleanUpPlan {
    var disallowedContents: [HistoryItemContent] = []
    var itemsLosingData: [HistoryItem] = []
    var itemsToRemove: [HistoryItem] = []

    var impact: StorageCleanUpImpact {
      StorageCleanUpImpact(itemsLosingData: itemsLosingData.count, itemsRemoved: itemsToRemove.count)
    }
  }

  // Finds what `allowList` would remove using only the `type` column, so the
  // payload of a representation that stays is not loaded for this.
  private func cleanUpPlan(for allowList: StorageAllowList) throws -> CleanUpPlan {
    let allowedNames = allowList.allowedTypes.map(\.rawValue)
    let enabledNames = allowList.enabledTypes.map(\.rawValue)

    var plan = CleanUpPlan()
    plan.disallowedContents = try typeOnlyContents(#Predicate<HistoryItemContent> { !allowedNames.contains($0.type) })

    var affectedItems: [PersistentIdentifier: HistoryItem] = [:]
    for content in plan.disallowedContents {
      if let item = content.item {
        affectedItems[item.persistentModelID] = item
      }
    }
    guard !affectedItems.isEmpty else {
      return plan
    }

    let itemsWithAllowedContent = Set(
      try typeOnlyContents(#Predicate<HistoryItemContent> { enabledNames.contains($0.type) })
        .compactMap { $0.item?.persistentModelID }
    )
    for (id, item) in affectedItems {
      if itemsWithAllowedContent.contains(id) {
        plan.itemsLosingData.append(item)
      } else {
        plan.itemsToRemove.append(item)
      }
    }

    return plan
  }

  private func typeOnlyContents(_ predicate: Predicate<HistoryItemContent>) throws -> [HistoryItemContent] {
    var descriptor = FetchDescriptor<HistoryItemContent>(predicate: predicate)
    descriptor.propertiesToFetch = [\.type]
    return try context.fetch(descriptor)
  }

  private func applyCleanUp(to allowList: StorageAllowList, undo: CleanUpUndoLog) throws -> StorageCleanUpResult {
    let plan = try cleanUpPlan(for: allowList)
    var result = StorageCleanUpResult(impact: plan.impact, removedItems: plan.itemsToRemove)
    let removedIDs = Set(plan.itemsToRemove.map(\.persistentModelID))
    // Disallowed contents of items being removed, and of no item at all.
    let unattachedContents = plan.disallowedContents.filter { content in
      content.item.map { removedIDs.contains($0.persistentModelID) } ?? true
    }

    // Only items that lose data are read beyond their type names.
    for item in plan.itemsLosingData {
      sanitize(item, to: allowList, undo: undo)
      undo.recordTitle(of: item)
      item.reconcileTitle(readableBy: allowList, contentsChanged: true)
      item.clearDecodedImageCache()
      result.changedItems.append(item)
    }

    for item in plan.itemsToRemove {
      undo.recordContents(of: item)
    }
    unattachedContents.forEach(context.delete)
    for item in plan.itemsToRemove {
      item.clearDecodedImageCache()
      context.delete(item)
    }

    // Markers stored before they were normalised on capture.
    let metadataNames = StoragePolicy.metadataTypes.map(\.rawValue)
    for content in try context.fetch(FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate<HistoryItemContent> { metadataNames.contains($0.type) }
    )) {
      guard let item = content.item, !removedIDs.contains(item.persistentModelID) else {
        continue
      }
      if sanitize(content, of: item, to: allowList, undo: undo) {
        result.markersNormalised += 1
      }
    }

    context.processPendingChanges()
    let orphans = try context.fetch(FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate<HistoryItemContent> { $0.item == nil }
    ))
    orphans.forEach(context.delete)
    result.orphansRemoved = orphans.count
    context.processPendingChanges()

    return result
  }

  // Removes or normalises the representations of one item that `allowList`
  // doesn't allow as stored. Works on items not yet in the store too. Reads
  // the stored value only of metadata markers, which are normalised. Returns
  // whether anything changed. The item itself is kept. With `undo`, each
  // value is recorded before its first change.
  @discardableResult
  func sanitize(_ item: HistoryItem, to allowList: StorageAllowList, undo: CleanUpUndoLog? = nil) -> Bool {
    var changed = false
    for content in item.contents where sanitize(content, of: item, to: allowList, undo: undo) {
      changed = true
    }
    return changed
  }

  private func sanitize(
    _ content: HistoryItemContent,
    of item: HistoryItem,
    to allowList: StorageAllowList,
    undo: CleanUpUndoLog?
  ) -> Bool {
    let type = NSPasteboard.PasteboardType(content.type)
    let admission: StorageAllowList.Admission
    if !allowList.allows(type) {
      admission = .drop
    } else if StoragePolicy.metadataTypes.contains(type) {
      admission = allowList.admission(of: type, value: content.value)
    } else {
      return false
    }

    switch admission {
    case .drop:
      undo?.recordContents(of: item)
      item.contents.removeAll { $0 === content }
      if content.modelContext != nil {
        context.delete(content)
      }
      return true
    case .store(let value) where value != content.value:
      undo?.recordValue(of: content)
      content.value = value
      return true
    case .store:
      return false
    }
  }

  // An error's category for logs: never its description, which could quote
  // stored content.
  nonisolated static func errorCategory(_ error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.removeScalarsUnsafeForTitleLayout() {
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    stopCompaction()
    try context.save()

    return count
  }
}

// What a failed clean-up puts back: each value as it was before its first
// change, recorded once per object and property, and restored in reverse.
@MainActor
final class CleanUpUndoLog {
  private struct Key: Hashable {
    let object: ObjectIdentifier
    let property: String
  }

  private var recorded: Set<Key> = []
  private var restorers: [() -> Void] = []

  func recordContents(of item: HistoryItem) {
    recordOnce(item, "contents") {
      let contents = item.contents
      return {
        item.contents = contents
        item.clearDecodedImageCache()
      }
    }
  }

  func recordTitle(of item: HistoryItem) {
    recordOnce(item, "title") {
      let snapshot = item.titleSnapshot
      return { item.restoreTitle(snapshot) }
    }
  }

  func recordValue(of content: HistoryItemContent) {
    recordOnce(content, "value") {
      let value = content.value
      return { content.value = value }
    }
  }

  func restore() {
    restorers.reversed().forEach { $0() }
  }

  // `capture` reads the current value and returns what puts it back. It runs
  // only the first time an object's property is recorded. The restorer keeps
  // the object alive, so its identifier is not reused meanwhile.
  private func recordOnce(_ object: AnyObject, _ property: String, _ capture: () -> () -> Void) {
    guard recorded.insert(Key(object: ObjectIdentifier(object), property: property)).inserted else {
      return
    }
    restorers.append(capture())
  }
}

// What one clean-up did. Counts only, so it can be logged.
struct StorageCleanUpResult {
  var impact = StorageCleanUpImpact()
  var markersNormalised = 0
  var orphansRemoved = 0
  // Items kept but changed, for the caller to refresh what it shows.
  var changedItems: [HistoryItem] = []
  var removedItems: [HistoryItem] = []

  var hasChanges: Bool { impact.affectsHistory || markersNormalised > 0 || orphansRemoved > 0 }

  var logMessage: String {
    "Applied storage settings to history: \(impact.itemsLosingData) items lost data, " +
      "\(impact.itemsRemoved) items removed, \(markersNormalised) markers normalised, " +
      "\(orphansRemoved) orphaned contents removed"
  }
}

// A compaction failure: the SQLite result code only.
nonisolated struct StorageCompactionError: CustomNSError {
  static let errorDomain = "MaccyStorageCompaction"
  let code: Int32

  var errorCode: Int { Int(code) }

  // Stopped by a save or a deadline; SQLite rolled it back.
  static let interrupted = StorageCompactionError(code: SQLITE_INTERRUPT)
  var isInterrupted: Bool { code == SQLITE_INTERRUPT }
}

// One compaction on its own SQLite connection. `run()` may run on any
// thread; `cancel()`, `waitUntilStoreReleased()` and `waitUntilFinished()`
// may be called from another one.
//
// It is a full VACUUM, done in two halves so that a save never waits long:
// 1. The WAL is checkpointed and truncated, and the store is rebuilt into a
//    new file next to it (`VACUUM INTO`): every live row is written into
//    fresh pages; nothing deleted is copied.
// 2. That file is copied back over the store with SQLite's backup API, in
//    steps of `pagesPerStep` pages, in one write transaction, which commits
//    at the end. This is what VACUUM itself does in its last phase, but
//    there in a single call that can't be interrupted (measured: up to about
//    7 s for a 1 GB store, see the PR).
// Then the WAL, which now holds the rebuilt pages, is checkpointed into the
// database file; the file is truncated to the rebuilt size. Old pages, with
// whatever deleted bytes they held, are overwritten or cut off.
//
// A save stops the compaction first (`Storage.stopCompaction`): `cancel()`
// sets a flag and calls `sqlite3_interrupt` on the connection (safe from
// another thread; the connection is withdrawn under the same lock before it
// is closed). The interrupt stops the statement in progress; the progress
// handler (every `progressSteps` VM instructions) and the busy handler check
// the flag and the deadline too, and the copy checks them between steps.
// The save then waits only while the compaction holds the store
// (`holdsStore`): during the first checkpoint and during the copy, which
// write to it. A copy that is stopped is rolled back
// (`sqlite3_backup_finish`) within one step. The rebuild only reads the
// store, so a save doesn't wait for it to wind down; the rebuild is
// abandoned, and the compaction can't take the store again once cancelled.
// A stopped compaction leaves the store as it was and throws
// `StorageCompactionError.interrupted`.
//
// Any write committed after the rebuild began would be lost by the copy, so
// the copy first takes the write lock and checks `PRAGMA data_version` on a
// separate connection; if anything was committed it is abandoned. After the
// copy has committed, the checkpoint runs in PASSIVE mode, which doesn't
// block SwiftData's reads or writes; a cancel no longer stops it, only the
// deadline does.
// A busy database is waited for up to `busyTimeout`, then reported as
// SQLITE_BUSY.
nonisolated final class StorageCompaction: @unchecked Sendable {
  enum Phase: Hashable, Sendable {
    case rebuilding
    case copyingBack
  }

  static let busyTimeout: TimeInterval = 2
  static let progressSteps: Int32 = 100
  // 1 MB with the 4 KB pages Core Data uses.
  static let pagesPerStep: Int32 = 256

  private let url: URL
  private let deadline: TimeInterval?
  private let lock = NSLock()
  private var cancelled = false
  // The connection `cancel()` interrupts: withdrawn once the copy has
  // committed, and before it is closed. Guarded by `lock`.
  private var interruptible: OpaquePointer?
  // Whether a save must wait. Guarded by `lock`; changes are signalled on
  // `storeReleased`.
  private var holdsStore = false
  private let storeReleased = NSCondition()
  private let finished = DispatchSemaphore(value: 0)

  #if DEBUG
  // Tests: called on the compaction's thread, once per phase, while it is
  // under way (from the progress handler while rebuilding, after the first
  // step of the copy).
  var phaseHandlerForTesting: (@Sendable (StorageCompaction, Phase) -> Void)?
  private var reportedPhases: Set<Phase> = []
  #endif

  init(url: URL, deadline: TimeInterval?) {
    self.url = url
    self.deadline = deadline
  }

  // The rebuilt copy, next to the store. Holds history while it exists: it
  // is deleted when the compaction ends, and before each one starts.
  static func copyURL(for url: URL) -> URL {
    url.deletingLastPathComponent().appending(path: url.lastPathComponent + "-compacting")
  }

  static func removeCopy(of url: URL) {
    let copy = copyURL(for: url).path
    for path in [copy, copy + "-journal", copy + "-wal", copy + "-shm"] {
      unlink(path)
    }
  }

  func cancel() {
    lock.withLock {
      cancelled = true
      if let interruptible {
        sqlite3_interrupt(interruptible)
      }
    }
  }

  var isCancelled: Bool { lock.withLock { cancelled } }

  private var isPastDeadline: Bool {
    deadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
  }

  var shouldStop: Bool { isCancelled || isPastDeadline }

  // Returns once a save may proceed: the compaction doesn't hold the store,
  // and after `cancel()` it can't take it again.
  func waitUntilStoreReleased() {
    storeReleased.lock()
    while lock.withLock({ holdsStore }) {
      storeReleased.wait()
    }
    storeReleased.unlock()
  }

  func waitUntilFinished() {
    finished.wait()
    finished.signal()
  }

  // Whether it finished within `timeout` seconds.
  func waitUntilFinished(timeout: TimeInterval) -> Bool {
    guard finished.wait(timeout: .now() + max(0, timeout)) == .success else {
      return false
    }
    finished.signal()
    return true
  }

  func runInBackground() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .utility).async {
        do {
          try self.run()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func run() throws {
    defer { finished.signal() }
    guard !shouldStop else {
      throw StorageCompactionError.interrupted
    }

    Self.removeCopy(of: url)
    defer { Self.removeCopy(of: url) }

    let database = try open(url, flags: SQLITE_OPEN_READWRITE)
    defer {
      lock.withLock { interruptible = nil }
      sqlite3_close_v2(database)
    }
    lock.withLock { interruptible = database }
    // Sees commits made by any other connection (`PRAGMA data_version`).
    let watcher = try open(url, flags: SQLITE_OPEN_READONLY)
    defer { sqlite3_close_v2(watcher) }

    // The copy's commit doesn't wait for the WAL to reach the disk (that
    // would hold the store for as long as syncing the whole rebuilt database
    // takes); the checkpoint syncs it before writing the database file. A
    // power loss before then loses the copy, not the store: it is rolled
    // back, and the compaction stays pending.
    try execute("PRAGMA synchronous = NORMAL", in: database)
    // Pages the copy writes go to the WAL as it goes (once 256 are dirty),
    // not all at its commit: that would hold the store for ~0.3 s.
    try execute("PRAGMA cache_spill = 256", in: database)
    let context = Unmanaged.passUnretained(self).toOpaque()
    sqlite3_busy_handler(database, { context, attempts in
      let job = Unmanaged<StorageCompaction>.fromOpaque(context!).takeUnretainedValue()
      guard !job.shouldStop, Double(attempts) * 0.01 < StorageCompaction.busyTimeout else {
        return 0
      }
      usleep(10_000)
      return 1
    }, context)
    sqlite3_progress_handler(database, Self.progressSteps, { context in
      let job = Unmanaged<StorageCompaction>.fromOpaque(context!).takeUnretainedValue()
      #if DEBUG
      job.reached(.rebuilding)
      #endif
      return job.shouldStop ? 1 : 0
    }, context)

    do {
      try holdingStore {
        try checkpoint(database, mode: SQLITE_CHECKPOINT_TRUNCATE)
      }
      let version = try integer("PRAGMA data_version", in: watcher)
      try stopIfCancelled()
      try rebuild(database)
      try stopIfCancelled()
      try holdingStore {
        try copyBack(into: database, unlessChangedSince: version, watcher: watcher)
      }
    } catch where shouldStop {
      throw StorageCompactionError.interrupted
    }
    // A cancel from now on doesn't interrupt; one that came during the last
    // step of the copy left SQLite's interrupt flag set, and a statement
    // started with none running clears it.
    lock.withLock { interruptible = nil }
    sqlite3_progress_handler(database, 0, nil, nil)
    try execute("SELECT 1", in: database)
    try checkpointEverything(database)
    // Empties the WAL if nobody is using it right now; it holds only rebuilt
    // pages either way.
    sqlite3_busy_handler(database, nil, nil)
    sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
  }

  private func rebuild(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(database, "VACUUM INTO ?", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    guard prepared == SQLITE_OK else {
      throw StorageCompactionError(code: prepared)
    }
    let copy = Self.copyURL(for: url).path
    sqlite3_bind_text(statement, 1, copy, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    let stepped = sqlite3_step(statement)
    guard stepped == SQLITE_DONE else {
      throw StorageCompactionError(code: stepped)
    }
  }

  private func copyBack(into database: OpaquePointer, unlessChangedSince version: Int32, watcher: OpaquePointer) throws {
    let source = try open(Self.copyURL(for: url), flags: SQLITE_OPEN_READONLY)
    defer { sqlite3_close_v2(source) }
    guard let backup = sqlite3_backup_init(database, "main", source, "main") else {
      throw StorageCompactionError(code: sqlite3_errcode(database))
    }
    var finished = false
    defer {
      // Rolls back a copy that didn't finish.
      if !finished {
        sqlite3_backup_finish(backup)
      }
    }

    // One page first: the write lock is held from here until the end.
    var stepped = sqlite3_backup_step(backup, 1)
    if stepped == SQLITE_OK {
      // Anything committed since the rebuild began would be overwritten.
      guard try integer("PRAGMA data_version", in: watcher) == version else {
        throw StorageCompactionError.interrupted
      }
    }
    while stepped == SQLITE_OK {
      #if DEBUG
      reached(.copyingBack)
      #endif
      try stopIfCancelled()
      stepped = sqlite3_backup_step(backup, Self.pagesPerStep)
    }
    finished = true
    let result = sqlite3_backup_finish(backup)
    guard stepped == SQLITE_DONE else {
      throw StorageCompactionError(code: stepped)
    }
    guard result == SQLITE_OK else {
      throw StorageCompactionError(code: result)
    }
  }

  // Copies every frame of the WAL into the database file without blocking
  // other connections, retrying while one of them is in the way.
  private func checkpointEverything(_ database: OpaquePointer) throws {
    var attempts = 0
    while true {
      var logFrames: Int32 = 0
      var checkpointedFrames: Int32 = 0
      let result = sqlite3_wal_checkpoint_v2(
        database, nil, SQLITE_CHECKPOINT_PASSIVE, &logFrames, &checkpointedFrames
      )
      guard result == SQLITE_OK else {
        throw StorageCompactionError(code: result)
      }
      if checkpointedFrames >= logFrames {
        return
      }
      attempts += 1
      guard !isPastDeadline, Double(attempts) * 0.01 < Self.busyTimeout else {
        throw StorageCompactionError(code: SQLITE_BUSY)
      }
      usleep(10_000)
    }
  }

  // Runs `body` holding the store, so a save waits for it. Not once
  // cancelled: a save that cancelled the compaction may already be under way.
  private func holdingStore(_ body: () throws -> Void) throws {
    try lock.withLock {
      guard !cancelled else {
        throw StorageCompactionError.interrupted
      }
      holdsStore = true
    }
    defer {
      storeReleased.lock()
      lock.withLock { holdsStore = false }
      storeReleased.broadcast()
      storeReleased.unlock()
    }
    try body()
  }

  #if DEBUG
  private func reached(_ phase: Phase) {
    guard let phaseHandlerForTesting, lock.withLock({ reportedPhases.insert(phase).inserted }) else {
      return
    }
    phaseHandlerForTesting(self, phase)
  }
  #endif

  private func stopIfCancelled() throws {
    if shouldStop {
      throw StorageCompactionError.interrupted
    }
  }

  private func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
    var database: OpaquePointer?
    let opened = sqlite3_open_v2(url.path, &database, flags, nil)
    guard opened == SQLITE_OK, let database else {
      sqlite3_close_v2(database)
      throw StorageCompactionError(code: opened)
    }
    return database
  }

  private func integer(_ sql: String, in database: OpaquePointer) throws -> Int32 {
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    guard prepared == SQLITE_OK else {
      throw StorageCompactionError(code: prepared)
    }
    let stepped = sqlite3_step(statement)
    guard stepped == SQLITE_ROW else {
      throw StorageCompactionError(code: stepped)
    }
    return sqlite3_column_int(statement, 0)
  }

  private func execute(_ sql: String, in database: OpaquePointer) throws {
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
      throw StorageCompactionError(code: result)
    }
  }

  private func checkpoint(_ database: OpaquePointer, mode: Int32) throws {
    var logFrames: Int32 = 0
    var checkpointedFrames: Int32 = 0
    let result = sqlite3_wal_checkpoint_v2(database, nil, mode, &logFrames, &checkpointedFrames)
    guard result == SQLITE_OK else {
      throw StorageCompactionError(code: result)
    }
  }
}
