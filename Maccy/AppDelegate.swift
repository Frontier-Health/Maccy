import Defaults
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  nonisolated static let isTesting = CommandLine.arguments.contains("enable-testing")
  var panel: FloatingPanel<ContentView>!

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  // Base accessibility label for the status item; kept separate from the optional
  // dynamic `title` (recent copy text) so VoiceOver always announces something
  // meaningful even when that preference is off or the app is disabled.
  private func updateStatusItemAccessibilityLabel() {
    var accessibilityLabel = NSLocalizedString("status_item_accessibility_label", comment: "")
    if isStatusItemDisabled {
      accessibilityLabel += " — \(NSLocalizedString("status_item_disabled_accessibility_suffix", comment: ""))"
    }
    statusItem.button?.setAccessibilityLabel(accessibilityLabel)
  }

  private var isStatusItemDisabled: Bool {
    !CaptureMode.effective(in: Clipboard.shared.capturePreferences).capturesCopies ||
      !StoragePolicy.current.storesAnything
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    #if DEBUG
    if Self.isTesting {
      // Start from a clean slate for the isolated testing preferences.
      UserDefaults.standard.removePersistentDomain(forName: Defaults.Keys.testingSuiteName)
    }
    #endif

    // Must run before the clipboard starts watching, so the first copy is
    // judged by the migrated mode.
    CaptureMode.migrateLegacyDefaults(in: Defaults.Keys.captureMode.suite)

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    // Notifications delivered by an earlier session (or an earlier version that put clipboard
    // text in them) can no longer be matched to items, so drop them before capture starts.
    Notifier.removeAllDelivered()

    // The popup hotkey works only once launch maintenance has finished (see LaunchSequence).
    KeyboardShortcuts.disable(.popup)

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    updateStatusItemAccessibilityLabel()

    Task {
      for await _ in Defaults.updates([.captureMode, .legacyIgnoreEvents, .legacyIgnoreOnlyNextEvent]) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    _ = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.sessionEnding = true
      }
    }

    // Nothing reads or shows history, and no alert is shown, until the
    // storage policy and launch maintenance have run; see LaunchSequence.
    LaunchSequence { [self] step in
      switch step {
      case .applyStoragePolicy:
        History.shared.beginLaunch()
        migrateUserDefaults()
      case .maintain:
        History.shared.performLaunchMaintenance()
      case .loadHistory:
        History.shared.finishLaunch()
      case .createInterface:
        disableUnusedGlobalHotkeys()
        panel = FloatingPanel(
          contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
          identifier: AppIdentity.bundleIdentifier,
          statusBarButton: statusItem.button,
          onClose: { AppState.shared.popup.reset() }
        ) {
          ContentView()
        }
        KeyboardShortcuts.enable(.popup)
      case .startCapture:
        Clipboard.shared.onNewCopy { History.shared.add($0) }
        Clipboard.shared.start()
      case .startMaintenanceSchedule:
        History.shared.startExpirySchedule()
      case .presentFailures:
        History.shared.presentDeferredFailures()
      }
    }.run()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard History.shared.isReady else { return false }
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  // Set when the session is ending (log out, restart, shut down): quitting
  // must not wait for a dialog then.
  private var sessionEnding = false

  // "Clear history on quit" runs here, where quitting can still be cancelled.
  // See QuitClearDecision. Terminations that never ask (a forced quit, a
  // crash, or a session ending while Maccy doesn't respond) skip this; the
  // clear at the next launch is the safety net.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if isSessionEndingQuit() {
      sessionEnding = true
    }
    return QuitClearDecision.reply(
      clearOnQuit: Defaults[.clearOnQuit],
      sessionEnding: sessionEnding,
      clear: { History.shared.clearOnQuit(alerting: false) },
      quitAnyway: {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = QuitClearDecision.title
        alert.informativeText = QuitClearDecision.message
        alert.addButton(withTitle: QuitClearDecision.quitAnywayButton)
        alert.addButton(withTitle: QuitClearDecision.cancelButton)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
      }
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    // A compaction still pending gets a short time; if it can't finish it
    // runs at the next launch.
    History.shared.compactBeforeQuit(timeLimit: sessionEnding ? 1 : 5)
  }

  // Whether the quit request comes from logging out, restarting or shutting
  // down.
  private func isSessionEndingQuit() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
          event.eventClass == AEEventClass(kCoreEventClass),
          event.eventID == AEEventID(kAEQuitApplication),
          let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else {
      return false
    }
    let sessionEndingReasons = [
      OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
      OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown)
    ]
    return sessionEndingReasons.contains(reason)
  }

  private func ensureMigration(key: String, _ action: () -> Void) {
    if Defaults[.migrations][key] != true {
      action()
      Defaults[.migrations][key] = true
    }
  }

  @MainActor
  private func migrateUserDefaults() {
    ensureMigration(key: "2024-07-01-version-2") {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")
    }

    ensureMigration(key: "2025-07-04-add-jpeg-heic") {
      // An invalid or profile-managed value is left as it is: rewriting it
      // from the fallback would turn storage back on.
      let policy = StoragePolicy.current
      guard !policy.isForced, let allowList = policy.allowList,
            !allowList.enabledTypes.isDisjoint(with: StorageType.images.types) else {
        return
      }
      Defaults[.enabledPasteboardTypes] = allowList.enabledTypes.union(StorageType.images.types)
    }

    ensureMigration(key: "2026-08-12-cleanup-orphaned-history-item-contents") {
      _ = try? Storage.shared.cleanupOrphanedContents()
    }

    ensureMigration(key: "2026-08-31-sanitize-history-item-titles") {
      _ = try? Storage.shared.sanitizeTitles()
    }

    // Representations the storage allow-list doesn't cover, including the web
    // archives this used to remove, are deleted on every launch while the
    // setting is valid. A failed clean-up is retried here on the next launch.
    // The list is built later, after launch maintenance.
    History.shared.enforceStoragePolicy(reloadingItems: false)

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    let modifierFlags = (NSApp.currentEvent?.modifierFlags ?? [])
      .union(NSEvent.modifierFlags)
      .intersection(.deviceIndependentFlagsMask)

    if let request = CaptureModeRequest(statusItemClickWith: modifierFlags) {
      Clipboard.shared.perform(request)
      return
    }

    guard History.shared.isReady else { return }
    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin, .togglePreview]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
            names.contains(name) else { return }
      MainActor.assumeIsolated {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}
