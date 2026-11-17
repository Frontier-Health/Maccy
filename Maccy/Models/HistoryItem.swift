import AppKit
import Defaults
import Sauce
import SwiftData
import Vision

@Model
class HistoryItem {
  @MainActor
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    // "," reserved for preferences
    // "`" reserved for cycling through windows
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y",
      "[", "]", ";", "'", ".", "/", "-", "=", "\\"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    return keys
  }

  // Letters first, then symbols.
  static func sortedPins(_ pins: some Sequence<String>) -> [String] {
    pins.sorted { lhs, rhs in
      let lhsIsLetter = lhs.first?.isLetter ?? false
      let rhsIsLetter = rhs.first?.isLetter ?? false
      return lhsIsLetter == rhsIsLetter ? lhs < rhs : lhsIsLetter
    }
  }

  @MainActor
  static var availablePins: [String] {
    History.shared.availablePins
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  // The stored title. Not read outside this file: everything that shows a
  // title goes through `displayTitle`, which checks it against the storage
  // policy first. Set only through `setTitle(_:source:)`.
  private var title = ""
  // What `title` was made from (a raw `HistoryItemTitleSource`), recorded
  // whenever the title is set. Rows stored before it existed read as unknown.
  private var titleSourceValue = HistoryItemTitleSource.unknown.rawValue

  /// Opaque identifier used for this item's delivered notification. Random, never derived from content.
  @Transient var notificationID = UUID().uuidString

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  // What `ValidatedImage.inspect` found for the image read now, and which
  // image that was, so a result for a representation that has since been
  // removed or disallowed is never used. Nothing decoded is kept here: the
  // decorators keep the thumbnail and preview they asked for.
  @Transient private var cachedImageInspection: ImageInspectionCache?
  // The Universal Clipboard image file, once `loadImageIfNeeded()` has read
  // it off the main thread (nil data: it failed a check).
  @Transient private var universalClipboardFileData: UniversalClipboardFileData?
  // The read of that file in progress, shared by everything waiting for it.
  @Transient private var universalClipboardFileLoad: UniversalClipboardFileLoad?
  // Raised by `clearDecodedImageCache()`. A load or decode that started under
  // an earlier value is discarded when it completes.
  @Transient private var imageGeneration = 0

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
    self.titleSourceValue = HistoryItemTitleSource.nothing.rawValue
  }

  // Whether this item already holds everything `item` holds. Compared by the
  // value each type is read as (see `canonicalContent(ofType:)`), so an older
  // item with several values of one type only supersedes a copy of the value
  // it shows and pastes.
  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        if content.type == NSPasteboard.PasteboardType.fileURL.rawValue {
          return contents.contains(where: { $0.type == content.type && $0.value == content.value })
        }
        return canonicalContent(ofType: content.type)?.value == content.value
      }
  }

  // MARK: One value per type
  //
  // A copy is stored with at most one value per type (see
  // `Clipboard.checkForChangesInPasteboard()`), except `public.file-url`, which
  // holds one value per copied file. Items stored before that rule may hold
  // several values of one type. The store doesn't keep their order, so the one
  // used is chosen from the values alone: the smallest by bytes. Every reader
  // (title, preview, editor, Get) and copy-back use that same value.

  func canonicalContent(ofType type: String) -> HistoryItemContent? {
    Self.canonical(contents.filter { $0.type == type })
  }

  static func canonical(_ candidates: [HistoryItemContent]) -> HistoryItemContent? {
    guard candidates.count > 1 else {
      return candidates.first
    }

    return candidates.min { lhs, rhs in
      switch (lhs.value, rhs.value) {
      case (.some(let left), .some(let right)):
        return left.lexicographicallyPrecedes(right)
      case (.some, .none):
        return true
      default:
        return false
      }
    }
  }

  // Whether the item holds more than one value of `type`.
  func hasSeveralValues(ofType type: String) -> Bool {
    contents.lazy.filter { $0.type == type }.prefix(2).count > 1
  }

  // What copy-back writes: the one value of each type `allowList` lets Maccy
  // read, plus every distinct copied file, in a stable order.
  func pasteboardContents(readableBy allowList: StorageAllowList) -> [HistoryItemContent] {
    let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
    let types = Set(contents.map(\.type))
      .filter { $0 != fileURLType && allowList.allows(NSPasteboard.PasteboardType($0)) }
      .sorted()
    var result = types.compactMap { canonicalContent(ofType: $0) }
    if allowList.allows(.fileURL) {
      var seen = Set<Data?>()
      for content in contents where content.type == fileURLType && seen.insert(content.value).inserted {
        result.append(content)
      }
    }
    return result
  }

  // MARK: Titles
  //
  // A title records where it came from: the user (an alias), one stored
  // representation type, or nothing. Nothing infers the source from the
  // current contents. `displayTitle` shows the stored title only while that
  // source may be read; otherwise it shows a title made from what may be read
  // now, so a title made from data the storage policy excludes is never shown,
  // whether or not the clean-up has removed that data yet.

  var titleSource: HistoryItemTitleSource { HistoryItemTitleSource(rawValue: titleSourceValue) }

  // The only place a title is assigned.
  func setTitle(_ newTitle: String, source: HistoryItemTitleSource) {
    title = newTitle
    titleSourceValue = source.rawValue
  }

  // A title the user typed. An empty one goes back to a derived title.
  @MainActor
  func setAlias(_ alias: String) {
    if alias.isEmpty {
      regenerateTitle()
    } else {
      setTitle(alias, source: .user)
    }
  }

  // Takes over another item's title and its recorded source, as a duplicate
  // merge does. `reconcileTitle` then checks it against this item's contents.
  func adoptTitle(of other: HistoryItem) {
    setTitle(other.title, source: other.titleSource)
  }

  // The title that may be shown under `allowList`: the stored one if its
  // source is the user or a type `allowList` allows that the item still has;
  // otherwise one made now from what may be read (never recognising image
  // text), or a placeholder when nothing on the item may be read.
  @MainActor
  var displayTitle: String { displayTitle(readableBy: StoragePolicy.currentReadAllowList) }
  @MainActor
  func displayTitle(readableBy allowList: StorageAllowList) -> String {
    if titleSource == .user {
      return title
    }

    guard allowList.hasStorableContent(contents.map { NSPasteboard.PasteboardType($0.type) }) else {
      return Self.hiddenTitle
    }

    // Text recognised in an image is not shown while recognition is off.
    if storedTitleIsReadable(by: allowList) && !(titleIsRecognizedText(readableBy: allowList) &&
                                                  !OCRSetting.current.isEnabled) {
      return title
    }

    return generateTitle(readableBy: allowList)
  }

  static var hiddenTitle: String {
    NSLocalizedString("HiddenItemTitle", value: "Content not shown", comment: "")
  }

  // Makes the title again from what `allowList` lets Maccy read and records
  // its source. An image's title is recognised asynchronously and is "" until
  // then.
  @MainActor
  func regenerateTitle(
    readableBy allowList: StorageAllowList = StoragePolicy.currentReadAllowList,
    recognizingImageText: Bool = true
  ) {
    if let imageSource = imageSource(readableBy: allowList) {
      setTitle("", source: imageSource.titleSource)
      // With recognition off, an image's title stays empty and no image is
      // passed to Vision.
      if recognizingImageText && OCRSetting.current.isEnabled {
        recognizeTitle(from: imageSource)
      }
      return
    }

    guard let found = titleText(readableBy: allowList) else {
      setTitle("", source: .nothing)
      return
    }

    setTitle(Self.formatTitle(found.text), source: .content(found.type))
  }

  // After the contents changed or a storage policy was applied: a derived
  // title whose source `allowList` doesn't allow, or which the item no longer
  // has, is made again from what it does allow. A title of unknown source is
  // made again when the contents changed. Returns whether it was.
  @MainActor
  @discardableResult
  func reconcileTitle(
    readableBy allowList: StorageAllowList,
    contentsChanged: Bool,
    recognizingImageText: Bool = true
  ) -> Bool {
    guard titleSource != .user,
          !storedTitleIsReadable(by: allowList, contentsChanged: contentsChanged) else {
      return false
    }

    regenerateTitle(readableBy: allowList, recognizingImageText: recognizingImageText)
    return true
  }

  // When "show special symbols" changes: a title derived from text is made
  // again. Aliases and image titles are kept.
  @MainActor
  func regenerateTitleForSpecialSymbols() {
    switch titleSource {
    case .user, .universalClipboardImage:
      return
    case .content(let type) where StorageType.images.types.contains(NSPasteboard.PasteboardType(type)):
      return
    case .unknown where imageSource(readableBy: StoragePolicy.currentReadAllowList) != nil:
      return
    default:
      regenerateTitle(recognizingImageText: false)
    }
  }

  // Whether the stored title came from something `allowList` lets Maccy read
  // that the item still has. A title of unknown source predates recorded
  // sources; an item stored then was never stripped, so its title came from
  // its contents or the user, and it is shown while every one of its
  // representations may be read and the contents haven't just changed.
  private func storedTitleIsReadable(by allowList: StorageAllowList, contentsChanged: Bool = false) -> Bool {
    switch titleSource {
    case .user:
      return true
    case .content(let type):
      // A title made from one of several values of a type may not be the
      // value read now; it is made again from that one.
      return allowList.allows(NSPasteboard.PasteboardType(type)) && contents.contains { $0.type == type } &&
        (type == NSPasteboard.PasteboardType.fileURL.rawValue || !hasSeveralValues(ofType: type))
    case .universalClipboardImage:
      if case .universalClipboardFile = imageSource(readableBy: allowList) {
        return true
      }
      return false
    case .nothing:
      return false
    case .unknown:
      return !contentsChanged && contents.allSatisfy { allowList.allows(NSPasteboard.PasteboardType($0.type)) } &&
        !contents.contains {
          $0.type != NSPasteboard.PasteboardType.fileURL.rawValue && hasSeveralValues(ofType: $0.type)
        }
    }
  }

  // A derived title made only from representations `allowList` lets Maccy
  // read, without recording it or recognising image text. There is no
  // fallback to the previous title.
  @MainActor
  func generateTitle(readableBy allowList: StorageAllowList = StoragePolicy.currentReadAllowList) -> String {
    guard imageSource(readableBy: allowList) == nil, let found = titleText(readableBy: allowList) else {
      return ""
    }

    return Self.formatTitle(found.text)
  }

  // Applies the text recognised in an image as the title, unless the title no
  // longer comes from that image (the user set one, or it was made again from
  // something else), the image may no longer be read, or the item is gone.
  @MainActor
  @discardableResult
  func acceptRecognizedText(_ text: String, from source: HistoryItemImageSource) -> Bool {
    guard modelContext != nil, !isDeleted, titleSource == source.titleSource,
          OCRSetting.current.isEnabled,
          imageSource(readableBy: StoragePolicy.currentReadAllowList) == source else {
      return false
    }

    setTitle(text, source: source.titleSource)
    return true
  }

  // Whether the stored title is (or may be) text recognised in an image: its
  // recorded source is an image, or it predates recorded sources and the item
  // has an image.
  func titleIsRecognizedText(readableBy allowList: StorageAllowList = .everything) -> Bool {
    switch titleSource {
    case .universalClipboardImage:
      return true
    case .content(let type):
      return StorageType.images.types.contains(NSPasteboard.PasteboardType(type))
    case .unknown:
      return imageSource(readableBy: allowList) != nil ||
        contents.contains { StorageType.images.types.contains(NSPasteboard.PasteboardType($0.type)) }
    case .user, .nothing:
      return false
    }
  }

  // Empties a title recognised in an image, keeping its source, as when
  // recognition is off. Returns whether the title changed.
  @discardableResult
  func eraseRecognizedTitle() -> Bool {
    guard titleIsRecognizedText(), !title.isEmpty else {
      return false
    }
    setTitle("", source: titleSource)
    return true
  }

  // Heals a title stored before unsafe scalars were removed on generation.
  // The source is unchanged. Returns whether the title changed.
  @MainActor
  func removeScalarsUnsafeForTitleLayout() -> Bool {
    guard title.containsScalarsUnsafeForTitleLayout else {
      return false
    }

    setTitle(title.removingScalarsUnsafeForTitleLayout(), source: titleSource)
    return true
  }

  // The stored title and its source, so the storage clean-up can put them
  // back if it fails. Opaque outside this file.
  struct TitleSnapshot: Equatable {
    fileprivate let title: String
    fileprivate let source: String
  }

  var titleSnapshot: TitleSnapshot { TitleSnapshot(title: title, source: titleSourceValue) }

  func restoreTitle(_ snapshot: TitleSnapshot) {
    title = snapshot.title
    titleSourceValue = snapshot.source
  }

  @MainActor
  private func recognizeTitle(from source: HistoryItemImageSource) {
    let imageData: Data?
    let fileURL: URL?
    switch source {
    case .content:
      imageData = self.imageData(from: source)
      fileURL = nil
    case .universalClipboardFile(let url):
      imageData = nil
      fileURL = url
    }

    #if DEBUG
    Self.recognitionStartsForTesting += 1
    #endif
    let job = TextRecognitionJob()
    Self.pendingTextRecognition[ObjectIdentifier(job)] = job
    let task = Task {
      let recognizedText = await Self.recognizeText(imageData: imageData, fileURL: fileURL, job: job)
      Self.pendingTextRecognition[ObjectIdentifier(job)] = nil
      if let recognizedText, !job.isCancelled {
        self.acceptRecognizedText(recognizedText, from: source)
      }
    }
    #if DEBUG
    Self.recognitionTasksForTesting.append(task)
    #else
    _ = task
    #endif
  }

  // Recognitions queued or running. Cancelled together when text recognition
  // is turned off or images may no longer be read.
  @MainActor private static var pendingTextRecognition: [ObjectIdentifier: TextRecognitionJob] = [:]

  // Stops every queued recognition before it decodes anything or reaches
  // Vision, cancels a Vision request already running, and discards results.
  @MainActor
  static func cancelAllTextRecognition() {
    let jobs = pendingTextRecognition.values
    pendingTextRecognition = [:]
    jobs.forEach { $0.cancel() }
  }

  @MainActor
  private static func formatTitle(_ text: String) -> String {
    // 1k characters is trade-off for performance
    var title = text
      .shortened(to: 1_000)
      .removingScalarsUnsafeForTitleLayout()

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  // The text a title or preview is made from, and its type: file paths, else
  // plain text, else rich text, else HTML.
  @MainActor
  private func titleText(readableBy allowList: StorageAllowList) -> (type: String, text: String)? {
    let urls = fileURLs(readableBy: allowList)
    if !urls.isEmpty, let content = firstContent([.fileURL], readableBy: allowList) {
      let text = urls
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
      return (content.type, text)
    }

    if let content = firstContent([.string], readableBy: allowList),
       let text = content.value.flatMap({ String(data: $0, encoding: .utf8) }), !text.isEmpty {
      return (content.type, text)
    }

    // Bounded RTF import; HTML is scanned, never rendered (see RichTextImport).
    if let content = firstContent([.rtf], readableBy: allowList),
       let text = content.value.flatMap(RichTextImport.text(fromRTF:)),
       !text.isEmpty {
      return (content.type, text)
    }

    if let content = firstContent([.html], readableBy: allowList),
       let text = content.value.flatMap(RichTextImport.text(fromHTML:)),
       !text.isEmpty {
      return (content.type, text)
    }

    return nil
  }

  // Shown in the preview and the menu bar. Falls back to the title that may
  // be shown, which for an image is the recognised text.
  @MainActor
  var previewableText: String {
    let allowList = StoragePolicy.currentReadAllowList
    return titleText(readableBy: allowList)?.text ?? displayTitle(readableBy: allowList)
  }

  // The plain text a text destination receives from an item that the title,
  // preview and editor show as files or an image: a plain paste, a text field
  // and the Get intent's text all get this, not the files or the image, so the
  // preview shows it too. Nil when there are no files or image, or no text.
  @MainActor
  func textPastedInsteadOfShownContent(
    readableBy allowList: StorageAllowList = StoragePolicy.currentReadAllowList
  ) -> String? {
    guard !fileURLs(readableBy: allowList).isEmpty || imageSource(readableBy: allowList) != nil,
          let text = text(readableBy: allowList), !text.isEmpty else {
      return nil
    }
    return text
  }

  // Whether that text is something other than the names or paths of the
  // item's own files (as Finder writes them): then a text destination gets
  // text the preview doesn't otherwise show, and it warns.
  @MainActor
  func pastedTextIsNotFileNames(readableBy allowList: StorageAllowList = StoragePolicy.currentReadAllowList) -> Bool {
    guard let text = textPastedInsteadOfShownContent(readableBy: allowList) else {
      return false
    }
    return !Self.isFileNamesOrPaths(text, of: fileURLs(readableBy: allowList))
  }

  // `text`, with line endings made "\n" and trailing whitespace ignored, is the
  // file names (last path components) or full paths of `urls` joined by
  // newlines, or the name or path of one of them (a copy of several pasteboard
  // items keeps the first item's text, which is one file's).
  nonisolated static func isFileNamesOrPaths(_ text: String, of urls: [URL]) -> Bool {
    guard !urls.isEmpty else {
      return false
    }
    func normalized(_ value: String) -> String {
      var lines = value.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      while let last = lines.unicodeScalars.last, last.properties.isWhitespace {
        lines.unicodeScalars.removeLast()
      }
      return lines
    }
    let names = urls.map(\.lastPathComponent)
    let paths = urls.map(\.path)
    let candidates = [names.joined(separator: "\n"), paths.joined(separator: "\n")] + names + paths
    let shown = normalized(text)
    return candidates.contains { normalized($0) == shown }
  }

  // Whether a formatted paste could insert other text than the plain text
  // shown. Maccy shows the plain text when there is any; a formatted paste
  // delivers HTML or RTF, which the copying app may have made to say
  // something else. The text extracted from each (HTML scanned, never
  // rendered) is compared with the plain text after only
  // `RichTextImport.comparableText`. Equal extracted text is not proof that a
  // renderer shows the same, so it never yields an assurance: at best nothing
  // is said (`.noTextDifference`), and only when every formatted version
  // uses nothing beyond an allow-list of plain formatting
  // (`RichTextImport.htmlMayRenderDifferently`,
  // `RichTextImport.rtfFormattingMayRenderDifferently`); otherwise the result
  // is `.renderingNotChecked`, expected for most styled web and Office copies.
  @MainActor
  func formattedTextComparison(
    readableBy allowList: StorageAllowList = StoragePolicy.currentReadAllowList
  ) -> FormattedTextComparison {
    guard let plain = text(readableBy: allowList) else {
      return .notApplicable
    }

    // One entry per formatted version: its text (nil when it couldn't be
    // read) and whether it can render differently from that text.
    var formatted: [(text: String?, mayRenderDifferently: Bool)] = []
    if let html = htmlData(readableBy: allowList) {
      formatted.append((RichTextImport.text(fromHTML: html), RichTextImport.htmlMayRenderDifferently(html)))
    }
    if let rtf = rtfData(readableBy: allowList) {
      let inspected = RichTextImport.inspectRTF(rtf)
      formatted.append((inspected?.text, inspected?.mayRenderDifferently ?? true))
    }
    guard !formatted.isEmpty else {
      return .notApplicable
    }

    let shown = RichTextImport.comparableText(plain)
    var notChecked = false
    var renderingNotChecked = RichTextImport.containsInvisibleOrDirectionalScalars(plain)
    for version in formatted {
      guard let text = version.text else {
        notChecked = true
        continue
      }
      if RichTextImport.comparableText(text) != shown {
        return .differs
      }
      if version.mayRenderDifferently || RichTextImport.containsInvisibleOrDirectionalScalars(text) {
        renderingNotChecked = true
      }
    }
    if notChecked {
      return .notChecked
    }
    return renderingNotChecked ? .renderingNotChecked : .noTextDifference
  }

  // Whether the plain text holds characters that are invisible or change
  // text direction (see `RichTextImport.containsInvisibleOrDirectionalScalars`):
  // a terminal or form receives them although the preview can't show them.
  @MainActor
  func plainTextHasInvisibleCharacters(
    readableBy allowList: StorageAllowList = StoragePolicy.currentReadAllowList
  ) -> Bool {
    text(readableBy: allowList).map(RichTextImport.containsInvisibleOrDirectionalScalars) ?? false
  }

  // MARK: Reading contents
  //
  // Every accessor reads only the representations the current storage policy
  // lets Maccy read (`StoragePolicy.readAllowList`), so data stored under an
  // earlier policy is not shown, pasted or exported even before the clean-up
  // removes it, or if the clean-up failed.

  var fileURLs: [URL] { fileURLs(readableBy: StoragePolicy.currentReadAllowList) }
  func fileURLs(readableBy allowList: StorageAllowList) -> [URL] {
    guard !universalClipboardText(readableBy: allowList) else {
      return []
    }

    var seen = Set<Data>()
    return contents
      .filter { NSPasteboard.PasteboardType($0.type) == .fileURL && allowList.allows(.fileURL) }
      .compactMap { $0.value }
      .filter { seen.insert($0).inserted }
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { htmlData(readableBy: StoragePolicy.currentReadAllowList) }
  func htmlData(readableBy allowList: StorageAllowList) -> Data? { contentData([.html], readableBy: allowList) }

  // Image data comes only from an image type allowed now, never from another
  // stored image format.
  var imageData: Data? { imageData(readableBy: StoragePolicy.currentReadAllowList) }
  func imageData(readableBy allowList: StorageAllowList) -> Data? {
    imageSource(readableBy: allowList).flatMap(imageData(from:))
  }

  func imageSource(readableBy allowList: StorageAllowList) -> HistoryItemImageSource? {
    if let content = firstContent(Self.imageTypes, readableBy: allowList), content.value != nil {
      return .content(content.type, ObjectIdentifier(content))
    }

    if let url = universalClipboardImageURL(readableBy: allowList) {
      return .universalClipboardFile(url)
    }

    return nil
  }

  private func imageData(from source: HistoryItemImageSource) -> Data? {
    switch source {
    case .content(_, let id):
      return contents.first { ObjectIdentifier($0) == id }?.value
    case .universalClipboardFile(let url):
      // Never read here, on the caller's (main) thread: only what
      // `loadImageIfNeeded()` read in the background.
      guard let loaded = universalClipboardFileData, loaded.url == url else {
        return nil
      }
      return loaded.data
    }
  }

  // Reads a Universal Clipboard image file off the main thread, once per file,
  // so `imageData` and the decoders can use it. Does nothing for other
  // images. Concurrent callers share one read. `clearDecodedImageCache()`
  // cancels a read in progress, and a read that completes after it is
  // discarded.
  @MainActor
  func loadImageIfNeeded() async {
    // A cancelled caller (for example a preview cleaned up before its task
    // ran) starts no read.
    guard !Task.isCancelled,
          case .universalClipboardFile(let url) = imageSource(readableBy: StoragePolicy.currentReadAllowList),
          universalClipboardFileData?.url != url else {
      return
    }

    let load: UniversalClipboardFileLoad
    if let current = universalClipboardFileLoad, current.url == url {
      load = current
    } else {
      universalClipboardFileLoad?.cancel()
      load = UniversalClipboardFileLoad(url: url)
      universalClipboardFileLoad = load
    }
    let generation = imageGeneration
    let result = await load.value
    guard generation == imageGeneration, universalClipboardFileLoad === load, !isDeleted else {
      return
    }
    // A cancelled read says nothing about the file; the next request reads it.
    if case .failure(.cancelled) = result {
      universalClipboardFileLoad = nil
      return
    }
    let data = try? result.get()
    universalClipboardFileLoad = nil
    universalClipboardFileData = UniversalClipboardFileData(url: url, data: data)
  }

  // Whether the item's image is a Universal Clipboard file that was read and
  // is not available (access denied, or a check failed). The preview then
  // shows a neutral placeholder, never the file's path.
  @MainActor
  var universalClipboardImageIsUnavailable: Bool {
    guard case .universalClipboardFile(let url) = imageSource(readableBy: StoragePolicy.currentReadAllowList),
          let loaded = universalClipboardFileData, loaded.url == url else {
      return false
    }
    return loaded.data == nil
  }

  // What `ValidatedImage.inspect` found for the image that may be read now,
  // from its header alone: nil when there is no image, it isn't loaded yet,
  // or it is refused (too many images, too many pixels, unreadable).
  @MainActor
  var imageInspection: ValidatedImage.Inspection? {
    guard let source = imageSource(readableBy: StoragePolicy.currentReadAllowList),
          let data = imageData(from: source) else {
      return nil
    }
    if let cached = cachedImageInspection, cached.source == source {
      return cached.inspection
    }
    let inspection = try? ValidatedImage.inspect(data).get()
    cachedImageInspection = ImageInspectionCache(source: source, inspection: inspection)
    return inspection
  }

  // The pixel size of the image that would be decoded, without decoding it.
  @MainActor
  var imagePixelSize: NSSize? {
    imageInspection.map { NSSize(width: $0.width, height: $0.height) }
  }

  // The image that may be read now, decoded for `purpose` through
  // `ValidatedImage` off the main actor. Nil when there is none, it is
  // refused, the calling task was cancelled, or meanwhile the item was
  // deleted, its images were cleaned up, or the image may no longer be read.
  #if DEBUG
  // DIAGNOSTIC (temporary): which nil path `decodedImage` took, with the
  // identities involved.
  @MainActor static var decodedImageTraceForTesting: [String] = []
  @MainActor private func traceIdentities(_ label: String) {
    let ids = contents.map { "\($0.type)#\(ObjectIdentifier($0).hashValue)/\($0.persistentModelID.hashValue)" }
    Self.decodedImageTraceForTesting.append("\(label): contents=\(ids) source=\(String(describing: imageSource(readableBy: StoragePolicy.currentReadAllowList)))")
  }
  #endif

  @MainActor
  func decodedImage(for purpose: ValidatedImage.Purpose) async -> DecodedImage? {
    #if DEBUG
    Self.decodedImageTraceForTesting = []
    #endif
    guard !Task.isCancelled else {
      #if DEBUG
      Self.decodedImageTraceForTesting.append("nil: cancelled before load")
      #endif
      return nil
    }
    await loadImageIfNeeded()
    let generation = imageGeneration
    #if DEBUG
    traceIdentities("before decode")
    #endif
    guard !Task.isCancelled, !isDeleted,
          let source = imageSource(readableBy: StoragePolicy.currentReadAllowList),
          let data = imageData(from: source) else {
      #if DEBUG
      Self.decodedImageTraceForTesting.append(
        "nil: before decode cancelled=\(Task.isCancelled) deleted=\(isDeleted) " +
        "source=\(imageSource(readableBy: StoragePolicy.currentReadAllowList) != nil)")
      #endif
      return nil
    }

    let decoded = await ValidatedImage.decode(data, for: purpose)
    #if DEBUG
    traceIdentities("after decode")
    if decoded == nil { Self.decodedImageTraceForTesting.append("nil: decode failed") }
    #endif
    guard !Task.isCancelled, generation == imageGeneration, !isDeleted,
          imageSource(readableBy: StoragePolicy.currentReadAllowList) == source else {
      #if DEBUG
      Self.decodedImageTraceForTesting.append(
        "nil: after decode cancelled=\(Task.isCancelled) generation=\(generation == imageGeneration) " +
        "deleted=\(isDeleted) sameSource=\(imageSource(readableBy: StoragePolicy.currentReadAllowList) == source) " +
        "storageHasChanges=\(Storage.shared.context.hasChanges)")
      #endif
      return nil
    }
    return decoded
  }

  var rtfData: Data? { rtfData(readableBy: StoragePolicy.currentReadAllowList) }
  func rtfData(readableBy allowList: StorageAllowList) -> Data? { contentData([.rtf], readableBy: allowList) }

  // Forgets the image's inspection and the Universal Clipboard file read,
  // cancels a read in progress, and makes every load and decode still in
  // flight discard its result.
  func clearDecodedImageCache() {
    imageGeneration += 1
    cachedImageInspection = nil
    universalClipboardFileLoad?.cancel()
    universalClipboardFileLoad = nil
    universalClipboardFileData = nil
  }

  var text: String? { text(readableBy: StoragePolicy.currentReadAllowList) }
  func text(readableBy allowList: StorageAllowList) -> String? {
    guard let data = contentData([.string], readableBy: allowList) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  // Replaces the item's contents with edited plain text. Every other
  // representation is deleted, not just detached, so the pre-edit content does
  // not linger in the store, nor in a derived title. Does nothing and returns
  // false unless the policy is valid and allows storing plain text.
  @MainActor
  @discardableResult
  func replaceText(with data: Data, storing policy: StoragePolicy) -> Bool {
    guard policy.allowList?.enabledTypes.contains(.string) == true else {
      return false
    }

    // Exactly one plain-text value remains, the edited one: any other value,
    // including a second plain-text value stored before one value per type
    // was enforced, is deleted.
    let stringType = NSPasteboard.PasteboardType.string.rawValue
    let kept = canonicalContent(ofType: stringType)
    let removed = contents.filter { $0 !== kept }
    contents.removeAll { $0 !== kept }
    removed.forEach { modelContext?.delete($0) }

    if let kept {
      kept.value = data
    } else {
      contents.append(HistoryItemContent(type: stringType, value: data))
    }
    // A derived title follows the edited text; an alias is kept.
    if titleSource != .user {
      regenerateTitle(readableBy: policy.readAllowList, recognizingImageText: false)
    }

    return true
  }

  var fromMaccy: Bool { contentData([.fromMaccy]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  // A Universal Clipboard image arrives as a file whose contents are read as an
  // image without checking their format, so it is used only when every image
  // type may be read.
  private func universalClipboardImageURL(readableBy allowList: StorageAllowList) -> URL? {
    guard universalClipboard,
          StorageType.images.types.allSatisfy(allowList.allows),
          let url = fileURLs(readableBy: allowList).first,
          url.pathExtension == "jpeg",
          UniversalClipboardFile.isInAllowedLocation(url) else {
      return nil
    }

    return url
  }

  private func universalClipboardText(readableBy allowList: StorageAllowList) -> Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic], readableBy: allowList) != nil
  }

  // The value read for the first of `types` (in that order) that the item
  // has and `allowList` allows. With several values of that type, the one
  // `canonicalContent(ofType:)` picks.
  private func firstContent(
    _ types: [NSPasteboard.PasteboardType],
    readableBy allowList: StorageAllowList
  ) -> HistoryItemContent? {
    for type in types where allowList.allows(type) {
      if let content = canonicalContent(ofType: type.rawValue) {
        return content
      }
    }
    return nil
  }

  // Metadata markers are always readable.
  private func contentData(
    _ types: [NSPasteboard.PasteboardType],
    readableBy allowList: StorageAllowList = .everything
  ) -> Data? {
    firstContent(types, readableBy: allowList)?.value
  }

  nonisolated private static let textRecognitionQueue = DispatchQueue(
    label: AppIdentity.bundleIdentifier + ".textRecognition",
    qos: .utility
  )

  #if DEBUG
  // How many recognitions were started, their tasks, how many reached the
  // queued work past its first check, and the size of each image actually
  // handed to Vision.
  @MainActor static var recognitionStartsForTesting = 0
  @MainActor static var recognitionTasksForTesting: [Task<Void, Never>] = []
  nonisolated(unsafe) static var recognitionWorkObserverForTesting: (@Sendable () -> Void)?
  nonisolated(unsafe) static var visionInputObserverForTesting: (@Sendable (Int) -> Void)?
  // The serial queue recognition runs on, so tests can hold it.
  nonisolated static var textRecognitionQueueForTesting: DispatchQueue { textRecognitionQueue }
  #endif

  /// Runs OCR on a dedicated queue so the blocking Vision call never occupies
  /// a thread of Swift's cooperative pool or the main thread.
  nonisolated static func recognizeText(
    imageData: Data?,
    fileURL: URL?,
    job: TextRecognitionJob = TextRecognitionJob()
  ) async -> String? {
    await withCheckedContinuation { continuation in
      textRecognitionQueue.async {
        continuation.resume(returning: performTextRecognition(imageData: imageData, fileURL: fileURL, job: job))
      }
    }
  }

  // Whether queued recognition may go on: the job wasn't cancelled, text
  // recognition is on and every image type may still be stored. Read when
  // the work starts and again just before Vision.
  nonisolated private static func recognitionMayProceed(_ job: TextRecognitionJob) -> Bool {
    guard !job.isCancelled, OCRSetting.current.isEnabled,
          let allowList = StoragePolicy.current.allowList else {
      return false
    }
    return StorageType.images.types.contains(where: allowList.allows)
  }

  nonisolated private static func performTextRecognition(
    imageData: Data?,
    fileURL: URL?,
    job: TextRecognitionJob
  ) -> String? {
    guard recognitionMayProceed(job) else {
      return nil
    }
    #if DEBUG
    recognitionWorkObserverForTesting?()
    #endif

    // A Universal Clipboard file is read here, on the recognition queue, with
    // every check `UniversalClipboardFile.read` makes.
    guard let data = imageData ?? fileURL.flatMap({ try? UniversalClipboardFile.read($0) }) else {
      return nil
    }
    // One validated image, decoded within the pixel limit; Vision never
    // sees the original container.
    guard recognitionMayProceed(job), let image = ValidatedImage.cgImage(from: data, for: .fullSize) else {
      return nil
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true

    guard recognitionMayProceed(job), job.begin(request) else {
      return nil
    }
    defer { job.end() }
    #if DEBUG
    visionInputObserverForTesting?(data.count)
    #endif

    do {
      try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
      print("Unable to perform the request: \(Notifier.redacted(error)).")
      return nil
    }

    // A result that arrives after recognition was turned off is discarded.
    guard recognitionMayProceed(job), let observations = request.results else {
      return nil
    }

    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}

// One queued text recognition. Cancelling it stops the work before it
// starts or reaches Vision, and cancels a Vision request already running.
nonisolated final class TextRecognitionJob: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var request: VNRequest?

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() {
    let running = lock.withLock {
      cancelled = true
      return request
    }
    running?.cancel()
  }

  // Records the request about to run; false if the job is already cancelled.
  func begin(_ request: VNRequest) -> Bool {
    lock.withLock {
      guard !cancelled else { return false }
      self.request = request
      return true
    }
  }

  func end() {
    lock.withLock { request = nil }
  }
}

// One read of a Universal Clipboard file in the background, awaited by
// everything that needs it and cancelled when the item's images are cleaned
// up. Immutable, so it can be cancelled from any context.
nonisolated final class UniversalClipboardFileLoad: Sendable {
  let url: URL
  private let cancellation: UniversalClipboardFile.Cancellation
  private let task: Task<Result<Data, UniversalClipboardFile.Rejection>, Never>

  init(url: URL) {
    let cancellation = UniversalClipboardFile.Cancellation()
    self.url = url
    self.cancellation = cancellation
    task = Task.detached { await UniversalClipboardFile.loadResult(url, cancellation: cancellation) }
  }

  var value: Result<Data, UniversalClipboardFile.Rejection> {
    get async { await task.value }
  }

  func cancel() {
    cancellation.cancel()
  }
}

nonisolated struct ImageInspectionCache {
  let source: HistoryItemImageSource
  let inspection: ValidatedImage.Inspection?
}

nonisolated struct UniversalClipboardFileData {
  let url: URL
  // Nil: a check failed or access was denied.
  let data: Data?
}

// Where an item's image comes from: a stored representation, or the file a
// Universal Clipboard copy points to.
nonisolated enum HistoryItemImageSource: Equatable {
  case content(String, ObjectIdentifier)
  case universalClipboardFile(URL)
}

// What a stored title was made from. Recorded when the title is set.
nonisolated enum HistoryItemTitleSource: Equatable, Sendable {
  // An alias the user typed.
  case user
  // The representation of this type (for an image type, its recognised text).
  case content(String)
  // The recognised text of the file a Universal Clipboard image points to.
  case universalClipboardImage
  // Derived, but there was nothing to make it from: the title is empty.
  case nothing
  // Stored before titles recorded their source.
  case unknown

  private static let userValue = "\(AppIdentity.bundleIdentifier).title.user"
  private static let universalClipboardImageValue = "\(AppIdentity.bundleIdentifier).title.universalClipboardImage"
  private static let nothingValue = "\(AppIdentity.bundleIdentifier).title.nothing"
  private static let unknownValue = "\(AppIdentity.bundleIdentifier).title.unknown"
  private static let contentPrefix = "content:"

  init(rawValue: String) {
    switch rawValue {
    case Self.userValue: self = .user
    case Self.universalClipboardImageValue: self = .universalClipboardImage
    case Self.nothingValue: self = .nothing
    case _ where rawValue.hasPrefix(Self.contentPrefix):
      self = .content(String(rawValue.dropFirst(Self.contentPrefix.count)))
    default: self = .unknown
    }
  }

  var rawValue: String {
    switch self {
    case .user: Self.userValue
    case .content(let type): Self.contentPrefix + type
    case .universalClipboardImage: Self.universalClipboardImageValue
    case .nothing: Self.nothingValue
    case .unknown: Self.unknownValue
    }
  }
}

extension HistoryItemImageSource {
  var titleSource: HistoryItemTitleSource {
    switch self {
    case .content(let type, _): .content(type)
    case .universalClipboardFile: .universalClipboardImage
    }
  }
}
