import AppKit

func importHTML(_ bytes: Data) -> NSMutableAttributedString? {
  NSMutableAttributedString(html: bytes, documentAttributes: nil)
}
