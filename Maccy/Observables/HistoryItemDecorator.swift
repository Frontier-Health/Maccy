import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  private static let previewMaxParagraphSize = 10_000

  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  // The item's `displayTitle`: what list rows, search, the Select intent and
  // accessibility show. Kept in step with the item; `refreshTitle()` makes it
  // re-read the storage policy too.
  private(set) var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  // A Universal Clipboard image counts before its file is read (in the
  // background); if the read fails the preview shows the broken-image symbol.
  // Any other image counts if ValidatedImage accepts it, judged from its
  // headers without decoding it.
  var hasImage: Bool {
    if case .universalClipboardFile = item.imageSource(readableBy: StoragePolicy.currentReadAllowList) {
      return true
    }
    return item.imageInspection != nil
  }
  var hasFileURLs: Bool { !item.fileURLs.isEmpty }
  var hasPlainText: Bool { item.text != nil }
  // Whether a formatted version is stored: checks the types present, without
  // decoding anything.
  var hasRichText: Bool { item.rtfData != nil || item.htmlData != nil }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  private(set) var previewText = SizedString("")
  // Worked out when the preview first asks, and again after the item changes.
  @ObservationIgnored private var cachedFormattedTextComparison: FormattedTextComparison?
  @ObservationIgnored private var cachedTextWarnings: TextWarnings?
  // Raised by `cleanupImages()`: an image generated for an earlier value is
  // discarded.
  @ObservationIgnored private var imageGeneration = 0
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  var imageSize: String? {
    item.imageData.map { ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file) }
  }

  // Whether the preview text is cut short of the item's text.
  var previewIsTruncated: Bool { previewText.isTruncated }

  // 10k characters seems to be more than enough on large displays
  var text: String { previewText.string.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  var multiSelectionIndex: Int? {
    guard selectionIndex >= 0, AppState.shared.navigator.isMultiSelectInProgress else {
      return nil
    }
    return selectionIndex
  }

  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    var parts: [String] = []
    if hasImage, let size = item.imagePixelSize {
      parts.append(
        String(
          format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""),
          Int(size.width),
          Int(size.height)
        )
      )
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if let index = multiSelectionIndex {
      parts.append(
        String(
          format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""),
          index + 1,
          AppState.shared.navigator.selection.count
        )
      )
    }
    return parts.joined(separator: ", ")
  }

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.displayTitle
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
    synchronizeItemText()
  }

  // The thumbnail and preview are decoded off the main actor through
  // ValidatedImage (`HistoryItem.decodedImage(for:)`), which shares one read
  // of a Universal Clipboard file between them. A result is kept only if the
  // task wasn't cancelled and `cleanupImages()` hasn't run since it started.
  @MainActor
  func ensureThumbnailImage() {
    guard hasImage, thumbnailImage == nil, thumbnailImageGenerationTask == nil else {
      return
    }
    let generation = imageGeneration
    thumbnailImageGenerationTask = Task { [weak self] in
      guard let decoded = await self?.item.decodedImage(for: .thumbnail),
            let self, !Task.isCancelled, generation == self.imageGeneration else {
        return
      }
      self.thumbnailImage = decoded.nsImage.resized(to: HistoryItemDecorator.thumbnailImageSize)
    }
  }

  @MainActor
  func ensurePreviewImage() {
    guard hasImage, previewImage == nil, previewImageGenerationTask == nil else {
      return
    }
    let generation = imageGeneration
    previewImageGenerationTask = Task { [weak self] in
      guard let decoded = await self?.item.decodedImage(for: .preview),
            let self, !Task.isCancelled, generation == self.imageGeneration else {
        return
      }
      self.previewImage = decoded.nsImage.resized(to: HistoryItemDecorator.previewImageSize)
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    return previewImage
  }

  // Generates the thumbnail and the preview and waits for both.
  @MainActor
  func sizeImages() async {
    ensurePreviewImage()
    ensureThumbnailImage()
    _ = await previewImageGenerationTask?.result
    _ = await thumbnailImageGenerationTask?.result
  }

  // Cancels image work in flight (including the item's file read) and drops
  // every decoded image; work that completes later is discarded.
  @MainActor
  func cleanupImages() {
    imageGeneration += 1
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    previewImageGenerationTask = nil
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
    item.clearDecodedImageCache()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        // History assigns numeric shortcuts when unpinning. Preserve them when
        // this observation callback runs after the history has been updated.
        self.synchronizeItemPin()
      }
    }
  }

  @MainActor
  func refreshTitle() {
    title = item.displayTitle
  }

  // Follows the stored title, its source and the contents, which together
  // decide `displayTitle`.
  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.displayTitle
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.title = self.item.displayTitle
        self.synchronizeItemTitle()
      }
    }
  }

  // Whether a formatted paste could insert other text than the preview shows.
  @MainActor
  var formattedTextComparison: FormattedTextComparison {
    if let cachedFormattedTextComparison {
      return cachedFormattedTextComparison
    }
    let comparison = item.formattedTextComparison()
    cachedFormattedTextComparison = comparison
    return comparison
  }

  // Plain text the preview shows besides the files or image it is titled by,
  // and what to warn about in the text a text destination receives.
  struct TextWarnings {
    // The text pasted instead of the files or image shown, if any.
    let pastedText: SizedString?
    // That text is something other than the item's file names or paths.
    let pastedTextIsNotFileNames: Bool
    // The plain text holds invisible or direction-changing characters.
    let hasInvisibleCharacters: Bool
  }

  @MainActor
  var textWarnings: TextWarnings {
    if let cachedTextWarnings {
      return cachedTextWarnings
    }
    let allowList = StoragePolicy.currentReadAllowList
    let warnings = TextWarnings(
      pastedText: item.textPastedInsteadOfShownContent(readableBy: allowList).map {
        SizedString($0, maxParagraphBytes: Self.previewMaxParagraphSize)
      },
      pastedTextIsNotFileNames: item.pastedTextIsNotFileNames(readableBy: allowList),
      hasInvisibleCharacters: item.plainTextHasInvisibleCharacters(readableBy: allowList)
    )
    cachedTextWarnings = warnings
    return warnings
  }

  private func synchronizeItemText() {
    cachedFormattedTextComparison = nil
    cachedTextWarnings = nil
    previewText = withObservationTracking {
      SizedString(item.previewableText, maxParagraphBytes: Self.previewMaxParagraphSize)
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        self?.synchronizeItemText()
      }
    }
  }
}
