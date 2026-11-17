import AppKit
import Testing
import Defaults
import SwiftData
import UserNotifications
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class HistoryTests { // swiftlint:disable:this type_body_length
    let savedStoragePreference = SavedStoragePreference()
    let savedSize = Defaults[.size]
    let savedSortBy = Defaults[.sortBy]
    let savedPinOrder = Defaults[.pinOrder]
    let savedPinTo = Defaults[.pinTo]
    let history = History.shared

    init() {
      Defaults.Keys.enabledPasteboardTypes.suite.removeObject(forKey: StoragePolicy.preferenceKey)
      History.shared.clearAll()
      History.shared.storageSettingChanged()
      Defaults[.size] = 10
      Defaults[.sortBy] = .firstCopiedAt
      Defaults[.pinOrder] = PinOrder()
      Defaults[.pinTo] = .bottom
    }

    deinit {
      savedStoragePreference.restore()
      Defaults[.size] = savedSize
      Defaults[.sortBy] = savedSortBy
      Defaults[.pinOrder] = savedPinOrder
      Defaults[.pinTo] = savedPinTo
    }

    // MARK: Deferred selection (a shortcut key selects after a short delay)

    @MainActor
    final class SelectionLog {
      var flags: [NSEvent.ModifierFlags] = []
    }

    @Test("A deferred selection runs once, with the modifier keys held when it was scheduled")
    func deferredSelectionUsesTheFlagsItWasScheduledWith() async throws {
      let deferred = DeferredSelection()
      deferred.sleepForTesting = {}
      let log = SelectionLog()
      deferred.schedule(flags: [.command, .shift], after: .milliseconds(10)) { log.flags.append($0) }
      let pending = deferred.pendingTaskForTesting
      #expect(deferred.isPending)
      #expect(log.flags.isEmpty)

      await pending?.value
      #expect(log.flags == [[.command, .shift]])
      #expect(!deferred.isPending)
    }

    @Test("A cancelled deferred selection never runs")
    func cancelledDeferredSelectionNeverRuns() async throws {
      let deferred = DeferredSelection()
      deferred.sleepForTesting = {}
      let log = SelectionLog()
      deferred.schedule(flags: [], after: .milliseconds(10)) { log.flags.append($0) }
      let pending = deferred.pendingTaskForTesting
      deferred.cancel()
      #expect(!deferred.isPending)

      await pending?.value
      #expect(log.flags.isEmpty)
    }

    @Test("A new deferred selection replaces the one still waiting")
    func newDeferredSelectionReplacesThePendingOne() async throws {
      let deferred = DeferredSelection()
      deferred.sleepForTesting = {}
      let log = SelectionLog()
      deferred.schedule(flags: [.option], after: .milliseconds(10)) { log.flags.append($0) }
      let replaced = deferred.pendingTaskForTesting
      deferred.schedule(flags: [.command], after: .milliseconds(10)) { log.flags.append($0) }
      let pending = deferred.pendingTaskForTesting
      await replaced?.value

      await pending?.value
      #expect(log.flags == [[.command]])
    }

    @Test("Closing the popup drops a selection that is still waiting")
    func closingThePopupDropsThePendingSelection() async throws {
      let popup = AppState.shared.popup
      let log = SelectionLog()
      popup.deferredSelection.sleepForTesting = {}
      defer { popup.deferredSelection.sleepForTesting = nil }
      popup.deferredSelection.schedule(flags: [.command]) { log.flags.append($0) }
      let pending = popup.deferredSelection.pendingTaskForTesting

      // The panel calls this when it closes.
      popup.reset()
      #expect(!popup.deferredSelection.isPending)

      await pending?.value
      #expect(log.flags.isEmpty)
    }

    private func shortcutEvent(flags: NSEvent.ModifierFlags) throws -> NSEvent {
      try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1",
        isARepeat: false, keyCode: 18
      ))
    }

    @Test("Shortcut wiring selects the event's item and captures its flags before deferring")
    func shortcutEventCapturesFlags() async throws {
      let popup = AppState.shared.popup
      popup.deferredSelection.sleepForTesting = {}
      defer {
        popup.reset()
        popup.deferredSelection.sleepForTesting = nil
      }
      let item = history.added(historyItem("shortcut item"))
      let event = try shortcutEvent(flags: [.command, .capsLock])
      let log = SelectionLog()
      #expect(popup.scheduleShortcutSelection(for: event) { selected, flags in
        #expect(selected == item)
        log.flags.append(flags)
      })
      let pending = popup.deferredSelection.pendingTaskForTesting
      #expect(log.flags.isEmpty)
      // There is no current AppKit key event corresponding to our synthetic
      // event when the deferred action runs; it must use the supplied event.
      await pending?.value
      #expect(log.flags == [[.command]])
    }

    @Test("Another key press cancels shortcut selection")
    func anotherKeyPressCancelsShortcut() async throws {
      let popup = AppState.shared.popup
      popup.deferredSelection.sleepForTesting = {}
      defer {
        popup.reset()
        popup.deferredSelection.sleepForTesting = nil
      }
      _ = history.added(historyItem("shortcut item"))
      let log = SelectionLog()
      #expect(popup.scheduleShortcutSelection(for: try shortcutEvent(flags: .command)) { _, flags in
        log.flags.append(flags)
      })
      let pending = popup.deferredSelection.pendingTaskForTesting
      popup.beginKeyPress()
      await pending?.value
      #expect(log.flags.isEmpty)
      #expect(!popup.deferredSelection.isPending)
    }

    @Test("History.select cancels pending shortcut selection")
    func historySelectionCancelsShortcut() async {
      let popup = AppState.shared.popup
      popup.deferredSelection.sleepForTesting = {}
      let savedPaste = Defaults[.pasteByDefault]
      Defaults[.pasteByDefault] = false
      defer {
        Defaults[.pasteByDefault] = savedPaste
        popup.reset()
        popup.deferredSelection.sleepForTesting = nil
      }
      let item = history.added(historyItem("selected directly"))
      let log = SelectionLog()
      popup.deferredSelection.schedule(flags: .command) { log.flags.append($0) }
      let pending = popup.deferredSelection.pendingTaskForTesting
      history.select(item, flags: .command)
      await pending?.value
      #expect(log.flags.isEmpty)
      #expect(!popup.deferredSelection.isPending)
    }

    @Test("Default is empty")
    func defaultIsEmpty() {
      #expect(history.items.toArray() == [])
    }

    @Test("Adding")
    func adding() {
      let first = history.added(historyItem("foo"))
      let second = history.added(historyItem("bar"))
      #expect(history.items.toArray() == [second, first])
    }

    @Test("Adding persisted duplicate")
    func addingPersistedDuplicate() throws {
      let first = historyItem("foo")
      first.setTitle("xyz", source: .user)
      first.application = "iTerm.app"
      history.added(first)
      first.pin = "f"

      let third = historyItem("foo")
      third.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.added(third)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.displayTitle == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding unsaved duplicate")
    @available(macOS 15.0, *)
    func addingUnsavedDuplicate() throws {
      let first = historyItem("foo")
      first.setTitle("xyz", source: .user)
      first.application = "iTerm.app"
      history.added(first)
      first.pin = "f"

      let second = historyItem("foo", persisted: false)
      second.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.added(second)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.displayTitle == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding item that is superseded by existing")
    func addingItemThatIsSupersededByExisting() throws {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.rtf.rawValue,
          value: "two".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.application = "Maccy.app"
      firstItem.contents = firstContents
      firstItem.regenerateTitle()
      history.added(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.application = "Maccy.app"
      secondItem.contents = secondContents
      secondItem.regenerateTitle()
      let second = history.added(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
      try assertStorageCounts(items: 1, contents: firstContents.count)
    }

    @Test("Adding item with different modified type")
    func addingItemWithDifferentModifiedType() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "1".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.contents = firstContents
      history.added(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "2".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.contents = secondContents
      let second = history.added(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Adding item from Maccy")
    func addingItemFromMaccy() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        )
      ]
      let first = HistoryItem()
      Storage.shared.context.insert(first)
      first.application = "Xcode.app"
      first.contents = firstContents
      history.added(first)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
          value: "".data(using: .utf8)
        )
      ]
      let second = HistoryItem()
      Storage.shared.context.insert(second)
      second.application = "Maccy.app"
      second.contents = secondContents
      let secondDecorator = history.added(second)

      #expect(history.items.toArray() == [secondDecorator])
      #expect(history.items[0].item.application == "Xcode.app")
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Modified after copying")
    func modifiedAfterCopying() {
      history.added(historyItem("foo"))

      let modifiedItem = historyItem("bar")
      modifiedItem.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: String(Clipboard.shared.changeCount).data(using: .utf8)
      ))
      let modifiedItemDecorator = history.added(modifiedItem)

      #expect(history.items.toArray() == [modifiedItemDecorator])
      #expect(history.items[0].text == "bar")
    }

    @Test("Clearing unpinned")
    func clearingUnpinned() throws {
      let pinned = history.added(historyItem("foo"))
      history.togglePin(pinned)
      history.added(historyItem("bar"))
      let orphan = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      )
      Storage.shared.context.insert(orphan)
      try Storage.shared.context.save()

      history.clear()

      #expect(history.items.toArray() == [pinned])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Clearing all")
    func clearingAll() throws {
      history.added(historyItem("foo"))
      let pinned = history.added(historyItem("bar"))
      history.togglePin(pinned)
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      ))
      try Storage.shared.context.save()

      history.clearAll()

      #expect(history.items.toArray() == [])
      try assertStorageCounts(items: 0, contents: 0)
    }

    @Test("Max size")
    func maxSize() throws {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.added(historyItem(String(index))))
      }

      #expect(history.items.count == 10)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[0]))
      try assertStorageCounts(items: 10, contents: 10)
    }

    @Test("Max size ignores pinned")
    func maxSizeIgnoresPinned() {
      var items: [HistoryItemDecorator] = []

      let item = history.added(historyItem("0"))
      items.append(item)
      history.togglePin(item)

      for index in 1...11 {
        items.append(history.added(historyItem(String(index))))
      }

      #expect(history.items.count == 11)
      #expect(history.items.contains(items[10]))
      #expect(history.items.contains(items[0]))
      #expect(!history.items.contains(items[1]))
    }

    @Test("Pinning updates pin order")
    func pinningUpdatesPinOrder() {
      let item = history.added(historyItem("foo"))
      history.togglePin(item)

      #expect(history.pinnedItems == [item])
      #expect(Defaults[.pinOrder].pins == [item.item.pin].compactMap { $0 })
    }

    @Test("Pins without a free key get no shortcuts")
    func noShortcutsForPinWithoutKey() {
      #expect(KeyShortcut.create(character: "").isEmpty)
      #expect(KeyShortcut.create(character: "b").count == 3)
    }

    @Test("Pinning after all shortcuts are assigned")
    func pinningAfterAllShortcutsAreAssigned() async throws {
      let supportedPins = HistoryItem.supportedPins
      for index in 0..<supportedPins.count {
        let item = history.added(historyItem("keyed \(index)"))
        history.togglePin(item)
      }

      #expect(history.availablePins.isEmpty)
      #expect(Set(history.pinnedItems.compactMap(\.item.pin)) == supportedPins)

      let first = history.added(historyItem("first without shortcut"))
      history.togglePin(first)
      let second = history.added(historyItem("second without shortcut"))
      history.togglePin(second)

      #expect(first.item.pin == "")
      #expect(second.item.pin == "")
      #expect(history.pinnedItems.suffix(2) == [first, second])
      #expect(history.unpinnedItems.isEmpty)

      for index in 0...Defaults[.size] {
        history.added(historyItem("unpinned \(index)"))
      }

      let expectedCount = supportedPins.count + 2
      #expect(history.pinnedItems.count == expectedCount)
      try assertStorageCounts(
        items: expectedCount + Defaults[.size],
        contents: expectedCount + Defaults[.size]
      )

      try await history.load()
      #expect(history.pinnedItems.count == expectedCount)
      #expect(
        Set(history.pinnedItems.filter { $0.item.pin == "" }.map(\.title)) ==
        ["first without shortcut", "second without shortcut"]
      )
    }

    @Test("Unpinning updates pin order")
    func unpinningUpdatesPinOrder() {
      let item = history.added(historyItem("foo"))
      history.togglePin(item)
      history.togglePin(item)

      #expect(history.pinnedItems == [])
      #expect(Defaults[.pinOrder].pins == [])
    }

    @Test("Moving pins updates pin order")
    func movingPinsUpdatesPinOrder() {
      let first = history.added(historyItem("foo"))
      let second = history.added(historyItem("bar"))
      history.togglePin(first)
      history.togglePin(second)

      history.movePin(from: IndexSet(integer: 0), to: 2)

      #expect(history.pinnedItems == [second, first])
      #expect(Defaults[.pinOrder].pins == [second.item.pin, first.item.pin].compactMap { $0 })
    }

    @Test("Max size is changed")
    func maxSizeIsChanged() {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.added(historyItem(String(index))))
      }
      Defaults[.size] = 5
      history.added(historyItem("11"))

      #expect(history.items.count == 5)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[5]))
    }

    @Test("Re-adding bottom-most pinned item at full capacity")
    func readdingBottomMostPinnedItemAtFullCapacity() {
      // Regression test for a crash when re-copying (invoking) the bottom-most
      // pinned item while history is at full capacity and pins are sorted to the
      // bottom. The stale insert index used to trap with an out-of-bounds insert.
      // Issue link: https://github.com/p0deje/Maccy/issues/1466
      // `pinTo` is restored to its default value(.top) in `deinit`.
      Defaults[.pinTo] = .bottom

      // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
      // pinned item ends up as the last element.
      let pinned = history.added(historyItem("pinned"))
      history.togglePin(pinned)

      // Fill unpinned history to full capacity.
      for index in 0..<Defaults[.size] {
        history.added(historyItem(String(index)))
      }

      #expect(history.items.last == pinned)

      // Re-copy the pinned item. It is detected as a duplicate, removed and
      // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
      // Before the fix this inserted at a stale, out-of-bounds index and crashed.
      let readded = history.added(historyItem("pinned"))

      #expect(history.items.contains(readded))
      #expect(history.items.filter(\.isPinned).count == 1)
    }

    @Test("Removing")
    func removing() throws {
      let foo = history.added(historyItem("foo"))
      let bar = history.added(historyItem("bar"))
      history.delete(foo)
      #expect(history.items.toArray() == [bar])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Cleaning up orphaned contents")
    func cleaningUpOrphanedContents() throws {
      let live = history.added(historyItem("live"))
      let liveContent = live.item.contents[0]
      for value in ["orphan-1", "orphan-2"] {
        Storage.shared.context.insert(HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        ))
      }
      try Storage.shared.context.save()

      #expect(try Storage.shared.cleanupOrphanedContents() == 2)
      #expect(try Storage.shared.cleanupOrphanedContents() == 0)
      #expect(live.item.contents == [liveContent])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Removing contents outside the storage allow-list")
    func removingUnpersistableContents() throws {
      let live = history.added(historyItem("live"))
      live.item.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.safariWebArchve.rawValue,
        value: Data(repeating: 0x61, count: 1024)
      ))
      try Storage.shared.context.save()

      #expect(try Storage.shared.cleanUp(to: .everything).impact.itemsLosingData == 1)
      #expect(try !Storage.shared.cleanUp(to: .everything).hasChanges)
      #expect(live.item.contents.map(\.type) == [NSPasteboard.PasteboardType.string.rawValue])
      try assertStorageCounts(items: 1, contents: 1)
    }

    private func assertStorageCounts(
      items: Int,
      contents: Int,
      orphaned: Int = 0,
      fileID: String = #fileID,
      filePath: String = #filePath,
      line: Int = #line,
      column: Int = #column
    ) throws {
      let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
      let context = Storage.shared.context
      context.processPendingChanges()
      try context.save()
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItem>()) == items,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>()) == contents,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>(
          predicate: #Predicate { $0.item == nil }
        )) == orphaned,
        sourceLocation: sourceLocation
      )
    }

    @Test("Notification content contains no clipboard content")
    func notificationContentHasNoClipboardContent() {
      let secret = "hunter2-API-TOKEN-4f9c1e"
      let item = historyItem(secret, persisted: false)
      #expect(item.displayTitle.contains(secret))

      let identifier = Notifier.identifier(for: item)
      for alertEnabled in [true, false] {
        let content = Notifier.makeContent(alertEnabled: alertEnabled)
        let everything = [
          content.title,
          content.subtitle,
          content.body,
          content.categoryIdentifier,
          content.threadIdentifier,
          content.summaryArgument,
          content.targetContentIdentifier ?? "",
          String(describing: content.userInfo),
          identifier
        ]
        for field in everything {
          #expect(!field.contains(secret))
        }
        #expect(content.userInfo.isEmpty)
      }
    }

    @Test("Notification body is generic and only present when alerts are enabled")
    func notificationBodyIsGeneric() {
      #expect(!Notifier.makeContent(alertEnabled: true).body.isEmpty)
      #expect(Notifier.makeContent(alertEnabled: false).body.isEmpty)
    }

    @Test("Notification identifiers are opaque and not derived from content")
    func notificationIdentifiersAreOpaque() {
      let first = historyItem("same content", persisted: false)
      let second = historyItem("same content", persisted: false)

      #expect(Notifier.identifier(for: first) == Notifier.identifier(for: first))
      #expect(Notifier.identifier(for: first) != Notifier.identifier(for: second))
      #expect(UUID(uuidString: Notifier.identifier(for: first)) != nil)
      #expect(!Notifier.identifier(for: first).contains("same content"))
      #expect(!Notifier.identifier(for: first).contains(first.displayTitle))
    }

    @Test("Notification submitted for a new copy carries no clipboard content")
    func submittedNotificationHasNoClipboardContent() async {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }

      let secret = "hunter2-API-TOKEN-4f9c1e"
      let item = historyItem(secret)
      let identifier = Notifier.identifier(for: item)
      history.add(item)
      await waitUntil { Notifier.isActive(identifier) }
      client.resolvePermissions()

      let requests = client.added.filter { $0.identifier == identifier }
      #expect(requests.count == 1)
      for request in requests {
        let content = request.content
        let everything = [
          request.identifier,
          content.title,
          content.subtitle,
          content.body,
          content.categoryIdentifier,
          content.threadIdentifier,
          content.summaryArgument,
          content.targetContentIdentifier ?? "",
          String(describing: content.userInfo)
        ]
        for field in everything {
          #expect(!field.contains(secret))
        }
        #expect(content.userInfo.isEmpty)
        #expect(content.body == Notifier.makeContent(alertEnabled: true).body)
      }
    }

    @Test("Deleting an item removes its delivered notification")
    func deleteRemovesDeliveredNotification() async {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }

      let item = historyItem("delivered then deleted")
      let identifier = Notifier.identifier(for: item)
      let decorator = history.add(item)
      await waitUntil { Notifier.isActive(identifier) }
      client.resolvePermissions()
      client.resolveAdds()
      #expect(!client.removed.contains(identifier))

      history.delete(decorator)

      #expect(client.removed.contains(identifier))
      #expect(!Notifier.isActive(identifier))
    }

    @Test("Notification is not submitted when its item is deleted before permissions resolve")
    func deleteBeforePermissionsDropsNotification() async {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }

      let item = historyItem("deleted before submission")
      let identifier = Notifier.identifier(for: item)
      let decorator = history.add(item)
      await waitUntil { Notifier.isActive(identifier) }

      history.delete(decorator)
      client.resolvePermissions()

      #expect(client.added.filter { $0.identifier == identifier }.isEmpty)
    }

    @Test("Notification is removed again when its item is deleted while submission is in flight")
    func deleteWhileSubmissionInFlightRemovesNotification() async {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }

      let item = historyItem("deleted in flight")
      let identifier = Notifier.identifier(for: item)
      let decorator = history.add(item)
      await waitUntil { Notifier.isActive(identifier) }
      client.resolvePermissions()
      #expect(client.added.filter { $0.identifier == identifier }.count == 1)

      history.delete(decorator)
      let removalsBeforeCompletion = client.removed.filter { $0 == identifier }.count
      client.resolveAdds()

      #expect(client.removed.filter { $0 == identifier }.count == removalsBeforeCompletion + 1)
    }

    @Test("Replacement of a duplicate inherits its notification")
    func duplicateReplacementInheritsNotification() async {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }

      let first = historyItem("copied twice")
      let identifier = Notifier.identifier(for: first)
      history.add(first)
      await waitUntil { Notifier.isActive(identifier) }
      client.resolvePermissions()
      client.resolveAdds()

      let second = historyItem("copied twice")
      let secondDecorator = history.add(second)

      #expect(Notifier.identifier(for: second) == identifier)
      #expect(!client.removed.contains(identifier))
      #expect(Notifier.isActive(identifier))

      history.delete(secondDecorator)

      #expect(client.removed.contains(identifier))
    }

    @Test("Clearing all history removes every notification and drops pending ones")
    func clearAllRemovesNotifications() async {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }

      let item = historyItem("cleared before submission")
      let identifier = Notifier.identifier(for: item)
      history.add(item)
      await waitUntil { Notifier.isActive(identifier) }

      history.clearAll()
      client.resolvePermissions()

      #expect(client.removeAllCount >= 1)
      #expect(client.added.filter { $0.identifier == identifier }.isEmpty)
    }

    @Test("Errors are logged by domain and code only")
    func redactedErrorOmitsPayload() {
      let secret = "patient-record-8841"
      let error = NSError(
        domain: "ExampleDomain",
        code: 1570,
        userInfo: [
          NSLocalizedDescriptionKey: "Validation failed for \(secret)",
          "NSValidationErrorValue": secret,
          NSUnderlyingErrorKey: NSError(domain: secret, code: 1)
        ]
      )

      let logged = Notifier.redacted(error)

      #expect(!logged.contains(secret))
      #expect(logged == "ExampleDomain code 1570")
    }

    @Test("Deleting immediately after add cannot register a late notification")
    func immediateDeleteDropsNotification() async {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }
      let item = historyItem("delete synchronously")
      let decorator = history.added(item)
      history.delete(decorator)
      await Task.yield()
      client.resolvePermissions()
      #expect(!Notifier.isActive(item.notificationID))
      #expect(client.added.isEmpty)
    }

    @Test("Every removal path revokes notifications and intent exports",
          arguments: ["delete", "clear", "clearAll", "trim", "policy", "pendingPolicy"])
    func removalRevokesArtifacts(path: String) throws {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      let savedStorage = SavedStoragePreference()
      Notifier.client = client
      defer {
        Notifier.client = savedClient
        savedStorage.restore()
      }
      let item = historyItem("artifact owner")
      let decorator = history.added(item)
      let identifier = item.notificationID
      client.resolvePermissions()
      client.resolveAdds()
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: item)
      if path == "policy" || path == "clearAll" {
        history.togglePin(decorator)
        try Storage.shared.save()
      }
      switch path {
      case "delete": history.delete(decorator)
      case "clear": history.clear()
      case "clearAll": history.clearAll()
      case "trim":
        Defaults[.size] = 1
        history.added(historyItem("replacement with different content"))
      case "policy":
        Defaults[.enabledPasteboardTypes] = [.fileURL]
        #expect(history.storageSettingChanged())
      case "pendingPolicy":
        item.setAlias("pending change before policy cleanup")
        try Storage.shared.cleanUp(to: StorageAllowList(enabledTypes: [.fileURL]))
      default: Issue.record("unknown removal path")
      }
      #expect(!FileManager.default.fileExists(atPath: export.path))
      #expect(client.removed.contains(identifier))
      #expect(!Notifier.isActive(identifier))
    }

    @Test("A policy change revokes prior exports even when storage cleanup fails")
    func failedPolicyCleanupRevokesExports() throws {
      struct InjectedFailure: Error {}
      let savedStorage = SavedStoragePreference()
      defer {
        Storage.shared.saveFailureForTesting = nil
        savedStorage.restore()
      }
      let item = historyItem("retained after failed cleanup")
      history.added(item)
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: item)
      Storage.shared.saveFailureForTesting = InjectedFailure()
      Defaults[.enabledPasteboardTypes] = [.fileURL]
      #expect(!history.storageSettingChanged())
      #expect(!FileManager.default.fileExists(atPath: export.path))
      #expect(item.contents.contains { $0.type == NSPasteboard.PasteboardType.string.rawValue })
      #expect(!item.displayTitle.contains("retained"))
    }

    @Test("Partial storage cleanup revokes exports and keeps the retained item's notification")
    func partialCleanupRevokesExports() throws {
      let client = RecordingNotificationClient()
      let savedClient = Notifier.client
      Notifier.client = client
      defer { Notifier.client = savedClient }
      let item = historyItem("keep allowed text")
      item.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue,
                                             value: Data("image bytes".utf8)))
      history.added(item)
      client.resolvePermissions()
      client.resolveAdds()
      let export = try IntentImageExports.write(Data("image bytes".utf8), for: item)
      try Storage.shared.cleanUp(to: StorageAllowList(enabledTypes: [.string]))
      #expect(!FileManager.default.fileExists(atPath: export.path))
      #expect(!client.removed.contains(item.notificationID))
      #expect(item.text == "keep allowed text")
    }

    private func waitUntil(_ condition: () -> Bool) async {
      for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
      }
    }

    private func historyItem(_ value: String, persisted: Bool = true) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      if persisted {
        Storage.shared.context.insert(item)
      }
      item.contents = contents
      item.numberOfCopies = 1
      item.regenerateTitle()

      return item
    }
  }
}

/// Records what `Notifier` submits and removes, and lets a test decide when the asynchronous
/// permission and submission callbacks fire.
@MainActor
final class RecordingNotificationClient: NotificationClient {
  private(set) var added: [UNNotificationRequest] = []
  private(set) var removed: [String] = []
  private(set) var removeAllCount = 0

  private var pendingPermissions: [@MainActor (Bool, Bool, Bool) -> Void] = []
  private var pendingAdds: [@MainActor (Bool) -> Void] = []

  func requestAuthorization() {}

  func permissions(
    _ completion: @escaping @MainActor (_ authorized: Bool, _ alertEnabled: Bool, _ soundEnabled: Bool) -> Void
  ) {
    pendingPermissions.append(completion)
  }

  func add(_ request: UNNotificationRequest, completion: @escaping @MainActor (_ delivered: Bool) -> Void) {
    added.append(request)
    pendingAdds.append(completion)
  }

  func remove(identifiers: [String]) {
    removed.append(contentsOf: identifiers)
  }

  func removeAll() {
    removeAllCount += 1
  }

  func resolvePermissions() {
    let completions = pendingPermissions
    pendingPermissions = []
    completions.forEach { $0(true, true, false) }
  }

  func resolveAdds() {
    let completions = pendingAdds
    pendingAdds = []
    completions.forEach { $0(true) }
  }
}
