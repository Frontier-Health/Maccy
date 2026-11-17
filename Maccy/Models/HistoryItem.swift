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
  var title = ""
  // The user set the title by hand (an alias). It survives the storage
  // clean-up while the item keeps allowed content; derived titles don't.
  var hasCustomTitle = false

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

  // A derived title, made only from representations `allowList` lets Maccy
  // read. There is no fallback to the previous title. An image's title is
  // recognised asynchronously and is "" until then.
  @MainActor
  func generateTitle(
    readableBy allowList: StorageAllowList = StoragePolicy.currentReadAllowList,
    recognizingImageText: Bool = true
  ) -> String {
    if let imageSource = imageSource(readableBy: allowList) {
      if recognizingImageText {
        recognizeTitle(from: imageSource)
      }
      return ""
    }

    guard let text = titleText(readableBy: allowList)?.text else {
      return ""
    }

    return Self.formatTitle(text)
  }

  // The representation a derived title is made from.
  func titleSource(readableBy allowList: StorageAllowList) -> HistoryItemTitleSource? {
    if let imageSource = imageSource(readableBy: allowList) {
      return .image(imageSource)
    }

    return titleText(readableBy: allowList)?.source
  }

  // Applies the text recognised in an image as the title, unless that image is
  // no longer the one the title would be made from (it was removed or its type
  // is no longer allowed), the item is gone, or the user set the title.
  @MainActor
  @discardableResult
  func acceptRecognizedText(_ text: String, from source: HistoryItemImageSource) -> Bool {
    guard modelContext != nil, !isDeleted, !hasCustomTitle,
          imageSource(readableBy: StoragePolicy.currentReadAllowList) == source else {
      return false
    }

    title = text
    return true
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

  // The text a title or preview is made from: file paths, else plain text,
  // else rich text, else HTML.
  private func titleText(readableBy allowList: StorageAllowList) -> (source: HistoryItemTitleSource, text: String)? {
    let urls = fileURLs(readableBy: allowList)
    if !urls.isEmpty, let content = firstContent([.fileURL], readableBy: allowList) {
      let text = urls
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
      return (.text(content.type, ObjectIdentifier(content)), text)
    }

    if let content = firstContent([.string], readableBy: allowList),
       let text = content.value.flatMap({ String(data: $0, encoding: .utf8) }), !text.isEmpty {
      return (.text(content.type, ObjectIdentifier(content)), text)
    }

    if let content = firstContent([.rtf], readableBy: allowList),
       let text = content.value.flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil)?.string }),
       !text.isEmpty {
      return (.text(content.type, ObjectIdentifier(content)), text)
    }

    if let content = firstContent([.html], readableBy: allowList),
       let text = content.value.flatMap({ NSAttributedString(html: $0, documentAttributes: nil)?.string }),
       !text.isEmpty {
      return (.text(content.type, ObjectIdentifier(content)), text)
    }

    return nil
  }

  // Shown in the preview. Falls back to the title, which for an image is the
  // recognised text.
  var previewableText: String {
    titleText(readableBy: StoragePolicy.currentReadAllowList)?.text ?? title
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
  // not linger in the store. Does nothing and returns false unless the policy
  // is valid and allows storing plain text.
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

// The representation a derived title is made from.
nonisolated enum HistoryItemTitleSource: Equatable {
  case image(HistoryItemImageSource)
  case text(String, ObjectIdentifier)
}
