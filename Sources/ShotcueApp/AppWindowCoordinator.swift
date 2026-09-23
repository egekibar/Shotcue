import AppKit

enum AppWindowID {
    /// SwiftUI sets `NSWindow.identifier` to the scene id, so AppKit can find this window by string
    /// (verified 2026-09-22: `NSApp.windows` → `library/Kütüphane/AppKitWindow`).
    static let library = "library"
}

enum LaunchFlags {
    /// `scripts/shot.sh` launches the app with this flag so screenshots have something to capture.
    static var shouldOpenLibrary: Bool {
        ProcessInfo.processInfo.environment["SHOTCUE_OPEN_LIBRARY"] == "1"
    }
}

/// Bridges SwiftUI's `openWindow` / `openSettings` actions into AppKit scope.
///
/// The actions only exist inside a `View`, but the delegate, the hotkey handler and notification
/// actions all need them. `MenuBarExtra`'s *label* view is instantiated while the app launches —
/// verified: its `onAppear` runs before `applicationDidFinishLaunching` — so connecting there makes
/// the actions available for the whole session even if the menu is never opened.
final class WindowOpener {
    private var openWindowAction: ((String) -> Void)?
    private var openSettingsAction: (() -> Void)?

    func connect(openWindow: @escaping (String) -> Void, openSettings: @escaping () -> Void) {
        self.openWindowAction = openWindow
        self.openSettingsAction = openSettings
    }

    func openLibrary() {
        guard let openWindowAction else {
            AppLog.app.error("openWindow not connected yet; library request dropped")
            return
        }
        openWindowAction(AppWindowID.library)
        // The scene root flips the policy to .regular on appear; raise the window if it already existed.
        if let window = Self.libraryWindow() {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// A menu-bar-only app is not active when this runs from the menu or a notification, so the
    /// Settings window would open behind the frontmost app without the explicit activation.
    func openSettingsWindow() {
        guard let openSettingsAction else {
            AppLog.app.error("openSettings not connected yet; settings request dropped")
            return
        }
        NSApp.activate()
        openSettingsAction()
    }

    static func libraryWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == AppWindowID.library }
    }
}

/// Dock visibility (spec §6.6, research 01 §8): menu-bar only by default, `.regular` while a real
/// window is on screen. Reference-counted because the library window and onboarding can overlap.
/// `.regular` requires an explicit `NSApp.activate()` afterwards, otherwise the window opens behind.
final class ActivationPolicyController {
    private var reasons: Set<String> = []

    static let libraryReason = "library"
    static let onboardingReason = "onboarding"

    /// Called once from `applicationDidFinishLaunching`: make the policy match reality in case a window
    /// already exists. Everything after that is driven by the scene root's `onAppear`/`onDisappear`,
    /// which was measured to fire reliably for `Window(_:id:)` (including on app termination), so no
    /// `NSWindow.willCloseNotification` backstop is needed — and an observer would have to smuggle the
    /// non-Sendable `Notification` into the main actor, which Swift 6 rejects.
    func install() {
        if WindowOpener.libraryWindow()?.isVisible == true {
            begin(Self.libraryReason)
        } else {
            apply()
        }
    }

    func begin(_ reason: String) {
        reasons.insert(reason)
        apply()
    }

    func end(_ reason: String) {
        reasons.remove(reason)
        apply()
    }

    private func apply() {
        if reasons.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }
}
