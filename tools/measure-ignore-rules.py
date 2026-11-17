#!/usr/bin/env python3
"""Run the production filter with only Defaults key and Logging adapters stubbed.

Requires macOS Command Line Tools, not Xcode. This measures the filter, not the
watcher, history storage, preference compilation on a cold cache, or UI latency.
"""
from pathlib import Path
import subprocess
import tempfile
import sys
import re

root = Path(__file__).resolve().parents[1]
source = (root / 'Maccy/IgnoreRules.swift').read_text()
source = source.replace('import Defaults', '').replace('import Logging', '')
if '--diagnostic' in sys.argv:
    source = re.sub(r'textLimit = [0-9_]+', 'textLimit = 1_000_000', source, count=1)
    source = source.replace('.milliseconds(100)', '.seconds(10)')
    print('DIAGNOSTIC ONLY: million-unit cap, ten-second budget', flush=True)
# Timing counters exist only in this standalone executable, never in the app.
source = source.replace('private(set) var lastRejection:', 'private(set) var measuredMatching: Duration = .zero\n  private(set) var lastRejection:')
source = source.replace('lastRejection = rejection(for: items)', 'measuredMatching = .zero\n    lastRejection = rejection(for: items)')
source = source.replace('matchingBudget -= started.duration(to: .now)',
                        'let elapsed = started.duration(to: .now)\n          matchingBudget -= elapsed\n          measuredMatching += elapsed')
adapters = '''
enum Defaults {
  static let domain = "org.p0deje.Maccy.standalone." + UUID().uuidString
  static let preferences = UserDefaults(suiteName: domain)!
  static subscript(key: Key) -> [String] {
    get { preferences.stringArray(forKey: key.name) ?? [] }
    set { preferences.set(newValue, forKey: key.name) }
  }
  enum Keys {
    static let ignoreRegexp = Key()
  }
  struct Key {
    static let ignoreRegexp = Key()
    let name = "ignoreRegexp"
    var suite: UserDefaults { Defaults.preferences }
  }
}
struct Logger {
  init(label: String) {}
  func warning(_ message: String) {}
}
'''
tests = (root / 'MaccyTests/ClipboardTests.swift').read_text()
fixtures = tests[tests.index('  static func wordPictureRTF'):tests.index('  @Test("RTF accounting')]
adapters += '\nenum Fixtures {\n' + fixtures + '\n}\n'
harness = r'''
func milliseconds(_ start: ContinuousClock.Instant) -> Double {
  let d = start.duration(to: .now)
  return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
let suite = "org.p0deje.Maccy.benchmark.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
preferences.set([
  #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
  #"[A-Za-z0-9+/]{40,}={0,2}"#,
  #"\b[0-9a-fA-F]{32}\b"#,
  #"\b[0-9]{3}[- ]?[0-9]{2}[- ]?[0-9]{4}\b"#,
  #"\b([A-Za-z]{8,})[-:]\1\b"#
], forKey: "ignoreRegexp")
let rules = IgnoreRules(preferences: preferences)
let words = "Annual report ordinary notes and totals. "
for (target, rows) in [(32_000, 100), (60_000, 200), (80_000, 300), (96_000, 400), (128_000, 600)] {
  for shape in ["Excel table", "Word styles/pages", "Docs inline spans"] {
    let plain: String
    let html: String
    if shape == "Excel table" {
      let fixture = Fixtures.tableFixture(rows: rows)
      plain = fixture.plain
      html = fixture.html
    } else {
      let paragraphs = (0..<(target / 80)).map { _ in String(repeating: words, count: 2).trimmingCharacters(in: .whitespaces) }
      plain = paragraphs.joined(separator: "\r\n")
      if shape == "Word styles/pages" {
        let styles = String(repeating: ".x{color:red}", count: 20_000)
        html = "<style><!-- /* Word definitions */ \(styles) --></style>\n" +
          paragraphs.map { "<p class=MsoNormal>\n<span style='font-family:Arial'>\($0)</span>\n</p>\n" }.joined()
      } else {
        html = paragraphs.map { "<p>\n<span class=copy style='font-family:Arial;color:red'>\($0)</span>\n</p>\n" }.joined()
      }
    }
    let extracted = ClipboardHTMLText.inspect(html)
    precondition(!extracted.visible.isEmpty)
    let item = NSPasteboardItem()
    item.setString(plain, forType: .string)
    item.setData(Data(html.utf8), forType: .html)
    let rtfText = plain.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: "\n")
    let rtf = NSAttributedString(string: rtfText).rtf(from: NSRange(location: 0, length: rtfText.utf16.count), documentAttributes: [:])!
    precondition(NSAttributedString(rtf: rtf, documentAttributes: nil)?.string == rtfText)
    item.setData(rtf, forType: .rtf)
    var selected = [IgnoreRules.normalizedTextKey(plain): plain]
    for text in [extracted.visible, extracted.hidden, rtfText] {
      let key = IgnoreRules.normalizedTextKey(text)
      if key.isEmpty || key == IgnoreRules.normalizedTextKey(plain) { continue }
      if text.utf16.count > (selected[key]?.utf16.count ?? 0) { selected[key] = text }
    }
    let units = selected.values.reduce(0) { $0 + $1.utf16.count }
    var times: [Double] = []
    var accepted = 0
    var matching: [Double] = []
    _ = rules.rejects([item])
    for _ in 0..<7 {
      let start = ContinuousClock.now
      let rejected = rules.rejects([item])
      times.append(milliseconds(start))
      let duration = rules.measuredMatching
      matching.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
      if !rejected { accepted += 1 }
    }
    if units <= IgnoreRules.textLimit && rtf.count <= IgnoreRules.rtfDataLimit {
      if accepted != 7 {
        print("FAILED under-cap fixture: \(shape), units \(units), accepted \(accepted)/7, reason \(String(describing: rules.lastRejection))")
        fflush(nil)
      }
      precondition(accepted == 7, "Under-cap realistic event must complete, not time out")
    }
    print("\(shape) | rows \(rows) | plain \(plain.utf16.count) | units \(units) | HTML bytes \(html.utf8.count) | RTF bytes \(rtf.count) | accepted \(accepted)/7 | median \(times.sorted()[3]) ms | range \(times.min()!)...\(times.max()!) | matching median \(matching.sorted()[3]) ms | reason \(String(describing: rules.lastRejection))")
    fflush(nil)
  }
}
for size in [1, 4, 8, 16, 17] {
  let payload = size * 1024 * 1024 / 4 - (size == 16 ? 1024 : 0)
  let rtf = Fixtures.wordPictureRTF("Annual report", pictureBytes: payload)
  let item = NSPasteboardItem()
  item.setString("Annual report", forType: .string)
  item.setData(rtf, forType: .rtf)
  var imports: [Double] = []
  var filters: [Double] = []
  var accepted = 0
  for _ in 0..<7 {
    var start = ContinuousClock.now
    let decoded = NSAttributedString(rtf: rtf, documentAttributes: nil)
    precondition(decoded?.string.contains("Annual report") == true)
    imports.append(milliseconds(start))
    start = .now
    if !rules.rejects([item]) { accepted += 1 }
    filters.append(milliseconds(start))
  }
  print("Picture RTF | raw \(rtf.count) | charged \(IgnoreRules.rtfTextDataSize(rtf)) | import median \(imports.sorted()[3]) ms | range \(imports.min()!)...\(imports.max()!) | filter median \(filters.sorted()[3]) ms | range \(filters.min()!)...\(filters.max()!) | accepted \(accepted)/7")
}
for size in [128, 256, 512, 1024, 8192] {
  let segment = #"{\b Annual} {\i report} ordinary notes. "#
  let rtf = Data((#"{\rtf1\ansi "# + String(repeating: segment, count: size * 1024 / segment.utf8.count) + "}").utf8)
  var times: [Double] = []
  for _ in 0..<7 {
    let start = ContinuousClock.now
    let decoded = NSAttributedString(rtf: rtf, documentAttributes: nil)
    precondition(decoded?.string.contains("Annual report") == true)
    times.append(milliseconds(start))
  }
  print("RTF import | bytes \(rtf.count) | median \(times.sorted()[3]) ms | range \(times.min()!)...\(times.max()!)")
}
'''
if '--check' in sys.argv:
    tests = (root / 'MaccyTests/ClipboardTests.swift').read_text()
    direct = tests[tests.index('@MainActor\nstruct ClipboardHTMLTextTests'):]
    direct = re.sub(r'  @Test\(.*?\n  func ', '  func ', direct, flags=re.S)
    direct = direct.replace('#expect(', 'precondition(').replace('#require(', 'require(')
    managed = tests[tests.index('final class ManagedDefaults:'):tests.index('// swiftlint:disable:next type_body_length\nstruct CaptureModeTests')]
    managed = managed.replace("final class ManagedDefaults", "nonisolated final class ManagedDefaults")
    watcher_fixtures = tests[tests.index('    @Test("NUL-terminated'):tests.index('    private func copyRichText(')]
    watcher_fixtures = re.sub(r'    @Test\(.*?\n    func ', '    func ', watcher_fixtures, flags=re.S)
    watcher_fixtures = watcher_fixtures.replace('#expect(', 'precondition(').replace('#require(', 'require(')
    adapters += "\nstruct RoundThreeFilterFixtures {\n" + r'''
      let pasteboard = NSPasteboard(name: .init("org.p0deje.Maccy.filter-fixtures." + UUID().uuidString))
      func copyString(_ value: String) {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
      }
      func copyRichText(_ value: String, type: NSPasteboard.PasteboardType) {
        pasteboard.declareTypes([type], owner: nil)
        pasteboard.setString(value, forType: type)
      }
      func checkNow() -> [Int] {
        IgnoreRules().rejects(pasteboard.pasteboardItems ?? []) ? [] : [1]
      }
''' + watcher_fixtures + "\n}\n"
    harness = managed + direct + r'''
func require<T>(_ value: T?) throws -> T { precondition(value != nil); return value! }
let tests = ClipboardHTMLTextTests()
try tests.utf16(encoding: .utf16)
try tests.utf16(encoding: .utf16LittleEndian)
try tests.utf16(encoding: .utf16BigEndian)
tests.undecodable()
tests.hiddenExtraction()
try tests.utf16Nuls()
try tests.configurationStates()
try tests.deduplicatedText()
try tests.rtfCostBoundary()
try tests.managedRules()
try tests.rejectionReasons()
tests.rtfSizing()
try tests.resetRepairedRules()
try tests.originalDeduplication()
let fixtures = RoundThreeFilterFixtures()
try fixtures.nulHTMLWatcher()
fixtures.wordPictureWatcher()
fixtures.emptyDerivedWatcher()
fixtures.assetURLWatcher()
fixtures.dataURIWatcher()
fixtures.originalWhitespaceWatcher()
try fixtures.realisticTableWatcher()
fixtures.droppedHTMLWatcher()
Defaults.preferences.removePersistentDomain(forName: Defaults.domain)
print("Production filter/extractor/settings assertions passed, including round-three watcher inputs (filter only; CI runs the watcher)")
'''
with tempfile.TemporaryDirectory(prefix='maccy-ignore-rules-') as temporary:
    directory = Path(temporary)
    swift = directory / 'main.swift'
    swift.write_text(source + adapters + harness)
    binary = directory / 'measure'
    subprocess.run(['swiftc', '-O', '-swift-version', '6', '-default-isolation', 'MainActor',
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
