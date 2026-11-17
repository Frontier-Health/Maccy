import AppKit

// No document type: AppKit sniffs the bytes and may choose HTML.
func importCopied(_ bytes: Data) -> String? {
  let text = try? NSAttributedString(
    data: bytes,
    options: [:],
    documentAttributes: nil)
  return text?.string
}
