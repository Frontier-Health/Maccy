import AppKit
import Defaults
import Logging

// Read the effective preferences on every event, rather than relying on delivery
// of a notification from another process or a configuration profile.
final class IgnoreRules {
  static let textLimit = 128_000 // UTF-16 code units, summed across the event.
  static let dataLimit = 8 * 1_024 * 1_024 // Bytes, summed across the event's text representations.
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
    guard !isManaged(in: preferences), isValid(pattern) else { return false }
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

  static func isManaged(in preferences: UserDefaults = Defaults.Keys.ignoreRegexp.suite) -> Bool {
    preferences.objectIsForced(forKey: Defaults.Keys.ignoreRegexp.name)
  }

  @discardableResult
  static func remove(at index: Int,
                     in preferences: UserDefaults = Defaults.Keys.ignoreRegexp.suite) -> Bool {
    guard !isManaged(in: preferences),
          var patterns = preferences.object(forKey: Defaults.Keys.ignoreRegexp.name) as? [String],
          patterns.indices.contains(index) else { return false }
    patterns.remove(at: index)
    preferences.set(patterns, forKey: Defaults.Keys.ignoreRegexp.name)
    return true
  }

  enum Rejection: String {
    case matchedRule = "matched a rule"
    case invalidStoredRule = "invalid stored rule"
    case textLimit = "over text limit"
    case dataLimit = "over data limit"
    case undecodable
    case timeBudget = "time budget"
  }

  private(set) var lastRejection: Rejection?
  private let logger = Logger(label: "org.p0deje.Maccy")

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
    lastRejection = rejection(for: items)
    guard let lastRejection else { return false }
    logger.warning("Clipboard copy rejected: \(lastRejection.rawValue)")
    return true
  }

  private func rejection(for items: [NSPasteboardItem]) -> Rejection? {
    refresh()
    guard !invalid else { return .invalidStoredRule }
    guard !expressions.isEmpty else { return nil }

    // Preflight the entire event before any decoding, including later items.
    var representations: [(NSPasteboard.PasteboardType, Data, NSPasteboardItem)] = []
    var remainingData = Self.dataLimit
    for item in items {
      for type in [NSPasteboard.PasteboardType.string, .rtf, .html] where item.types.contains(type) {
        // An advertised but undelivered representation cannot be verified.
        guard let data = item.data(forType: type) else { return .undecodable }
        guard data.count <= remainingData else { return .dataLimit }
        remainingData -= data.count
        representations.append((type, data, item))
      }
    }

    var remainingText = Self.textLimit
    var matchingBudget: Duration = .milliseconds(100)
    for (type, data, item) in representations {
      let texts: [String]
      switch type {
      case .string:
        guard let text = item.string(forType: .string) else { return .undecodable }
        texts = [text]
      case .rtf:
        guard let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string else {
          return .undecodable
        }
        texts = [text]
      case .html:
        guard let source = ClipboardHTMLText.decode(data) else { return .undecodable }
        // Check source length before extraction, then count both matching inputs.
        guard source.utf16.count <= remainingText else { return .textLimit }
        texts = [source, ClipboardHTMLText.extract(source)]
      default:
        continue
      }
      for text in texts {
        let length = text.utf16.count
        guard length <= remainingText else { return .textLimit }
        remainingText -= length
        for expression in expressions {
          let started = ContinuousClock.now
          let deadline = started.advanced(by: matchingBudget)
          if started >= deadline { return .timeBudget }
          var rejection: Rejection?
          var progressCallbacks = 0
          expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                                      range: NSRange(location: 0, length: length)) { result, flags, stop in
            if result != nil {
              rejection = .matchedRule
            } else if flags.contains(.internalError) {
              rejection = .undecodable
            } else {
              progressCallbacks += 1
              // Amortize clock reads during frequent ICU progress callbacks.
              // Check every 64 callbacks and always on completion.
              if (progressCallbacks % 64 == 0 || flags.contains(.completed)) && ContinuousClock.now >= deadline {
                rejection = .timeBudget
              }
            }
            if rejection != nil { stop.pointee = true }
          }
          matchingBudget -= started.duration(to: .now)
          if let rejection { return rejection }
          if matchingBudget <= .zero { return .timeBudget }
        }
      }
    }
    return nil
  }
}

// A forward-only scanner, not an HTML renderer. No resource loading, DOM, or
// external entity expansion. Raw source is matched too, including hidden text.
enum ClipboardHTMLText {
  static func decode(_ data: Data) -> String? {
    let prefix = Array(data.prefix(128))
    if prefix.starts(with: [0xFF, 0xFE]) {
      return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    }
    if prefix.starts(with: [0xFE, 0xFF]) {
      return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    }
    // Clipboard HTML without a BOM commonly has alternating ASCII and NUL.
    let pairs = prefix.count / 2
    if pairs >= 2 {
      let evenZeros = stride(from: 0, to: pairs * 2, by: 2).filter { prefix[$0] == 0 }.count
      let oddZeros = stride(from: 1, to: pairs * 2, by: 2).filter { prefix[$0] == 0 }.count
      if oddZeros > pairs / 2 && evenZeros == 0 {
        return String(data: data, encoding: .utf16LittleEndian)
      }
      if evenZeros > pairs / 2 && oddZeros == 0 {
        return String(data: data, encoding: .utf16BigEndian)
      }
    }
    let utf8 = prefix.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    if let text = String(data: utf8, encoding: .utf8) { return text }
    // Repair isolated bad UTF-8 sequences, but don't treat wholly undecodable
    // bytes as an empty, safe document.
    let repaired = String(decoding: utf8, as: UTF8.self)
    return repaired.unicodeScalars.contains { $0.value != 0xFFFD } ? repaired : nil
  }

  static func extract(_ data: Data) -> String? {
    decode(data).map { extract($0) }
  }

  private static let blocks: Set<String> = [
    "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "fieldset",
    "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
    "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot",
    "th", "thead", "tr", "ul"
  ]

  static func extract(_ source: String) -> String {
    let bytes = Array(source.utf8)
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count)
    var index = 0
    var hidden: String?
    while index < bytes.count {
      if bytes[index] == 60 { // <
        if hidden == nil && bytes[index...].starts(with: [60, 33, 45, 45]) {
          index += 4
          while index < bytes.count && !bytes[index...].starts(with: [45, 45, 62]) { index += 1 }
          index = min(index + 3, bytes.count)
          continue
        }
        let start = index
        var cursor = index + 1
        let closing = cursor < bytes.count && bytes[cursor] == 47
        if closing { cursor += 1 }
        let nameStart = cursor
        while cursor < bytes.count && isName(bytes[cursor]) { cursor += 1 }
        let name = cursor - nameStart <= 32
          ? String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased() : ""
        // A literal '<' (e.g. "a < 3") isn't a tag.
        if nameStart == cursor && (cursor == bytes.count || bytes[cursor] != 33) {
          if hidden == nil { output.append(60) }
          index += 1
          continue
        }
        var quote: UInt8?
        while cursor < bytes.count {
          let byte = bytes[cursor]
          if let current = quote {
            if byte == current { quote = nil }
          } else if byte == 34 || byte == 39 {
            quote = byte
          } else if byte == 62 || byte == 60 {
            break
          }
          cursor += 1
        }
        if let hiddenName = hidden {
          if closing && name == hiddenName { hidden = nil }
        } else {
          if blocks.contains(name), output.last != 32 { output.append(32) }
          if !closing && (name == "script" || name == "style") { hidden = name }
        }
        index = cursor < bytes.count && bytes[cursor] == 62 ? cursor + 1 : cursor
        // Every iteration advances, including malformed tags at end of input.
        if index == start { index += 1 }
        continue
      }
      if hidden != nil {
        index += 1
        continue
      }
      if bytes[index] == 38 { // &; bound lookahead so malformed entities stay linear.
        var end = index + 1
        while end < bytes.count && end - index <= 32 && isEntityByte(bytes[end]) { end += 1 }
        if end < bytes.count && bytes[end] == 59,
           let entity = entity(bytes[(index + 1)..<end]) {
          output.append(contentsOf: entity.utf8)
          index = end + 1
          continue
        }
      }
      output.append(bytes[index])
      index += 1
    }
    return String(decoding: output, as: UTF8.self)
  }

  private static func isName(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 58 || byte == 45
  }

  private static func isEntityByte(_ byte: UInt8) -> Bool {
    isName(byte) || byte == 35
  }

  private static func entity(_ bytes: ArraySlice<UInt8>) -> String? {
    let name = String(decoding: bytes, as: UTF8.self)
    switch name {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos": return "'"
    case "nbsp": return "\u{00A0}"
    default:
      guard name.hasPrefix("#") else { return nil }
      let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
      guard let value = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
            value != 0, let scalar = UnicodeScalar(value) else { return nil }
      return String(scalar)
    }
  }
}
