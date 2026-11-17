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
    source = source.replace('textLimit = 80_000', 'textLimit = 1_000_000')
    source = source.replace('.milliseconds(100)', '.seconds(10)')
    print('DIAGNOSTIC ONLY: million-unit cap, ten-second budget', flush=True)
adapters = '''
enum Defaults {
  enum Keys {
    static let ignoreRegexp = Key()
  }
  struct Key {
    let name = "ignoreRegexp"
    var suite: UserDefaults { .standard }
  }
}
struct Logger {
  init(label: String) {}
  func warning(_ message: String) {}
}
'''
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
  #"\b[A-Za-z0-9+/]{40,}={0,2}"#,
  #"\b[0-9]{3}[- ]?[0-9]{2}[- ]?[0-9]{4}\b"#,
  #"\b([A-Za-z]{8,})[-:]\1\b"#
], forKey: "ignoreRegexp")
let rules = IgnoreRules(preferences: preferences)
let words = "Annual report ordinary notes and totals. "
for target in [32_000, 60_000, 80_000, 96_000, 128_000] {
  for shape in ["Excel 2000 cells", "Word styles/pages", "Docs inline spans"] {
    let unit = shape == "Excel 2000 cells" ? target / 2000 : 40
    let count = shape == "Excel 2000 cells" ? 2000 : target / 40
    let text = String(repeating: words, count: unit / words.count + 1).prefix(unit - 1) + " "
    let html: String
    if shape == "Excel 2000 cells" {
      html = "<table>" + (0..<count).map { "<td class=cell x:num='\($0)' style='color:red'>\(text)</td>" }.joined() + "</table>"
    } else if shape == "Word styles/pages" {
      let styles = String(repeating: ".x{color:red}", count: 20_000)
      let body = String(repeating: String(text), count: count)
      html = "<style><!-- /* Word definitions */ \(styles) --></style><p>\(body)</p>"
    } else {
      html = String(repeating: "<span style='font-family:Arial;color:red'>\(text)</span>", count: count)
    }
    let extracted = ClipboardHTMLText.inspect(html)
    precondition(extracted.visible.contains("Annual"))
    let plain = extracted.visible
    let item = NSPasteboardItem()
    item.setString(plain + "\n", forType: .string)
    item.setData(Data(html.utf8), forType: .html)
    let rtf = NSAttributedString(string: plain).rtf(from: NSRange(location: 0, length: plain.utf16.count), documentAttributes: [:])!
    item.setData(rtf, forType: .rtf)
    let units = Set([plain, extracted.visible, extracted.hidden].map { IgnoreRules.trimmingTrailingWhitespace($0) }).reduce(0) { $0 + $1.utf16.count }
    var times: [Double] = []
    var accepted = 0
    _ = rules.rejects([item])
    for _ in 0..<7 {
      let start = ContinuousClock.now
      let rejected = rules.rejects([item])
      times.append(milliseconds(start))
      if !rejected { accepted += 1 }
    }
    if units <= IgnoreRules.textLimit && rtf.count <= IgnoreRules.rtfDataLimit {
      precondition(accepted == 7, "Under-cap realistic event must complete, not time out")
    }
    print("\(shape) | target \(target) | units \(units) | HTML bytes \(html.utf8.count) | RTF bytes \(rtf.count) | accepted \(accepted)/7 | median \(times.sorted()[3]) ms | range \(times.min()!)...\(times.max()!) | reason \(String(describing: rules.lastRejection))")
  }
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
print("Production filter/extractor/settings-boundary standalone assertions passed")
'''
with tempfile.TemporaryDirectory(prefix='maccy-ignore-rules-') as temporary:
    directory = Path(temporary)
    swift = directory / 'main.swift'
    swift.write_text(source + adapters + harness)
    binary = directory / 'measure'
    subprocess.run(['swiftc', '-O', '-swift-version', '6', '-default-isolation', 'MainActor',
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
