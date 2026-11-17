import AppKit

// The only places Maccy turns copied rich text into plain text.
//
// - HTML is never given to `NSAttributedString(html:)` or any other WebKit-backed
//   importer: that importer runs WebKit, can fetch remote images and style
//   sheets, and is slow. `ClipboardHTMLText` (a forward-only scanner, no
//   rendering, no resource loading) extracts its visible text instead.
// - RTF goes to AppKit's RTF reader (`NSAttributedString(rtf:)`), which is not
//   WebKit and has no network loader. It is given at most the RTF the ignore
//   rules accept (`IgnoreRules.rawRTFDataLimit` raw bytes, of which at most
//   `IgnoreRules.rtfDataLimit` are text and formatting rather than pictures or
//   binary data), measured at about 36 ms for the text limit. Larger RTF is not
//   imported.
enum RichTextImport {
  #if DEBUG
  // How many RTF documents were handed to AppKit's reader, so tests can check
  // a path imports nothing. There is no HTML importer to count.
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
    return NSAttributedString(rtf: data, documentAttributes: nil)?.string
  }

  // The visible text of an HTML document, without rendering it or loading
  // anything it refers to. Nil if it can't be decoded.
  static func text(fromHTML data: Data) -> String? {
    ClipboardHTMLText.extract(data)
  }

  // The letters and digits of `text`, in order: what has to agree for the
  // plain and formatted versions of a copy to say the same thing. Whitespace,
  // punctuation and list bullets differ legitimately between the two.
  nonisolated static func comparableText(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
  }
}

// How a copy's formatted versions compare with the plain text Maccy shows.
nonisolated enum FormattedTextComparison: Equatable, Sendable {
  // No formatted version, or nothing shown as plain text to compare with.
  case notApplicable
  // Every formatted version holds the same letters and digits as the plain text.
  case same
  // A formatted version holds different text: a formatted paste can insert
  // something other than what is shown.
  case differs
  // A formatted version was too large or unreadable to check.
  case notChecked
}
