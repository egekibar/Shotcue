import AppKit
import ShotcueCore
import ShotcueUI
import SwiftUI

/// First-launch permission onboarding (spec §6.1, research 02 §4).
///
/// A plain `NSWindow` rather than a SwiftUI `Window` scene: onboarding is driven from AppKit scope
/// (launch, hotkey-without-permission) and must be able to appear before any scene has ever been
/// opened, then disappear without leaving a scene identifier behind.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let permissionsStore: PermissionsStore
    private let permissions: any PermissionService
    private let activationPolicy: ActivationPolicyController
    /// The relaunch's quit goes through the shutdown like any other (final review N1).
    private let termination: TerminationController
    private var window: NSWindow?
    /// Screen Recording state when the window opened, so we only relaunch on a real transition.
    private var screenRecordingWasGranted = false

    init(
        permissionsStore: PermissionsStore, permissions: any PermissionService,
        activationPolicy: ActivationPolicyController, termination: TerminationController
    ) {
        self.permissionsStore = permissionsStore
        self.permissions = permissions
        self.activationPolicy = activationPolicy
        self.termination = termination
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let service = permissions
        Task { @MainActor in
            screenRecordingWasGranted = await service.state(of: .screenRecording) == .granted
        }

        let hosting: NSHostingView<OnboardingView> = NSHostingView(
            rootView: OnboardingView(
                permissions: permissionsStore,
                onDone: { [weak self] in self?.finish() }))
        hosting.sizingOptions = [.intrinsicContentSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Shotcue Kurulumu"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces]
        // The red close button must end the Dock presence too, not only "Başla".
        window.delegate = self
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
        window.center()
        self.window = window

        // Onboarding is a real, focusable window, so the app becomes a regular app while it is up.
        activationPolicy.begin(ActivationPolicyController.onboardingReason)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        // `windowWillClose` does the bookkeeping for both paths (this one and the close button).
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        activationPolicy.end(ActivationPolicyController.onboardingReason)
    }

    /// "Başla": if Screen Recording flipped to granted while the window was open, the app has to be
    /// restarted before `screencapture` will actually work (research 02 §4.1: "İzin verildikten sonra
    /// uygulamayı yeniden başlatmak gerekir").
    private func finish() {
        let service = permissions
        let wasGranted = screenRecordingWasGranted
        Task { @MainActor in
            let isGranted = await service.state(of: .screenRecording) == .granted
            close()
            if isGranted && !wasGranted {
                relaunchAfterPermissionGrant()
            }
        }
    }

    /// Quits so that the installed bundle starts again. Only meaningful for a real `.app`; the bare SwiftPM
    /// binary has nothing to relaunch, so it just logs.
    ///
    /// This runs inside `finish()`'s main-actor Task, so it must not call `NSApp.terminate` itself: with runs in
    /// flight or unsaved work the shutdown could then never run and the app would hang (final review N1).
    /// `TerminationController` asks AppKit from the run loop, runs the shutdown (and its confirmation) first, and the
    /// relauncher starts only once the quit goes ahead (`startRelauncher()`).
    private func relaunchAfterPermissionGrant() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            AppLog.app.notice("not running from an .app bundle; skipping relaunch")
            return
        }
        AppLog.app.notice("quitting to relaunch after the Screen Recording grant")
        termination.quit(relaunching: true)
    }

    /// Starts the detached `/bin/sh` that opens the installed bundle again once this process is gone. Called from
    /// `applicationWillTerminate` when onboarding asked for the relaunch, so a quit the user cancels relaunches
    /// nothing.
    ///
    /// Launching the new instance while this one still runs (`createsNewApplicationInstance`) would make its Carbon
    /// registration of the same hotkey fail with `eventHotKeyExistsErr`, because this process still holds it until it
    /// exits.
    static func startRelauncher() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `$1` = our pid, `$2` = bundle path: positional parameters, so the path is never re-parsed.
        relauncher.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "shotcue-relaunch", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path,
        ]
        // `open` hands this environment on to the new instance (measured: a launch flag set here came back
        // in the relaunched app). Our own launch flags must not: `SHOTCUE_OPEN_LIBRARY` would reopen the
        // library, and any flag that relaunches would loop.
        relauncher.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SHOTCUE_") }
        relauncher.standardInput = FileHandle.nullDevice
        relauncher.standardOutput = FileHandle.nullDevice
        relauncher.standardError = FileHandle.nullDevice
        do {
            try relauncher.run()
        } catch {
            AppLog.app.error(
                "relaunch failed: \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
            )
            return
        }
        AppLog.app.notice("relaunching after the Screen Recording grant")
    }
}
