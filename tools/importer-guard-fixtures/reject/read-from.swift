import AppKit

func importInto(_ text: NSMutableAttributedString, _ bytes: Data) throws {
  try text
    .read(from: bytes, options: [:], documentAttributes: nil)
}
