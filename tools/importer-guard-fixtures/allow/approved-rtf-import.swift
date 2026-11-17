// guard-fixture-path: Maccy/RichTextImport.swift
import AppKit

func rtfText(_ data: Data) -> String? {
  let document = try? NSAttributedString(
    data: data,
    options: [.documentType: NSAttributedString.DocumentType.rtf],
    documentAttributes: nil
  )
  return document?.string
}
