import AppKit

// NSAttributedString(html: data) and NSImage(data: data) are never called here.
/* Nor is NSAttributedString(
   data: bytes, options: [:], documentAttributes: nil) /* nested */ WKWebView */
let note = "Never use NSImage(data: x) or WKWebView"
let raw = #"NSAttributedString(rtfd: "quoted") \(not interpolated)"#
let block = """
  NSBitmapImageRep(data: bytes)
  """
let plain = NSAttributedString(string: "About Maccy")
