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

  // Brings every stored item in line with `policy`: representations it doesn't
  // allow are deleted, metadata is normalised, items left without any enabled
  // content are deleted, and the titles of changed items are regenerated so they
  // no longer show removed content. Orphaned contents are deleted too. Returns
  // the number of items changed or deleted plus orphans removed.
  @discardableResult
  func enforce(_ policy: StoragePolicy) throws -> Int {
    var changes = 0
    for item in try context.fetch(FetchDescriptor<HistoryItem>()) where enforce(policy, on: item) {
      changes += 1
      if policy.hasStorableContent(item.contents.map { NSPasteboard.PasteboardType($0.type) }) {
        item.title = item.generateTitle()
      } else {
        item.contents.forEach(context.delete)
        context.delete(item)
      }
    }

    context.processPendingChanges()
    changes += try cleanupOrphanedContents()
    if changes > 0 {
      try context.save()
    }

    return changes
  }

  // Deletes or normalises the contents of one item that `policy` doesn't allow
  // as stored. Returns whether anything changed. The item itself is kept.
  @discardableResult
  func enforce(_ policy: StoragePolicy, on item: HistoryItem) -> Bool {
    var changed = false
    for content in item.contents {
      switch policy.admission(of: NSPasteboard.PasteboardType(content.type), value: content.value) {
      case .drop:
        item.contents.removeAll { $0 === content }
        context.delete(content)
        changed = true
      case .store(let value) where value != content.value:
        content.value = value
        changed = true
      case .store:
        break
      }
    }

    return changed
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
