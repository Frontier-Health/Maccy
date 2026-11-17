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
      fatalError("Cannot load database: \(error.localizedDescription).")
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

  // Brings every stored item in line with `allowList`, all or nothing:
  // representations it doesn't allow are deleted, metadata markers are
  // normalised, items left without any allowed content are deleted (pinned
  // ones too), and the derived titles of changed items are regenerated from
  // what survives. A title the user set is kept. Orphaned contents are deleted.
  //
  // Unrelated pending changes are saved first. The clean-up then runs with
  // autosave off and is saved once; if anything fails, including the save, the
  // context is rolled back and the store is left as it was. `beforeCommit`
  // runs just before the save; tests use it to inject a failure.
  @discardableResult
  func cleanUp(
    to allowList: StorageAllowList,
    beforeCommit: () throws -> Void = {}
  ) throws -> StorageCleanUpResult {
    if context.hasChanges {
      try context.save()
    }

    let autosaveEnabled = context.autosaveEnabled
    context.autosaveEnabled = false
    defer { context.autosaveEnabled = autosaveEnabled }

    do {
      let result = try applyCleanUp(to: allowList)
      try beforeCommit()
      if context.hasChanges {
        try context.save()
      }
      return result
    } catch {
      context.rollback()
      throw error
    }
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

  private func applyCleanUp(to allowList: StorageAllowList) throws -> StorageCleanUpResult {
    let plan = try cleanUpPlan(for: allowList)
    var result = StorageCleanUpResult(impact: plan.impact)
    let removedIDs = Set(plan.itemsToRemove.map(\.persistentModelID))
    // Disallowed contents of items being removed, and of no item at all.
    let unattachedContents = plan.disallowedContents.filter { content in
      content.item.map { removedIDs.contains($0.persistentModelID) } ?? true
    }

    // Only items that lose data are read beyond their type names.
    for item in plan.itemsLosingData {
      let titleSourceBefore = item.titleSource(readableBy: .everything)
      sanitize(item, to: allowList)
      if !item.hasCustomTitle && item.titleSource(readableBy: allowList) != titleSourceBefore {
        item.title = item.generateTitle(readableBy: allowList)
      }
      item.clearDecodedImageCache()
      result.changedItems.append(item)
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
      if sanitize(content, of: item, to: allowList) {
        result.markersNormalised += 1
      }
    }

    context.processPendingChanges()
    let orphans = try context.fetch(FetchDescriptor<HistoryItemContent>(predicate: #Predicate<HistoryItemContent> { $0.item == nil }))
    orphans.forEach(context.delete)
    result.orphansRemoved = orphans.count
    context.processPendingChanges()

    return result
  }

  // Removes or normalises the representations of one item that `allowList`
  // doesn't allow as stored. Works on items not yet in the store too. Reads
  // the stored value only of metadata markers, which are normalised. Returns
  // whether anything changed. The item itself is kept.
  @discardableResult
  func sanitize(_ item: HistoryItem, to allowList: StorageAllowList) -> Bool {
    var changed = false
    for content in item.contents where sanitize(content, of: item, to: allowList) {
      changed = true
    }
    return changed
  }

  private func sanitize(_ content: HistoryItemContent, of item: HistoryItem, to allowList: StorageAllowList) -> Bool {
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
      item.contents.removeAll { $0 === content }
      if content.modelContext != nil {
        context.delete(content)
      }
      return true
    case .store(let value) where value != content.value:
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

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
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

// What one clean-up did. Counts only, so it can be logged.
struct StorageCleanUpResult {
  var impact = StorageCleanUpImpact()
  var markersNormalised = 0
  var orphansRemoved = 0
  // Items kept but changed, for the caller to refresh what it shows.
  var changedItems: [HistoryItem] = []

  var hasChanges: Bool { impact.affectsHistory || markersNormalised > 0 || orphansRemoved > 0 }

  var logMessage: String {
    "Applied storage settings to history: \(impact.itemsLosingData) items lost data, " +
      "\(impact.itemsRemoved) items removed, \(markersNormalised) markers normalised, " +
      "\(orphansRemoved) orphaned contents removed"
  }
}
