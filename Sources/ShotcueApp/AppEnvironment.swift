import AppKit
import Foundation
import ShotcueCapture
import ShotcueClaudeBridge
import ShotcueCore
import ShotcueNotes
import ShotcuePersistence
import ShotcueUI
import os

/// Single owner of every concrete service, store and AppKit controller (spec §6.7).
/// Nothing else in the app calls a service initialiser.
final class AppEnvironment {
    let settings: SettingsStore
    let fileStore: FileStore
    let services: AppServices
    let notifier: UserNotificationNotifier
    let hotKeys: CarbonHotKeyService
    let runCoordinator: RunCoordinator
    let scheduler: SchedulerDriver
    let transcription: TranscriptionCoordinator
    let diagnostics: Diagnostics
    let status: AppStatusModel
    let settingsObserver: SettingsObserver
    /// One image cache for the library grid, the inspector and the quick panel.
    let thumbnails: ThumbnailCache

    let libraryStore: LibraryStore
    let menuBarStore: MenuBarStore
    let permissionsStore: PermissionsStore
    /// The transcription model's state and its one download flow (Settings, quick panel, inspector).
    let transcriberModel: TranscriberModelStore

    let windowOpener: WindowOpener
    let activationPolicy: ActivationPolicyController
    let quickPanel: QuickPanelController
    let onboarding: OnboardingWindowController
    let captureFlow: CaptureFlowController
    /// Quit / SIGTERM: stop the runs, keep unsaved work (final review I2).
    let termination: TerminationController
    /// In-app updates from GitHub Releases: the check timer, the update window, the install quit.
    let updates: UpdateCoordinator

    /// Where each agent CLI is; resolved without blocking launch (checked by the runner, handoff, diagnostics).
    let locators: AgentLocators
    /// Settings' default agent, readable off the main actor (the send gate, the UI's pickers).
    private let defaultAgentBox: OSAllocatedUnfairLock<AgentKind>

    private let database: AppDatabase
    private var appliedSnapshot: AppSettingsSnapshot?
    /// The combo `pauseHotKey()` took down while Settings records a new one.
    private var pausedHotKey: KeyCombo?

    init() throws {
        let settings = SettingsStore(defaults: .standard)
        self.settings = settings

        // 1. Storage root + directory layout (spec §6.3).
        let root = settings.storageRoot
        let fileStore = FileStore(rootURL: root)
        do {
            try fileStore.ensureDirectories()
        } catch {
            throw AppServiceError.storageUnavailable(root.path)
        }
        self.fileStore = fileStore

        // 2. Database + repositories.
        let database = try AppDatabase.open(at: fileStore.databaseURL)
        self.database = database
        let projects = GRDBProjectRepository(database: database)
        let tasks = GRDBTaskRepository(database: database)
        let runs = GRDBRunRepository(database: database)

        // 3. Capture, thumbnails, permissions, hotkey.
        let capture = ScreencaptureService()
        let thumbnailService = ImageIOThumbnailService()
        let permissions = SystemPermissionService()
        self.hotKeys = CarbonHotKeyService()

        // 4. Voice notes + transcription.
        let snapshot = AppSettingsBridge.snapshot(of: settings)
        let recorder = EngineAudioRecorder(inputDeviceUID: snapshot.inputDeviceUID)
        let transcriber = WhisperKitTranscriber(
            modelName: snapshot.sttModel,
            modelsDirectory: AppSettingsBridge.modelsDirectory(in: fileStore))
        let transcription = TranscriptionCoordinator(
            transcriber: transcriber,
            taskRepository: tasks,
            fileStore: fileStore,
            language: snapshot.sttLanguage,
            titleMaker: true)
        self.transcription = transcription

        // 5. Agent runners. A missing binary must not stop the app from launching (spec §8), and looking
        //    for one must not block launch: only the fixed locations are checked here; the login-shell
        //    fallbacks run in the background and the runner waits for them.
        let clock = SystemClock()
        let notifier = UserNotificationNotifier(center: .current())
        self.notifier = notifier
        let locators = AgentLocators(paths: snapshot.agentPaths)
        self.locators = locators
        let defaultAgentBox = OSAllocatedUnfairLock(initialState: snapshot.defaultAgent)
        self.defaultAgentBox = defaultAgentBox
        let defaultAgent: @Sendable () -> AgentKind = { defaultAgentBox.withLock { $0 } }
        let gitInspector = ShellGitInspector()
        let runCoordinator = RunCoordinator(
            runner: AgentRouterRunner(locators: locators),
            taskRepository: tasks,
            projectRepository: projects,
            runRepository: runs,
            gitInspector: gitInspector,
            fileStore: fileStore,
            notifier: notifier,
            clock: clock,
            settings: AppSettingsBridge.runSettings(from: snapshot),
            // Final review I1: nothing starts before launch recovery; `AppDelegate` resumes the queue after it.
            holdsQueueUntilResumed: true)
        self.runCoordinator = runCoordinator
        // Every sender (UI stores through AppServices, the quick panel, the scheduler) goes through this:
        // with the task's agent CLI missing, sends are refused up front (spec §8).
        let dispatcher = AgentGatedDispatcher(
            base: runCoordinator, locators: locators,
            agentForTask: { taskID in
                var project: Project?
                if let projectID = (try? await tasks.task(id: taskID))??.projectID {
                    project = (try? await projects.project(id: projectID)) ?? nil
                }
                return AgentKind.resolve(project: project?.agent, default: defaultAgent())
            })

        // 6. Scheduler + hand-off.
        self.scheduler = SchedulerDriver(
            dispatcher: dispatcher,
            taskRepository: tasks,
            projectRepository: projects,
            clock: clock,
            calendar: .current,
            interval: 30)
        // `DesktopHandoffService` is built per call by `ClaudeHandoff`, with the paths the locators know by
        // then (the background searches may finish after launch).
        let handoff = ClaudeHandoff(locators: locators, fileStore: fileStore, composerRoute: "code/new")

        // 7. The façade the UI module sees.
        let services = AppServices(
            projects: projects,
            tasks: tasks,
            runs: runs,
            capture: capture,
            thumbnails: thumbnailService,
            permissions: permissions,
            recorder: recorder,
            transcriber: transcriber,
            transcriptionQueue: transcription,
            dispatcher: dispatcher,
            handoff: handoff,
            fileStore: fileStore,
            clock: clock,
            // "Diff'i göster" (Plan 07): the same inspector that snapshots git around every run.
            diff: gitInspector,
            defaultAgent: defaultAgent)
        self.services = services

        // 8. Stores (Plan 05) and the shared image cache.
        let thumbnails = ThumbnailCache(fileStore: fileStore)
        self.thumbnails = thumbnails
        let transcriberModel = TranscriberModelStore(
            transcriber: transcriber, transcriptionQueue: transcription, modelName: snapshot.sttModel)
        self.transcriberModel = transcriberModel
        self.libraryStore = LibraryStore(
            services: services,
            modelStore: transcriberModel,
            renumber: { projectID in
                try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: projectID)
            })
        let permissionsStore = PermissionsStore(services: services)
        self.permissionsStore = permissionsStore
        self.menuBarStore = MenuBarStore(services: services)

        // 9. App-level state and AppKit controllers.
        let status = AppStatusModel()
        // Until `<cli> --version` answers, a located binary reads "kontrol ediliyor…" and one still being
        // searched for "aranıyor…" — neither is "bulunamadı" (red) yet.
        for agent in AgentKind.allCases {
            status.agentFound[agent] = locators[agent].current != .missing
            if locators[agent].current == .searching { status.agentVersions[agent] = "aranıyor…" }
        }
        self.status = status
        self.settingsObserver = SettingsObserver()
        self.windowOpener = WindowOpener()
        let activationPolicy = ActivationPolicyController()
        self.activationPolicy = activationPolicy
        self.diagnostics = Diagnostics(
            locators: locators,
            permissions: permissions,
            fileStore: fileStore,
            settings: settings)
        let quickPanel = QuickPanelController(
            makeStore: { taskID in
                let store = QuickPanelStore(services: services, settings: settings, modelStore: transcriberModel)
                // ⌘⇧↩ with a transcript on its way closes the panel at once (final review C1); a send that then
                // cannot go out is reported like any other failed run.
                store.onSendFailure = { title, message, taskID in
                    status.lastError = message
                    Task {
                        await notifier.notify(
                            AppNotification(kind: .runFailed, title: title, body: message, taskID: taskID))
                    }
                }
                // `capture(taskID:)` loads the row, the thumbnail and the projects; the panel shows at once
                // and fills in as soon as the load lands.
                Task { await store.capture(taskID: taskID) }
                return store
            },
            thumbnails: thumbnails)
        // Spec §5.1 step 5: "Panel kapanır; menü çubuğu ikonu kısa süre vurgulanır."
        quickPanel.onClosed = { [weak status] in status?.flashMenuBarIcon() }
        self.quickPanel = quickPanel
        let termination = TerminationController(
            runCoordinator: runCoordinator, dispatcher: dispatcher, libraryStore: libraryStore,
            quickPanel: quickPanel)
        self.termination = termination
        self.updates = UpdateCoordinator(
            settings: settings, activationPolicy: activationPolicy, termination: termination)
        let onboarding = OnboardingWindowController(
            permissionsStore: permissionsStore,
            permissions: permissions,
            activationPolicy: activationPolicy,
            termination: termination)
        self.onboarding = onboarding
        self.captureFlow = CaptureFlowController(
            services: services,
            settings: settings,
            fileStore: fileStore,
            notifier: notifier,
            status: status,
            permissionsStore: permissionsStore,
            quickPanel: quickPanel,
            onboarding: onboarding)
    }

    // MARK: - Settings application

    /// Pushes changed settings into the services that cache them. Idempotent: identical snapshots are
    /// skipped, so it is safe to call from the observer, from the Settings window closing, and at launch.
    func applySettings() {
        let snapshot = AppSettingsBridge.snapshot(of: settings)
        guard snapshot != appliedSnapshot else { return }
        let previous = appliedSnapshot
        appliedSnapshot = snapshot

        defaultAgentBox.withLock { $0 = snapshot.defaultAgent }
        let runSettings = AppSettingsBridge.runSettings(from: snapshot)
        let coordinator = runCoordinator
        Task { await coordinator.updateSettings(runSettings) }

        if previous?.sttLanguage != snapshot.sttLanguage {
            let transcription = transcription
            let language = snapshot.sttLanguage
            Task { await transcription.setLanguage(language) }
        }
        if previous?.hotKey != snapshot.hotKey || previous?.hotKeyPaused != snapshot.hotKeyPaused {
            if snapshot.hotKeyPaused {
                pauseHotKey()
            } else {
                registerHotKey(snapshot.hotKey)
            }
        }
        if previous?.launchAtLogin != snapshot.launchAtLogin {
            reconcileLoginItem(desired: snapshot.launchAtLogin)
        }
        // Settings that are baked in at init: tell the user instead of pretending they took effect.
        if let previous,
            previous.sttModel != snapshot.sttModel
                || previous.inputDeviceUID != snapshot.inputDeviceUID
                || previous.storageRootPath != snapshot.storageRootPath
                || previous.agentPaths != snapshot.agentPaths
        {
            status.lastError =
                "Bu ayar için Shotcue'yu yeniden başlatın (model / giriş cihazı / depolama / ajan yolu)."
        }
    }

    /// (Re)registers the global hotkey. Carbon refuses a combination another app already owns; that is a
    /// user-visible condition, so it lands in `status.hotKeyError` (shown under Settings) rather than
    /// being swallowed.
    ///
    /// `CarbonHotKeyService.register` tears the current registration down before it tries the new one,
    /// so a refused combo would leave the app without any hotkey. The previous combo is registered again
    /// in that case and the picker goes back to it, so Settings always shows the combo that works.
    /// Main actor only: the Carbon service asserts the main queue.
    func registerHotKey(_ combo: KeyCombo) {
        // Already active — e.g. the picker was just reverted to the combo restored below. Registering it
        // again would only clear the error that explains the revert.
        guard hotKeys.registeredCombo != combo else { return }
        // While the recorder was listening nothing was registered; the paused combo is the one to fall back to.
        let previous = hotKeys.registeredCombo ?? pausedHotKey
        pausedHotKey = nil
        let flow = captureFlow
        // The Carbon service already calls this on the main queue; the hop makes the isolation explicit.
        let handler: @Sendable () -> Void = {
            Task { @MainActor in flow.begin() }
        }
        do {
            try hotKeys.register(combo, handler: handler)
            status.hotKeyError = nil
            AppLog.app.notice("hotkey \(combo.label, privacy: .public) registered")
        } catch {
            let reason = "Kısayol \(combo.label) kaydedilemedi (\(Self.describe(hotKeyError: error)))."
            defer { AppLog.app.error("\(self.status.hotKeyError ?? reason, privacy: .public)") }
            guard let previous else {
                status.hotKeyError = reason
                return
            }
            do {
                try hotKeys.register(previous, handler: handler)
                status.hotKeyError = "\(reason) \(previous.label) kullanılmaya devam ediyor."
                settings.hotKey = previous
            } catch {
                status.hotKeyError = "\(reason) Önceki kısayol \(previous.label) de geri yüklenemedi."
            }
        }
    }

    /// Settings' recorder is listening: without this, Carbon would swallow the current combo before the
    /// recorder saw it. The combo is remembered so a refused new one can fall back to it.
    func pauseHotKey() {
        if let current = hotKeys.registeredCombo { pausedHotKey = current }
        hotKeys.unregister()
        AppLog.app.notice("hotkey paused for recording")
    }

    /// -9878 is Carbon's `eventHotKeyExistsErr`: another app owns the combination.
    private static func describe(hotKeyError error: Error) -> String {
        if case HotKeyError.registrationFailed(let status) = error {
            return status == -9878 ? "başka bir uygulama kullanıyor" : "hata \(status)"
        }
        return error.localizedDescription
    }

    private func reconcileLoginItem(desired: Bool) {
        do {
            try LoginItemManager.setEnabled(desired)
        } catch {
            status.lastError = "Girişte başlat ayarlanamadı: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }

    // MARK: - Status

    /// `<cli> --version` of every agent, transcriber model state, project list, input devices and login item status.
    func refreshStatus() {
        let transcriberModel = transcriberModel
        let projectRepository = services.projects
        Task { @MainActor in
            for agent in AgentKind.allCases {
                let version = await diagnostics.version(of: agent)
                status.agentVersions[agent] = version.text
                status.agentFound[agent] = version.found
                AppLog.app.notice(
                    "\(agent.executableName, privacy: .public) \(version.found ? "found" : "missing", privacy: .public): \(version.text, privacy: .public)"
                )
            }
            await transcriberModel.refresh()
            status.projects = (try? await projectRepository.allProjects()) ?? []
        }
        status.inputDevices = AudioDeviceCatalog.inputDevices()
        status.foundationModelsText = FoundationModelsStatus.current.localizedDescription
        refreshLoginItemStatus()
    }

    /// The menu bar store streams tasks continuously but reads the pause flag only when it starts.
    func refreshMenuBar() {
        menuBarStore.stop()
        menuBarStore.start()
    }

    /// Notification "Aç": opens the library on the task's own list with the task selected and the
    /// inspector shown. `LibraryStore` streams only while the library window is on screen and drops a
    /// selection its filtered list does not contain — opened from closed, its first stream pass could
    /// drop an id selected up front. So the sidebar (and search) are pointed at the task, the window is
    /// opened, and the task is selected only once the store lists it (polled on the main actor, ≤ 2 s).
    func revealTask(_ taskID: UUID) async {
        guard let task = try? await services.tasks.task(id: taskID) else {
            windowOpener.openLibrary()
            return
        }
        if !libraryStore.searchText.isEmpty { libraryStore.searchText = "" }
        libraryStore.selection = task.projectID.map { .project($0) } ?? .inbox
        windowOpener.openLibrary()
        let deadline = ContinuousClock.now + .seconds(2)
        while !libraryStore.tasks.contains(where: { $0.id == taskID }) {
            guard ContinuousClock.now < deadline else {
                AppLog.app.error("reveal: task \(taskID, privacy: .public) not listed within 2 s; library left open")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        libraryStore.selectedTaskIDs = [taskID]
        libraryStore.isInspectorPresented = true
    }

    /// Spec/research 01 §8: never cache the login item state, read it every time Settings opens.
    func refreshLoginItemStatus() {
        status.loginItemStatusText = LoginItemManager.statusText
    }

    func runDiagnostics() {
        guard !status.diagnosticsRunning else { return }
        status.diagnosticsRunning = true
        Task { @MainActor in
            defer { status.diagnosticsRunning = false }
            do {
                let url = try await diagnostics.writeReport(
                    transcriberState: transcriberModel.state,
                    loginItemStatus: LoginItemManager.statusText,
                    hotKeyLabel: settings.hotKey.label)
                NSWorkspace.shared.open(url)
            } catch {
                status.lastError = "Tanılama yazılamadı: \(error.localizedDescription)"
            }
        }
    }

    /// First launch (or after a TCC reset): show onboarding while Screen Recording is missing — the one
    /// permission the app cannot work without (spec §6.1 "açılışta CGPreflightScreenCaptureAccess(); false
    /// ise onboarding"). The microphone is optional (spec §8: text notes still work) and can be granted from
    /// the onboarding rows, the quick panel or Settings; gating launch on it would reopen onboarding on
    /// every start until the user decides.
    /// The refresh also primes `permissionsStore`, whose `isBlocking` gates the hotkey.
    /// Returns whether onboarding was shown (it carries its own notification row).
    @discardableResult
    func showOnboardingIfNeeded() async -> Bool {
        await permissionsStore.refresh()
        guard permissionsStore.isBlocking else { return false }
        onboarding.show()
        return true
    }

    // MARK: - Bootstrap

    static func presentFatalAndExit(_ error: Error) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Shotcue başlatılamadı"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Çık")
        alert.runModal()
        exit(1)
    }
}

/// Lazily built once, on the main actor, before the first scene body runs
/// (`AppDelegate.applicationWillFinishLaunching` touches it first to control the ordering).
enum AppBootstrap {
    static let environment: AppEnvironment = {
        do {
            return try AppEnvironment()
        } catch {
            AppEnvironment.presentFatalAndExit(error)
        }
    }()
}
