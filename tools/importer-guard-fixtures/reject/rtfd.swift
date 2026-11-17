import AppKit

func importRTFD(_ bytes: Data) -> NSAttributedString? {
  NSAttributedString(rtfd: bytes, documentAttributes: nil)
}
