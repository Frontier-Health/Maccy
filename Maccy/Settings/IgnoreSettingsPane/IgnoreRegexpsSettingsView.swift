import SwiftUI
import Defaults

struct IgnoreRegexpsSettingsView: View {
  @Default(.ignoreRegexp) private var ignoredRegexps

  @FocusState private var focus: Int?
  @State private var drafts: [Int: String] = [:]
  @State private var selection: Int?
  @State private var saveFailed = false

  var body: some View {
    VStack(alignment: .leading) {
      List(selection: $selection) {
        ForEach(Array(ignoredRegexps.enumerated()), id: \.offset) { index, regexp in
          HStack {
            TextField("", text: Binding(
              get: { drafts[index] ?? regexp },
              set: { drafts[index] = $0 }
            ))
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
      }

      ControlGroup {
        Button("", systemImage: "plus") {
          saveFailed = !IgnoreRules.save("^[a-zA-Z0-9]{50}$")
          focus = ignoredRegexps.indices.last
        }
        Button("", systemImage: "minus") {
          removeSelection()
        }
      }.frame(width: 50)

      if saveFailed {
        Text("InvalidIgnoreRuleDraft", tableName: "IgnoreSettings")
          .foregroundStyle(.red)
      }
      if IgnoreRules().hasInvalidStoredRules {
        Text("InvalidIgnoreRule", tableName: "IgnoreSettings")
          .foregroundStyle(.red)
      }
      Text("IgnoredRegexpsDescription", tableName: "IgnoreSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
    }.padding()
  }

  private func removeSelection() {
    guard let selection, ignoredRegexps.indices.contains(selection) else { return }
    ignoredRegexps.remove(at: selection)
    self.selection = nil
    saveFailed = false
  }
}

#Preview {
  IgnoreRegexpsSettingsView()
    .environment(\.locale, .init(identifier: "en"))
}
