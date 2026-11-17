// guard-fixture-path: Maccy/RichTextImport.swift
import AppKit

func rtfText(_ data: Data) -> String? {
  (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html],
                           documentAttributes: nil))?.string
}
