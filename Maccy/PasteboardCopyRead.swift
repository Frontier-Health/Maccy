import AppKit

// Reads one copy from the pasteboard for the clipboard watcher, with bounded
// work before any limit is checked.
//
// 1. Which (pasteboard item, type) pairs are read is decided from type names
//    alone (`plan`): of each type the storage allow-list allows, the value of
//    the first item that has it; of file URLs, every item's, since a Finder
//    copy of several files has one item per file. Later items' values of a
//    type are never read here.
// 2. Each planned representation is read exactly once, and its size is
//    checked against `ContentLimits` (per representation and the running
//    total of the copy) as soon as it arrives, before it is decoded, trimmed
//    or scanned. Nothing more is read once a limit is passed.
// 3. Those bytes are kept and reused: for the blank-text check, the ignore
//    rules (`data(item:type:)`) and the record. The ignore rules read later
//    items' values themselves, within their own limits, and only when there
//    are rules.
//
// For plain text, `NSPasteboard.string(forType:)` joins every item's string
// with newlines; Maccy keeps only the first item's, so it never doubles text
// that apps (BBEdit, Edge) put in two items, and a multi-item copy can paste
// less from Maccy than a direct paste would (see README).
struct PasteboardCopyRead {
  struct Key: Hashable {
    let item: Int
    let type: NSPasteboard.PasteboardType
  }

  #if DEBUG
  // How many representations were read and how many were decoded (text
  // decoded, RTF imported or HTML scanned) here, so tests can check what
  // happens before the limits.
  nonisolated(unsafe) static var readsForTesting = 0
  nonisolated(unsafe) static var decodesForTesting = 0
  #endif

  // Markers stored empty whatever the copying app wrote
  // (`StorageAllowList.admission`): their data is never read.
  private static let markersStoredEmpty: Set<NSPasteboard.PasteboardType> = [.fromMaccy, .universalClipboard]

  // The planned representations, in order, with the bytes read.
  private(set) var values: [(key: Key, data: Data?)] = []
  // Values of a type a later item also offered, which are not read.
  private(set) var duplicatesDropped = 0
  // Set when a limit was passed; reading stopped there.
  private(set) var violation: ContentLimits.Violation?

  // Which representations to read, from type names alone.
  static func plan(
    _ itemTypes: [[NSPasteboard.PasteboardType]],
    storing allowList: StorageAllowList
  ) -> (keys: [Key], duplicatesDropped: Int) {
    var keys: [Key] = []
    var claimed = Set<NSPasteboard.PasteboardType>()
    var duplicates = 0
    for (index, types) in itemTypes.enumerated() {
      var seenInItem = Set<NSPasteboard.PasteboardType>()
      for type in types where allowList.allows(type) && seenInItem.insert(type).inserted {
        if type == .fileURL || claimed.insert(type).inserted {
          keys.append(Key(item: index, type: type))
        } else {
          duplicates += 1
        }
      }
    }
    return (keys, duplicates)
  }

  static func read(_ items: [NSPasteboardItem], storing allowList: StorageAllowList) -> PasteboardCopyRead {
    var copy = PasteboardCopyRead()
    let planned = plan(items.map(\.types), storing: allowList)
    copy.duplicatesDropped = planned.duplicatesDropped
    var tally = ContentLimits.Tally()
    for key in planned.keys {
      guard !markersStoredEmpty.contains(key.type) else {
        copy.values.append((key: key, data: nil))
        continue
      }
      let data = items[key.item].data(forType: key.type)
      #if DEBUG
      readsForTesting += 1
      #endif
      if let exceeded = tally.add(key.type, bytes: data?.count ?? 0) {
        copy.violation = exceeded
        return copy
      }
      copy.values.append((key: key, data: data))
    }
    return copy
  }

  // The bytes read for one representation, if it was planned.
  func data(item: Int, type: NSPasteboard.PasteboardType) -> Data? {
    values.first { $0.key == Key(item: item, type: type) }?.data
  }

  // What the record stores, from the bytes already read. An item whose plain
  // text is blank and has no rich text with content contributes nothing (as
  // before: such an item is not a copy worth recording). Every distinct file
  // URL is kept once.
  func contents(storing allowList: StorageAllowList) -> [HistoryItemContent] {
    let skippedItems = Set(values.compactMap { entry -> Int? in
      guard entry.key.type == .string, isBlank(entry.data), !hasRichText(inItem: entry.key.item) else {
        return nil
      }
      return entry.key.item
    })

    var contents: [HistoryItemContent] = []
    var fileURLs = Set<Data>()
    for (key, data) in values where !skippedItems.contains(key.item) {
      guard case .store(let value) = allowList.admission(of: key.type, value: data) else {
        continue
      }
      if key.type == .fileURL {
        // A file URL without data has nothing to paste.
        guard let value, fileURLs.insert(value).inserted else { continue }
      }
      contents.append(HistoryItemContent(type: key.type.rawValue, value: value))
    }
    return contents
  }

  // How many file URL values repeated an earlier one.
  var duplicateFileURLs: Int {
    let urls = values.filter { $0.key.type == .fileURL }.compactMap(\.data)
    return urls.count - Set(urls).count
  }

  private func isBlank(_ data: Data?) -> Bool {
    guard let data else {
      return true
    }
    #if DEBUG
    Self.decodesForTesting += 1
    #endif
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // Whether the item's planned RTF or HTML has text (or, for HTML, media).
  // RTF is imported only within RichTextImport's bounds; HTML is scanned,
  // never rendered, so nothing it refers to is loaded.
  private func hasRichText(inItem item: Int) -> Bool {
    if let rtf = data(item: item, type: .rtf) {
      #if DEBUG
      Self.decodesForTesting += 1
      #endif
      if let text = RichTextImport.text(fromRTF: rtf) {
        return !text.isEmpty
      }
    }

    if let html = data(item: item, type: .html) {
      #if DEBUG
      Self.decodesForTesting += 1
      #endif
      return ClipboardHTMLText.hasContent(html)
    }

    return false
  }
}
