import AppKit
import ShotcueClaudeBridge
import ShotcueCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Builds the environment before any scene body runs, so a failure can still show an alert.
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = AppBootstrap.environment
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppBootstrap.environment

        // Menu-bar-only by default (Info.plist LSUIElement is already true; this makes it explicit
        // and covers the case where a window opened and closed before we got here).
        NSApp.setActivationPolicy(.accessory)
        environment.activationPolicy.install()

        // The notifier owns the category/action identifiers (Plan 04); the app only routes taps.
        UNUserNotificationCenter.current().delegate = self
        environment.notifier.registerCategories()

        // Settings → services. First call pushes everything (run settings, STT language, hotkey, login item).
        environment.settingsObserver.start(environment.settings) {
            AppBootstrap.environment.applySettings()
        }
        environment.applySettings()
        environment.refreshStatus()
        environment.menuBarStore.start()

        // Spec §8 then §6.5, in this order: runs interrupted by the last quit are failed first, then the
        // scheduler starts. It owns its 30 s DispatchSourceTimer and the NSWorkspace.didWakeNotification
        // observer; its first timer pass is `interval` away, so launch asks for one immediate reconcile.
        Task { @MainActor in
            do {
                let recovered = try await environment.runCoordinator.recoverInterruptedRuns()
                if recovered > 0 {
                    AppLog.app.notice("marked \(recovered, privacy: .public) interrupted run(s) as failed")
                }
            } catch {
                environment.status.lastError =
                    "Yarım kalan çalışmalar işaretlenemedi: \(error.localizedDescription)"
            }
            await environment.scheduler.start()
            await environment.scheduler.tick()
        }

        // Voice notes recorded while the model was missing get transcribed now. This can take minutes
        // (every pending note), so it never sits in front of the launch work above.
        let transcriptionQueue = environment.services.transcriptionQueue
        Task { await transcriptionQueue.processPending() }

        // Both of these may wait on the user for as long as they like, so they run on their own.
        // Onboarding has its own notifications row; without it, ask for notifications once here.
        Task { @MainActor in
            let onboardingShown = await environment.showOnboardingIfNeeded()
            if !onboardingShown {
                await Self.requestNotificationAuthorizationIfNeeded(environment.notifier)
            }
        }

        if LaunchFlags.shouldOpenLibrary {
            environment.windowOpener.openLibrary()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let environment = AppBootstrap.environment
        // The hotkey and the observer must go down synchronously; the scheduler is an actor, so its
        // stop is fire-and-forget — the process is exiting either way and its timer dies with it.
        environment.hotKeys.unregister()
        environment.settingsObserver.stop()
        let scheduler = environment.scheduler
        Task { await scheduler.stop() }
    }

    /// Menu-bar app: closing the library window must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Clicking the Dock icon (only visible while .regular) reopens the library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppBootstrap.environment.windowOpener.openLibrary() }
        return true
    }

    /// Only prompt once: an already-denied user must not be nagged on every launch (spec §9).
    static func requestNotificationAuthorizationIfNeeded(_ notifier: UserNotificationNotifier) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        await notifier.requestAuthorization()
    }

    // MARK: - UNUserNotificationCenterDelegate (actions wired in Task 6)

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        AppLog.app.notice("notification action \(response.actionIdentifier, privacy: .public) (not wired yet)")
    }

    /// Banners while Shotcue is frontmost, too — a finished run is the whole point of the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
