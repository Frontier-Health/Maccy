import AppKit

func importFile(_ url: URL) throws -> NSAttributedString {
  try NSAttributedString(url: url, options: [:], documentAttributes: nil)
}
