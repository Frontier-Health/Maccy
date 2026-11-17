import SwiftUI
import Defaults

struct IgnoreRegexpsSettingsView: View {
  @Default(.ignoreRegexp) private var ignoredRegexps

  @FocusState private var focus: Int?
  @State private var drafts: [Int: String] = [:]
  @State private var selection: Int?
  @State private var saveFailed = false
  @State private var addLimitReached = false
  @State private var confirmReset = false
  @State private var issue = IgnoreRules.configurationIssue()

  private var managed: Bool { IgnoreRules.isManaged() }

  var body: some View {
    VStack(alignment: .leading) {
      List(selection: $selection) {
        ForEach(Array(ignoredRegexps.enumerated()), id: \.offset) { index, regexp in
          HStack {
            TextField("", text: Binding(
              get: { drafts[index] ?? regexp },
              set: { drafts[index] = $0 }
            ))
            .disabled(managed)
            .onSubmit {
              saveFailed = !IgnoreRules.save(drafts[index] ?? regexp, replacingAt: index)
            }
            .focused($focus, equals: index)
            if !IgnoreRules.isValid(regexp) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(Text("InvalidIgnoreRule", tableName: "IgnoreSettings"))
            }
          }.tag(index)
        }
      }.onDeleteCommand {
        removeSelection()
      }
      .onChange(of: ignoredRegexps) {
        drafts = [:]
        addLimitReached = false
      }

      ControlGroup {
        Button("", systemImage: "plus") {
          addLimitReached = ignoredRegexps.count >= IgnoreRules.ruleLimit
          saveFailed = !addLimitReached && !IgnoreRules.save("^[a-zA-Z0-9]{50}$")
          focus = ignoredRegexps.indices.last
        }
        Button("", systemImage: "minus") {
          removeSelection()
        }
      }.frame(width: 50)
        .disabled(managed || issue == .unreadable)

      if issue == .unreadable && !managed {
        Button { confirmReset = true } label: { Text("ResetIgnoreRules", tableName: "IgnoreSettings") }
          .confirmationDialog(Text("ResetIgnoreRulesConfirmation", tableName: "IgnoreSettings"),
                              isPresented: $confirmReset) {
            Button(role: .destructive) {
              if IgnoreRules.reset() {
                drafts = [:]
                selection = nil
                saveFailed = false
              }
              issue = IgnoreRules.configurationIssue()
            } label: { Text("ResetIgnoreRules", tableName: "IgnoreSettings") }
          }
      }

      if addLimitReached {
        Text("IgnoreRuleAddLimit", tableName: "IgnoreSettings")
          .foregroundStyle(.red)
      }
      if saveFailed {
        Text("InvalidIgnoreRuleDraft", tableName: "IgnoreSettings")
          .foregroundStyle(.red)
      }
      if let issue {
        Label {
          Text(message(for: issue), tableName: "IgnoreSettings")
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .fontWeight(.semibold)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      }
      if managed {
        Text("ManagedIgnoreRules", tableName: "IgnoreSettings")
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("IgnoredRegexpsDescription", tableName: "IgnoreSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
    }.padding()
      .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
        issue = IgnoreRules.configurationIssue()
      }
  }

  private func message(for issue: IgnoreRules.ConfigurationIssue) -> LocalizedStringKey {
    switch issue {
    case .unreadable: return managed ? "UnreadableManagedIgnoreRules" : "UnreadableIgnoreRules"
    case .tooManyRules: return managed ? "TooManyManagedIgnoreRules" : "TooManyIgnoreRules"
    case .invalidRule: return managed ? "InvalidManagedIgnoreRule" : "InvalidIgnoreRule"
    }
  }

  private func removeSelection() {
    guard let selection, ignoredRegexps.indices.contains(selection) else { return }
    guard IgnoreRules.remove(at: selection) else { return }
    self.selection = nil
    saveFailed = false
  }
}

#Preview {
  IgnoreRegexpsSettingsView()
    .environment(\.locale, .init(identifier: "en"))
}
