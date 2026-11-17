import SwiftUI
import Defaults

struct AdvancedSettingsPane: View {
  @State private var captureMode = CaptureMode.capturing
  @State private var captureModeLocked = false

  // On for both `paused` and `skipNext`. Switching it either way sets the whole
  // mode, which clears any pending one-shot skip. Disabled while a configuration
  // profile pins the capture state.
  private var turnedOff: Binding<Bool> {
    Binding(
      get: { !captureMode.capturesCopies },
      set: { Clipboard.shared.perform($0 ? .pause : .resume) }
    )
  }

  var body: some View {
    VStack(alignment: .leading) {
      Toggle(isOn: turnedOff) {
        Text("TurnOff", tableName: "AdvancedSettings")
      }
      .disabled(captureModeLocked)
      .task {
        for await _ in Defaults.updates([.captureMode, .legacyIgnoreEvents, .legacyIgnoreOnlyNextEvent]) {
          let preferences = Clipboard.shared.capturePreferences
          captureMode = CaptureMode.effective(in: preferences)
          captureModeLocked = CaptureMode.isLockedByProfile(in: preferences)
        }
      }
      Text("TurnOffDescription", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      Text("TurnOffShellScript", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .font(.system(size: 11, design: .monospaced))
        .controlSize(.small)
        .padding(.vertical, 2)
      Text("TurnOffViaMenuIconDescription", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      Text("TurnOffNextShellScript", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .font(.system(size: 11, design: .monospaced))
        .controlSize(.small)
        .padding(.vertical, 2)

      Divider()

      Defaults.Toggle(key: .intentsEnabled) {
        if UserDefaults.standard.objectIsForced(forKey: "intentsEnabled") {
          Label {
            Text("IntentsEnabled", tableName: "AdvancedSettings")
          } icon: {
            Image(systemName: "lock.fill")
          }
        } else {
          Text("IntentsEnabled", tableName: "AdvancedSettings")
        }
      }
      .disabled(UserDefaults.standard.objectIsForced(forKey: "intentsEnabled"))
      .help(Text("IntentsEnabledTooltip", tableName: "AdvancedSettings"))

      Defaults.Toggle(key: .clearOnQuit) {
        Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")
      }.help(Text("ClearHistoryOnQuitTooltip", tableName: "AdvancedSettings"))

      Defaults.Toggle(key: .clearSystemClipboard) {
        Text("ClearSystemClipboard", tableName: "AdvancedSettings")
      }.help(Text("ClearSystemClipboardTooltip", tableName: "AdvancedSettings"))
    }
    .frame(minWidth: 350, maxWidth: 450)
    .padding()
  }
}

#Preview {
  AdvancedSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
