import AppKit

func importWord(_ bytes: Data) -> NSAttributedString? {
  NSAttributedString(docFormat: bytes, documentAttributes: nil)
}
