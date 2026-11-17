import AppKit
import Testing
import Defaults
@testable import Maccy

extension SharedStateTests {
  // swiftlint:disable type_body_length
  @MainActor
  final class ClipboardTests {
    let clipboard = Clipboard.shared
    let pasteboard = NSPasteboard.general
    let image: NSImage
    let coloredString = NSAttributedString(string: "foo",
                                           attributes: [.foregroundColor: NSColor.red])

    let dynamicType = NSPasteboard.PasteboardType(rawValue: "dyn.ah62d4qmxhk4d425try1g44pdsm11g55gsu1e82xnqzv")
    let customType = NSPasteboard.PasteboardType(rawValue: "org.maccy.ConfidentialType")
    let fileURLType = NSPasteboard.PasteboardType.fileURL
    let htmlType = NSPasteboard.PasteboardType.html
    let rtfType = NSPasteboard.PasteboardType.rtf
    let stringType = NSPasteboard.PasteboardType.string
    let tiffType = NSPasteboard.PasteboardType.tiff
    let transientType = NSPasteboard.PasteboardType.transient
    let unknownType = NSPasteboard.PasteboardType(rawValue: "com.apple.AnnotationKit.AnnotationItem")

    let savedEnabledTypes = Defaults[.enabledPasteboardTypes]
    let savedCaptureSettings = SavedCaptureSettings(Clipboard.shared.capturePreferences)
    let savedIgnoreRegexp = Defaults[.ignoreRegexp]
    let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
    let savedIgnoredApps = Defaults[.ignoredApps]
    let savedIgnoredPasteboardTypes = Defaults[.ignoredPasteboardTypes]

    init() throws {
      image = try #require(NSImage(named: "NSInfo"))
      Defaults[.ignoreRegexp] = []
      Defaults[.ignoredApps] = []
      Defaults[.ignoredPasteboardTypes] = []
      Defaults[.ignoreAllAppsExceptListed] = false
      savedCaptureSettings.clear()
      clipboard.syncCaptureState()
      clipboard.clearHooks()
    }

    deinit {
      Defaults[.enabledPasteboardTypes] = savedEnabledTypes
      savedCaptureSettings.restore()
      Defaults[.ignoreRegexp] = savedIgnoreRegexp
      Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
      Defaults[.ignoredApps] = savedIgnoredApps
      Defaults[.ignoredPasteboardTypes] = savedIgnoredPasteboardTypes
    }

    @Test("Changes listener and add hooks")
    func changesListenerAndAddHooks() async throws {
      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.count == 1)
    }

    @Test("Ignore string with only spaces")
    func ignoreStringWithOnlySpaces() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(" ", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore string with only newlines")
    func ignoreStringWithOnlyNewlines() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("\n", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Does not ignore RTF")
    func doesNotIgnoreRTF() async throws {
      let copies = try await waitForCopies(after: {
        let rtf = NSAttributedString(string: "foo").rtf(
          from: NSRange(0...2),
          documentAttributes: [:]
        )
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
      })
      #expect(copies.count == 1)
    }

    @Test("Does not ignore HTML")
    func doesNotIgnoreHTML() async throws {
      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.html], owner: nil)
        pasteboard.setString("foo", forType: .html)
      })
      #expect(copies.count == 1)
    }

    @Test("Paused ignores copies and stays paused")
    func pausedIgnoresCopies() async throws {
      setCaptureMode(.paused)

      let first = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("foo", forType: .string)
      })
      #expect(first.isEmpty)
      #expect(storedCaptureMode == .paused)

      let second = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(second.isEmpty)
      #expect(storedCaptureMode == .paused)
    }

    @Test("Skip next ignores exactly one copy")
    func skipNextIgnoresExactlyOneCopy() async throws {
      setCaptureMode(.skipNext)

      let skipped = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("foo", forType: .string)
      })
      #expect(skipped.isEmpty)
      #expect(storedCaptureMode == .capturing)

      let captured = try await waitForCopies(after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(captured.count == 1)
    }

    // Regression: arming a one-shot skip, cancelling it, then pausing used to
    // leave a stale one-shot flag that resumed capture after one copy. Driven
    // through the status item's click handling and the real watcher.
    @Test("Arm skip next, cancel, pause, copy: nothing is captured")
    func cancelledSkipNextThenPauseDoesNotCapture() throws {
      let optionShift = try #require(CaptureModeRequest(statusItemClickWith: [.option, .shift]))
      let option = try #require(CaptureModeRequest(statusItemClickWith: [.option]))

      clipboard.perform(optionShift) // Arm.
      #expect(storedCaptureMode == .skipNext)
      clipboard.perform(optionShift) // Cancel.
      #expect(storedCaptureMode == .capturing)
      clipboard.perform(option) // Pause.
      #expect(storedCaptureMode == .paused)
      #expect(checkNow().isEmpty)

      copyString("foo")
      #expect(checkNow().isEmpty)
      copyString("bar")
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .paused)
      #expect(CaptureMode.effective(in: preferences) == .paused)
    }

    @Test("Pause, copy, resume with no check in between: the copy is not captured")
    func copyWhilePausedIsNotCapturedAfterQuickResume() throws {
      #expect(checkNow().isEmpty)

      clipboard.perform(.togglePause)
      copyString("secret")
      clipboard.perform(.togglePause)
      #expect(storedCaptureMode == .capturing)
      #expect(checkNow().isEmpty)

      copyString("after resume")
      #expect(checkNow().count == 1)

      // Resuming from Maccy marks the pasteboard as seen at that moment, so a
      // copy made after it is recorded even before the next check.
      clipboard.perform(.togglePause)
      copyString("secret")
      clipboard.perform(.togglePause)
      copyString("right after resume")
      let copies = checkNow()
      #expect(copies.count == 1)
      #expect(copies.first?.contents.contains { $0.value == Data("secret".utf8) } == false)
    }

    @Test("Pause, copy, resume written outside Maccy with no check in between: the copy is not captured")
    func copyWhilePausedIsNotCapturedAfterQuickExternalResume() throws {
      #expect(checkNow().isEmpty)

      // What `defaults write org.p0deje.Maccy captureMode …` does.
      preferences.set(CaptureMode.paused.rawValue, forKey: CaptureMode.defaultsKey)
      copyString("secret")
      preferences.set(CaptureMode.capturing.rawValue, forKey: CaptureMode.defaultsKey)
      #expect(checkNow().isEmpty)

      // The check after that is attributable again.
      #expect(checkNow().isEmpty)
      copyString("after resume")
      #expect(checkNow().count == 1)
    }

    @Test("Copies that would be ignored anyway don't use up skip next")
    func ignoredCopiesDoNotConsumeSkipNext() throws {
      setCaptureMode(.skipNext)

      // Clearing the clipboard, and whitespace only.
      pasteboard.clearContents()
      #expect(checkNow().isEmpty)
      copyString(" ")
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .skipNext)

      // Concealed, transient and auto-generated markers.
      for marker in [NSPasteboard.PasteboardType.concealed, .transient, .autoGenerated] {
        copyString("secret", types: [.string, marker])
        #expect(checkNow().isEmpty)
      }
      #expect(storedCaptureMode == .skipNext)

      // Ignored app, ignored type and ignore pattern.
      Defaults[.ignoredApps] = [try frontmostAppBundleIdentifier()]
      copyString("from ignored app")
      #expect(checkNow().isEmpty)
      Defaults[.ignoredApps] = []

      Defaults[.ignoredPasteboardTypes] = [customType.rawValue]
      copyString("ignored type", types: [.string, customType])
      #expect(checkNow().isEmpty)

      Defaults[.ignoreRegexp] = ["^ignored pattern$"]
      copyString("ignored pattern")
      #expect(checkNow().isEmpty)
      Defaults[.ignoreRegexp] = []
      #expect(storedCaptureMode == .skipNext)

      // Maccy's own writes.
      copyString("from history", types: [.string, .fromMaccy])
      pasteboard.setString("", forType: .fromMaccy)
      #expect(checkNow().isEmpty)
      clipboard.copyInMaccy("search query")
      #expect(storedCaptureMode == .skipNext)

      // The first copy that would have been recorded is the one skipped.
      copyString("password")
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .capturing)

      // Using up the skip is the watcher's own write, not an uncertain
      // transition, so the very next copy is recorded.
      copyString("right after")
      #expect(checkNow().count == 1)
    }

    @Test("Skip next armed from the menu icon skips the very next copy and only that one")
    func skipNextArmedFromUISkipsExactlyOneCopy() throws {
      #expect(checkNow().isEmpty)

      clipboard.perform(.toggleSkipNext)
      #expect(storedCaptureMode == .skipNext)

      copyString("password")
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .capturing)

      copyString("next copy")
      #expect(checkNow().count == 1)
    }

    @Test("Legacy ignoreEvents written after migration pauses until cleared")
    func legacyPauseAfterMigration() throws {
      preferences.set("true", forKey: CaptureMode.legacyIgnoreEventsKey)
      #expect(checkNow().isEmpty)

      copyString("secret")
      #expect(checkNow().isEmpty)
      #expect(CaptureMode.effective(in: preferences) == .paused)

      preferences.set("false", forKey: CaptureMode.legacyIgnoreEventsKey)
      #expect(checkNow().isEmpty)
      copyString("after resume")
      #expect(checkNow().count == 1)
    }

    @Test("Legacy ignoreOnlyNextEvent written after migration skips one copy")
    func legacyOneShotAfterMigration() throws {
      preferences.set(true, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
      #expect(checkNow().isEmpty)
      #expect(preferences.object(forKey: CaptureMode.legacyIgnoreOnlyNextEventKey) == nil)
      #expect(storedCaptureMode == .skipNext)

      copyString("secret")
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .capturing)
    }

    @Test("Ignore application")
    func ignoreApplication() async throws {
      Defaults[.ignoredApps] = [try frontmostAppBundleIdentifier()]

      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore all applications except")
    func ignoreAllApplicationsExcept() async throws {
      Defaults[.ignoreAllAppsExceptListed] = true
      Defaults[.ignoredApps] = [try frontmostAppBundleIdentifier()]

      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.count == 1)
    }

    @Test("Ignore transient types")
    func ignoreTransientTypes() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string, transientType], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore custom types")
    func ignoreCustomTypes() async throws {
      Defaults[.ignoredPasteboardTypes] = [customType.rawValue]

      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string, customType], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.isEmpty)
    }

    @Test("Ignore copies with unknown types")
    func ignoreCopiesWithUnknownTypes() async throws {
      let copies = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([unknownType], owner: nil)
        pasteboard.setString(" ", forType: unknownType)
      })
      #expect(copies.isEmpty)
    }

    @Test("Copy")
    func copy() {
      let imageData = image.tiffRepresentation!
      let contents = [
        HistoryItemContent(type: stringType.rawValue, value: "foo".data(using: .utf8)!),
        HistoryItemContent(type: tiffType.rawValue, value: imageData),
        HistoryItemContent(type: fileURLType.rawValue, value: "file://foo.bar".data(using: .utf8)!)
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.application = "com.foo.bar"
      clipboard.copy(item)
      #expect(pasteboard.string(forType: .string) == "foo")
      #expect(pasteboard.data(forType: .tiff) == imageData)
      #expect(pasteboard.string(forType: .fileURL) == "file://foo.bar")
      #expect(pasteboard.string(forType: .fromMaccy) == "")
      #expect(pasteboard.string(forType: .source) == "com.foo.bar")
    }

    @Test("Copy string")
    func copyString() {
      clipboard.copyInMaccy("foo")
      #expect(pasteboard.string(forType: .string) == "foo")
      #expect(pasteboard.string(forType: .source) == NSPasteboard.PasteboardType.fromMaccy.rawValue)
    }

    @Test("Copy without formatting")
    func copyWithoutFormatting() {
      let contents = [
        HistoryItemContent(type: stringType.rawValue, value: "foo".data(using: .utf8)!),
        HistoryItemContent(type: fileURLType.rawValue, value: "file://foo.bar".data(using: .utf8)!),
        HistoryItemContent(type: rtfType.rawValue,
                           value: coloredString.rtf(from: NSRange(location: 0, length: coloredString.length),
                                                    documentAttributes: [:]))
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.application = "com.foo.bar"
      clipboard.copy(item, removeFormatting: true)
      #expect(pasteboard.string(forType: .string) == "foo")
      #expect(pasteboard.string(forType: .fromMaccy) == "")
      #expect(pasteboard.string(forType: .source) == "com.foo.bar")
      #expect(pasteboard.string(forType: .fileURL) == "file://foo.bar")
      #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test("Handles items without data")
    func handlesItemsWithoutData() async throws {
      pasteboard.clearContents()

      let copies = try await waitForCopies(after: {
        pasteboard.declareTypes([.fileURL, .string], owner: nil)
        // fileURL is left without data
        pasteboard.setString("bar", forType: .string)
      })
      #expect(copies.count == 1)
    }

    @Test("Merges multiple items")
    func mergesMultipleItems() async throws {
      let item1 = NSPasteboardItem()
      item1.setString("foo", forType: .string)
      let item2 = NSPasteboardItem()
      item2.setData(image.tiffRepresentation!, forType: .tiff)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item1, item2])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(
        Set(copied.contents.map({ $0.type })) ==
        Set([tiffType.rawValue, stringType.rawValue])
      )
    }

    @Test("Removes disabled types")
    func removesDisabledTypes() async throws {
      Defaults[.enabledPasteboardTypes] = [.fileURL]

      let item = NSPasteboardItem()
      item.setString("foo", forType: .string)
      item.setData(image.tiffRepresentation!, forType: .tiff)
      item.setData("file://foo.bar".data(using: .utf8)!, forType: .fileURL)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(copied.contents.map({ $0.type }) == [fileURLType.rawValue])
    }

    @Test("Removes dynamic types")
    func removesDynamicTypes() async throws {
      let item = NSPasteboardItem()
      item.setString("foo", forType: .string)
      item.setData("".data(using: .utf8)!, forType: dynamicType)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(copied.contents.map({ $0.type }) == [stringType.rawValue])
    }

    @Test("Does not store Safari web archive")
    func doesNotStoreSafariWebArchive() async throws {
      let webArchive = NSPasteboard.PasteboardType.safariWebArchve

      let item = NSPasteboardItem()
      item.setString("hello from safari", forType: .string)
      item.setData(Data(repeating: 0x61, count: 1024 * 1024), forType: webArchive)

      let copies = try await waitForCopies(after: {
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
      })
      let copied = try #require(copies.first)
      #expect(copies.count == 1)
      #expect(Set(copied.contents.map(\.type)) == [stringType.rawValue])
    }

    @Test("An invalid stored pattern before a valid pattern blocks matches and unrelated copies")
    func invalidIgnoreRuleFailsClosed() {
      Defaults[.ignoreRegexp] = ["[", "secret"]
      copyString("secret")
      #expect(checkNow().isEmpty)
      copyString("ordinary text")
      #expect(checkNow().isEmpty)
      #expect(IgnoreRules().hasInvalidStoredRules)
      Defaults[.ignoreRegexp] = ["secret"]
      copyString("ordinary text")
      #expect(checkNow().count == 1)
      copyString("secret")
      #expect(checkNow().isEmpty)
    }

    @Test("HTML-only text is decoded and blocked, including entities and split tags")
    func ignoreHTMLOnly() {
      Defaults[.ignoreRegexp] = ["secret&token"]
      copyRichText("<p>sec<b>ret</b>&amp;token</p>", type: .html)
      #expect(checkNow().isEmpty)
      copyRichText("<p>ordinary text</p>", type: .html)
      #expect(checkNow().count == 1)
    }

    @Test("Embedded images and CSS stay usable; links, comments and scripts still protect secrets")
    func hiddenHTMLWatcher() {
      Defaults[.ignoreRegexp] = [
        #"\b[A-Za-z0-9+/]{40,}={0,2}"#,
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
      ]
      copyRichText("<p>ordinary text</p><img src='data:image/png;base64," +
                   String(repeating: "A", count: 20_000) + "\n" +
                   String(repeating: "A", count: 20_000) + "'><style>" +
                   String(repeating: "A", count: 100) + "</style>", type: .html)
      #expect(checkNow().count == 1)
      Defaults[.ignoreRegexp] = ["sk_live_"]
      for html in ["<a href='https://example.org/sk_live_'>ordinary</a>",
                   "<!--sk_live_--><p>ordinary</p>", "<script>sk_live_</script><p>ordinary</p>",
                   "<a href=/it's>sk_live_</a><b>abc</b> don't",
                   "<style><!-- /* Word's defs */ x{color:red} --></STYLE><p>sk_live_</p>"] {
        copyRichText(html, type: .html)
        #expect(checkNow().isEmpty)
      }
      for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
        let html = String(repeating: "日本語", count: 100) + "<p>sk_live_</p>"
        pasteboard.declareTypes([.html], owner: nil)
        pasteboard.setData(html.data(using: encoding), forType: .html)
        #expect(checkNow().isEmpty)
      }
    }

    @Test("Image-only HTML beside empty plain text remains eligible without rules")
    func imageOnlyHTML() {
      for element in ["img", "svg", "video", "picture", "object", "canvas"] {
        copyString("")
        pasteboard.addTypes([.html], owner: nil)
        pasteboard.setString("<meta charset='utf-8'><" + element + " src='data:image/png;base64,AAAA'>", forType: .html)
        #expect(checkNow().count == 1)
      }
    }

    @Test("RTF-only text is blocked")
    func ignoreRTFOnly() throws {
      Defaults[.ignoreRegexp] = ["secret"]
      for (text, expected) in [("secret", 0), ("ordinary text", 1)] {
        let attributed = NSAttributedString(string: text)
        let data = try #require(attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [:]))
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(data, forType: .rtf)
        #expect(checkNow().count == expected)
      }
    }

    @Test("One matching item rejects the entire event, in either order")
    func ignoreWholeEvent() {
      Defaults[.ignoreRegexp] = ["secret"]
      for texts in [["ordinary text", "secret"], ["secret", "ordinary text"]] {
        let items = texts.map { text in
          let item = NSPasteboardItem()
          item.setString(text, forType: .string)
          return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        #expect(checkNow().isEmpty)
      }
    }

    @Test("A rich representation is checked even alongside harmless plain text and when disabled")
    func inspectAllRepresentations() {
      Defaults[.ignoreRegexp] = ["secret"]
      Defaults[.enabledPasteboardTypes] = [.string]
      copyString("ordinary text", types: [.string, .html])
      pasteboard.setString("<p>secret</p>", forType: .html)
      #expect(checkNow().isEmpty)
    }

    @Test("Text cap rejects the whole event rather than truncating, including a padded secret")
    func ignoreTextLimit() {
      Defaults[.ignoreRegexp] = ["secret"]
      copyString(String(repeating: "a", count: IgnoreRules.textLimit))
      #expect(checkNow().count == 1)
      copyString(String(repeating: "a", count: IgnoreRules.textLimit + 1))
      #expect(checkNow().isEmpty)
      copyString(String(repeating: "a", count: IgnoreRules.textLimit) + "secret")
      #expect(checkNow().isEmpty)
      // Count UTF-16 units, not grapheme clusters.
      copyString(String(repeating: "😀", count: IgnoreRules.textLimit / 2 + 1))
      #expect(checkNow().isEmpty)
    }

    @Test("Text and raw-data caps cover all items and rich-text markup")
    func ignoreAggregateAndDataLimits() {
      Defaults[.ignoreRegexp] = ["secret"]
      let items = (0..<2).map { index in
        let item = NSPasteboardItem()
        item.setString(String(repeating: "a", count: IgnoreRules.textLimit / 2 + 1) + String(index), forType: .string)
        return item
      }
      pasteboard.clearContents()
      pasteboard.writeObjects(items)
      #expect(checkNow().isEmpty)
      copyRichText("<!--" + String(repeating: "a", count: IgnoreRules.dataLimit) + "--><p>safe</p>", type: .html)
      #expect(checkNow().isEmpty)
    }

    @Test("Malformed HTML remains usable; unreadable RTF still fails closed")
    func ignoreUnreadableRichText() {
      Defaults[.ignoreRegexp] = ["secret"]
      for html in ["<p>unclosed", "<!DOCTYPE html><p>safe</p>", "<p>&unknown;</p>",
                   "<!DOCTYPE x [<!ENTITY x 'secret'>]><p>&x;</p>"] {
        copyRichText(html, type: .html)
        #expect(checkNow().count == 1)
      }
      copyRichText("not RTF", type: .rtf)
      #expect(checkNow().isEmpty)
    }

    @Test("Expensive backtracking fails closed without consuming skip next")
    func expensiveIgnoreRule() {
      Defaults[.ignoreRegexp] = ["^(a+)+$"]
      setCaptureMode(.skipNext)
      copyString(String(repeating: "a", count: 200) + "!")
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .skipNext)
    }

    @Test("Raw preference changes invalidate the watcher's cached rules without a notification")
    func ignoreRuleCacheRefreshes() {
      let defaults = Defaults.Keys.ignoreRegexp.suite
      defaults.set(["first"], forKey: Defaults.Keys.ignoreRegexp.name)
      copyString("first")
      #expect(checkNow().isEmpty)
      defaults.set(["second"], forKey: Defaults.Keys.ignoreRegexp.name)
      copyString("first")
      #expect(checkNow().count == 1)
      copyString("second")
      #expect(checkNow().isEmpty)
      defaults.set("wrong type", forKey: Defaults.Keys.ignoreRegexp.name)
      copyString("ordinary text")
      #expect(checkNow().isEmpty)
      #expect(IgnoreRules().hasInvalidStoredRules)
      defaults.set([], forKey: Defaults.Keys.ignoreRegexp.name)
      copyString("second")
      #expect(checkNow().count == 1)
    }

    @Test("Save-time validation preserves the stored rule, then the watcher uses the repaired rule")
    func validateIgnoreRuleOnSave() {
      Defaults[.ignoreRegexp] = ["secret"]
      for draft in ["[", "", String(repeating: "a", count: IgnoreRules.patternLimit + 1)] {
        #expect(!IgnoreRules.save(draft, replacingAt: 0))
        #expect(Defaults[.ignoreRegexp] == ["secret"])
        copyString("secret")
        #expect(checkNow().isEmpty)
      }
      #expect(IgnoreRules.save("token", replacingAt: 0))
      copyString("token")
      #expect(checkNow().isEmpty)
      copyString("secret")
      #expect(checkNow().count == 1)
    }

    @Test("An ignored rich-text or multi-item event leaves skip next armed")
    func ignoredRichCopyDoesNotConsumeSkipNext() {
      Defaults[.ignoreRegexp] = ["secret"]
      setCaptureMode(.skipNext)
      copyRichText("<p>secret</p>", type: .html)
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .skipNext)
      ignoreWholeEvent()
      #expect(storedCaptureMode == .skipNext)
      copyString("ordinary text")
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .capturing)
      copyString("next copy")
      #expect(checkNow().count == 1)
    }

    @Test("Chrome HTML beside empty plain text is captured without rules, including large copies")
    func chromeHTMLWithoutRules() {
      for count in [1, IgnoreRules.dataLimit + 1] {
        copyString("")
        pasteboard.addTypes([.html], owner: nil)
        pasteboard.setString("<meta charset='utf-8'><!--StartFragment--><b>" +
                             String(repeating: "a", count: count) + "</b><!--EndFragment-->", forType: .html)
        #expect(checkNow().count == 1)
      }
    }

    @Test("Ordinary browser and document fragments are captured with rules; hidden source matches reject")
    func tolerantHTMLWatcher() {
      Defaults[.ignoreRegexp] = ["password"]
      for html in ["<meta charset='utf-8'><!--StartFragment--><p class=copy>ordinary&nbsp;text<br>more",
                   "<!DOCTYPE html><!--[if mso]><xml>office</xml><![endif]--><p>ordinary text</p>",
                   "<p>unclosed", "ordinary &bad; text", "<p title='unfinished"] {
        copyRichText(html, type: .html)
        #expect(checkNow().count == 1)
      }
      for html in ["pass<b>word</b>", "<p title=password>ordinary text</p>",
                   "<!--password--><p>ordinary</p>", "<script>password</script><p>ordinary</p>",
                   "pass&#119;ord"] {
        copyRichText(html, type: .html)
        #expect(checkNow().isEmpty)
      }
      pasteboard.declareTypes([.html], owner: nil)
      pasteboard.setData("<p>pass<b>word</b>".data(using: .utf16), forType: .html)
      #expect(checkNow().isEmpty)
    }

    @Test("Undelivered advertised HTML rejects the event and preserves skip next")
    func undeliveredHTML() {
      Defaults[.ignoreRegexp] = ["secret"]
      setCaptureMode(.skipNext)
      copyString("ordinary", types: [.string, .html])
      #expect(checkNow().isEmpty)
      #expect(storedCaptureMode == .skipNext)
      let rules = IgnoreRules()
      #expect(rules.rejects(pasteboard.pasteboardItems ?? []))
      #expect(rules.lastRejection == .undecodable)
    }

    @Test("An invalid stored entry remains removable and repairable at the settings boundary")
    func removeInvalidRule() {
      Defaults[.ignoreRegexp] = ["[", "secret"]
      #expect(IgnoreRules.remove(at: 0))
      #expect(Defaults[.ignoreRegexp] == ["secret"])
      copyString("ordinary")
      #expect(checkNow().count == 1)
      #expect(!IgnoreRules.remove(at: 5))
      Defaults[.ignoreRegexp] = ["["]
      #expect(IgnoreRules.save("token", replacingAt: 0))
      copyString("token")
      #expect(checkNow().isEmpty)
    }

    private func copyRichText(_ text: String, type: NSPasteboard.PasteboardType) {
      pasteboard.declareTypes([type], owner: nil)
      pasteboard.setString(text, forType: type)
    }

    private var preferences: UserDefaults { clipboard.capturePreferences }

    private var storedCaptureMode: CaptureMode { CaptureMode.stored(in: preferences) }

    // Writes the mode the way `defaults write` would, then treats everything on
    // the pasteboard so far as seen.
    private func setCaptureMode(_ mode: CaptureMode) {
      preferences.set(mode.rawValue, forKey: CaptureMode.defaultsKey)
      clipboard.syncCaptureState()
    }

    private func copyString(_ string: String, types: [NSPasteboard.PasteboardType] = [.string]) {
      pasteboard.declareTypes(types, owner: nil)
      pasteboard.setString(string, forType: .string)
    }

    // Runs one watcher check now and returns what it recorded.
    private func checkNow() -> [HistoryItem] {
      var copies: [HistoryItem] = []
      clipboard.clearHooks()
      clipboard.onNewCopy { copies.append($0) }
      clipboard.checkForChangesInPasteboard()
      clipboard.clearHooks()
      return copies
    }

    private func waitForCopies(expectingCopy: Bool = true, after trigger: () -> Void) async throws -> [HistoryItem] {
      var copies: [HistoryItem] = []
      clipboard.onNewCopy { copies.append($0) }
      clipboard.start()
      trigger()
      let deadline = ContinuousClock.now + .seconds(2)
      while (!expectingCopy || copies.isEmpty) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      return copies
    }

    private func frontmostAppBundleIdentifier() throws -> String {
      guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
        try Test.cancel("No frontmost application to attribute a copy to")
      }

      return bundleIdentifier
    }
  }
  // swiftlint:enable type_body_length
}

// The raw capture settings, so a test can start from none and restore them.
struct SavedCaptureSettings: @unchecked Sendable {
  static let keys = [
    CaptureMode.defaultsKey,
    CaptureMode.legacyIgnoreEventsKey,
    CaptureMode.legacyIgnoreOnlyNextEventKey
  ]

  let defaults: UserDefaults
  let values: [String: Any]

  init(_ defaults: UserDefaults) {
    self.defaults = defaults
    values = Self.keys.reduce(into: [:]) { values, key in
      values[key] = defaults.object(forKey: key)
    }
  }

  func clear() {
    Self.keys.forEach(defaults.removeObject(forKey:))
  }

  func restore() {
    clear()
    values.forEach { defaults.set($1, forKey: $0) }
  }
}

// A preferences domain where some keys are pinned the way a configuration
// profile pins them: reads return the pinned value and writes don't change it.
final class ManagedDefaults: UserDefaults, @unchecked Sendable {
  private let forced: [String: Any]

  init?(suiteName: String, forced: [String: Any]) {
    self.forced = forced
    super.init(suiteName: suiteName)
  }

  override func objectIsForced(forKey defaultName: String) -> Bool {
    forced[defaultName] != nil || super.objectIsForced(forKey: defaultName)
  }

  override func object(forKey defaultName: String) -> Any? {
    forced[defaultName] ?? super.object(forKey: defaultName)
  }

  override func removeObject(forKey defaultName: String) {
    if forced[defaultName] == nil {
      super.removeObject(forKey: defaultName)
    }
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    if forced[defaultName] == nil {
      super.set(value, forKey: defaultName)
    }
  }
}

// swiftlint:disable:next type_body_length
struct CaptureModeTests {
  @Test("Only capturing records copies")
  func onlyCapturingRecordsCopies() {
    #expect(CaptureMode.capturing.capturesCopies)
    #expect(!CaptureMode.paused.capturesCopies)
    #expect(!CaptureMode.skipNext.capturesCopies)
  }

  @Test("More restrictive mode", arguments: [
    (CaptureMode.capturing, CaptureMode.capturing, CaptureMode.capturing),
    (.capturing, .skipNext, .skipNext),
    (.capturing, .paused, .paused),
    (.skipNext, .capturing, .skipNext),
    (.skipNext, .paused, .paused),
    (.paused, .capturing, .paused),
    (.paused, .skipNext, .paused)
  ])
  func atLeast(mode: CaptureMode, other: CaptureMode, expected: CaptureMode) {
    #expect(mode.atLeast(other) == expected)
  }

  // MARK: Reading the stored value

  @Test("An absent captureMode means capturing")
  func absentMeansCapturing() throws {
    let defaults = try Self.makeDefaults()
    #expect(CaptureMode.stored(in: defaults) == .capturing)
    #expect(CaptureMode.effective(in: defaults) == .capturing)
  }

  @Test("Each case name reads back as itself", arguments: CaptureMode.allCases)
  func readsCaseNames(mode: CaptureMode) throws {
    let defaults = try Self.makeDefaults()
    // What `defaults write org.p0deje.Maccy captureMode <mode>` stores.
    defaults.set(mode.rawValue, forKey: CaptureMode.defaultsKey)
    #expect(CaptureMode.stored(in: defaults) == mode)
    #expect(CaptureMode.effective(in: defaults) == mode)
  }

  @Test("A malformed captureMode string means paused", arguments: [
    "pause", "PAUSED", "Capturing", "CAPTURING", "capturing ", " paused", "skipnext", "skip_next", "", "true", "0"
  ])
  func malformedStringMeansPaused(value: String) throws {
    let defaults = try Self.makeDefaults()
    defaults.set(value, forKey: CaptureMode.defaultsKey)
    #expect(CaptureMode.stored(in: defaults) == .paused)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("A captureMode of the wrong type means paused", arguments: [
    true as any Sendable, false, 0, 1, 2.5, ["capturing"], ["captureMode": "capturing"], Data("capturing".utf8), Date()
  ])
  func wrongTypeMeansPaused(value: any Sendable) throws {
    let defaults = try Self.makeDefaults()
    defaults.set(value, forKey: CaptureMode.defaultsKey)
    #expect(CaptureMode.stored(in: defaults) == .paused)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("Legacy boolean values", arguments: [
    (true as any Sendable, true), (false, false), (1, true), (0, false),
    ("true", true), ("YES", true), ("1", true), ("false", false), ("NO", false), ("0", false),
    // Malformed: pause rather than capture.
    ("maybe", true), ("", true), (["true"], true)
  ])
  func legacyFlag(value: any Sendable, expected: Bool) throws {
    let defaults = try Self.makeDefaults()
    #expect(CaptureMode.legacyFlag(CaptureMode.legacyIgnoreEventsKey, in: defaults) == nil)
    defaults.set(value, forKey: CaptureMode.legacyIgnoreEventsKey)
    #expect(CaptureMode.legacyFlag(CaptureMode.legacyIgnoreEventsKey, in: defaults) == expected)
  }

  // MARK: Legacy keys after migration

  @Test("Legacy ignoreEvents that reads true pauses, whatever captureMode says", arguments: CaptureMode.allCases)
  func legacyIgnoreEventsPauses(mode: CaptureMode) throws {
    let defaults = try Self.makeMigratedDefaults()
    defaults.set(mode.rawValue, forKey: CaptureMode.defaultsKey)
    defaults.set("true", forKey: CaptureMode.legacyIgnoreEventsKey)
    #expect(CaptureMode.effective(in: defaults) == .paused)

    defaults.set("false", forKey: CaptureMode.legacyIgnoreEventsKey)
    #expect(CaptureMode.effective(in: defaults) == mode)
  }

  @Test("Legacy ignoreOnlyNextEvent arms skip next once, then is removed")
  func legacyOneShotIsAbsorbed() throws {
    let defaults = try Self.makeMigratedDefaults()
    defaults.set(true, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
    #expect(CaptureMode.effective(in: defaults) == .skipNext)

    CaptureMode.absorbLegacyOneShot(in: defaults)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreOnlyNextEventKey) == nil)
    #expect(CaptureMode.stored(in: defaults) == .skipNext)

    CaptureMode.consumeSkip(in: defaults)
    #expect(CaptureMode.effective(in: defaults) == .capturing)
  }

  @Test("Legacy ignoreOnlyNextEvent doesn't downgrade a pause")
  func legacyOneShotKeepsPause() throws {
    let defaults = try Self.makeMigratedDefaults()
    defaults.set(CaptureMode.paused.rawValue, forKey: CaptureMode.defaultsKey)
    defaults.set(true, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)

    CaptureMode.absorbLegacyOneShot(in: defaults)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreOnlyNextEventKey) == nil)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("Skip next is consumed only from skip next")
  func consumeSkipOnlyFromSkipNext() throws {
    let defaults = try Self.makeDefaults()
    for mode in [CaptureMode.capturing, .paused] {
      defaults.set(mode.rawValue, forKey: CaptureMode.defaultsKey)
      CaptureMode.consumeSkip(in: defaults)
      #expect(CaptureMode.stored(in: defaults) == mode)
    }
  }

  // MARK: Requests from the UI

  @Test("Status item clicks")
  func statusItemClick() {
    let cases: [(NSEvent.ModifierFlags, CaptureModeRequest?)] = [
      ([], nil),
      ([.shift], nil),
      ([.command], nil),
      ([.option], .togglePause),
      ([.option, .command], .togglePause),
      ([.option, .shift], .toggleSkipNext)
    ]
    for (modifierFlags, expected) in cases {
      #expect(CaptureModeRequest(statusItemClickWith: modifierFlags) == expected)
    }
  }

  @Test("Requests", arguments: [
    (CaptureMode.capturing, CaptureModeRequest.togglePause, CaptureMode.paused),
    (.paused, .togglePause, .capturing),
    (.skipNext, .togglePause, .capturing),
    (.capturing, .toggleSkipNext, .skipNext),
    (.paused, .toggleSkipNext, .capturing),
    (.skipNext, .toggleSkipNext, .capturing),
    (.capturing, .pause, .paused),
    (.skipNext, .pause, .paused),
    (.paused, .resume, .capturing),
    (.skipNext, .resume, .capturing)
  ])
  func requests(from mode: CaptureMode, request: CaptureModeRequest, expected: CaptureMode) throws {
    let defaults = try Self.makeMigratedDefaults()
    defaults.set(mode.rawValue, forKey: CaptureMode.defaultsKey)
    #expect(CaptureMode.perform(request, in: defaults) == expected)
    // Persisted, not just returned.
    #expect(CaptureMode.stored(in: defaults) == expected)
  }

  @Test("Arm skip next, cancel, pause: each click persists and the result stays paused")
  func cancelledSkipNextThenPause() throws {
    let defaults = try Self.makeMigratedDefaults()
    let optionShift = try #require(CaptureModeRequest(statusItemClickWith: [.option, .shift]))
    let option = try #require(CaptureModeRequest(statusItemClickWith: [.option]))

    CaptureMode.perform(optionShift, in: defaults)
    #expect(CaptureMode.stored(in: defaults) == .skipNext)
    CaptureMode.perform(optionShift, in: defaults)
    #expect(CaptureMode.stored(in: defaults) == .capturing)
    CaptureMode.perform(option, in: defaults)
    #expect(CaptureMode.stored(in: defaults) == .paused)

    // Copies observed while paused leave it paused.
    CaptureMode.consumeSkip(in: defaults)
    CaptureMode.consumeSkip(in: defaults)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("Resuming clears pauses and one-shots written to the legacy keys")
  func resumeClearsLegacyKeys() throws {
    let defaults = try Self.makeMigratedDefaults()
    defaults.set(true, forKey: CaptureMode.legacyIgnoreEventsKey)
    defaults.set(true, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
    #expect(CaptureMode.effective(in: defaults) == .paused)

    #expect(CaptureMode.perform(.togglePause, in: defaults) == .capturing)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreEventsKey) == nil)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreOnlyNextEventKey) == nil)
  }

  // MARK: Attributing a pasteboard change

  @Test("Attributing a change", arguments: [
    (CaptureMode.capturing, CaptureMode.capturing as CaptureMode?, false, true),
    (.capturing, .capturing, true, false),
    (.capturing, .paused, false, false),
    (.capturing, .skipNext, false, false),
    (.capturing, nil, false, false),
    (.skipNext, .skipNext, false, true),
    (.skipNext, .skipNext, true, false),
    (.skipNext, .capturing, false, false),
    (.skipNext, .paused, false, false),
    (.paused, .paused, false, false)
  ])
  func attributable(mode: CaptureMode, previous: CaptureMode?, settingsChanged: Bool, expected: Bool) {
    let attributable = CaptureMode.changeIsAttributable(
      to: mode,
      previousMode: previous,
      settingsChanged: settingsChanged
    )
    #expect(attributable == expected)
  }

  @Test("Change flag is taken once")
  func changeFlag() {
    let flag = CaptureSettingsChangeFlag()
    #expect(!flag.take())
    flag.set()
    flag.set()
    #expect(flag.take())
    #expect(!flag.take())
  }

  // MARK: Configuration profiles

  @Test("A forced paused captureMode can't be resumed", arguments: CaptureModeRequest.allRequests)
  func forcedPauseLocks(request: CaptureModeRequest) throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.defaultsKey: CaptureMode.paused.rawValue])
    #expect(CaptureMode.isLockedByProfile(in: defaults))
    #expect(CaptureMode.perform(request, in: defaults) == .paused)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("A forced skipNext is paused, never consumed")
  func forcedSkipNextIsPaused() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.defaultsKey: CaptureMode.skipNext.rawValue])
    #expect(CaptureMode.effective(in: defaults) == .paused)
    CaptureMode.consumeSkip(in: defaults)
    #expect(CaptureMode.effective(in: defaults) == .paused)
    #expect(CaptureMode.isLockedByProfile(in: defaults))
    #expect(CaptureMode.perform(.resume, in: defaults) == .paused)
  }

  @Test("A forced malformed captureMode is paused and locked")
  func forcedMalformedIsPaused() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.defaultsKey: "Paused"])
    #expect(CaptureMode.effective(in: defaults) == .paused)
    #expect(CaptureMode.isLockedByProfile(in: defaults))
  }

  @Test("A forced capturing captureMode locks the controls too")
  func forcedCapturingLocks() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.defaultsKey: CaptureMode.capturing.rawValue])
    #expect(CaptureMode.isLockedByProfile(in: defaults))
    #expect(CaptureMode.perform(.pause, in: defaults) == .capturing)
  }

  @Test("A forced legacy ignoreEvents pauses and can't be resumed", arguments: CaptureModeRequest.allRequests)
  func forcedLegacyPauseLocks(request: CaptureModeRequest) throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.legacyIgnoreEventsKey: true])
    CaptureMode.migrateLegacyDefaults(in: defaults)
    #expect(CaptureMode.effective(in: defaults) == .paused)
    #expect(CaptureMode.isLockedByProfile(in: defaults))
    let storedBefore = defaults.string(forKey: CaptureMode.defaultsKey)
    #expect(CaptureMode.perform(request, in: defaults) == .paused)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreEventsKey) as? Bool == true)
    // Nothing is written, so removing the profile doesn't reveal a resume made
    // while it was installed.
    #expect(defaults.string(forKey: CaptureMode.defaultsKey) == storedBefore)
  }

  @Test("A forced legacy ignoreEvents of false neither pauses nor locks")
  func forcedLegacyFalseDoesNotLock() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.legacyIgnoreEventsKey: false])
    CaptureMode.migrateLegacyDefaults(in: defaults)
    #expect(CaptureMode.effective(in: defaults) == .capturing)
    #expect(!CaptureMode.isLockedByProfile(in: defaults))
    #expect(CaptureMode.perform(.pause, in: defaults) == .paused)
  }

  @Test("A forced legacy ignoreOnlyNextEvent can't be removed, so it pauses")
  func forcedLegacyOneShotPauses() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.legacyIgnoreOnlyNextEventKey: true])
    CaptureMode.migrateLegacyDefaults(in: defaults)
    CaptureMode.absorbLegacyOneShot(in: defaults)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreOnlyNextEventKey) as? Bool == true)
    #expect(CaptureMode.effective(in: defaults) == .paused)
    #expect(CaptureMode.isLockedByProfile(in: defaults))
    #expect(CaptureMode.perform(.resume, in: defaults) == .paused)
  }

  @Test("With a forced captureMode, migration keeps a legacy pause it can't replace")
  func forcedCaptureModeKeepsLegacyPause() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.defaultsKey: CaptureMode.capturing.rawValue])
    defaults.set(true, forKey: CaptureMode.legacyIgnoreEventsKey)
    #expect(CaptureMode.effective(in: defaults) == .paused)

    CaptureMode.migrateLegacyDefaults(in: defaults)

    #expect(CaptureMode.legacyFlag(CaptureMode.legacyIgnoreEventsKey, in: defaults) == true)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("With a forced captureMode, a legacy one-shot pauses and is kept by migration and the watcher")
  func forcedCaptureModeTurnsLegacyOneShotIntoPause() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.defaultsKey: CaptureMode.capturing.rawValue])
    defaults.set(true, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
    #expect(CaptureMode.effective(in: defaults) == .paused)

    CaptureMode.migrateLegacyDefaults(in: defaults)
    #expect(CaptureMode.effective(in: defaults) == .paused)

    CaptureMode.absorbLegacyOneShot(in: defaults)
    CaptureMode.consumeSkip(in: defaults)

    #expect(CaptureMode.legacyFlag(CaptureMode.legacyIgnoreOnlyNextEventKey, in: defaults) == true)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("A legacy one-shot written after migration pauses while captureMode is forced")
  func forcedCaptureModeLegacyOneShotAfterMigration() throws {
    let defaults = try Self.makeManagedDefaults([CaptureMode.defaultsKey: CaptureMode.capturing.rawValue])
    CaptureMode.migrateLegacyDefaults(in: defaults)
    #expect(CaptureMode.effective(in: defaults) == .capturing)

    defaults.set("true", forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
    CaptureMode.absorbLegacyOneShot(in: defaults)

    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  // MARK: Migration

  // nil means the old key is absent.
  @Test("Migrates legacy keys", arguments: [
    (nil as Bool?, nil as Bool?, CaptureMode.capturing),
    (false, nil, .capturing),
    (nil, false, .capturing),
    (false, false, .capturing),
    (true, nil, .paused),
    (true, false, .paused),
    // Both true is the stale-flag state from the original bug: pause.
    (true, true, .paused),
    // The documented "ignore next copy" command on its own.
    (nil, true, .skipNext),
    (false, true, .skipNext)
  ])
  func migratesLegacyKeys(ignoreEvents: Bool?, ignoreOnlyNextEvent: Bool?, expected: CaptureMode) throws {
    let defaults = try Self.makeDefaults()
    if let ignoreEvents {
      defaults.set(ignoreEvents, forKey: CaptureMode.legacyIgnoreEventsKey)
    }
    if let ignoreOnlyNextEvent {
      defaults.set(ignoreOnlyNextEvent, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
    }

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == expected)
    #expect(CaptureMode.effective(in: defaults) == expected)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreEventsKey) == nil)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreOnlyNextEventKey) == nil)
  }

  @Test("Migrates string values written by a plain defaults write")
  func migratesStringValues() throws {
    let defaults = try Self.makeDefaults()
    // `defaults write org.p0deje.Maccy ignoreEvents true` stores the string "true".
    defaults.set("true", forKey: CaptureMode.legacyIgnoreEventsKey)

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == .paused)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("Migration keeps the more restrictive of captureMode and the legacy keys", arguments: [
    // An explicit pause is not downgraded by a stale one-shot flag.
    (CaptureMode.paused, nil as Bool?, true as Bool?, CaptureMode.paused),
    (.paused, false, true, .paused),
    (.paused, false, false, .paused),
    (.skipNext, true, nil, .paused),
    (.skipNext, nil, true, .skipNext),
    (.capturing, true, nil, .paused),
    (.capturing, nil, true, .skipNext)
  ])
  func migrationKeepsMoreRestrictive(
    stored: CaptureMode,
    ignoreEvents: Bool?,
    ignoreOnlyNextEvent: Bool?,
    expected: CaptureMode
  ) throws {
    let defaults = try Self.makeDefaults()
    defaults.set(stored.rawValue, forKey: CaptureMode.defaultsKey)
    if let ignoreEvents {
      defaults.set(ignoreEvents, forKey: CaptureMode.legacyIgnoreEventsKey)
    }
    if let ignoreOnlyNextEvent {
      defaults.set(ignoreOnlyNextEvent, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
    }

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == expected)
    #expect(CaptureMode.effective(in: defaults) == expected)
  }

  @Test("Migration leaves a malformed captureMode in place, still paused")
  func migrationKeepsMalformedValue() throws {
    let defaults = try Self.makeDefaults()
    defaults.set("Capturing", forKey: CaptureMode.defaultsKey)

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == .paused)
    #expect(defaults.string(forKey: CaptureMode.defaultsKey) == "Capturing")
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  @Test("Migration runs once, but legacy keys written later still count")
  func legacyKeysAfterMigration() throws {
    let defaults = try Self.makeDefaults()
    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == .capturing)

    // An old script writing the old keys afterwards.
    defaults.set(true, forKey: CaptureMode.legacyIgnoreEventsKey)
    defaults.set(true, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == nil)
    #expect(CaptureMode.effective(in: defaults) == .paused)
  }

  // A throwaway preferences domain.
  private static func makeDefaults() throws -> UserDefaults {
    let suiteName = "org.p0deje.Maccy.tests.captureMode.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private static func makeMigratedDefaults() throws -> UserDefaults {
    let defaults = try makeDefaults()
    CaptureMode.migrateLegacyDefaults(in: defaults)
    return defaults
  }

  private static func makeManagedDefaults(_ forced: [String: Any]) throws -> UserDefaults {
    let suiteName = "org.p0deje.Maccy.tests.captureMode.\(UUID().uuidString)"
    let defaults = try #require(ManagedDefaults(suiteName: suiteName, forced: forced))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}

extension CaptureModeRequest {
  static let allRequests: [CaptureModeRequest] = [.togglePause, .toggleSkipNext, .pause, .resume]
}


@MainActor
struct ClipboardHTMLTextTests {
  @Test("Tolerant HTML extraction", arguments: [
    ("<meta charset='utf-8'><!--StartFragment--><p class=copy>pass<b>word</b><br>next&nbsp;line</p><!--EndFragment-->", " password next\u{00A0}line "),
    ("<!DOCTYPE html><!--[if mso]><xml>office</xml><![endif]--><p>Word<span> text</span></p>", " Word text "),
    ("&amp;&lt;&gt;&quot;&apos;&nbsp;&#65;&#x1F600;", "&<>\"'\u{00A0}A😀"),
    ("pass<b>word</b><span>123</span>", "password123"),
    ("a<script src=x>hidden <b>script</b></script><style>hidden</style>b", "ab"),
    ("a<!--unfinished", "a"),
    ("a<b title='unterminated", "a"),
    ("a<b <span>c</span>", "ac"),
    ("a &bogus; &#xZZ; &#0; &#xD800; &unfinished", "a &bogus; &#xZZ; &#0; &#xD800; &unfinished"),
    ("a < 3 and > 1", "a < 3 and > 1"),
    ("<div>a</div><div>b</div>", " a b "),
    ("<span title='a>b'>text</span>", "text")
  ])
  func fragments(input: String, expected: String) {
    #expect(ClipboardHTMLText.extract(Data(input.utf8)) == expected)
  }

  @Test("UTF-16 HTML, with and without BOM", arguments: [
    String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian
  ])
  func utf16(encoding: String.Encoding) throws {
    let data = try #require("<meta charset=utf-16>pass<b>word</b>".data(using: encoding))
    #expect(ClipboardHTMLText.extract(data) == "password")
  }

  @Test("Undecodable HTML fails explicitly")
  func undecodable() {
    #expect(ClipboardHTMLText.extract(Data([0xFF])) == nil)
    #expect(ClipboardHTMLText.extract(Data([0xEF, 0xBB, 0xBF]) + Data("pass<b>word</b>".utf8)) == "password")
    #expect(ClipboardHTMLText.extract(Data("text".utf8) + Data([0xFF])) == "text\u{FFFD}")
  }

  @Test("Hidden extraction excludes CSS/data payloads and tolerates raw-text elements and stray quotes")
  func hiddenExtraction() {
    let fragment = ClipboardHTMLText.inspect("<a href=/it's>sk_live_</a><b>abc</b> don't")
    #expect(fragment.visible == "sk_live_abc don't")
    #expect(fragment.hidden == "/it's")
    #expect(ClipboardHTMLText.extract("<style><!-- /* Word's defs */ x{} --></STYLE>secret") == "secret")
    let text = ClipboardHTMLText.inspect("<img src='data:image/png;base64,AAAA' style='secret'><a href='https://x/secret'>safe</a><!--secret--><script>if(a < b) 'secret'</SCRIPT>")
    #expect(text.visible == "safe")
    #expect(text.hidden.contains("data:image/png;base64,"))
    #expect(!text.hidden.contains("AAAA"))
    #expect(text.hidden.contains("https://x/secret"))
    #expect(text.hidden.contains("if(a < b) 'secret'"))
    #expect(text.hasContent)
    #expect(ClipboardHTMLText.inspect("<img src='data:image/png;base64,AAAA BBBB'>").hidden == "data:image/png;base64,")
  }

  @Test("BOM-less UTF-16 beyond the ASCII signature is decoded; embedded NULs fail closed")
  func utf16Nuls() throws {
    let text = String(repeating: "日本語", count: 100) + "<b>secret</b>"
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
      let data = try #require(text.data(using: encoding))
      #expect(ClipboardHTMLText.decode(data) == text)
    }
    #expect(ClipboardHTMLText.decode(Data([0, 0, 0, 0])) == nil)
  }

  @Test("Settings distinguish unreadable, too many and invalid rules; reset and add honor ownership")
  func configurationStates() throws {
    let suite = "org.p0deje.Maccy.tests.ignoreRules.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = Defaults.Keys.ignoreRegexp.name
    for raw: Any in ["foo", ["secret", 42] as [Any]] {
      defaults.set(raw, forKey: key)
      #expect(IgnoreRules.configurationIssue(in: defaults) == .unreadable)
      #expect(!IgnoreRules.save("valid", in: defaults))
      #expect(IgnoreRules.configurationIssue(in: defaults) == .unreadable)
      #expect(IgnoreRules(preferences: defaults).rejects([]))
      #expect(IgnoreRules.reset(in: defaults))
      #expect(IgnoreRules.configurationIssue(in: defaults) == nil)
    }
    defaults.set(Array(repeating: "valid", count: IgnoreRules.ruleLimit + 1), forKey: key)
    #expect(IgnoreRules.configurationIssue(in: defaults) == .tooManyRules)
    #expect(IgnoreRules(preferences: defaults).rejects([]))
    #expect(IgnoreRules.remove(at: 0, in: defaults))
    #expect(IgnoreRules.configurationIssue(in: defaults) == nil)
    defaults.set(["["], forKey: key)
    #expect(IgnoreRules.configurationIssue(in: defaults) == .invalidRule)
    let managed = try #require(ManagedDefaults(suiteName: suite + ".managed", forced: [key: "foo"]))
    #expect(!IgnoreRules.reset(in: managed))
    #expect(IgnoreRules.configurationIssue(in: managed) == .unreadable)
  }

  @Test("Text is counted once across plain, HTML and RTF, with trailing whitespace normalized")
  func deduplicatedText() throws {
    let suite = "org.p0deje.Maccy.tests.ignoreRules.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["secret"], forKey: Defaults.Keys.ignoreRegexp.name)
    let text = String(repeating: "ordinary ", count: IgnoreRules.textLimit / 9 - 1)
    let item = NSPasteboardItem()
    item.setString(text + "\n", forType: .string)
    item.setString("<span>" + text + "</span>", forType: .html)
    let attributed = NSAttributedString(string: text)
    item.setData(try #require(attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                                            documentAttributes: [:])), forType: .rtf)
    #expect(!IgnoreRules(preferences: defaults).rejects([item]))
  }

  @Test("Cheap representations across all items precede RTF; RTF has its own aggregate byte cap")
  func rtfCostBoundary() throws {
    let suite = "org.p0deje.Maccy.tests.ignoreRules.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["secret"], forKey: Defaults.Keys.ignoreRegexp.name)
    let rules = IgnoreRules(preferences: defaults)
    let rtf = NSPasteboardItem()
    rtf.setData(Data(repeating: 97, count: IgnoreRules.rtfDataLimit + 1), forType: .rtf)
    let plain = NSPasteboardItem()
    plain.setString("secret", forType: .string)
    #expect(rules.rejects([rtf, plain]))
    #expect(rules.lastRejection == .matchedRule)
    plain.setString("<b>secret</b>", forType: .html)
    plain.setString("ordinary", forType: .string)
    #expect(rules.rejects([rtf, plain]))
    #expect(rules.lastRejection == .matchedRule)
    #expect(rules.rejects([rtf]))
    #expect(rules.lastRejection == .rtfDataLimit)
    defaults.set([], forKey: Defaults.Keys.ignoreRegexp.name)
    #expect(!rules.rejects([rtf]))
  }

  @Test("Managed lists refuse replacement, addition and deletion without shadow writes")
  func managedRules() throws {
    let key = Defaults.Keys.ignoreRegexp.name
    let suite = "org.p0deje.Maccy.tests.ignoreRules.\(UUID().uuidString)"
    let defaults = try #require(ManagedDefaults(suiteName: suite, forced: [key: ["["]]))
    #expect(IgnoreRules.isManaged(in: defaults))
    #expect(!IgnoreRules.save("valid", replacingAt: 0, in: defaults))
    #expect(!IgnoreRules.save("valid", in: defaults))
    #expect(!IgnoreRules.remove(at: 0, in: defaults))
    #expect(defaults.object(forKey: key) as? [String] == ["["])
    #expect(defaults.persistentDomain(forName: suite)?[key] == nil)
    let rules = IgnoreRules(preferences: defaults)
    #expect(rules.hasInvalidStoredRules)
    #expect(rules.rejects([]))
    #expect(rules.lastRejection == .invalidStoredRule)
  }

  @Test("Data preflight precedes decoding; rejection categories contain no copied text")
  func rejectionReasons() throws {
    let suite = "org.p0deje.Maccy.tests.ignoreRules.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["secret"], forKey: Defaults.Keys.ignoreRegexp.name)
    let rules = IgnoreRules(preferences: defaults)
    let broken = NSPasteboardItem()
    broken.setData(Data([0xFF]), forType: .html)
    let huge = NSPasteboardItem()
    huge.setData(Data(repeating: 97, count: IgnoreRules.dataLimit + 1), forType: .html)
    #expect(rules.rejects([broken, huge]))
    #expect(rules.lastRejection == .dataLimit)
    #expect(rules.rejects([broken]))
    #expect(rules.lastRejection == .undecodable)
    let item = NSPasteboardItem()
    item.setString("secret", forType: .string)
    #expect(rules.rejects([item]))
    #expect(rules.lastRejection == .matchedRule)
    item.setString(String(repeating: "a", count: IgnoreRules.textLimit + 1), forType: .string)
    #expect(rules.rejects([item]))
    #expect(rules.lastRejection == .textLimit)
    defaults.set(["^(a+)+$"], forKey: Defaults.Keys.ignoreRegexp.name)
    item.setString(String(repeating: "a", count: 200) + "!", forType: .string)
    #expect(rules.rejects([item]))
    #expect(rules.lastRejection == .timeBudget)
  }
}
