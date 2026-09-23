import AppKit
import ShotcueCapture
import ShotcueCore
import ShotcueUI

/// Spec §5.1: global hotkey → region selection → PNG moved into the store → `ShotTask` + `Capture`
/// rows → background thumbnail → optional clipboard copy → quick panel.
final class CaptureFlowController {
    private let services: AppServices
    private let settings: SettingsStore
    private let fileStore: FileStore
    private let notifier: any Notifier
    private let status: AppStatusModel
    private let permissionsStore: PermissionsStore
    private let quickPanel: QuickPanelController
    private let onboarding: OnboardingWindowController
    private var isCapturing = false

    init(
        services: AppServices, settings: SettingsStore, fileStore: FileStore, notifier: any Notifier,
        status: AppStatusModel, permissionsStore: PermissionsStore, quickPanel: QuickPanelController,
        onboarding: OnboardingWindowController
    ) {
        self.services = services
        self.settings = settings
        self.fileStore = fileStore
        self.notifier = notifier
        self.status = status
        self.permissionsStore = permissionsStore
        self.quickPanel = quickPanel
        self.onboarding = onboarding
    }

    /// Entry point for the global hotkey (called on the main actor by `AppEnvironment.registerHotKey`).
    /// A second press while `screencapture -i -s` owns the mouse would put two selection cursors on
    /// screen, so re-entrant presses are dropped instead of queued.
    func begin() {
        guard !isCapturing else { return }
        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }
            await run()
        }
    }

    private func run() async {
        // 1. Permission gate. Spec §8: until Screen Recording is granted the hotkey opens onboarding.
        //    `isBlocking` is true until the store has been refreshed once, so refresh first (and every
        //    time: the grant can change in System Settings while the app runs).
        await permissionsStore.refresh()
        guard !permissionsStore.isBlocking else {
            onboarding.show()
            return
        }

        // 2. Region selection into a temporary file; nil means the user pressed Esc (no task is created).
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-capture-\(UUID().uuidString).png")
        let captured: CaptureResult?
        do {
            captured = try await services.capture.captureRegion(to: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            await report(title: "Yakalama başarısız", error: error)
            return
        }
        guard let captured else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        // 3. Move the PNG to captures/YYYY/MM/<uuid>.png (spec §6.3; the DB stores the relative path).
        let captureID = UUID()
        let now = services.clock.now
        let relPath = fileStore.captureRelPath(id: captureID, date: now)
        let destination = fileStore.absoluteURL(for: relPath)
        do {
            try fileStore.ensureParentDirectory(for: relPath)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: captured.fileURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            await report(title: "Yakalama diske yazılamadı", error: error)
            return
        }

        // 4. Rows. The task starts in `inbox` without a project; the quick panel assigns the project and
        //    performs the inbox → ready transition (spec §7), so the state machine stays in one place.
        let inboxTasks = (try? await services.tasks.tasks(projectID: nil)) ?? []
        let task = ShotTask(
            title: TitleMaker.title(noteText: "", transcript: nil, createdAt: now),
            status: .inbox,
            mode: .implement,
            sortIndex: SortIndex.between(inboxTasks.map(\.sortIndex).max(), nil),
            createdAt: now,
            updatedAt: now)
        let capture = Capture(
            id: captureID,
            taskID: task.id,
            relPath: relPath,
            width: captured.width,
            height: captured.height,
            scale: captured.scale,
            createdAt: now)
        do {
            try await services.tasks.save(task)
            try await services.tasks.save(capture)
        } catch {
            // No half-created task: drop the row (if it landed) and the file (spec §8).
            try? await services.tasks.deleteTask(id: task.id)
            try? FileManager.default.removeItem(at: destination)
            await report(title: "Yakalama kaydedilemedi", error: error)
            return
        }

        // 5. Thumbnail off the main actor; a missing thumbnail is cosmetic (the full PNG is shown instead).
        makeThumbnail(for: capture)

        // 6. Clipboard (spec §5.1 step 3, optional setting). A failed copy never fails the capture.
        if settings.copyToClipboardOnCapture, !PasteboardWriter.copyPNG(at: destination) {
            AppLog.app.error("clipboard copy failed for \(relPath, privacy: .private)")
        }

        // 7. Quick panel. The menu bar highlight follows when the panel closes (spec §5.1 step 5).
        quickPanel.present(taskID: task.id)
    }

    private func makeThumbnail(for capture: Capture) {
        let thumbnails = services.thumbnails
        let tasks = services.tasks
        let store = fileStore
        let source = store.absoluteURL(for: capture.relPath)
        let thumbRelPath = store.thumbRelPath(id: capture.id)
        let destination = store.absoluteURL(for: thumbRelPath)
        Task.detached(priority: .utility) {
            do {
                try store.ensureParentDirectory(for: thumbRelPath)
                try await thumbnails.makeThumbnail(from: source, to: destination, maxPixel: 512)
                // Re-read the row: in the meantime the capture may have been deleted or moved to another
                // task, and upserting the stale copy would resurrect or move it back.
                let current = try await tasks.captures(taskID: capture.taskID).first { $0.id == capture.id }
                guard var updated = current else { return }
                updated.thumbRelPath = thumbRelPath
                try await tasks.save(updated)
            } catch {
                AppLog.app.error(
                    "thumbnail failed for \(capture.id, privacy: .public): \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
                )
            }
        }
    }

    /// Spec §8: capture failures produce a notification plus a visible error, and no task row.
    private func report(title: String, error: Error) async {
        let message = Self.describe(error)
        // The title is one of this file's fixed strings; the message can carry screencapture's stderr or a file name.
        AppLog.app.error("\(title, privacy: .public): \(message, privacy: .private)")
        status.lastError = "\(title): \(message)"
        await notifier.notify(AppNotification(kind: .runFailed, title: title, body: message))
    }

    /// `CaptureError` is not a `LocalizedError`; its stderr is what the user needs to see (spec §8).
    private static func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.screencaptureFailed(let exitCode, let stderr):
            return stderr.isEmpty
                ? "screencapture \(exitCode) koduyla çıktı" : "screencapture (\(exitCode)): \(stderr)"
        case CaptureError.unreadableImage(let url):
            return "Görüntü okunamadı: \(url.lastPathComponent)"
        case CaptureError.launchFailed(let message):
            return "screencapture başlatılamadı: \(message)"
        default:
            return error.localizedDescription
        }
    }
}
