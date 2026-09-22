import AppKit
import Foundation
import ShotcueCapture
import ShotcueClaudeBridge
import ShotcueCore
import ShotcueNotes
import ShotcuePersistence
import ShotcueUI

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

    let windowOpener: WindowOpener
    let activationPolicy: ActivationPolicyController
    let quickPanel: QuickPanelController
    let onboarding: OnboardingWindowController
    let captureFlow: CaptureFlowController

    private let database: AppDatabase
    private let claudeExecutable: URL?
    private var appliedSnapshot: AppSettingsSnapshot?

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

        // 5. Claude runner. A missing binary must not stop the app from launching (spec §8).
        let clock = SystemClock()
        let notifier = UserNotificationNotifier(center: .current())
        self.notifier = notifier
        let claudeExecutable = ClaudeLocator.locate(preferredPath: settings.claudePath)
        self.claudeExecutable = claudeExecutable
        let runner: any ClaudeRunner =
            claudeExecutable.map {
                ProcessClaudeRunner(executableURL: $0, environmentOverrides: [:])
            } ?? MissingClaudeRunner()
        let gitInspector = ShellGitInspector()
        let runCoordinator = RunCoordinator(
            runner: runner,
            taskRepository: tasks,
            projectRepository: projects,
            runRepository: runs,
            gitInspector: gitInspector,
            fileStore: fileStore,
            notifier: notifier,
            clock: clock,
            settings: AppSettingsBridge.runSettings(from: snapshot))
        self.runCoordinator = runCoordinator

        // 6. Scheduler + hand-off.
        self.scheduler = SchedulerDriver(
            dispatcher: runCoordinator,
            taskRepository: tasks,
            projectRepository: projects,
            clock: clock,
            calendar: .current,
            interval: 30)
        // `DesktopHandoffService` needs a concrete URL. When `claude` is missing the deep links still
        // form (they only carry the session id) and the .command file fails loudly on open, which is
        // the same story Settings already tells.
        let handoff = DesktopHandoffService(
            claudeExecutable: claudeExecutable ?? ClaudeFallback.executableURL,
            fileStore: fileStore,
            composerRoute: "code/new")

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
            dispatcher: runCoordinator,
            handoff: handoff,
            fileStore: fileStore,
            clock: clock)
        self.services = services

        // 8. Stores (Plan 05) and the shared image cache.
        let thumbnails = ThumbnailCache(fileStore: fileStore)
        self.thumbnails = thumbnails
        self.libraryStore = LibraryStore(
            services: services,
            renumber: { projectID in
                try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: projectID)
            })
        let permissionsStore = PermissionsStore(services: services)
        self.permissionsStore = permissionsStore
        self.menuBarStore = MenuBarStore(services: services)

        // 9. App-level state and AppKit controllers.
        let status = AppStatusModel()
        self.status = status
        self.settingsObserver = SettingsObserver()
        self.windowOpener = WindowOpener()
        let activationPolicy = ActivationPolicyController()
        self.activationPolicy = activationPolicy
        self.diagnostics = Diagnostics(
            claudeExecutable: claudeExecutable,
            permissions: permissions,
            fileStore: fileStore,
            settings: settings)
        let quickPanel = QuickPanelController(
            makeStore: { taskID in
                let store = QuickPanelStore(services: services, settings: settings)
                // `capture(taskID:)` loads the row, the thumbnail and the projects; the panel shows at once
                // and fills in as soon as the load lands.
                Task { await store.capture(taskID: taskID) }
                return store
            })
        self.quickPanel = quickPanel
        let onboarding = OnboardingWindowController(
            permissionsStore: permissionsStore,
            permissions: permissions,
            activationPolicy: activationPolicy)
        self.onboarding = onboarding
        self.captureFlow = CaptureFlowController(
            services: services,
            settings: settings,
            fileStore: fileStore,
            notifier: notifier,
            status: status,
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

        let runSettings = AppSettingsBridge.runSettings(from: snapshot)
        let coordinator = runCoordinator
        Task { await coordinator.updateSettings(runSettings) }

        if previous?.sttLanguage != snapshot.sttLanguage {
            let transcription = transcription
            let language = snapshot.sttLanguage
            Task { await transcription.setLanguage(language) }
        }
        if previous?.hotKey != snapshot.hotKey {
            registerHotKey(snapshot.hotKey)
        }
        if previous?.launchAtLogin != snapshot.launchAtLogin {
            reconcileLoginItem(desired: snapshot.launchAtLogin)
        }
        // Settings that are baked in at init: tell the user instead of pretending they took effect.
        if let previous,
            previous.sttModel != snapshot.sttModel
                || previous.inputDeviceUID != snapshot.inputDeviceUID
                || previous.storageRootPath != snapshot.storageRootPath
        {
            status.lastError = "Bu ayar için Shotcue'yu yeniden başlatın (model / giriş cihazı / depolama)."
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
        let previous = hotKeys.registeredCombo
        // Already active — e.g. the picker was just reverted to the combo restored below. Registering it
        // again would only clear the error that explains the revert.
        guard previous != combo else { return }
        let flow = captureFlow
        // The Carbon service already calls this on the main queue; the hop makes the isolation explicit.
        let handler: @Sendable () -> Void = {
            Task { @MainActor in flow.begin() }
        }
        do {
            try hotKeys.register(combo, handler: handler)
            status.hotKeyError = nil
        } catch {
            let reason = "Kısayol \(combo.label) kaydedilemedi (\(Self.describe(hotKeyError: error)))."
            guard let previous else {
                status.hotKeyError = reason
                return
            }
            do {
                try hotKeys.register(previous, handler: handler)
                status.hotKeyError = "\(reason) \(previous.label) kullanılmaya devam ediyor."
                settings.hotKeyLabel = previous.label
            } catch {
                status.hotKeyError = "\(reason) Önceki kısayol \(previous.label) de geri yüklenemedi."
            }
        }
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

    /// `claude --version`, transcriber model state, project list and login item status.
    func refreshStatus() {
        let transcriber = services.transcriber
        let projectRepository = services.projects
        Task { @MainActor in
            let version = await diagnostics.claudeVersion()
            status.claudeVersion = version.text
            status.claudeFound = version.found
            status.transcriberState = await transcriber.modelState()
            status.projects = (try? await projectRepository.allProjects()) ?? []
        }
        refreshLoginItemStatus()
    }

    /// Spec/research 01 §8: never cache the login item state, read it every time Settings opens.
    func refreshLoginItemStatus() {
        status.loginItemStatusText = LoginItemManager.statusText
    }

    func downloadTranscriberModel() {
        let transcriber = services.transcriber
        Task { @MainActor in
            status.transcriberState = .downloading(progress: 0)
            do {
                try await transcriber.downloadModel()
                status.transcriberState = await transcriber.modelState()
                await services.transcriptionQueue.processPending()
            } catch {
                status.transcriberState = .failed(error.localizedDescription)
            }
        }
    }

    func runDiagnostics() {
        guard !status.diagnosticsRunning else { return }
        status.diagnosticsRunning = true
        Task { @MainActor in
            defer { status.diagnosticsRunning = false }
            do {
                let url = try await diagnostics.writeReport(
                    transcriberState: status.transcriberState,
                    loginItemStatus: LoginItemManager.statusText,
                    hotKeyLabel: settings.hotKey.label)
                NSWorkspace.shared.open(url)
            } catch {
                status.lastError = "Tanılama yazılamadı: \(error.localizedDescription)"
            }
        }
    }

    /// First launch (or after a TCC reset): show onboarding when screen recording is missing (spec §6.1)
    /// or the microphone has never been asked for. A microphone the user denied on purpose does not
    /// bring onboarding back on every launch: text notes work without it (spec §8).
    /// The refresh also primes `permissionsStore`, whose `isBlocking` gates the hotkey.
    func showOnboardingIfNeeded() async {
        await permissionsStore.refresh()
        let microphoneNeverAsked = permissionsStore.state(of: .microphone) == .notDetermined
        guard permissionsStore.isBlocking || microphoneNeverAsked else { return }
        onboarding.show()
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
