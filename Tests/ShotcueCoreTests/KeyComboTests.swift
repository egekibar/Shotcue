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

@Suite("KeyCombo recording")
struct KeyComboRecordingTests {
    @Test func modifierMaskUsesCarbonBits() {
        #expect(KeyCombo.modifierMask(command: true, shift: true, option: false, control: false) == 0x0300)
        #expect(KeyCombo.modifierMask(command: false, shift: false, option: true, control: true) == 0x1800)
    }

    @Test func labelListsModifiersInMacOrderThenTheKey() {
        let mods = KeyCombo.modifierMask(command: true, shift: true, option: true, control: true)
        let combo = KeyCombo.recorded(keyCode: 0x00, modifiers: mods, characters: "a")
        #expect(combo?.label == "⌃⌥⇧⌘A")
        #expect(combo?.keyCode == 0x00)
        #expect(combo?.modifiers == mods)
    }

    @Test func recordedPresetKeysKeepThePresetLabels() {
        let ctrlShift = KeyCombo.controlKey | KeyCombo.shiftKey
        #expect(KeyCombo.recorded(keyCode: 0x13, modifiers: ctrlShift, characters: "2") == KeyCombo.defaultCombo)
        #expect(
            KeyCombo.recorded(keyCode: 0x31, modifiers: KeyCombo.optionKey, characters: " ")
                == KeyCombo.presets[4])
    }

    @Test func specialKeysAreNamedByKeyCode() {
        let cmd = KeyCombo.commandKey
        #expect(KeyCombo.recorded(keyCode: 0x24, modifiers: cmd, characters: "\r")?.label == "⌘↩")
        #expect(KeyCombo.recorded(keyCode: 0x7E, modifiers: cmd, characters: "")?.label == "⌘↑")
        #expect(KeyCombo.recorded(keyCode: 0x60, modifiers: cmd, characters: "")?.label == "⌘F5")
        #expect(KeyCombo.recorded(keyCode: 0x69, modifiers: 0, characters: "")?.label == "F13")
    }

    /// Turkish-Q letters come from the layout, so ⌘Ş reads as Ş and not as the US key under it.
    @Test func layoutCharactersAreUppercased() {
        let combo = KeyCombo.recorded(keyCode: 0x29, modifiers: KeyCombo.commandKey, characters: "ş")
        #expect(combo?.label == "⌘Ş")
    }

    /// A global hotkey without ⌘/⌃/⌥ would swallow ordinary typing everywhere; only F-keys may stand alone.
    @Test func rejectsCombosThatWouldEatTyping() {
        #expect(KeyCombo.recorded(keyCode: 0x00, modifiers: 0, characters: "a") == nil)
        #expect(KeyCombo.recorded(keyCode: 0x00, modifiers: KeyCombo.shiftKey, characters: "a") == nil)
        #expect(KeyCombo.recorded(keyCode: 0x31, modifiers: KeyCombo.shiftKey, characters: " ") == nil)
        #expect(KeyCombo.recorded(keyCode: 0x00, modifiers: KeyCombo.commandKey, characters: "") == nil)
    }

    @Test func validityMatchesRecording() {
        #expect(KeyCombo.defaultCombo.isValidHotKey)
        #expect(KeyCombo.presets.allSatisfy { $0.isValidHotKey })
        #expect(!KeyCombo(keyCode: 0x00, modifiers: KeyCombo.shiftKey, label: "⇧A").isValidHotKey)
        #expect(KeyCombo(keyCode: 0x69, modifiers: 0, label: "F13").isValidHotKey)
        #expect(!KeyCombo(keyCode: 0x00, modifiers: KeyCombo.commandKey, label: "").isValidHotKey)
    }
}
