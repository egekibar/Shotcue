import AppKit

/// Bridges SwiftUI's `openWindow` / `openSettings` actions into AppKit scope (delegate, hotkey,
/// notification actions). Filled in Task 2.
final class WindowOpener {
    func connect(openWindow: @escaping (String) -> Void, openSettings: @escaping () -> Void) {
        _ = openWindow
        _ = openSettings
    }
    func openLibrary() {}
    func openSettingsWindow() {}
}

/// Owns `NSApp.setActivationPolicy` so the Dock icon appears only while a real window is on screen
/// (spec §6.6). Filled in Task 2.
final class ActivationPolicyController {
    func install() {}
    func begin(_ reason: String) {}
    func end(_ reason: String) {}
}
