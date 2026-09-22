/// Global hotkey definition using Carbon virtual key codes and modifier masks
/// (values copied from HIToolbox/Events.h so Core stays framework-free).
public struct KeyCombo: Hashable, Sendable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    public static let commandKey: UInt32 = 1 << 8
    public static let shiftKey: UInt32 = 1 << 9
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 12

    static let vkANSI2: UInt32 = 0x13
    static let vkANSI3: UInt32 = 0x14
    static let vkANSI4: UInt32 = 0x15
    static let vkSpace: UInt32 = 0x31

    public static let presets: [KeyCombo] = [
        KeyCombo(keyCode: vkANSI2, modifiers: controlKey | shiftKey, label: "⌃⇧2"),
        KeyCombo(keyCode: vkANSI3, modifiers: controlKey | shiftKey, label: "⌃⇧3"),
        KeyCombo(keyCode: vkANSI4, modifiers: controlKey | shiftKey, label: "⌃⇧4"),
        KeyCombo(keyCode: vkANSI2, modifiers: commandKey | shiftKey, label: "⌘⇧2"),
        KeyCombo(keyCode: vkSpace, modifiers: optionKey, label: "⌥Space"),
        KeyCombo(keyCode: vkSpace, modifiers: controlKey | optionKey, label: "⌃⌥Space"),
    ]

    public static let defaultCombo = presets[0]
}
