import AppKit
import Defaults
import SwiftData
import Testing
@testable import Maccy

// A7: clipboard content is untrusted. What Maccy shows is what it pastes, and
// reading a copy loads nothing, doesn't stall and doesn't exhaust memory.
extension SharedStateTests {
  @MainActor
  final class UntrustedContentTests { // swiftlint:disable:this type_body_length
    let clipboard = Clipboard.shared
    let pasteboard = NSPasteboard.general
    let preferences = Defaults.Keys.enabledPasteboardTypes.suite

    let savedEnabledTypes = SavedStoragePreference()
    let savedCaptureSettings = SavedCaptureSettings(Clipboard.shared.capturePreferences)
    let savedIgnoreRegexp = Defaults[.ignoreRegexp]
    let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
    let savedIgnoredApps = Defaults[.ignoredApps]
    let savedIgnoredPasteboardTypes = Defaults[.ignoredPasteboardTypes]

    init() {
      preferences.removeObject(forKey: StoragePolicy.preferenceKey)
      Defaults[.ignoreRegexp] = []
      Defaults[.ignoredApps] = []
      Defaults[.ignoredPasteboardTypes] = []
      Defaults[.ignoreAllAppsExceptListed] = false
      savedCaptureSettings.clear()
      clipboard.syncCaptureState()
      clipboard.clearHooks()
      try? Storage.shared.context.save()
      History.shared.clearAll()
      Storage.shared.saveFailureForTesting = nil
      clipboard.afterInspectionForTesting = nil
      History.shared.storageSettingChanged()
    }

    deinit {
      savedEnabledTypes.restore()
      savedCaptureSettings.restore()
      Defaults[.ignoreRegexp] = savedIgnoreRegexp
      Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
      Defaults[.ignoredApps] = savedIgnoredApps
      Defaults[.ignoredPasteboardTypes] = savedIgnoredPasteboardTypes
      UniversalClipboardFile.allowedDirectoriesForTesting = nil
      UniversalClipboardFile.maximumBytesForTesting = nil
      UniversalClipboardFile.readObserverForTesting = nil
    }

    // MARK: Group 1: one value per type

    @Test("Two pasteboard items with different strings: one string is stored, shown and pasted everywhere")
    func twoItemsWithDifferentStrings() throws {
      let first = NSPasteboardItem()
      first.setString("shown text", forType: .string)
      let second = NSPasteboardItem()
      second.setString("other text", forType: .string)
      pasteboard.clearContents()
      pasteboard.writeObjects([first, second])
      // What any app pasting the original copy receives.
      #expect(pasteboard.string(forType: .string) == "shown text")

      let copied = try #require(checkNow().first)
      let decorator = History.shared.added(copied)
      let item = decorator.item
      #expect(stringValues(item) == ["shown text"])
      expectReadsEverywhere(decorator, as: "shown text")
    }

    @Test("A formatted version with other text is flagged in the preview; the same text is not")
    func formattedTextMismatchIsIndicated() throws {
      let first = NSPasteboardItem()
      first.setString("Pay Alice 100", forType: .string)
      let second = NSPasteboardItem()
      second.setString("<p><b>Pay Mallory 100</b></p>", forType: .html)
      pasteboard.clearContents()
      pasteboard.writeObjects([first, second])

      let decorator = History.shared.added(try #require(checkNow().first))
      #expect(decorator.item.displayTitle == "Pay Alice 100")
      #expect(decorator.formattedTextComparison == .differs)
      #expect(PreviewItemView.formattedTextNote(.differs) != nil)

      let same = NSPasteboardItem()
      same.setString("Pay  Alice 100", forType: .string)
      same.setString("<ul><li>Pay <i>Alice</i>&nbsp;100.</li></ul>", forType: .html)
      let rtf = NSAttributedString(string: "Pay Alice 100")
      same.setData(try #require(rtf.rtf(from: NSRange(location: 0, length: rtf.length))), forType: .rtf)
      pasteboard.clearContents()
      pasteboard.writeObjects([same])
      let sameDecorator = History.shared.added(try #require(checkNow().first))
      #expect(sameDecorator.formattedTextComparison == .same)
      #expect(PreviewItemView.formattedTextNote(.same) == nil)
    }

    @Test("A Finder copy of several files keeps and pastes every file, each once")
    func multiFileCopyPastesAllFiles() throws {
      let urls = ["/tmp/a7 first file.txt", "/tmp/a7-second.txt", "/tmp/a7-third.pdf"].map {
        URL(fileURLWithPath: $0)
      }
      let items = (urls + [urls[0]]).map { url in
        let item = NSPasteboardItem()
        item.setData(url.dataRepresentation, forType: .fileURL)
        return item
      }
      pasteboard.clearContents()
      pasteboard.writeObjects(items)

      let decorator = History.shared.added(try #require(checkNow().first))
      let item = decorator.item
      #expect(item.contents.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }.count == 3)
      #expect(Set(item.fileURLs) == Set(urls))

      for removeFormatting in [false, true] {
        clipboard.copy(item, removeFormatting: removeFormatting)
        let pasted = (pasteboard.pasteboardItems ?? []).compactMap { pasteboardItem in
          pasteboardItem.data(forType: .fileURL).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        }
        #expect(pasted.count == 3)
        #expect(Set(pasted) == Set(urls))
      }
    }

    @Test("An item stored with two values of one type reads, shows and pastes the same one",
          arguments: [false, true])
    func storedDuplicatesAgree(reversed: Bool) throws {
      let values = ["zulu", "alpha"]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = (reversed ? values.reversed() : values).map {
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data($0.utf8))
      }
      // A title an earlier version made from whichever value it read.
      item.setTitle(reversed ? "alpha" : "zulu", source: .content(NSPasteboard.PasteboardType.string.rawValue))
      try Storage.shared.context.save()

      // The smallest value by bytes, whatever order the store returns.
      let decorator = HistoryItemDecorator(item)
      expectReadsEverywhere(decorator, as: "alpha")
      item.setTitle("zulu", source: .unknown)
      #expect(item.displayTitle == "alpha")

      let reloaded = try #require(ModelContext(Storage.shared.container).model(for: item.persistentModelID)
        as? HistoryItem)
      #expect(reloaded.displayTitle == "alpha")
      #expect(reloaded.pasteboardContents(readableBy: .everything).compactMap(\.value) == [Data("alpha".utf8)])

      // A new copy of the value shown is a duplicate of it; a copy of the
      // other value is not.
      #expect(item.supersedes(HistoryItem(contents: [stringContent("alpha")])))
      #expect(!item.supersedes(HistoryItem(contents: [stringContent("zulu")])))

      // The editor saves exactly one string.
      #expect(item.replaceText(with: Data("edited".utf8), storing: StoragePolicy.current))
      #expect(stringValues(item) == ["edited"])
      #expect(item.contents.count == 1)
    }

    // MARK: Group 2: the Universal Clipboard file

    @Test("A Universal Clipboard image file is read only if it passes every check, and never on the main thread")
    func universalClipboardFileChecks() async throws {
      let files = FileManager.default
      let root = files.temporaryDirectory.appending(path: "a7-uc-\(UUID().uuidString)")
      let staging = root.appending(path: "items")
      let elsewhere = root.appending(path: "elsewhere")
      try files.createDirectory(at: staging.appending(path: "copy"), withIntermediateDirectories: true)
      try files.createDirectory(at: elsewhere, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      UniversalClipboardFile.allowedDirectoriesForTesting = [staging.path]
      let jpeg = try jpegData()
      UniversalClipboardFile.maximumBytesForTesting = jpeg.count

      let valid = staging.appending(path: "copy/photo.jpeg")
      try jpeg.write(to: valid)
      let outside = elsewhere.appending(path: "photo.jpeg")
      try jpeg.write(to: outside)
      let directory = staging.appending(path: "folder.jpeg")
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      let symlink = staging.appending(path: "link.jpeg")
      try files.createSymbolicLink(at: symlink, withDestinationURL: outside)
      let linkedDirectory = staging.appending(path: "linked")
      try files.createSymbolicLink(at: linkedDirectory, withDestinationURL: elsewhere)
      let throughLinkedDirectory = linkedDirectory.appending(path: "photo.jpeg")
      let oversized = staging.appending(path: "copy/large.jpeg")
      try (jpeg + Data([0])).write(to: oversized)
      let remote = try #require(URL(string: "https://example.com/photo.jpeg"))

      let reads = ThreadRecorder()
      UniversalClipboardFile.readObserverForTesting = { reads.record($0) }

      // A valid file: shown as an image, but only read in the background.
      let item = universalClipboardItem(valid)
      #expect(HistoryItemDecorator(item).hasImage)
      #expect(item.image == nil)
      #expect(item.imageData == nil)
      #expect(reads.values.isEmpty)
      await item.loadImageIfNeeded()
      #expect(item.imageData == jpeg)
      #expect(item.image != nil)
      #expect(Get.contents(of: item, readableBy: StoragePolicy.currentReadAllowList).image == jpeg)

      // Paths outside the staging location are never looked up at all.
      for url in [remote, outside] {
        let rejected = universalClipboardItem(url)
        #expect(rejected.imageSource(readableBy: .everything) == nil)
        await rejected.loadImageIfNeeded()
        #expect(rejected.imageData == nil)
        #expect(!HistoryItemDecorator(rejected).hasImage)
      }
      // Inside it, but not a regular local file within the limit.
      for url in [directory, symlink, throughLinkedDirectory, oversized] {
        let rejected = universalClipboardItem(url)
        await rejected.loadImageIfNeeded()
        #expect(rejected.imageData == nil, "\(url.lastPathComponent)")
        #expect(rejected.image == nil, "\(url.lastPathComponent)")
      }
      // Every read so far ran in the background.
      #expect(reads.values.count == 5)
      #expect(reads.values.allSatisfy { !$0 })

      // Why each one is refused.
      UniversalClipboardFile.readObserverForTesting = nil
      #expect(throws: UniversalClipboardFile.Rejection.notFileURL) { try UniversalClipboardFile.read(remote) }
      #expect(throws: UniversalClipboardFile.Rejection.outsideAllowedLocation) {
        try UniversalClipboardFile.read(outside)
      }
      #expect(throws: UniversalClipboardFile.Rejection.notRegularFile) { try UniversalClipboardFile.read(directory) }
      #expect(throws: UniversalClipboardFile.Rejection.notRegularFile) { try UniversalClipboardFile.read(symlink) }
      #expect(throws: UniversalClipboardFile.Rejection.outsideAllowedLocation) {
        try UniversalClipboardFile.read(throughLinkedDirectory)
      }
      #expect(throws: UniversalClipboardFile.Rejection.tooLarge) { try UniversalClipboardFile.read(oversized) }
      #expect(throws: UniversalClipboardFile.Rejection.outsideAllowedLocation) {
        try UniversalClipboardFile.read(staging.appending(path: "copy/../../elsewhere/photo.jpeg"))
      }
      #expect(try UniversalClipboardFile.read(valid) == jpeg)
    }

    @Test("Without an override, only the two known staging directories are allowed")
    func universalClipboardStagingDirectories() {
      let directories = UniversalClipboardFile.allowedDirectories
      #expect(directories.count == 2)
      #expect(directories.contains {
        $0.hasSuffix("/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/")
      })
      #expect(directories.contains("/private/var/folders/*/*/T/com.apple.useractivityd/shared-pasteboard/items/"))
      for path in [
        "/private/var/folders/ab/cdef123/T/com.apple.useractivityd/shared-pasteboard/items/UUID/photo.jpeg",
        "/var/folders/ab/cdef123/T/com.apple.useractivityd/shared-pasteboard/items/UUID/photo.jpeg"
      ] {
        #expect(UniversalClipboardFile.isInAllowedLocation(URL(fileURLWithPath: path)))
      }
      for path in [
        "/Volumes/Share/photo.jpeg",
        "/private/var/folders/ab/T/com.apple.useractivityd/shared-pasteboard/items/photo.jpeg",
        "/private/var/folders/ab/cd/T/com.apple.useractivityd/shared-pasteboard/items",
        "/private/var/folders/ab/cd/T/com.apple.useractivityd/shared-pasteboard/itemsX/photo.jpeg",
        "/private/var/folders/ab/cd/T/com.apple.useractivityd/shared-pasteboard/items/../../../../x.jpeg"
      ] {
        #expect(!UniversalClipboardFile.isInAllowedLocation(URL(fileURLWithPath: path)), "\(path)")
      }
    }

    // MARK: Group 3: no WebKit import

    @Test("HTML referring to a remote image and style sheet is captured, titled and checked without rendering it")
    func htmlIsNeverRendered() throws {
      // Every WebKit importer is gone from the app (tools/check-rich-text-importers.py
      // enforces it in CI), so nothing below can load these. This checks the
      // paths produce the scanned text, import no RTF and load no WebKit.
      let webKitWasLoaded = webKitIsLoaded
      let rtfImports = RichTextImport.rtfImportsForTesting
      let html = """
        <html><head><link rel="stylesheet" href="https://example.invalid/a7.css">
        <style>@import url("https://example.invalid/b.css");</style></head>
        <body><img src="https://example.invalid/a7.png"><p>Hello <b>remote</b></p></body></html>
        """
      let item = NSPasteboardItem()
      item.setString(html, forType: .html)
      pasteboard.clearContents()
      pasteboard.writeObjects([item])

      let decorator = History.shared.added(try #require(checkNow().first))
      // The scanned text; block breaks may show as special symbols.
      #expect(decorator.item.displayTitle.contains("Hello remote"))
      decorator.item.regenerateTitle()
      #expect(decorator.item.displayTitle.contains("Hello remote"))
      #expect(decorator.previewText.string.contains("Hello remote"))
      #expect(decorator.hasRichText)
      #expect(!decorator.hasPlainText)
      #expect(RichTextImport.rtfImportsForTesting == rtfImports)
      if !webKitWasLoaded {
        #expect(!webKitIsLoaded)
      }
    }

    @Test("RTF is imported for a title only within the ignore-rule RTF limits")
    func rtfImportIsBounded() throws {
      let small = NSAttributedString(string: "Small rich text")
      let smallRTF = try #require(small.rtf(from: NSRange(location: 0, length: small.length)))
      let imports = RichTextImport.rtfImportsForTesting
      #expect(RichTextImport.text(fromRTF: smallRTF) == "Small rich text")
      #expect(RichTextImport.rtfImportsForTesting == imports + 1)

      let large = NSAttributedString(string: String(repeating: "x", count: IgnoreRules.rtfDataLimit + 1))
      let largeRTF = try #require(large.rtf(from: NSRange(location: 0, length: large.length)))
      #expect(!RichTextImport.rtfIsImportable(largeRTF))
      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: largeRTF)
      ])
      Storage.shared.context.insert(item)
      item.regenerateTitle()
      #expect(item.displayTitle == "")
      #expect(HistoryItemDecorator(item).hasRichText)
      #expect(RichTextImport.rtfImportsForTesting == imports + 1)
    }

    // MARK: Helpers

    // Whether WebKit (modern or legacy) is in the process. Doesn't load it.
    private var webKitIsLoaded: Bool {
      NSClassFromString("WKWebView") != nil || NSClassFromString("WebView") != nil
    }

    private func universalClipboardItem(_ url: URL) -> HistoryItem {
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [
        HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: url.dataRepresentation),
        HistoryItemContent(type: NSPasteboard.PasteboardType.universalClipboard.rawValue, value: Data())
      ]
      return item
    }

    private func jpegData(width: Int = 4, height: Int = 4) throws -> Data {
      let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
        hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
      return try #require(rep.representation(using: .jpeg, properties: [:]))
    }

    // Title, list row, preview, editor, Get, formatted paste and plain paste
    // all yield `text`, and each paste writes it exactly once.
    private func expectReadsEverywhere(
      _ decorator: HistoryItemDecorator,
      as text: String,
      sourceLocation: SourceLocation = #_sourceLocation
    ) {
      let item = decorator.item
      #expect(item.displayTitle == text, sourceLocation: sourceLocation)
      #expect(decorator.title == text, sourceLocation: sourceLocation)
      #expect(item.previewableText == text, sourceLocation: sourceLocation)
      #expect(decorator.previewText.string == text, sourceLocation: sourceLocation)
      // The editor starts from the preview text.
      #expect(LargeTextView.EditorState(text: decorator.previewText.string).text == text,
              sourceLocation: sourceLocation)
      #expect(Get.contents(of: item, readableBy: StoragePolicy.currentReadAllowList).text == text,
              sourceLocation: sourceLocation)

      clipboard.copy(item)
      #expect(pastedStrings() == [text], sourceLocation: sourceLocation)
      clipboard.copy(item, removeFormatting: true)
      #expect(pastedStrings() == [text], sourceLocation: sourceLocation)
    }

    private func stringValues(_ item: HistoryItem) -> [String] {
      item.contents
        .filter { $0.type == NSPasteboard.PasteboardType.string.rawValue }
        .compactMap { $0.value.flatMap { String(data: $0, encoding: .utf8) } }
    }

    private func stringContent(_ text: String) -> HistoryItemContent {
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
    }

    // Every plain-text value on the pasteboard, across all its items.
    private func pastedStrings() -> [String] {
      (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
    }

    // Runs one production watcher check now and returns what it recorded.
    private func checkNow() -> [HistoryItem] {
      var copies: [HistoryItem] = []
      clipboard.clearHooks()
      clipboard.onNewCopy { copies.append($0) }
      clipboard.checkForChangesInPasteboard()
      clipboard.clearHooks()
      return copies
    }
  }
}

// Records, from any thread, whether each call ran on the main thread.
final class ThreadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Bool] = []

  func record(_ onMainThread: Bool) {
    lock.withLock { recorded.append(onMainThread) }
  }

  var values: [Bool] { lock.withLock { recorded } }
}
