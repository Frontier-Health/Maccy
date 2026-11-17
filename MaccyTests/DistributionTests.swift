import AppKit
import Defaults
import Foundation
import Testing
@testable import Maccy

extension SharedStateTests {
  @MainActor
  struct DistributionTests {
    @Test("The built app and its tests use the configured organisation identity")
    func bundleIdentity() throws {
      let identifier = try #require(Bundle.main.bundleIdentifier)
      #expect(identifier == AppIdentity.bundleIdentifier)
      #expect(!identifier.hasPrefix("org.p0deje."))
      #expect(!identifier.contains("$("))
      #expect(Bundle(for: BundleMarker.self).bundleIdentifier == identifier + ".Tests")
      #expect(Defaults.Keys.testingSuiteName == identifier + ".uitests")
    }

    @Test("The exported pin type matches the drag implementation")
    func exportedPinType() throws {
      let types = try #require(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
      let identifiers = types.compactMap { $0["UTTypeIdentifier"] as? String }
      #expect(identifiers == [PinReorderDrag.contentType.identifier])
      #expect(identifiers == [AppIdentity.bundleIdentifier + ".pin-reorder"])
      #expect(!identifiers.contains { $0.hasPrefix("org.p0deje.") || $0.contains("$(") })
      #expect(NSPasteboard.PasteboardType.fromMaccy.rawValue == AppIdentity.bundleIdentifier)
    }

    @Test("Every About link points to the fork repository")
    func aboutLinks() {
      let credits = About().credits
      var links: [String] = []
      credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
        if let link = value as? String { links.append(link) }
      }
      #expect(!links.isEmpty)
      #expect(links.allSatisfy { $0 == "https://github.com/Frontier-Health/Maccy" })
      #expect(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
              == "Copyright © Alexey Rodionov")
    }

    @Test("Localized defaults commands use the built app identity")
    func shellCommands() throws {
      for locale in Bundle.main.localizations {
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for key in ["TurnOffShellScript", "TurnOffNextShellScript"] {
          let script = bundle.localizedString(forKey: key, value: nil, table: "AdvancedSettings")
          #expect(script.isEmpty || script.contains("<BUNDLE_ID>"))
          #expect(!script.localizedCaseInsensitiveContains("org.p0deje"))
        }
      }
      let script = AppIdentity.shellScript("TurnOffShellScript")
      #expect(script.contains(AppIdentity.bundleIdentifier))
      #expect(!script.contains("<BUNDLE_ID>"))
    }

    @Test("The built app has no self-updater configuration or framework")
    func noSelfUpdater() throws {
      let info = try #require(Bundle.main.infoDictionary)
      #expect(info.keys.filter { $0.hasPrefix("SU") }.isEmpty)
      let frameworks = Bundle.main.privateFrameworksURL
      let names = try frameworks.map { try FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
      #expect(!names.contains { $0.localizedCaseInsensitiveContains("sparkle") })
    }
  }
}

private final class BundleMarker {}
