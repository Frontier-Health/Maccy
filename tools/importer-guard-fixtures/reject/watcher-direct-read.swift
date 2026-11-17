// guard-fixture-path: Maccy/Clipboard.swift
func check() {
  let isMaccySource = pasteboard
    .string(forType: .source) == "x"
}
