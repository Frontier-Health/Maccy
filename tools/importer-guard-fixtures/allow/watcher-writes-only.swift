// guard-fixture-path: Maccy/Clipboard.swift
// A comment about pasteboard.string(forType: .source) is fine.
func copy() {
  pasteboard.setString("", forType: .fromMaccy)
  pasteboard.setData(Data(), forType: .string)
  let note = "item.data(forType: .string)"
}
