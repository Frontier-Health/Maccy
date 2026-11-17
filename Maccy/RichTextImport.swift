import AppKit

// The only places Maccy turns copied rich text into plain text.
//
// - HTML is never given to `NSAttributedString(html:)` or any other WebKit-backed
//   importer: that importer runs WebKit, can fetch remote images and style
//   sheets, and is slow. `ClipboardHTMLText` (a forward-only scanner, no
//   rendering, no resource loading) extracts its text instead. The scanner
//   doesn't evaluate CSS, so its text is not necessarily what a renderer shows.
// - RTF goes to AppKit's RTF reader with an explicit `.documentType: .rtf`, so
//   AppKit never sniffs the bytes and picks another importer (HTML bytes are
//   refused, not imported as HTML). That reader is not WebKit and has no network
//   loader. `text(fromRTF:)` gives it at most the RTF the ignore rules accept
//   (`IgnoreRules.rawRTFDataLimit` raw bytes, of which at most
//   `IgnoreRules.rtfDataLimit` are text and formatting rather than pictures or
//   binary data), measured at about 36 ms for the text limit. Larger RTF is not
//   imported. The ignore rules apply their own limits and call `rtfText(_:)`.
//
// tools/check-rich-text-importers.py fails CI if any other app file imports a
// document or decodes an image some other way.
enum RichTextImport {
  #if DEBUG
  // How many RTF documents were handed to AppKit's reader by
  // `text(fromRTF:)`, so tests can check a path imports nothing. There is no
  // HTML importer to count.
  nonisolated(unsafe) static var rtfImportsForTesting = 0
  #endif

  // Whether `data` is small enough to import (see above).
  static func rtfIsImportable(_ data: Data) -> Bool {
    data.count <= IgnoreRules.rawRTFDataLimit && IgnoreRules.rtfTextDataSize(data) <= IgnoreRules.rtfDataLimit
  }

  // The text of an RTF document, or nil if it is too large or unreadable.
  static func text(fromRTF data: Data) -> String? {
    guard rtfIsImportable(data) else {
      return nil
    }

    #if DEBUG
    rtfImportsForTesting += 1
    #endif
    return rtfText(data)
  }

  // The text of an RTF document and whether its formatting may make a
  // renderer show it differently (see `rtfFormattingMayRenderDifferently`),
  // from one import; nil if it is too large or unreadable.
  static func inspectRTF(_ data: Data) -> (text: String, mayRenderDifferently: Bool)? {
    guard rtfIsImportable(data) else {
      return nil
    }

    #if DEBUG
    rtfImportsForTesting += 1
    #endif
    guard let document = rtfDocument(data) else {
      return nil
    }
    return (document.string, rtfMayRenderDifferently(data) || rtfFormattingMayRenderDifferently(document))
  }

  // AppKit's RTF reader, told the data is RTF. Unbounded: callers bound the
  // input first.
  nonisolated static func rtfText(_ data: Data) -> String? {
    rtfDocument(data)?.string
  }

  private nonisolated static func rtfDocument(_ data: Data) -> NSAttributedString? {
    try? NSAttributedString(
      data: data,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    )
  }

  // An allow-list of formatting that cannot hide, recolour or reorder text:
  // fonts (bold and italic are font traits) of at least `minimumRTFPointSize`,
  // underline, links, paragraph styles with the natural writing direction
  // (alignment, spacing and tabs), and zero kerning. Anything else, among
  // them any explicit foreground or background colour, a smaller font, a
  // writing direction or bidi embedding, attachments, superscript or a
  // baseline offset, strikethrough, outlines, shadows and expansion, can make
  // what is rendered differ from the text, so it is reported. Whether a
  // colour contrasts with the background the paste lands on can't be known.
  nonisolated static let minimumRTFPointSize: CGFloat = 6

  nonisolated static func rtfFormattingMayRenderDifferently(_ document: NSAttributedString) -> Bool {
    var found = false
    document.enumerateAttributes(in: NSRange(location: 0, length: document.length)) { attributes, _, stop in
      for (key, value) in attributes where !isPlainRTFAttribute(key, value) {
        found = true
        stop.pointee = true
        return
      }
    }
    return found
  }

  private nonisolated static func isPlainRTFAttribute(_ key: NSAttributedString.Key, _ value: Any) -> Bool {
    switch key {
    case .font:
      return ((value as? NSFont)?.pointSize ?? 0) >= minimumRTFPointSize
    case .paragraphStyle:
      return (value as? NSParagraphStyle)?.baseWritingDirection == .natural
    case .underlineStyle, .underlineColor, .link, .ligature:
      return true
    case .kern:
      return (value as? NSNumber)?.doubleValue == 0
    default:
      return false
    }
  }

  // The text of an HTML document, without rendering it or loading anything
  // it refers to. Nil if it can't be decoded.
  static func text(fromHTML data: Data) -> String? {
    ClipboardHTMLText.extract(data)
  }

  // What has to be identical for the plain and formatted versions of a copy
  // to count as the same text: `text` in Unicode NFC, with every run of
  // whitespace (including non-breaking spaces and line breaks) made one space,
  // and none at either end. Punctuation, digits, case and invisible or
  // direction-changing characters all count.
  nonisolated static func comparableText(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
      if scalar.properties.isWhitespace {
        pendingSpace = !result.isEmpty
        continue
      }
      if pendingSpace {
        result.append(" ")
        pendingSpace = false
      }
      result.append(scalar)
    }
    return String(result)
  }

  // Whether `text` holds a character that is invisible or changes text
  // direction: zero-width and other format controls (Unicode category Cf,
  // which includes the bidi embeddings, overrides and isolates), and C0 and
  // C1 controls other than tab and line feed. A carriage return is an
  // ordinary line separator (Windows `\r\n`, old Mac `\r`). A zero-width
  // joiner between two emoji (as in 👩‍💻) is part of the emoji, not hidden.
  nonisolated static func containsInvisibleOrDirectionalScalars(_ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    for (index, scalar) in scalars.enumerated() where isInvisibleOrDirectional(scalar) {
      if scalar == "\u{200D}", index > 0, index + 1 < scalars.count,
         isEmojiComponent(scalars[index - 1]), isEmojiComponent(scalars[index + 1]) {
        continue
      }
      return true
    }
    return false
  }

  nonisolated static func isInvisibleOrDirectional(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .format:
      return true
    case .control:
      return scalar != "\t" && scalar != "\n" && scalar != "\r"
    default:
      return false
    }
  }

  // An emoji, or the variation selector or skin-tone modifier that ends one.
  private nonisolated static func isEmojiComponent(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value > 0x7F && (scalar.properties.isEmoji || scalar.properties.isEmojiModifier ||
                            scalar == "\u{FE0F}")
  }

  // Whether HTML may make what a renderer shows differ from the scanned
  // text. An allow-list: only a fragment made solely of plain structural and
  // inline elements without attributes (see `PlainHTML`) is not reported.
  // Scans tags only, without rendering.
  static func htmlMayRenderDifferently(_ data: Data) -> Bool {
    guard let source = ClipboardHTMLText.decode(data) else {
      return true
    }
    return !PlainHTML.isPlain(source)
  }

  // Formatting AppKit's reader drops but other renderers apply, found in the
  // RTF itself: hidden text (`\v`, which AppKit keeps as ordinary text) and
  // Word's highlight and character shading (`\highlightN`, `\chcbpatN` with
  // N > 0), which AppKit ignores.
  nonisolated static func rtfMayRenderDifferently(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 0x5C else {
        index += 1
        continue
      }
      index += 1
      guard index < bytes.count, isLetter(bytes[index]) else {
        // An escaped character (`\\`, `\{`, `\'hh`…) is not a control word.
        index += 1
        continue
      }
      let nameStart = index
      while index < bytes.count && isLetter(bytes[index]) { index += 1 }
      let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
      let numberStart = index
      if index < bytes.count && bytes[index] == 0x2D { index += 1 }
      while index < bytes.count && (0x30...0x39).contains(bytes[index]) { index += 1 }
      let number = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
      switch name {
      case "v":
        // `\v0` turns hidden text off but still says the document uses it.
        return true
      case "highlight", "chcbpat":
        if (number ?? 1) > 0 { return true }
      default:
        break
      }
    }
    return false
  }
}

// The allow-list for `RichTextImport.htmlMayRenderDifferently`. HTML is
// plain only if every tag is one of `elements` with no attributes other than
// those listed for it, every comment is a StartFragment/EndFragment marker,
// and the only declaration is `<!DOCTYPE html>`. Everything else (any other
// element such as `font`, `bdo`, `bdi`, `ruby`, `sup`, `sub`, `img`, `svg`,
// `script`, `style`, `title` or a form control; any other attribute such as
// `style`, `class`, `id`, `color`, `dir`, `hidden`, `size` or an event
// handler; CDATA, processing instructions, an unterminated tag) is not.
// Linear in the input; it stops at the first thing not allowed.
nonisolated enum PlainHTML {
  static let elements: [String: Set<String>] = {
    var elements: [String: Set<String>] = [:]
    for name in ["html", "head", "body", "p", "br", "div", "span", "b", "strong", "i", "em", "u", "s",
                 "code", "pre", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                 "table", "thead", "tbody", "tr"] {
      elements[name] = []
    }
    elements["meta"] = ["charset"]
    elements["a"] = ["href"]
    elements["td"] = ["colspan", "rowspan"]
    elements["th"] = ["colspan", "rowspan"]
    return elements
  }()
  static let comments: Set<String> = ["StartFragment", "EndFragment"]

  static func isPlain(_ source: String) -> Bool {
    let bytes = Array(source.utf8)
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 0x3C else {
        index += 1
        continue
      }
      if bytes[index...].starts(with: Array("<!--".utf8)) {
        let start = index + 4
        var end = start
        while end < bytes.count && !bytes[end...].starts(with: Array("-->".utf8)) { end += 1 }
        guard end < bytes.count else { return false }
        let comment = String(decoding: bytes[start..<end], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard comments.contains(comment) else { return false }
        index = end + 3
        continue
      }
      if index + 1 < bytes.count && (bytes[index + 1] == 0x21 || bytes[index + 1] == 0x3F) {
        // A declaration or processing instruction: only <!DOCTYPE html>.
        var end = index
        while end < bytes.count && bytes[end] != 0x3E { end += 1 }
        guard end < bytes.count else { return false }
        let declaration = String(decoding: bytes[index...end], as: UTF8.self).lowercased()
          .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard declaration == "<!doctype html>" else { return false }
        index = end + 1
        continue
      }
      var cursor = index + 1
      let closing = cursor < bytes.count && bytes[cursor] == 0x2F
      if closing { cursor += 1 }
      let nameStart = cursor
      while cursor < bytes.count && isNameByte(bytes[cursor]) { cursor += 1 }
      guard cursor > nameStart else {
        // A `<` that starts no tag is text, as the scanner reads it.
        index += 1
        continue
      }
      let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
      guard let allowedAttributes = elements[name] else { return false }
      var attributes = Set<String>()
      while cursor < bytes.count && bytes[cursor] != 0x3E {
        if isSpace(bytes[cursor]) || bytes[cursor] == 0x2F {
          cursor += 1
          continue
        }
        if bytes[cursor] == 0x3C { return false }
        let attributeStart = cursor
        while cursor < bytes.count && !isSpace(bytes[cursor]) && ![0x3D, 0x3E, 0x3C].contains(bytes[cursor]) {
          cursor += 1
        }
        attributes.insert(String(decoding: bytes[attributeStart..<cursor], as: UTF8.self).lowercased())
        while cursor < bytes.count && isSpace(bytes[cursor]) { cursor += 1 }
        if cursor < bytes.count && bytes[cursor] == 0x3D {
          cursor += 1
          while cursor < bytes.count && isSpace(bytes[cursor]) { cursor += 1 }
          let quote: UInt8? = cursor < bytes.count && [0x22, 0x27].contains(bytes[cursor]) ? bytes[cursor] : nil
          if quote != nil { cursor += 1 }
          while cursor < bytes.count {
            if let quote {
              if bytes[cursor] == quote { break }
            } else if isSpace(bytes[cursor]) || bytes[cursor] == 0x3E {
              break
            }
            cursor += 1
          }
          if quote != nil {
            guard cursor < bytes.count else { return false }
            cursor += 1
          }
        }
        if cursor == attributeStart { cursor += 1 }
      }
      // An unterminated tag.
      guard cursor < bytes.count else { return false }
      if closing ? !attributes.isEmpty : !attributes.isSubset(of: allowedAttributes) {
        return false
      }
      index = cursor + 1
    }
    return true
  }

  private static func isNameByte(_ byte: UInt8) -> Bool {
    (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) ||
      byte == 0x3A || byte == 0x2D || byte == 0x5F
  }

  private static func isSpace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
}

// How a copy's formatted versions compare with the plain text Maccy shows.
// No case says the two are the same: equal scanned text doesn't prove a
// renderer shows that text.
nonisolated enum FormattedTextComparison: Equatable, Sendable {
  // No formatted version, or nothing shown as plain text to compare with.
  case notApplicable
  // The text of every formatted version equals the plain text and none uses
  // anything that can change what is rendered. Nothing is shown.
  case noTextDifference
  // The texts are equal, but a formatted version (or the text) uses
  // something that can change what is rendered: a neutral note says the
  // formatted paste was not checked.
  case renderingNotChecked
  // A formatted version holds different text: a formatted paste can insert
  // something other than what is shown.
  case differs
  // A formatted version was too large or unreadable to check.
  case notChecked
}
