import AppKit

func importWrapper(_ wrapper: FileWrapper) -> NSAttributedString? {
  NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil)
}
