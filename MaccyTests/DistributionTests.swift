import Foundation
import Testing
@testable import Maccy

extension SharedStateTests {
  @MainActor
  struct DistributionTests {
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
