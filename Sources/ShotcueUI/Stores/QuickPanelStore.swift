import Foundation
import Observation
import ShotcueCore

/// Backs the post-capture quick panel (spec §5.1, §5.2). Plan 06 creates one per capture, calls
/// `capture(taskID:)` and sets `onClose` to hide the `NSPanel`.
///
/// The panel is deliberately forgiving: `dismiss()` saves nothing (the capture stays in the inbox), but
/// a recording in flight is still stopped and stored so audio is never lost.
@MainActor
@Observable
public final class QuickPanelStore {
    public private(set) var task: ShotTask?
    public private(set) var projects: [Project] = []
    public private(set) var voiceNotes: [VoiceNote] = []
    public private(set) var thumbnailURL: URL?
    public private(set) var isRecording = false
    public private(set) var recordingSeconds: Double = 0
    public private(set) var level: Float = 0
    public private(set) var microphoneState: PermissionState = .notDetermined

    public var noteText: String = ""
    public var selectedProjectID: UUID?
    public var mode: TaskMode = .implement
    public var scheduleDate: Date
    public var isSchedulePresented = false
    public var lastError: String?

    /// Plan 06 sets this to hide the panel; the store itself never touches AppKit windows.
    public var onClose: (() -> Void)?

    /// A ⌘⇧↩ that waited for a transcript after the panel closed could not send the task (final review C1):
    /// the task's current title, the Turkish reason and the task id. The App shows it and posts a notification.
    public var onSendFailure: ((_ title: String, _ message: String, _ taskID: UUID) -> Void)?

    /// The send finishing in the background after ⌘⇧↩ closed the panel (C1); tests await it.
    @ObservationIgnored var backgroundSend: Task<Void, Never>?
    /// How long ⌘⇧↩ waits for a pending transcript, and how often it looks. Internal so tests can shorten them.
    @ObservationIgnored var transcriptWaitTimeout: Duration = TranscriptGate.defaultTimeout
    @ObservationIgnored var transcriptPollInterval: Duration = .milliseconds(500)

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNoteID: UUID?
    @ObservationIgnored private var pendingRelPath: String?
    /// The stop in progress: the recorder is finishing the file and the voice-note row is not saved yet.
    /// Everything that needs the note (save, send, dismiss) waits for it.
    @ObservationIgnored private var recordingStop: Task<Void, Never>?
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private var didClose = false

    /// The level meter ticks at 200 ms, which is also the recording timer's resolution.
    static let tick: Duration = .milliseconds(200)
    static let tickSeconds: Double = 0.2

    /// The shared transcription model (spec §6.2): after a recording without it, the panel says so and offers the
    /// download (final review C1 (c)). Nil disables the notice.
    public let modelStore: TranscriberModelStore?

    public init(services: AppServices, settings: SettingsStore, modelStore: TranscriberModelStore? = nil) {
        self.services = services
        self.settings = settings
        self.modelStore = modelStore
        self.scheduleDate = services.clock.now.addingTimeInterval(3600)
    }

    // MARK: - Loading

    /// Loads the freshly created task, its capture thumbnail and the project list, then picks defaults.
    public func capture(taskID: UUID) async {
        do {
            let loaded = try await services.tasks.task(id: taskID)
            task = loaded
            noteText = loaded?.noteText ?? ""
            projects = try await services.projects.allProjects()
            voiceNotes = try await services.tasks.voiceNotes(taskID: taskID)
            let captures = try await services.tasks.captures(taskID: taskID)
            if let first = captures.first {
                thumbnailURL = services.fileStore.absoluteURL(for: first.thumbRelPath ?? first.relPath)
            }
        } catch {
            report(error)
        }
        // "son kullanılan varsayılan" (spec §5.1), else the first project in manual order.
        let remembered = settings.lastUsedProject
        if let remembered, projects.contains(where: { $0.id == remembered }) {
            selectedProjectID = remembered
        } else {
            selectedProjectID = projects.first?.id
        }
        applyProjectDefaults()
        microphoneState = await services.permissions.state(of: .microphone)
        await modelStore?.refresh()
    }

    // MARK: - Derived

    public var canSave: Bool { task != nil }

    /// A recording of this panel waits for a transcription model that is not there (not downloaded, still
    /// downloading or unloadable): the panel shows "model indirilmedi" and the download button instead of
    /// "cihaz içi transkripsiyon".
    public var showsModelNotice: Bool {
        guard let modelStore, !modelStore.isReady else { return false }
        return voiceNotes.contains { $0.isAwaitingTranscript }
    }

    public var canRecord: Bool { microphoneState != .denied && task != nil }

    public var selectedProject: Project? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// `⌘1…⌘9` picks the nth project (spec §5.1). 1-based; nil when the project is past the ninth.
    public func projectShortcutIndex(for projectID: UUID) -> Int? {
        guard let index = projects.firstIndex(where: { $0.id == projectID }), index < 9 else { return nil }
        return index + 1
    }

    public func selectProject(atShortcut number: Int) {
        guard number >= 1, number <= projects.count, number <= 9 else { return }
        selectedProjectID = projects[number - 1].id
        applyProjectDefaults()
    }

    /// Mode follows the project's own default until the user overrides it in this panel.
    private func applyProjectDefaults() {
        guard let project = selectedProject else { return }
        mode = project.defaultMode
    }

    // MARK: - Recording

    public func requestMicrophone() async {
        microphoneState = await services.permissions.request(.microphone)
    }

    public func toggleRecording() async {
        if isRecording || recordingStop != nil {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard let task else { return }
        if microphoneState == .notDetermined { await requestMicrophone() }
        guard microphoneState != .denied else {
            lastError = "Mikrofon izni verilmedi. Sistem Ayarları > Gizlilik'ten açabilirsin."
            return
        }
        let noteID = UUID()
        let relPath = services.fileStore.audioRelPath(id: noteID)
        let url = services.fileStore.absoluteURL(for: relPath)
        do {
            try services.fileStore.ensureParentDirectory(for: relPath)
            try await services.recorder.start(writingTo: url)
        } catch {
            report(error)
            return
        }
        _ = task
        pendingNoteID = noteID
        pendingRelPath = relPath
        isRecording = true
        recordingSeconds = 0
        level = 0
        let levels = services.recorder.levels
        levelTask = Task { [weak self] in
            for await value in levels {
                guard let self, self.isRecording else { return }
                self.level = value
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: QuickPanelStore.tick)
                guard let self, self.isRecording else { return }
                self.recordingSeconds += QuickPanelStore.tickSeconds
            }
        }
    }

    /// Stops the recording and stores its voice-note row. A stop already in progress is awaited instead of
    /// started twice, so every caller returns only once the note is saved.
    private func stopRecording() async {
        if let recordingStop {
            await recordingStop.value
            return
        }
        guard isRecording else { return }
        let stop = Task { await self.finishRecording() }
        recordingStop = stop
        await stop.value
        recordingStop = nil
    }

    private func finishRecording() async {
        tickTask?.cancel()
        tickTask = nil
        levelTask?.cancel()
        levelTask = nil
        isRecording = false
        level = 0
        guard let task, let noteID = pendingNoteID, let relPath = pendingRelPath else { return }
        pendingNoteID = nil
        pendingRelPath = nil
        do {
            let info = try await services.recorder.stop()
            let note = VoiceNote(
                id: noteID, taskID: task.id, relPath: relPath,
                durationSec: info.duration, transcriptState: .pending,
                createdAt: services.clock.now)
            try await services.tasks.save(note)
            voiceNotes.append(note)
            recordingSeconds = info.duration
            // Transcription keeps running after the panel closes (spec §5.2). Not awaited: the queue returns
            // only once the note is transcribed, and nothing here should wait for that (⌘⇧↩ waits, bounded, in
            // `saveAndSend`).
            let queue = services.transcriptionQueue
            Task.detached(priority: .utility) { await queue.enqueue(voiceNoteID: noteID) }
        } catch {
            report(error)
        }
        await modelStore?.refresh()
    }

    // MARK: - Saving

    /// `⌘↩`. Writes note, title, project and mode; assigning a project also makes the task `ready`.
    ///
    /// The row is re-read first and only the fields the panel owns are written back (note, project, mode,
    /// and the title while the user has not pinned one), so changes made elsewhere while the panel was open
    /// survive. The automatic title uses the latest transcripts, which may have arrived in the background.
    @discardableResult
    public func save() async -> Bool {
        guard let cached = task else { return false }
        if isRecording || recordingStop != nil { await stopRecording() }
        let now = services.clock.now
        do {
            guard var current = try await services.tasks.task(id: cached.id) else {
                lastError = "Görev bulunamadı."
                return false
            }
            guard current.status.isEditable else {
                lastError = "Çalışan bir görev düzenlenemez."
                return false
            }
            current.noteText = noteText
            current.mode = mode
            let notes = try await services.tasks.voiceNotes(taskID: current.id)
            voiceNotes = notes
            if !current.titleEditedByUser {
                let transcript = notes.compactMap(\.transcript)
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                current.title = TitleMaker.title(
                    noteText: noteText, transcript: transcript,
                    createdAt: current.createdAt)
            }
            current.updatedAt = now
            if let selectedProjectID {
                current.projectID = selectedProjectID
                if current.status == .inbox { try current.transition(to: .ready, at: now) }
            } else {
                // Without a project the task goes (back) to the inbox; it is never left `ready`.
                current = try ProjectAssignment.withoutProject(current, now: now)
            }
            try await services.tasks.save(current)
            task = current
        } catch {
            report(error)
            return false
        }
        if let selectedProjectID {
            settings.lastUsedProjectID = selectedProjectID.uuidString
        }
        return true
    }

    /// `⌘↩`. Writes everything and closes the panel. Plan 06's key monitor calls this directly, so the
    /// view does not need to sequence `save()` and `dismiss()` itself.
    public func saveAndClose() async {
        guard await save() else { return }
        close()
    }

    /// `⌘⇧↩`. Needs a project: a project-less task cannot be sent (spec §5.3).
    ///
    /// Final review C1: the task goes out only with usable text for every voice note. A transcript still on its
    /// way (the model is ready) is waited for after the panel has closed; the send then finishes in the
    /// background and a failure reaches `onSendFailure`. A missing model or a failed transcript is refused here,
    /// with the panel still open.
    public func saveAndSend() async {
        guard selectedProjectID != nil else {
            lastError = "Göndermek için bir proje seç."
            return
        }
        guard await save(), let current = task else { return }
        let gate = TranscriptGate(
            services: services, timeout: transcriptWaitTimeout, pollInterval: transcriptPollInterval)
        switch await gate.decide(taskID: current.id) {
        case .send:
            do {
                try await services.dispatcher.enqueue(taskID: current.id)
            } catch {
                report(error)
                return
            }
            close()
        case .refuse(let message):
            lastError = message
        case .wait:
            backgroundSend = Self.sendWhenTranscribed(
                taskID: current.id, fallbackTitle: current.title, gate: gate, services: services,
                onFailure: onSendFailure)
            close()
        }
    }

    /// Waits for the transcript, then enqueues; holds no reference to the (closed) panel's store.
    private static func sendWhenTranscribed(
        taskID: UUID, fallbackTitle: String, gate: TranscriptGate, services: AppServices,
        onFailure: ((String, String, UUID) -> Void)?
    ) -> Task<Void, Never> {
        Task {
            let outcome = await gate.waitForTranscripts(of: [taskID])[taskID] ?? .refuse(TranscriptGate.timeoutMessage)
            let failure: String?
            switch outcome {
            case .send:
                do {
                    try await services.dispatcher.enqueue(taskID: taskID)
                    failure = nil
                } catch let stateError as TaskStateError {
                    failure = LibraryStore.message(for: stateError)
                } catch {
                    failure = error.localizedDescription
                }
            case .refuse(let message):
                failure = message
            case .wait:
                failure = TranscriptGate.timeoutMessage
            }
            guard let failure else { return }
            // The title may have followed the transcript meanwhile.
            let title = (try? await services.tasks.task(id: taskID))?.title ?? fallbackTitle
            onFailure?(title, failure, taskID)
        }
    }

    /// "Zamanla…" in the panel footer.
    public func saveAndSchedule(at date: Date) async {
        guard selectedProjectID != nil else {
            lastError = "Zamanlamak için bir proje seç."
            return
        }
        guard await save(), var current = task else { return }
        current.scheduledAt = date
        do {
            try current.transition(to: .scheduled, at: services.clock.now)
            try await services.tasks.save(current)
            task = current
        } catch {
            report(error)
            return
        }
        close()
    }

    /// `Esc`. Nothing is written: the capture stays in the inbox with no project (spec §5.1 step 4).
    /// A recording in flight is still finished and stored so audio is never thrown away.
    /// Idempotent: Esc can arrive twice (the view's `.onExitCommand` and Plan 06's key monitor), and a
    /// second one must neither stop the recording again nor close the panel while the note is saved.
    public func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        if isRecording || recordingStop != nil {
            Task { [weak self] in
                await self?.stopRecording()
                self?.close()
            }
            return
        }
        close()
    }

    /// `onClose` fires at most once per panel, whichever path (Esc, ⌘↩, ⌘⇧↩, Zamanla) closes it.
    private func close() {
        levelTask?.cancel()
        levelTask = nil
        tickTask?.cancel()
        tickTask = nil
        guard !didClose else { return }
        didClose = true
        onClose?()
    }

    private func report(_ error: any Error) {
        if let stateError = error as? TaskStateError {
            lastError = LibraryStore.message(for: stateError)
        } else {
            lastError = error.localizedDescription
        }
    }
}
