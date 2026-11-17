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

  // AppKit's RTF reader, told the data is RTF. Unbounded: callers bound the
  // input first.
  nonisolated static func rtfText(_ data: Data) -> String? {
    let document = try? NSAttributedString(
      data: data,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    )
    return document?.string
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
  // C1 controls other than tab and line feed. A zero-width joiner between two
  // emoji (as in 👩‍💻) is part of the emoji, not hidden.
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
      return scalar != "\t" && scalar != "\n"
    default:
      return false
    }
  }

  // An emoji, or the variation selector or skin-tone modifier that ends one.
  private nonisolated static func isEmojiComponent(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value > 0x7F && (scalar.properties.isEmoji || scalar.properties.isEmojiModifier ||
                            scalar == "\u{FE0F}")
  }

  // Whether HTML uses anything that can make what a renderer shows differ
  // from the scanned text: a `style` attribute or `<style>` block, a `class`
  // or `id` together with a style sheet, the `hidden` attribute, `<script>`,
  // form controls, an `<img>` with a text alternative, or `<svg>`. Plain
  // structural and inline markup is not. Scans tags only, without rendering.
  static func htmlMayRenderDifferently(_ data: Data) -> Bool {
    guard let source = ClipboardHTMLText.decode(data) else {
      return true
    }
    return HTMLRenderingFeatures.scan(source)
  }

  // Whether RTF marks text hidden (`\v`): AppKit's reader may keep text a
  // renderer doesn't show.
  nonisolated static func rtfMayRenderDifferently(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    var index = 0
    while index + 1 < bytes.count {
      // `\v` not followed by a letter (`\viewkind` is another word); `\v0`
      // turns hidden text off but still says the document uses it.
      if bytes[index] == 0x5C, bytes[index + 1] == 0x76,
         index == 0 || bytes[index - 1] != 0x5C {
        let next = index + 2 < bytes.count ? bytes[index + 2] : 0x20
        let isLetter = (0x41...0x5A).contains(next) || (0x61...0x7A).contains(next)
        if !isLetter {
          return true
        }
      }
      index += 1
    }
    return false
  }
}

// A tag scanner for `RichTextImport.htmlMayRenderDifferently`. Linear in the
// input; it stops at the first feature found.
private nonisolated enum HTMLRenderingFeatures {
  private static let formControls: Set<String> = [
    "input", "button", "select", "option", "textarea", "form", "label", "datalist", "output"
  ]
  private static let textAlternatives: Set<String> = ["alt", "title", "aria-label"]

  static func scan(_ source: String) -> Bool {
    let bytes = Array(source.utf8)
    var index = 0
    var hasStyleSheet = false
    var usesClassOrID = false
    while index < bytes.count {
      guard bytes[index] == 0x3C else {
        index += 1
        continue
      }
      // Comments and declarations hide nothing a renderer shows.
      if bytes[index...].starts(with: Array("<!--".utf8)) {
        index += 4
        while index < bytes.count && !bytes[index...].starts(with: Array("-->".utf8)) { index += 1 }
        index += 3
        continue
      }
      var cursor = index + 1
      if cursor < bytes.count && bytes[cursor] == 0x2F {
        cursor += 1
      }
      let nameStart = cursor
      while cursor < bytes.count && isNameByte(bytes[cursor]) { cursor += 1 }
      guard cursor > nameStart else {
        index += 1
        continue
      }
      let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
      var attributes: [String: String] = [:]
      while cursor < bytes.count && bytes[cursor] != 0x3E {
        if isSpace(bytes[cursor]) || bytes[cursor] == 0x2F {
          cursor += 1
          continue
        }
        let attributeStart = cursor
        while cursor < bytes.count && !isSpace(bytes[cursor]) && ![0x3D, 0x3E].contains(bytes[cursor]) {
          cursor += 1
        }
        let attribute = String(decoding: bytes[attributeStart..<cursor], as: UTF8.self).lowercased()
        var value = ""
        while cursor < bytes.count && isSpace(bytes[cursor]) { cursor += 1 }
        if cursor < bytes.count && bytes[cursor] == 0x3D {
          cursor += 1
          while cursor < bytes.count && isSpace(bytes[cursor]) { cursor += 1 }
          let quote: UInt8? = cursor < bytes.count && [0x22, 0x27].contains(bytes[cursor]) ? bytes[cursor] : nil
          if quote != nil { cursor += 1 }
          let valueStart = cursor
          while cursor < bytes.count {
            if let quote {
              if bytes[cursor] == quote { break }
            } else if isSpace(bytes[cursor]) || bytes[cursor] == 0x3E {
              break
            }
            cursor += 1
          }
          value = String(decoding: bytes[valueStart..<cursor], as: UTF8.self).lowercased()
          if quote != nil && cursor < bytes.count { cursor += 1 }
        }
        if !attribute.isEmpty {
          attributes[attribute] = value
        }
        if cursor == attributeStart { cursor += 1 }
      }
      index = cursor + 1

      if ["style", "script", "svg"].contains(name) || formControls.contains(name) {
        return true
      }
      if attributes["style"] != nil || attributes["hidden"] != nil {
        return true
      }
      if name == "img" && !textAlternatives.isDisjoint(with: attributes.keys) {
        return true
      }
      if name == "link" && attributes["rel"]?.split(separator: " ").contains("stylesheet") == true {
        hasStyleSheet = true
      }
      if attributes["class"] != nil || attributes["id"] != nil {
        usesClassOrID = true
      }
      if hasStyleSheet && usesClassOrID {
        return true
      }
    }
    return false
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
