import AppKit
import Defaults

// Read the effective preferences on every event, rather than relying on delivery
// of a notification from another process or a configuration profile.
final class IgnoreRules {
  static let textLimit = 16_384 // UTF-16 code units, summed across the event.
  static let dataLimit = 65_536 // Bytes, summed across the event's text representations.
  static let patternLimit = 4_096
  static let ruleLimit = 128

  private enum Stored: Equatable {
    case patterns([String])
    case malformed
  }

  private let preferences: UserDefaults
  private var cached: Stored?
  private var expressions: [NSRegularExpression] = []
  private var invalid = false

  init(preferences: UserDefaults = Defaults.Keys.ignoreRegexp.suite) {
    self.preferences = preferences
  }

  static func isValid(_ pattern: String) -> Bool {
    !pattern.isEmpty && pattern.utf16.count <= patternLimit &&
      (try? NSRegularExpression(pattern: pattern)) != nil
  }

  // The settings UI uses this exact save boundary. An invalid draft never
  // replaces the last saved rule. Other invalid stored rules remain repairable.
  @discardableResult
  static func save(_ pattern: String, replacingAt index: Int? = nil,
                   in preferences: UserDefaults = Defaults.Keys.ignoreRegexp.suite) -> Bool {
    guard isValid(pattern) else { return false }
    var patterns = preferences.object(forKey: Defaults.Keys.ignoreRegexp.name) as? [String] ?? []
    if let index {
      guard patterns.indices.contains(index) else { return false }
      patterns[index] = pattern
    } else {
      guard patterns.count < ruleLimit else { return false }
      patterns.append(pattern)
    }
    preferences.set(patterns, forKey: Defaults.Keys.ignoreRegexp.name)
    return true
  }

  var hasInvalidStoredRules: Bool {
    refresh()
    return invalid
  }

  private func refresh() {
    let raw = preferences.object(forKey: Defaults.Keys.ignoreRegexp.name)
    let stored: Stored = if let raw {
      (raw as? [String]).map(Stored.patterns) ?? .malformed
    } else {
      .patterns([])
    }
    guard cached != stored else { return }
    cached = stored
    expressions = []
    invalid = false
    guard case let .patterns(patterns) = stored else {
      invalid = true
      return
    }
    invalid = patterns.count > Self.ruleLimit
    // Compile all rules independently; a broken entry cannot suppress later ones.
    for pattern in patterns.prefix(Self.ruleLimit) {
      guard !pattern.isEmpty, pattern.utf16.count <= Self.patternLimit,
            let expression = try? NSRegularExpression(pattern: pattern) else {
        invalid = true
        continue
      }
      expressions.append(expression)
    }
  }

  func rejects(_ items: [NSPasteboardItem]) -> Bool {
    refresh()
    guard !invalid else { return true }
    guard !expressions.isEmpty else { return false }

    var remainingText = Self.textLimit
    var remainingData = Self.dataLimit
    var matchingBudget: Duration = .milliseconds(20)
    for item in items {
      // Inspect every representation, even if it is disabled for storage or a
      // different plain-text representation happens to be present.
      for type in [NSPasteboard.PasteboardType.string, .rtf, .html] where item.types.contains(type) {
        guard let data = item.data(forType: type), data.count <= remainingData else { return true }
        remainingData -= data.count
        guard let text = Self.text(from: data, type: type, item: item),
              text.utf16.count <= remainingText else { return true }
        remainingText -= text.utf16.count
        for expression in expressions {
          let started = ContinuousClock.now
          let deadline = started.advanced(by: matchingBudget)
          if started >= deadline { return true }
          var reject = false
          expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                                      range: NSRange(location: 0, length: text.utf16.count)) { result, flags, stop in
            if result != nil || flags.contains(.internalError) || ContinuousClock.now >= deadline {
              reject = true
              stop.pointee = true
            }
          }
          matchingBudget -= started.duration(to: .now)
          if reject || matchingBudget <= .zero { return true }
        }
      }
    }
    return false
  }

  private static func text(from data: Data, type: NSPasteboard.PasteboardType,
                           item: NSPasteboardItem) -> String? {
    switch type {
    case .string:
      return item.string(forType: .string)
    case .rtf:
      return NSAttributedString(rtf: data, documentAttributes: nil)?.string
    case .html:
      return ClipboardHTMLText.extract(data)
    default:
      return nil
    }
  }
}

// Accept a conservative UTF-8 XHTML fragment. XMLParser never renders HTML or
// loads URLs. Ordinary HTML that isn't well-formed XML is rejected, not guessed
// at by stripping tags (which could hide text or entities from the rules).
final class ClipboardHTMLText: NSObject, XMLParserDelegate {
  private var text = ""

  static func extract(_ data: Data) -> String? {
    guard let html = String(data: data, encoding: .utf8),
          !html.localizedCaseInsensitiveContains("<!DOCTYPE"),
          !html.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
    let parser = XMLParser(data: Data(("<clipboard>" + html + "</clipboard>").utf8))
    let delegate = ClipboardHTMLText()
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    guard parser.parse() else { return nil }
    return delegate.text
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
    if text.utf16.count > IgnoreRules.textLimit { parser.abortParsing() }
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    guard let string = String(data: CDATABlock, encoding: .utf8) else {
      parser.abortParsing()
      return
    }
    self.parser(parser, foundCharacters: string)
  }
}
