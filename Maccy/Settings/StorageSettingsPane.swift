import SwiftUI
import Defaults
import Settings

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    // The effective setting, including a value forced by a configuration
    // profile or an invalid stored value.
    private(set) var policy = StoragePolicy.current
    // A change that would remove stored data, waiting for confirmation.
    var pendingChange: PendingStorageToggleChange?

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { _ in
        self.policy = StoragePolicy.current
      }
    }

    isolated deinit {
      observer?.invalidate()
    }

    func binding(for toggle: StorageType) -> Binding<Bool> {
      Binding(
        get: { self.policy.isEnabled(toggle) },
        set: { isOn in
          let change = StorageToggleChange.change(from: StoragePolicy.current, setting: toggle, to: isOn,
                                                  impact: { try Self.impact(of: $0) })
          switch change {
          case .refused:
            break
          case .apply(let enabledTypes):
            self.write(enabledTypes)
          case .confirm(let enabledTypes, let impact):
            // Until confirmed the toggle keeps showing the stored value.
            self.pendingChange = PendingStorageToggleChange(
              toggle: toggle, isOn: isOn, enabledTypes: enabledTypes, impact: impact
            )
          }
        }
      )
    }

    // Confirms the change the dialog showed. It is checked against the
    // setting as it is now (see `StorageToggleChange.confirming`): a value now
    // forced is left alone, and a changed value or count is asked about again.
    func confirm(_ change: PendingStorageToggleChange) {
      pendingChange = nil
      let confirmation = StorageToggleChange.confirming(change, from: StoragePolicy.current) {
        try Self.impact(of: $0)
      }
      switch confirmation {
      case .refused:
        policy = StoragePolicy.current
      case .apply(let enabledTypes):
        write(enabledTypes)
      case .reconfirm(let updated):
        policy = StoragePolicy.current
        // Shown once the current dialog has gone.
        Task { @MainActor in
          self.pendingChange = updated
        }
      }
    }

    func cancelPendingChange() {
      pendingChange = nil
      policy = StoragePolicy.current
    }

    // History applies the new value straight away; the clean-up logs its
    // counts.
    private func write(_ enabledTypes: Set<NSPasteboard.PasteboardType>) {
      Defaults[.enabledPasteboardTypes] = enabledTypes
      policy = StoragePolicy.current
      History.shared.storageSettingChanged()
    }

    private static func impact(of allowList: StorageAllowList) throws -> StorageCleanUpImpact {
      try Storage.shared.cleanUpImpact(of: allowList)
    }
  }

  @Default(.sortBy) private var sortBy
  // The effective values, refreshed whenever the preference changes, so a
  // profile-forced or out-of-range value is shown as it is applied.
  @State private var size = HistorySize.current
  @State private var sizeIsForced = HistorySize.isForced
  @State private var expiry = HistoryExpiry.current

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = NSNumber(value: HistorySize.range.lowerBound)
    formatter.maximum = NSNumber(value: HistorySize.range.upperBound)
    return formatter
  }()

  private let expiryFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 0
    formatter.maximum = NSNumber(value: HistoryExpiry.maximumHours)
    return formatter
  }()

  private var sizeBinding: Binding<Int> {
    Binding(
      get: { size },
      set: { Defaults[.size] = min(max($0, HistorySize.range.lowerBound), HistorySize.range.upperBound) }
    )
  }

  private var expiryBinding: Binding<Int> {
    Binding(
      get: { expiry.hours ?? 0 },
      set: { Defaults[.historyExpiryHours] = min(max($0, 0), HistoryExpiry.maximumHours) }
    )
  }

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(
        bottomDivider: true,
        label: { Text("Save", tableName: "StorageSettings") }
      ) {
        ForEach(StorageType.toggles) { toggle in
          Toggle(
            isOn: viewModel.binding(for: toggle),
            label: { Text(LocalizedStringKey(toggle.id), tableName: "StorageSettings") }
          )
          .disabled(viewModel.policy.isForced)
        }
        Text("SaveDescription", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)
        if viewModel.policy.isInvalid {
          Text(viewModel.policy.isForced ? Self.invalidManagedSaveTypes : Self.invalidSaveTypes)
            .controlSize(.small)
            .foregroundStyle(.red)
        } else if viewModel.policy.isForced {
          Text(Self.managedSaveTypes)
            .controlSize(.small)
            .foregroundStyle(.gray)
        }
      }

      Settings.Section(label: { Text("Size", tableName: "StorageSettings") }) {
        HStack {
          TextField("", value: sizeBinding, formatter: sizeFormatter)
            .frame(width: 80)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
            .disabled(sizeIsForced)
          Stepper("", value: sizeBinding, in: HistorySize.range)
            .labelsHidden()
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
            .disabled(sizeIsForced)
          if sizeIsForced {
            Image(systemName: "lock.fill")
              .help(Self.managedValue)
              .accessibilityLabel(Self.managedValue)
          }
          Text(storageSize)
            .controlSize(.small)
            .foregroundStyle(.gray)
            .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
            .onAppear {
              storageSize = Storage.shared.size
            }
        }
        .task {
          for await _ in Defaults.updates(.size) {
            size = HistorySize.current
            sizeIsForced = HistorySize.isForced
          }
        }
      }

      Settings.Section(label: { Text(Self.expiryLabel) }) {
        HStack {
          TextField("", value: expiryBinding, formatter: expiryFormatter)
            .frame(width: 80)
            .accessibilityLabel(Text(Self.expiryLabel))
            .disabled(expiry.isForced)
          Stepper("", value: expiryBinding, in: 0...HistoryExpiry.maximumHours)
            .labelsHidden()
            .accessibilityLabel(Text(Self.expiryLabel))
            .disabled(expiry.isForced)
          Text(Self.expiryUnit)
          if expiry.isForced {
            Image(systemName: "lock.fill")
              .help(Self.managedValue)
              .accessibilityLabel(Self.managedValue)
          }
        }
        .task {
          for await _ in Defaults.updates(.historyExpiryHours) {
            expiry = HistoryExpiry.current
          }
        }
        Text(Self.expiryDescription(expiry))
          .fixedSize(horizontal: false, vertical: true)
          .controlSize(.small)
          .foregroundStyle(expiry.isInvalid ? Color.red : Color.gray)
        if let warning = Self.maintenanceFailing(History.shared.failingOperations) {
          Text(warning)
            .fixedSize(horizontal: false, vertical: true)
            .controlSize(.small)
            .foregroundStyle(.red)
        }
        Text(Self.compactionNote)
          .fixedSize(horizontal: false, vertical: true)
          .controlSize(.small)
          .foregroundStyle(.gray)
      }

      Settings.Section(label: { Text("SortBy", tableName: "StorageSettings") }) {
        Picker("", selection: $sortBy) {
          ForEach(Sorter.By.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 160, alignment: .leading)
        .help(Text("SortByTooltip", tableName: "StorageSettings"))
        .accessibilityLabel(Text("SortBy", tableName: "StorageSettings"))
      }
    }
    .alert(
      Self.removeStoredDataTitle,
      isPresented: Binding(
        get: { viewModel.pendingChange != nil },
        set: { isPresented in
          if !isPresented && viewModel.pendingChange != nil {
            viewModel.cancelPendingChange()
          }
        }
      ),
      presenting: viewModel.pendingChange
    ) { change in
      Button(Self.removeStoredDataConfirm, role: .destructive) {
        viewModel.confirm(change)
      }
      Button(Self.removeStoredDataCancel, role: .cancel) {
        viewModel.cancelPendingChange()
      }
    } message: { change in
      Text(Self.removeStoredDataMessage(change.impact))
    }
  }

  // Strings added for the storage policy carry their English text as the
  // fallback, so a locale without them shows English rather than the key.
  private static func localized(_ key: String, _ value: String) -> String {
    NSLocalizedString(key, tableName: "StorageSettings", value: value, comment: "")
  }

  static var invalidSaveTypes: String {
    localized(
      "InvalidSaveTypes",
      "The saved list of content types is invalid. Until it is fixed, Maccy is not saving new copies and is " +
        "not removing stored data to match this setting: turn on the types to save. Aliases, pins and the " +
        "clear actions still work."
    )
  }

  static var invalidManagedSaveTypes: String {
    localized(
      "InvalidManagedSaveTypes",
      "The list of content types in your configuration profile is invalid. Until your administrator fixes it, " +
        "Maccy is not saving new copies and is not removing stored data to match this setting. Aliases, pins " +
        "and the clear actions still work."
    )
  }

  private static var managedSaveTypes: String {
    localized(
      "ManagedSaveTypes",
      "These settings are controlled by a configuration profile. Only your administrator can change them."
    )
  }

  private static var managedValue: String {
    localized("ManagedValue", "Set by your administrator in a configuration profile.")
  }

  private static var expiryLabel: String {
    localized("Expiry", "Remove after:")
  }

  private static var expiryUnit: String {
    localized("ExpiryUnit", "hours (0 = never)")
  }

  static func expiryDescription(_ expiry: HistoryExpiry) -> String {
    switch (expiry.state, expiry.isForced) {
    case (.off, false):
      return localized(
        "ExpiryOff",
        "Items are kept until you delete them or the history size is reached. Set a number of hours to remove " +
          "items you have not copied for that long (copying an item from Maccy counts). Pinned items are kept."
      )
    case (.off, true):
      return localized(
        "ExpiryOffManaged",
        "Your administrator has turned automatic removal off."
      )
    case (.hours(let hours), false):
      return String(format: localized(
        "ExpiryOn",
        "Items you have not copied for %lld hours are removed (copying an item from Maccy counts). Pinned " +
          "items are kept. Checked at launch, every few minutes and before history is shown. If the Mac's " +
          "clock is set back by more than 10 minutes twice, a recently copied item can be removed early."
      ), Int64(hours))
    case (.hours(let hours), true):
      return String(format: localized(
        "ExpiryOnManaged",
        "Set by your administrator: items not copied for %lld hours are removed, including pinned items. " +
          "Checked at launch, every few minutes and before history is shown. If the Mac's clock is set back by " +
          "more than 10 minutes twice, a recently copied item can be removed early."
      ), Int64(hours))
    case (.invalid, false):
      return String(format: localized(
        "ExpiryInvalid",
        "The saved expiry value is invalid. Until it is fixed, Maccy removes items not copied for %lld hour. " +
          "Pinned items are kept. Enter a number of hours, or 0 to turn this off."
      ), Int64(HistoryExpiry.invalidValueHours))
    case (.invalid, true):
      return String(format: localized(
        "ExpiryInvalidManaged",
        "The expiry value in your configuration profile is invalid (it must be 0 or a positive number of " +
          "hours). Until your administrator fixes it, Maccy removes items not copied for %lld hour, including " +
          "pinned items."
      ), Int64(HistoryExpiry.invalidValueHours))
    }
  }

  // Lists every automatic operation that is failing now, or nil if none is.
  static func maintenanceFailing(_ operations: [MaintenanceOperation: Date]) -> String? {
    guard let lastFailure = operations.values.max() else {
      return nil
    }
    let names = operations.keys.sorted().map(\.label)
    return String(format: localized(
      "MaintenanceFailing",
      "Maccy is failing at: %1$@. Items or files that should have been removed may still be on this Mac. " +
        "Last failure at %2$@. Maccy keeps trying."
    ), ListFormatter.localizedString(byJoining: names), lastFailure.formatted(date: .abbreviated, time: .shortened))
  }

  private static var compactionNote: String {
    localized(
      "CompactionNote",
      "After history is cleared or items are removed, Maccy rebuilds its database in the background so the " +
        "deleted data is dropped from it: straight after clearing, otherwise at most once an hour and when " +
        "Maccy quits or opens. This is not secure erasure: copies can remain on the disk, in APFS snapshots, " +
        "in Time Machine and in other backups."
    )
  }

  private static var removeStoredDataTitle: String {
    localized("RemoveStoredDataTitle", "Remove this data from history?")
  }

  private static var removeStoredDataConfirm: String {
    localized("RemoveStoredDataConfirm", "Remove")
  }

  private static var removeStoredDataCancel: String {
    localized("RemoveStoredDataCancel", "Cancel")
  }

  static func removeStoredDataMessage(_ impact: StorageCleanUpImpact?) -> String {
    guard let impact else {
      return localized(
        "RemoveStoredDataMessageUncounted",
        "Items in history may lose data or be removed entirely, including pinned items. This cannot be undone."
      )
    }

    return String(
      format: localized(
        "RemoveStoredDataMessage",
        "%1$lld items in history will lose data and %2$lld items will be removed entirely, including pinned " +
          "items. This cannot be undone."
      ),
      Int64(impact.itemsLosingData),
      Int64(impact.itemsRemoved)
    )
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
