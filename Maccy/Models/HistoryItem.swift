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

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  @Transient private var cachedDecodedImage: NSImage?
  // Where the cached image was decoded from, so a cache made from a
  // representation that has since been removed or disallowed is never used.
  @Transient private var cachedDecodedImageSource: HistoryItemImageSource?

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
    self.titleSourceValue = HistoryItemTitleSource.nothing.rawValue
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        contents.contains(where: { $0.type == content.type && $0.value == content.value })
      }
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

    if storedTitleIsReadable(by: allowList) {
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
      if recognizingImageText {
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
      return allowList.allows(NSPasteboard.PasteboardType(type)) && contents.contains { $0.type == type }
    case .universalClipboardImage:
      if case .universalClipboardFile = imageSource(readableBy: allowList) {
        return true
      }
      return false
    case .nothing:
      return false
    case .unknown:
      return !contentsChanged && contents.allSatisfy { allowList.allows(NSPasteboard.PasteboardType($0.type)) }
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
          imageSource(readableBy: StoragePolicy.currentReadAllowList) == source else {
      return false
    }

    setTitle(text, source: source.titleSource)
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

    Task {
      if let recognizedText = await Self.recognizeText(imageData: imageData, fileURL: fileURL) {
        self.acceptRecognizedText(recognizedText, from: source)
      }
    }
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

    if let content = firstContent([.rtf], readableBy: allowList),
       let text = content.value.flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil)?.string }),
       !text.isEmpty {
      return (content.type, text)
    }

    if let content = firstContent([.html], readableBy: allowList),
       let text = content.value.flatMap({ NSAttributedString(html: $0, documentAttributes: nil)?.string }),
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

    return contents
      .filter { NSPasteboard.PasteboardType($0.type) == .fileURL && allowList.allows(.fileURL) }
      .compactMap { $0.value }
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { htmlData(readableBy: StoragePolicy.currentReadAllowList) }
  func htmlData(readableBy allowList: StorageAllowList) -> Data? { contentData([.html], readableBy: allowList) }
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

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
      return try? Data(contentsOf: url)
    }
  }

  var image: NSImage? {
    guard let source = imageSource(readableBy: StoragePolicy.currentReadAllowList) else {
      if cachedDecodedImage != nil {
        clearDecodedImageCache()
      }
      return nil
    }

    if let image = cachedDecodedImage, cachedDecodedImageSource == source {
      return image
    }

    guard let data = imageData(from: source) else {
      return nil
    }

    cachedDecodedImage = NSImage(data: data)
    cachedDecodedImageSource = source
    return cachedDecodedImage
  }

  var rtfData: Data? { rtfData(readableBy: StoragePolicy.currentReadAllowList) }
  func rtfData(readableBy allowList: StorageAllowList) -> Data? { contentData([.rtf], readableBy: allowList) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  func clearDecodedImageCache() {
    cachedDecodedImage?.recache()
    cachedDecodedImage = nil
    cachedDecodedImageSource = nil
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

    let stringType = NSPasteboard.PasteboardType.string.rawValue
    let removed = contents.filter { $0.type != stringType }
    contents.removeAll { $0.type != stringType }
    removed.forEach { modelContext?.delete($0) }

    if let index = contents.firstIndex(where: { $0.type == stringType }) {
      contents[index].value = data
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
          url.pathExtension == "jpeg" else {
      return nil
    }

    return url
  }

  private func universalClipboardText(readableBy allowList: StorageAllowList) -> Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic], readableBy: allowList) != nil
  }

  private func firstContent(
    _ types: [NSPasteboard.PasteboardType],
    readableBy allowList: StorageAllowList
  ) -> HistoryItemContent? {
    contents.first { content in
      let type = NSPasteboard.PasteboardType(content.type)
      return types.contains(type) && allowList.allows(type)
    }
  }

  // Metadata markers are always readable.
  private func contentData(
    _ types: [NSPasteboard.PasteboardType],
    readableBy allowList: StorageAllowList = .everything
  ) -> Data? {
    firstContent(types, readableBy: allowList)?.value
  }

  nonisolated private static let textRecognitionQueue = DispatchQueue(
    label: "org.p0deje.Maccy.textRecognition",
    qos: .utility
  )

  /// Runs OCR on a dedicated queue so the blocking Vision call never occupies
  /// a thread of Swift's cooperative pool or the main thread.
  nonisolated private static func recognizeText(imageData: Data?, fileURL: URL?) async -> String? {
    await withCheckedContinuation { continuation in
      textRecognitionQueue.async {
        continuation.resume(returning: performTextRecognition(imageData: imageData, fileURL: fileURL))
      }
    }
  }

  nonisolated private static func performTextRecognition(imageData: Data?, fileURL: URL?) -> String? {
    guard let data = imageData ?? fileURL.flatMap({ try? Data(contentsOf: $0) }) else {
      return nil
    }

    let requestHandler = VNImageRequestHandler(data: data)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true

    do {
      try requestHandler.perform([request])
    } catch {
      print("Unable to perform the request: \(error).")
      return nil
    }

    guard let observations = request.results else {
      return nil
    }

    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
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

  private static let userValue = "org.p0deje.Maccy.title.user"
  private static let universalClipboardImageValue = "org.p0deje.Maccy.title.universalClipboardImage"
  private static let nothingValue = "org.p0deje.Maccy.title.nothing"
  private static let unknownValue = "org.p0deje.Maccy.title.unknown"
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
