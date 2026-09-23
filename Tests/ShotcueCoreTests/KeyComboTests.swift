import Testing

@testable import ShotcueCore

@Suite("KeyCombo")
struct KeyComboTests {
    @Test func carbonMasksMatchHIToolbox() {
        #expect(KeyCombo.commandKey == 0x0100 && KeyCombo.shiftKey == 0x0200)
        #expect(KeyCombo.optionKey == 0x0800 && KeyCombo.controlKey == 0x1000)
    }
    @Test func defaultIsControlShiftTwo() {
        let d = KeyCombo.defaultCombo
        #expect(d.keyCode == 0x13)  // kVK_ANSI_2
        #expect(d.modifiers == KeyCombo.controlKey | KeyCombo.shiftKey)
        #expect(d.label == "⌃⇧2")
    }
    @Test func presetsAreUniqueAndLabeled() {
        #expect(KeyCombo.presets.count == 6)
        #expect(Set(KeyCombo.presets).count == 6)
        #expect(KeyCombo.presets.map(\.label) == ["⌃⇧2", "⌃⇧3", "⌃⇧4", "⌘⇧2", "⌥Space", "⌃⌥Space"])
    }
}
