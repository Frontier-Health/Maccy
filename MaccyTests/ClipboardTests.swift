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
    let savedCaptureMode = Defaults[.captureMode]
    let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
    let savedIgnoredApps = Defaults[.ignoredApps]
    let savedIgnoredPasteboardTypes = Defaults[.ignoredPasteboardTypes]

    init() throws {
      image = try #require(NSImage(named: "NSInfo"))
      Defaults[.ignoreAllAppsExceptListed] = false
      Defaults[.captureMode] = .capturing
      clipboard.clearHooks()
    }

    deinit {
      Defaults[.enabledPasteboardTypes] = savedEnabledTypes
      Defaults[.captureMode] = savedCaptureMode
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
      Defaults[.captureMode] = .paused

      let first = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("foo", forType: .string)
      })
      #expect(first.isEmpty)
      #expect(Defaults[.captureMode] == .paused)

      let second = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(second.isEmpty)
      #expect(Defaults[.captureMode] == .paused)
    }

    @Test("Skip next ignores exactly one copy")
    func skipNextIgnoresExactlyOneCopy() async throws {
      Defaults[.captureMode] = .skipNext

      let skipped = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("foo", forType: .string)
      })
      #expect(skipped.isEmpty)
      #expect(Defaults[.captureMode] == .capturing)

      let captured = try await waitForCopies(after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(captured.count == 1)
    }

    // Regression: arming a one-shot skip, cancelling it, then pausing used to
    // leave a stale one-shot flag that resumed capture after one copy.
    @Test("Arm skip next, cancel, pause, copy: nothing is captured")
    func cancelledSkipNextThenPauseDoesNotCapture() async throws {
      var mode = CaptureMode.capturing
      mode = mode.togglingSkipNext() // Option-Shift-click: arm
      mode = mode.togglingSkipNext() // Option-Shift-click: cancel
      mode = mode.togglingPause() // Option-click: pause
      #expect(mode == .paused)
      Defaults[.captureMode] = mode

      let first = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("foo", forType: .string)
      })
      #expect(first.isEmpty)

      let second = try await waitForCopies(expectingCopy: false, after: {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("bar", forType: .string)
      })
      #expect(second.isEmpty)
      #expect(Defaults[.captureMode] == .paused)
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

struct CaptureModeTests {
  @Test("Only capturing records copies")
  func onlyCapturingRecordsCopies() {
    #expect(CaptureMode.capturing.capturesCopies)
    #expect(!CaptureMode.paused.capturesCopies)
    #expect(!CaptureMode.skipNext.capturesCopies)
  }

  @Test("Mode after a copy", arguments: [
    (CaptureMode.capturing, CaptureMode.capturing),
    (CaptureMode.paused, CaptureMode.paused),
    (CaptureMode.skipNext, CaptureMode.capturing)
  ])
  func afterCopy(from mode: CaptureMode, expected: CaptureMode) {
    #expect(mode.afterCopy == expected)
  }

  @Test("Toggling pause", arguments: [
    (CaptureMode.capturing, CaptureMode.paused),
    (CaptureMode.paused, CaptureMode.capturing),
    (CaptureMode.skipNext, CaptureMode.capturing)
  ])
  func togglingPause(from mode: CaptureMode, expected: CaptureMode) {
    #expect(mode.togglingPause() == expected)
  }

  @Test("Toggling skip next", arguments: [
    (CaptureMode.capturing, CaptureMode.skipNext),
    (CaptureMode.paused, CaptureMode.capturing),
    (CaptureMode.skipNext, CaptureMode.capturing)
  ])
  func togglingSkipNext(from mode: CaptureMode, expected: CaptureMode) {
    #expect(mode.togglingSkipNext() == expected)
  }

  @Test("Skip next skips exactly one copy")
  func skipNextSkipsExactlyOneCopy() {
    let afterFirst = CaptureMode.skipNext.afterCopy
    #expect(afterFirst == .capturing)
    #expect(afterFirst.capturesCopies)
    #expect(afterFirst.afterCopy == .capturing)
  }

  @Test("Pause and resume both clear a pending skip")
  func pauseAndResumeClearSkipNext() {
    // Pause from an armed skip: first click resumes, second pauses for good.
    let paused = CaptureMode.skipNext.togglingPause().togglingPause()
    #expect(paused == .paused)
    #expect(paused.afterCopy == .paused)
    #expect(paused.afterCopy.afterCopy == .paused)

    // Resume (settings toggle off / Option-click) from an armed skip.
    let resumed = CaptureMode.skipNext.togglingPause()
    #expect(resumed == .capturing)
    #expect(resumed.capturesCopies)
  }

  @Test("Arm skip next, cancel, pause, copy: nothing is captured")
  func cancelledSkipNextThenPauseDoesNotCapture() {
    // Cancel with Option-Shift-click (skip next) or Option-click (pause).
    let cancels: [(CaptureMode) -> CaptureMode] = [{ $0.togglingSkipNext() }, { $0.togglingPause() }]
    for cancel in cancels {
      let mode = cancel(CaptureMode.capturing.togglingSkipNext()).togglingPause()
      #expect(mode == .paused)
      #expect(!mode.capturesCopies)
      #expect(!mode.afterCopy.capturesCopies)
      #expect(!mode.afterCopy.afterCopy.capturesCopies)
    }
  }

  @Test("Stores its raw value under captureMode")
  func storesRawValue() throws {
    let (defaults, key) = try Self.makeDefaults()

    #expect(Defaults[key] == .capturing)
    for mode in CaptureMode.allCases {
      Defaults[key] = mode
      #expect(defaults.string(forKey: CaptureMode.defaultsKey) == mode.rawValue)
    }

    // What `defaults write org.p0deje.Maccy captureMode paused` stores.
    defaults.set("paused", forKey: CaptureMode.defaultsKey)
    #expect(Defaults[key] == .paused)
  }

  // nil means the old key is absent.
  @Test("Migrates legacy keys", arguments: [
    (nil as Bool?, nil as Bool?, CaptureMode.capturing),
    (false, nil, .capturing),
    (nil, false, .capturing),
    (false, false, .capturing),
    (true, nil, .paused),
    (true, false, .paused),
    (true, true, .skipNext),
    // The documented "ignore next copy" command on its own, or a stale flag
    // left by an Option-click toggle; both fail safe to skipping one copy.
    (nil, true, .skipNext),
    (false, true, .skipNext)
  ])
  func migratesLegacyKeys(ignoreEvents: Bool?, ignoreOnlyNextEvent: Bool?, expected: CaptureMode) throws {
    let (defaults, key) = try Self.makeDefaults()
    if let ignoreEvents {
      defaults.set(ignoreEvents, forKey: CaptureMode.legacyIgnoreEventsKey)
    }
    if let ignoreOnlyNextEvent {
      defaults.set(ignoreOnlyNextEvent, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)
    }

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == expected)
    #expect(Defaults[key] == expected)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreEventsKey) == nil)
    #expect(defaults.object(forKey: CaptureMode.legacyIgnoreOnlyNextEventKey) == nil)
  }

  @Test("Migrates string values written by a plain defaults write")
  func migratesStringValues() throws {
    let (defaults, key) = try Self.makeDefaults()
    // `defaults write org.p0deje.Maccy ignoreEvents true` stores the string "true".
    defaults.set("true", forKey: CaptureMode.legacyIgnoreEventsKey)

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == .paused)
    #expect(Defaults[key] == .paused)
  }

  @Test("Ignores legacy keys once migrated")
  func ignoresLegacyKeysAfterMigration() throws {
    let (defaults, key) = try Self.makeDefaults()
    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == .capturing)

    // An old script or MDM profile writing the old keys afterwards.
    defaults.set(true, forKey: CaptureMode.legacyIgnoreEventsKey)
    defaults.set(true, forKey: CaptureMode.legacyIgnoreOnlyNextEventKey)

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == nil)
    #expect(Defaults[key] == .capturing)
  }

  @Test("Keeps an existing captureMode when the legacy keys say capturing")
  func keepsExistingModeWhenLegacyCaptures() throws {
    let (defaults, key) = try Self.makeDefaults()
    Defaults[key] = .paused
    defaults.set(false, forKey: CaptureMode.legacyIgnoreEventsKey)

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == .capturing)
    #expect(Defaults[key] == .paused)
  }

  @Test("Legacy pause wins over an existing capturing mode")
  func legacyPauseWinsOverExistingCapturing() throws {
    let (defaults, key) = try Self.makeDefaults()
    Defaults[key] = .capturing
    defaults.set(true, forKey: CaptureMode.legacyIgnoreEventsKey)

    #expect(CaptureMode.migrateLegacyDefaults(in: defaults) == .paused)
    #expect(Defaults[key] == .paused)
  }

  // A throwaway preferences domain, plus a `captureMode` key that reads it the
  // same way the app does.
  private static func makeDefaults() throws -> (UserDefaults, Defaults.Key<CaptureMode>) {
    let suiteName = "org.p0deje.Maccy.tests.captureMode.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let key = Defaults.Key<CaptureMode>(CaptureMode.defaultsKey, default: .capturing, suite: defaults)
    return (defaults, key)
  }
}
