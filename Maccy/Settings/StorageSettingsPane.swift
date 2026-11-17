import SwiftUI
import Defaults
import Settings

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    // A change that would remove stored data, waiting for confirmation.
    struct PendingChange {
      let enabledTypes: Set<NSPasteboard.PasteboardType>
      let impact: StorageCleanUpImpact?
    }

    // The effective setting, including a value forced by a configuration
    // profile or an invalid stored value.
    private(set) var policy = StoragePolicy.current
    var pendingChange: PendingChange?

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
          let change = StorageToggleChange.change(from: StoragePolicy.current, setting: toggle, to: isOn) {
            try Storage.shared.cleanUpImpact(of: $0)
          }
          switch change {
          case .refused:
            break
          case .apply(let enabledTypes):
            self.write(enabledTypes)
          case .confirm(let enabledTypes, let impact):
            // Until confirmed the toggle keeps showing the stored value.
            self.pendingChange = PendingChange(enabledTypes: enabledTypes, impact: impact)
          }
        }
      )
    }

    func confirmPendingChange() {
      if let pendingChange {
        write(pendingChange.enabledTypes)
      }
      pendingChange = nil
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
      History.shared.enforceStoragePolicy()
    }
  }

  @Default(.size) private var size
  @Default(.sortBy) private var sortBy

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

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
          TextField("", value: $size, formatter: sizeFormatter)
            .frame(width: 80)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
          Stepper("", value: $size, in: 1...999)
            .labelsHidden()
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
          Text(storageSize)
            .controlSize(.small)
            .foregroundStyle(.gray)
            .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
            .onAppear {
              storageSize = Storage.shared.size
            }
        }
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
    ) { _ in
      Button(Self.removeStoredDataConfirm, role: .destructive) {
        viewModel.confirmPendingChange()
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

  private static var invalidSaveTypes: String {
    localized(
      "InvalidSaveTypes",
      "The saved list of content types is invalid. Maccy is not saving anything you copy until it is fixed: " +
        "turn on the types to save. Existing history is kept as it is."
    )
  }

  private static var invalidManagedSaveTypes: String {
    localized(
      "InvalidManagedSaveTypes",
      "The list of content types in your configuration profile is invalid. Maccy is not saving anything you " +
        "copy until your administrator fixes it. Existing history is kept as it is."
    )
  }

  private static var managedSaveTypes: String {
    localized(
      "ManagedSaveTypes",
      "These settings are controlled by a configuration profile. Only your administrator can change them."
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
