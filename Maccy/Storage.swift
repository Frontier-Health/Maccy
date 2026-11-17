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
  // checkpointed and truncated, free pages are removed from the database file
  // (incremental vacuum, or VACUUM for a store without incremental
  // auto-vacuum), and the WAL is truncated again. Rows deleted before this
  // then no longer sit in the WAL or in free pages of the database file. See
  // `StorageCompaction`.
  //
  // This is NOT secure erasure. The file system decides where the old bytes
  // physically were and when they are overwritten; SSD wear levelling, APFS
  // snapshots, Time Machine and other backups are out of Maccy's control.
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
  // It runs on a background thread (a full VACUUM of a 1 GB store took 12 s
  // in a measurement; the incremental vacuum takes time in proportion to what
  // was deleted). It can't overlap a save of this store: autosave is off
  // while it runs, and every save through `save()` (and the other saves here)
  // first stops it with `stopCompaction()`, which interrupts it and waits
  // until its connection is closed. SQLite rolls an interrupted vacuum back,
  // leaving the database as it was, and it throws
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
    stopCompaction()
    try StorageCompaction(url: storeURL, deadline: deadline).run()
  }

  // Interrupts a compaction in progress and waits until its connection is
  // closed, so a save can't overlap it.
  func stopCompaction() {
    guard let job = runningCompaction else {
      return
    }
    job.cancel()
    job.waitUntilFinished()
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
  // Free pages were left after an incremental vacuum.
  static let freePagesRemain = StorageCompactionError(code: -1)
  var isInterrupted: Bool { code == SQLITE_INTERRUPT }
}

// One compaction on its own SQLite connection: checkpoint (TRUNCATE),
// incremental vacuum (or VACUUM), checkpoint. `run()` may run on any thread; `cancel()` and
// `waitUntilFinished()` may be called from another one. A progress handler
// and a busy handler stop it promptly once cancelled or past its deadline,
// and SQLite rolls back an interrupted VACUUM. A busy database is waited for
// up to `busyTimeout`, then reported as SQLITE_BUSY.
nonisolated final class StorageCompaction: @unchecked Sendable {
  static let busyTimeout: TimeInterval = 2

  private let url: URL
  private let deadline: TimeInterval?
  private let lock = NSLock()
  private var cancelled = false
  private let finished = DispatchSemaphore(value: 0)

  init(url: URL, deadline: TimeInterval?) {
    self.url = url
    self.deadline = deadline
  }

  func cancel() {
    lock.withLock { cancelled = true }
  }

  var shouldStop: Bool {
    lock.withLock { cancelled } || deadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
  }

  func waitUntilFinished() {
    finished.wait()
    finished.signal()
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

    var database: OpaquePointer?
    let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
    defer { sqlite3_close_v2(database) }
    guard opened == SQLITE_OK, let database else {
      throw StorageCompactionError(code: opened)
    }

    let context = Unmanaged.passUnretained(self).toOpaque()
    sqlite3_busy_handler(database, { context, attempts in
      let job = Unmanaged<StorageCompaction>.fromOpaque(context!).takeUnretainedValue()
      guard !job.shouldStop, Double(attempts) * 0.01 < StorageCompaction.busyTimeout else {
        return 0
      }
      usleep(10_000)
      return 1
    }, context)
    sqlite3_progress_handler(database, 10, { context in
      Unmanaged<StorageCompaction>.fromOpaque(context!).takeUnretainedValue().shouldStop ? 1 : 0
    }, context)

    do {
      try checkpoint(database)
      // Core Data creates its stores with incremental auto-vacuum. Then
      // every free page (where deleted rows were) is filled with a page moved
      // from the end of the file, and the file is truncated: the cost follows
      // what was deleted, not the size of the store. Otherwise a full VACUUM
      // rebuilds the file.
      if try integer("PRAGMA auto_vacuum", in: database) == 2 {
        try execute("PRAGMA incremental_vacuum", in: database)
        guard try integer("PRAGMA freelist_count", in: database) == 0 else {
          throw StorageCompactionError.freePagesRemain
        }
      } else {
        try execute("VACUUM", in: database)
      }
      try checkpoint(database)
    } catch where shouldStop {
      throw StorageCompactionError.interrupted
    }
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

  private func checkpoint(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(database, "PRAGMA wal_checkpoint(TRUNCATE)", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    guard prepared == SQLITE_OK else {
      throw StorageCompactionError(code: prepared)
    }
    let stepped = sqlite3_step(statement)
    guard stepped == SQLITE_ROW else {
      throw StorageCompactionError(code: stepped)
    }
    // The first column is 1 if the checkpoint could not complete.
    guard sqlite3_column_int(statement, 0) == 0 else {
      throw StorageCompactionError(code: SQLITE_BUSY)
    }
  }

  private func execute(_ sql: String, in database: OpaquePointer) throws {
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
      throw StorageCompactionError(code: result)
    }
  }
}
