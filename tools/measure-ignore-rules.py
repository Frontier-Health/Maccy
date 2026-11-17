#!/usr/bin/env python3
"""Run the production filter with only Defaults key and Logging adapters stubbed.

Requires macOS Command Line Tools, not Xcode. This measures the filter, not the
watcher, history storage, preference compilation on a cold cache, or UI latency.
"""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
source = (root / 'Maccy/IgnoreRules.swift').read_text()
source = source.replace('import Defaults', '').replace('import Logging', '')
if '--diagnostic-million' in sys.argv:
    # Measure completed work at the rejected candidate cap, not an early timeout.
    source = source.replace('textLimit = 128_000', 'textLimit = 1_000_000')
    source = source.replace('.milliseconds(100)', '.seconds(10)')
    print('DIAGNOSTIC: 1,000,000-unit candidate with 10-second budget; not production limits', flush=True)
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
let suite = "org.p0deje.Maccy.benchmark.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
preferences.set((0..<10).map { "secret-token-\($0)" }, forKey: "ignoreRegexp")
let rules = IgnoreRules(preferences: preferences)
let bodyLength = (IgnoreRules.textLimit - 9) / 2
let body = String(repeating: "ordinary text ", count: IgnoreRules.textLimit / 14).prefix(bodyLength - 1) + "x"
let source = "<p>" + body + "</p>"
let data = Data(source.utf8)
let item = NSPasteboardItem()
item.setData(data, forType: .html)
precondition(ClipboardHTMLText.extract(data) == " " + body + " ")
let units = source.utf16.count + ClipboardHTMLText.extract(data)!.utf16.count
precondition(units == IgnoreRules.textLimit - 1)
let initialRejected = rules.rejects([item])
precondition(!initialRejected, "Rejection: \(String(describing: rules.lastRejection))") // Warm cache, matching the event path.
var elapsed: [Double] = []
for _ in 0..<7 {
  let started = ContinuousClock.now
  let rejected = rules.rejects([item])
  let duration = started.duration(to: .now)
  precondition(!rejected, "Unexpected rejection: \(String(describing: rules.lastRejection))")
  elapsed.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
}
print("\(units) aggregate UTF-16 units; \(data.count) raw bytes; 10 compiled nonmatching simple rules; 7 accepted events")
print("milliseconds: \(elapsed)")
print("median ms: \(elapsed.sorted()[3]); range: \(elapsed.min()!)...\(elapsed.max()!)")
// Supplementary implementation checks; these do not replace watcher tests.
for (input, expected) in [
  ("<meta charset='utf-8'><!--StartFragment--><p>pass<b>word</b><br>next&nbsp;line</p>", " password next\u{00A0}line "),
  ("<!DOCTYPE html><!--[if mso]>hidden<![endif]--><p>Word</p>", " Word "),
  ("a<script>hidden</script><style>hidden</style>b", "ab"),
  ("&amp;&lt;&gt;&quot;&apos;&nbsp;&#65;&#x1F600;", "&<>\"'\u{00A0}A😀"),
  ("a<b <span>c</span>", "ac"),
  ("a<!--unfinished", "a"),
  ("a<b title='unfinished", "a"),
  ("&bogus; &#xD800;", "&bogus; &#xD800;")
] {
  precondition(ClipboardHTMLText.extract(input) == expected, input)
}
for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
  precondition(ClipboardHTMLText.extract("<p>password".data(using: encoding)!) == " password")
}
print("Supplementary extractor checks passed")
'''
with tempfile.TemporaryDirectory(prefix='maccy-ignore-rules-') as temporary:
    directory = Path(temporary)
    swift = directory / 'main.swift'
    swift.write_text(source + adapters + harness)
    binary = directory / 'measure'
    subprocess.run(['swiftc', '-O', '-swift-version', '6', '-default-isolation', 'MainActor',
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
