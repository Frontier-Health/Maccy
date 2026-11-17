import AppKit
import Defaults
import Logging

// Read the effective preferences on every event, rather than relying on delivery
// of a notification from another process or a configuration profile.
final class IgnoreRules {
  static let textLimit = 104_000 // Unique matching text, in UTF-16 code units across the event.
  static let dataLimit = 8 * 1_024 * 1_024 // Bytes, summed across the event's text representations.
  static let rtfDataLimit = 512 * 1_024 // Aggregate RTF bytes excluding binary destinations.
  static let rawRTFDataLimit = 16 * 1_024 * 1_024 // Aggregate raw RTF, including pictures.
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
    let raw = preferences.object(forKey: Defaults.Keys.ignoreRegexp.name)
    guard raw == nil || raw is [String] else { return false }
    var patterns = raw as? [String] ?? []
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

  enum ConfigurationIssue: Equatable {
    case unreadable
    case tooManyRules
    case invalidRule
  }

  static func configurationIssue(in preferences: UserDefaults = Defaults.Keys.ignoreRegexp.suite) -> ConfigurationIssue? {
    guard let raw = preferences.object(forKey: Defaults.Keys.ignoreRegexp.name) else { return nil }
    guard let patterns = raw as? [String] else { return .unreadable }
    if patterns.count > ruleLimit { return .tooManyRules }
    return patterns.allSatisfy(isValid) ? nil : .invalidRule
  }

  @discardableResult
  static func reset(in preferences: UserDefaults = Defaults.Keys.ignoreRegexp.suite) -> Bool {
    guard !isManaged(in: preferences), configurationIssue(in: preferences) == .unreadable else { return false }
    preferences.set([String](), forKey: Defaults.Keys.ignoreRegexp.name)
    return true
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
    case rtfDataLimit = "over RTF data limit"
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
    var representations: [(NSPasteboard.PasteboardType, Data, NSPasteboardItem, Int)] = []
    var remainingData = Self.dataLimit
    var remainingRawRTF = Self.rawRTFDataLimit
    for item in items {
      for type in [NSPasteboard.PasteboardType.string, .rtf, .html] where item.types.contains(type) {
        // An advertised but undelivered representation cannot be verified.
        guard let data = item.data(forType: type) else { return .undecodable }
        let charged: Int
        if type == .rtf {
          guard data.count <= remainingRawRTF else { return .rtfDataLimit }
          remainingRawRTF -= data.count
          charged = Self.rtfTextDataSize(data)
        } else {
          charged = data.count
        }
        guard charged <= remainingData else { return .dataLimit }
        remainingData -= charged
        representations.append((type, data, item, charged))
      }
    }

    var remainingRTF = Self.rtfDataLimit
    var candidates: [String: (text: String, plain: Bool)] = [:]
    var order: [String] = []
    var deferredRejection: Rejection?
    var remainingText = Self.textLimit
    var matchingBudget: Duration = .milliseconds(100)
    func matchCandidates() -> Rejection? {
      for key in order {
        guard let candidate = candidates[key] else { continue }
        let text = candidate.text
        let length = text.utf16.count
        guard length <= remainingText else { return .textLimit }
        remainingText -= length
        for expression in expressions {
          let started = ContinuousClock.now
          let deadline = started.advanced(by: matchingBudget)
          if started >= deadline { return .timeBudget }
          var rejection: Rejection?
          expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                                      range: NSRange(location: 0, length: length)) { result, flags, stop in
            if ContinuousClock.now >= deadline {
              rejection = .timeBudget
            } else if result != nil {
              rejection = .matchedRule
            } else if flags.contains(.internalError) {
              rejection = .undecodable
            }
            if rejection != nil { stop.pointee = true }
          }
          matchingBudget -= started.duration(to: .now)
          if let rejection { return rejection }
          if matchingBudget <= .zero { return .timeBudget }
        }
      }
      return nil
    }
    var plainKeys = Set<String>()
    var matchedPlain = false
    for (type, data, item, charged) in representations.sorted(by: { entryPriority($0.0) < entryPriority($1.0) }) {
      if type != .string && !matchedPlain {
        if let rejection = matchCandidates() { return rejection }
        plainKeys = Set(order)
        candidates = [:]
        order = []
        matchedPlain = true
      }
      let texts: [String]
      switch type {
      case .string:
        guard let text = item.string(forType: .string) else { return .undecodable }
        texts = [text]
      case .rtf:
        guard charged <= remainingRTF else { deferredRejection = .rtfDataLimit; continue }
        remainingRTF -= charged
        guard let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string else {
          deferredRejection = .undecodable
          continue
        }
        texts = [text]
      case .html:
        guard let source = ClipboardHTMLText.decode(data) else { return .undecodable }
        let extracted = ClipboardHTMLText.inspect(source)
        texts = [extracted.visible, extracted.hidden]
      default:
        continue
      }
      for original in texts {
        let key = Self.normalizedTextKey(original)
        if type != .string && (key.isEmpty || plainKeys.contains(key)) { continue }
        if let existing = candidates[key] {
          if !existing.plain && (type == .string || original.utf16.count > existing.text.utf16.count) {
            candidates[key] = (original, type == .string)
          }
        } else {
          candidates[key] = (original, type == .string)
          order.append(key)
        }
      }
    }
    if let rejection = matchCandidates() { return rejection }
    return deferredRejection
  }

  private func entryPriority(_ type: NSPasteboard.PasteboardType) -> Int {
    type == .string ? 0 : (type == .html ? 1 : 2)
  }

  static func normalizedTextKey(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  // Count formatting/text bytes, not opaque destinations. Any malformed structure
  // falls back to the full size, so a broken group cannot buy extra capacity.
  static func rtfTextDataSize(_ data: Data) -> Int {
    let bytes = Array(data)
    guard bytes.first == 123, bytes.last == 125 else { return data.count }
    let destinations: Set<String> = ["pict", "themedata", "datastore", "colorschememapping", "objdata", "blipuid"]
    var stack: [(start: Int, excluded: Bool)] = []
    var excluded = 0
    var index = 0
    func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 123 {
        let start = index
        index += 1
        var cursor = index
        while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
        if cursor + 1 < bytes.count && bytes[cursor] == 92 && bytes[cursor + 1] == 42 {
          cursor += 2
          while cursor < bytes.count && bytes[cursor] == 32 { cursor += 1 }
        }
        var destination = ""
        if cursor < bytes.count && bytes[cursor] == 92 {
          cursor += 1
          let nameStart = cursor
          while cursor < bytes.count && letter(bytes[cursor]) { cursor += 1 }
          destination = String(decoding: bytes[nameStart..<cursor], as: UTF8.self)
        }
        stack.append((start, (stack.last?.excluded ?? false) || destinations.contains(destination)))
      } else if byte == 125 {
        guard let group = stack.popLast() else { return data.count }
        if group.excluded && !(stack.last?.excluded ?? false) { excluded += index + 1 - group.start }
        index += 1
      } else if byte == 92 {
        let controlStart = index
        index += 1
        guard index < bytes.count else { return data.count }
        if !letter(bytes[index]) {
          index += 1 // Escaped braces/backslashes are never group boundaries.
          continue
        }
        let nameStart = index
        while index < bytes.count && letter(bytes[index]) { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
        let numberStart = index
        if index < bytes.count && bytes[index] == 45 { index += 1 }
        while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        let number = String(decoding: bytes[numberStart..<index], as: UTF8.self)
        if index < bytes.count && bytes[index] == 32 { index += 1 }
        if name == "bin" {
          guard let count = Int(number), count >= 0, count <= bytes.count - index else { return data.count }
          if !(stack.last?.excluded ?? false) { excluded += index + count - controlStart }
          index += count // Raw bytes may include braces and backslashes.
        }
      } else {
        index += 1
      }
    }
    return stack.isEmpty ? data.count - excluded : data.count
  }
}

// A forward-only scanner, not an HTML renderer. No resource loading, DOM, or
// external entity expansion. Hidden text excludes CSS and data URI payloads.
enum ClipboardHTMLText {
  static func decode(_ data: Data) -> String? {
    let prefix = Array(data.prefix(128))
    if prefix.starts(with: [0xFF, 0xFE]) {
      return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    }
    if prefix.starts(with: [0xFE, 0xFF]) {
      return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    }
    let utf8 = prefix.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    if let text = String(data: utf8, encoding: .utf8), !text.contains("\0") { return text }
    if utf8.contains(0) {
      // NUL-terminated UTF-8 and UTF-16 can both decode without errors. Require
      // actual ASCII markup in UTF-16 candidates rather than accepting CJK noise.
      var terminated = utf8
      while terminated.last == 0 { terminated = terminated.dropLast() }
      var candidates = [String.Encoding.utf16LittleEndian, .utf16BigEndian]
        .compactMap { String(data: data, encoding: $0) }
        .filter { !$0.contains("\0") && $0.range(of: "<[A-Za-z/!][^<>]*>", options: .regularExpression) != nil }
      if let text = String(data: Data(terminated.filter { $0 != 0 }), encoding: .utf8), !text.isEmpty {
        candidates.append(text)
      }
      return candidates.max { asciiCount($0) < asciiCount($1) }
    }
    // Repair isolated bad UTF-8 sequences, but don't treat wholly undecodable
    // bytes as an empty, safe document.
    let repaired = String(decoding: utf8, as: UTF8.self)
    return repaired.unicodeScalars.contains { $0.value != 0xFFFD } ? repaired : nil
  }

  private static func asciiCount(_ text: String) -> Int {
    text.unicodeScalars.filter { (9...13).contains($0.value) || (32...126).contains($0.value) }.count
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

  private static let mediaTags: Set<String> = [
    "img", "source", "video", "audio", "picture", "track", "image", "v:imagedata"
  ]
  private static let knownTags = blocks.union(mediaTags).union([
    "html", "head", "body", "title", "base", "link", "meta", "style", "script", "noscript",
    "a", "abbr", "b", "bdi", "bdo", "cite", "code", "data", "del", "dfn", "em", "i", "ins",
    "kbd", "mark", "q", "rp", "rt", "ruby", "s", "samp", "small", "span", "strong", "sub",
    "sup", "time", "u", "var", "wbr", "font", "center", "input", "button", "label", "select",
    "option", "textarea", "svg", "path", "g", "use", "defs", "text", "canvas", "iframe",
    "embed", "object", "param", "o:p", "xml"
  ])

  struct Contents {
    let visible: String
    let hidden: String
    let hasContent: Bool
  }

  static func hasContent(_ data: Data) -> Bool {
    decode(data).map { inspect($0).hasContent } ?? false
  }

  static func extract(_ source: String) -> String { inspect(source).visible }

  static func inspect(_ source: String) -> Contents {
    let bytes = Array(source.utf8)
    var visible: [UInt8] = []
    var hidden: [UInt8] = []
    var media = false
    var index = 0
    func appendHidden(_ range: Range<Int>) {
      let value = decodeEntities(String(decoding: bytes[range], as: UTF8.self))
      let sanitized = value.replacingOccurrences(
        of: #"(?i)(?<![A-Za-z0-9+.\-])(data:(?!text/)(?:(?:image/|font/|audio/|video/|application/octet-stream)[^,\s\"'()<>]*|[^,\s\"'()<>]*;base64),)[^\s\"'()<>]*"#,
        with: "$1", options: .regularExpression)
      if !hidden.isEmpty { hidden.append(10) }
      hidden.append(contentsOf: sanitized.utf8)
    }
    while index < bytes.count {
      guard bytes[index] == 60 else {
        visible.append(bytes[index])
        index += 1
        continue
      }
      if bytes[index...].starts(with: [60, 33, 45, 45]) {
        let start = index + 4
        index = start
        while index < bytes.count && !bytes[index...].starts(with: [45, 45, 62]) { index += 1 }
        appendHidden(start..<index)
        index = min(index + 3, bytes.count)
        continue
      }
      if bytes[index...].starts(with: Array("<![CDATA[".utf8)) {
        let start = index + 9
        index = start
        while index < bytes.count && !bytes[index...].starts(with: Array("]]>".utf8)) { index += 1 }
        appendHidden(start..<index)
        index = min(index + 3, bytes.count)
        continue
      }
      if index + 1 < bytes.count && bytes[index + 1] == 33 {
        let start = index + 2
        index = start
        while index < bytes.count && bytes[index] != 62 { index += 1 }
        appendHidden(start..<index)
        index = min(index + 1, bytes.count)
        continue
      }
      var cursor = index + 1
      let closing = cursor < bytes.count && bytes[cursor] == 47
      if closing { cursor += 1 }
      let nameStart = cursor
      while cursor < bytes.count && isName(bytes[cursor]) { cursor += 1 }
      let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
      if nameStart == cursor && (cursor == bytes.count || bytes[cursor] != 33) {
        visible.append(60)
        index += 1
        continue
      }
      if !knownTags.contains(name) { appendHidden(nameStart..<cursor) }
      if !closing && ["img", "svg", "video", "picture", "object", "canvas"].contains(name) { media = true }
      var attributes: [(name: String, value: Range<Int>)] = []
      // Parse attributes; quotes are special only at the start of a value after '='.
      while cursor < bytes.count && bytes[cursor] != 62 && bytes[cursor] != 60 {
        if isSpace(bytes[cursor]) || bytes[cursor] == 47 { cursor += 1; continue }
        let attributeStart = cursor
        while cursor < bytes.count && !isSpace(bytes[cursor]) && ![61, 62, 60].contains(bytes[cursor]) { cursor += 1 }
        let attribute = String(decoding: bytes[attributeStart..<cursor], as: UTF8.self).lowercased()
        appendHidden(attributeStart..<cursor)
        while cursor < bytes.count && isSpace(bytes[cursor]) { cursor += 1 }
        if cursor < bytes.count && bytes[cursor] == 61 {
          cursor += 1
          while cursor < bytes.count && isSpace(bytes[cursor]) { cursor += 1 }
          let quote: UInt8? = cursor < bytes.count && [34, 39].contains(bytes[cursor]) ? bytes[cursor] : nil
          if quote != nil { cursor += 1 }
          let valueStart = cursor
          while cursor < bytes.count {
            if let quote {
              if bytes[cursor] == quote { break }
            } else if isSpace(bytes[cursor]) || bytes[cursor] == 62 || bytes[cursor] == 60 { break }
            cursor += 1
          }
          attributes.append((attribute, valueStart..<cursor))
          if quote != nil && cursor < bytes.count { cursor += 1 }
        }
        if cursor == attributeStart { cursor += 1 }
      }
      let imageInput = name == "input" && attributes.contains {
        $0.name == "type" && decodeEntities(String(decoding: bytes[$0.value], as: UTF8.self))
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
      }
      let mediaElement = mediaTags.contains(name) || imageInput
      for attribute in attributes {
        let asset = mediaElement && ["src", "srcset", "poster"].contains(attribute.name) ||
          name == "image" && ["href", "xlink:href"].contains(attribute.name)
        if attribute.name != "style" && !asset { appendHidden(attribute.value) }
      }
      if blocks.contains(name), visible.last != 32 { visible.append(32) }
      index = cursor < bytes.count && bytes[cursor] == 62 ? cursor + 1 : cursor
      if !closing && (name == "script" || name == "style") {
        let contentStart = index
        // Raw-text elements recognize only their own closing tag; quotes/comments
        // and '<' within the body cannot hide the rest of an Office document.
        let terminator = Array(("</" + name).utf8)
        while index < bytes.count {
          if bytes[index] == 60 && index + terminator.count <= bytes.count {
            let candidate = bytes[index..<(index + terminator.count)].map { (65...90).contains($0) ? $0 + 32 : $0 }
            let end = index + terminator.count
            if candidate == terminator && (end == bytes.count || isSpace(bytes[end]) || bytes[end] == 62) { break }
          }
          index += 1
        }
        if name == "script" || index == bytes.count { appendHidden(contentStart..<index) }
      }
    }
    let text = decodeEntities(String(decoding: visible, as: UTF8.self))
    return Contents(visible: text, hidden: String(decoding: hidden, as: UTF8.self),
                    hasContent: media || !text.isEmpty)
  }

  private static func isSpace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }

  private static func decodeEntities(_ source: String) -> String {
    let bytes = Array(source.utf8)
    var output: [UInt8] = []
    var index = 0
    while index < bytes.count {
      if bytes[index] == 38 {
        var end = index + 1
        while end < bytes.count && end - index <= 32 && isEntityByte(bytes[end]) { end += 1 }
        if end < bytes.count && bytes[end] == 59, let decoded = entity(bytes[(index + 1)..<end]) {
          output.append(contentsOf: decoded.utf8)
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
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 58 || byte == 45 || byte == 95
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
