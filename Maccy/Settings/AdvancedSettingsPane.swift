import SwiftUI
import Defaults

struct AdvancedSettingsPane: View {
  @State private var captureMode = CaptureMode.capturing
  @State private var captureModeLocked = false
  @State private var ocr = OCRSetting.current

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
      Text(verbatim: AppIdentity.shellScript("TurnOffShellScript"))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .font(.system(size: 11, design: .monospaced))
        .controlSize(.small)
        .padding(.vertical, 2)
      Text("TurnOffViaMenuIconDescription", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      Text(verbatim: AppIdentity.shellScript("TurnOffNextShellScript"))
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

      Toggle(isOn: Binding(get: { ocr.isEnabled }, set: { Defaults[.ocrEnabled] = $0 })) {
        if ocr.isForced {
          Label {
            Text(Self.ocrLabel)
          } icon: {
            Image(systemName: "lock.fill")
          }
        } else {
          Text(Self.ocrLabel)
        }
      }
      .disabled(ocr.isForced)
      .help(Self.ocrHelp)
      .task {
        for await _ in Defaults.updates(.ocrEnabled) {
          ocr = OCRSetting.current
        }
      }
      if ocr.state == .invalid {
        Text(Self.ocrInvalid(isForced: ocr.isForced))
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(.red)
          .controlSize(.small)
      }

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

  // English only; other locales fall back to it.
  private static func localized(_ key: String, _ value: String) -> String {
    NSLocalizedString(key, tableName: "AdvancedSettings", value: value, comment: "")
  }

  static var ocrLabel: String {
    localized("OCREnabled", "Recognize text in copied images")
  }

  static var ocrHelp: String {
    localized(
      "OCREnabledTooltip",
      "Uses text recognition to title copied images. When off, no image is analysed, image titles are empty " +
        "and titles recognised earlier are erased."
    )
  }

  static func ocrInvalid(isForced: Bool) -> String {
    isForced
      ? localized("OCREnabledInvalidManaged",
                  "The text recognition value in your configuration profile is invalid, so text recognition is off.")
      : localized("OCREnabledInvalid",
                  "The saved text recognition value is invalid, so text recognition is off. Turn it on or off to fix it.")
  }
}

#Preview {
  AdvancedSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
