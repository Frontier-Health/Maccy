import SwiftUI
import Defaults
import Settings

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    // The effective setting, including a value forced by a configuration
    // profile or a malformed stored value.
    private(set) var policy = StoragePolicy.current

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
          guard !self.policy.isForced else { return }
          Defaults[.enabledPasteboardTypes] = self.policy.enabledTypes(setting: toggle, to: isOn)
          self.policy = StoragePolicy.current
        }
      )
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
        if viewModel.policy.isMalformed {
          Text(
            LocalizedStringKey(viewModel.policy.isForced ? "InvalidManagedSaveTypes" : "InvalidSaveTypes"),
            tableName: "StorageSettings"
          )
          .controlSize(.small)
          .foregroundStyle(.red)
        } else if viewModel.policy.isForced {
          Text("ManagedSaveTypes", tableName: "StorageSettings")
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
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
