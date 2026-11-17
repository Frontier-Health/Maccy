import AppKit

func png(_ data: Data) -> Data? {
  NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
}
