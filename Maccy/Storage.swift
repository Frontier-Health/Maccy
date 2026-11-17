import AppKit.NSPasteboard
import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(Notifier.redacted(error)).")
    }
  }

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
  #endif

  // Saves the context. Every save that can carry history content goes
  // through here, so tests can make it fail.
  func save() throws {
    #if DEBUG
    if let saveFailureForTesting {
      throw saveFailureForTesting
    }
    #endif
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
