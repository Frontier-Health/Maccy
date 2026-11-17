import SwiftUI
import Defaults

struct AdvancedSettingsPane: View {
  @Default(.captureMode) private var captureMode

  // On for both `paused` and `skipNext`. Switching it either way sets the whole
  // mode, which clears any pending one-shot skip.
  private var turnedOff: Binding<Bool> {
    Binding(
      get: { !captureMode.capturesCopies },
      set: { captureMode = $0 ? .paused : .capturing }
    )
  }

  var body: some View {
    VStack(alignment: .leading) {
      Toggle(isOn: turnedOff) {
        Text("TurnOff", tableName: "AdvancedSettings")
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
