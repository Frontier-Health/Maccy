import AppKit

func title(_ bytes: Data) -> String? {
  NSAttributedString(rtf: bytes, documentAttributes: nil)?.string
}
