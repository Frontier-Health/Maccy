import AppKit

func describe(_ data: Data) -> String { "size: \(NSImage(data: data)?.size ?? .zero)" }
