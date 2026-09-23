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

        // Final review I2: SIGTERM (`pkill`, `make install`) takes the quit path instead of killing the process.
        environment.termination.installSignalHandler()

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
        // Final review I1: the coordinator holds its queue until here, so no run can start before recovery;
        // then the queue resumes — tasks queued before the quit start again — but only once `claude` is known
        // to exist (the same wait as `ClaudeGatedDispatcher`): without it, queued tasks stay queued.
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
            if await environment.claude.executable() != nil {
                await environment.runCoordinator.resumeQueue()
            } else {
                AppLog.app.notice("claude missing: the run queue stays held, queued tasks stay queued")
            }
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

        // Automatic update checks: the first one shortly after launch, then once a day.
        environment.updates.start()

        if LaunchFlags.shouldOpenLibrary {
            environment.windowOpener.openLibrary()
        }
    }

    /// Final review I2: runs in flight are stopped (after a confirmation when the user quit) and unsaved text and
    /// audio are kept before AppKit terminates; with nothing to stop or save it terminates at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppBootstrap.environment.termination.applicationShouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let environment = AppBootstrap.environment
        // The hotkey and the observer must go down synchronously; the scheduler is an actor, so its
        // stop is fire-and-forget — the process is exiting either way and its timer dies with it.
        environment.hotKeys.unregister()
        environment.settingsObserver.stop()
        let scheduler = environment.scheduler
        Task { await scheduler.stop() }
        // Onboarding asked for a restart after the Screen Recording grant, or an update is staged, and the quit went
        // ahead (final review N1). The update helper swaps the bundle before it opens the app.
        if environment.termination.relaunchRequested, !environment.updates.startSwapIfStaged() {
            OnboardingWindowController.startRelauncher()
        }
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

    // MARK: - UNUserNotificationCenterDelegate

    /// RUN_DONE: Aç / Terminalde devam et; RUN_FAILED: Aç / Yeniden çalıştır (spec §6.7). The identifiers
    /// are Plan 04's constants, never copied string literals.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let environment = AppBootstrap.environment
        let userInfo = response.notification.request.content.userInfo
        let taskID = Self.uuid(userInfo[UserNotificationNotifier.taskIDKey])
        let runID = Self.uuid(userInfo[UserNotificationNotifier.runIDKey])
        AppLog.app.notice("notification action \(response.actionIdentifier, privacy: .public)")

        switch response.actionIdentifier {
        case UserNotificationNotifier.openAction, UNNotificationDefaultActionIdentifier:
            // `revealTask` opens the library itself, after pointing the sidebar at the task.
            if let taskID {
                await environment.revealTask(taskID)
            } else {
                environment.windowOpener.openLibrary()
            }

        case UserNotificationNotifier.terminalAction:
            // `Run.id` doubles as the Claude session id (Plan 00 Task 1), so the session to resume is
            // either the run the notification came from or the task's newest run.
            guard let sessionID = await Self.sessionID(runID: runID, taskID: taskID, environment: environment)
            else {
                environment.status.lastError = "Devam edilecek oturum bulunamadı."
                return
            }
            // The session resumes from the task's project folder, where the run worked (final review M6).
            guard let projectPath = await Self.projectPath(taskID: taskID, environment: environment) else {
                environment.status.lastError = "Oturum proje klasöründen devam ettirilir; görevin bir projesi yok."
                return
            }
            do {
                try environment.services.handoff.openInTerminal(sessionID: sessionID, projectPath: projectPath)
            } catch {
                environment.status.lastError = "Terminal açılamadı: \(error.localizedDescription)"
            }

        case UserNotificationNotifier.retryAction:
            // A capture failure is also posted as RUN_FAILED but carries no task: nothing to rerun.
            guard let taskID else { return }
            do {
                try await environment.services.dispatcher.enqueue(taskID: taskID)
            } catch {
                environment.status.lastError = "Yeniden çalıştırılamadı: \(error.localizedDescription)"
            }

        default:
            break
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    /// The notification's run (RUN_DONE: claude ran it), or the task's newest run that actually started claude
    /// (final review M4, the Inspector's rule). The spelling `--resume` needs is applied by `ClaudeHandoff`, the
    /// same as for the Inspector's resume buttons.
    private static func sessionID(
        runID: UUID?, taskID: UUID?, environment: AppEnvironment
    ) async -> String? {
        if let runID { return runID.uuidString }
        guard let taskID else { return nil }
        let runs = (try? await environment.services.runs.runs(taskID: taskID)) ?? []
        return environment.fileStore.latestLaunchedRun(in: runs)?.id.uuidString
    }

    /// The folder of the task's project; nil when the task or its project is gone.
    private static func projectPath(taskID: UUID?, environment: AppEnvironment) async -> String? {
        guard let taskID, let task = try? await environment.services.tasks.task(id: taskID),
            let projectID = task.projectID,
            let project = try? await environment.services.projects.project(id: projectID)
        else { return nil }
        return project.path
    }

    /// Banners while Shotcue is frontmost, too — a finished run is the whole point of the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
