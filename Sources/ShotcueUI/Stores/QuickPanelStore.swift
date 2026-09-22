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

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNoteID: UUID?
    @ObservationIgnored private var pendingRelPath: String?

    /// The level meter ticks at 200 ms, which is also the recording timer's resolution.
    static let tick: Duration = .milliseconds(200)
    static let tickSeconds: Double = 0.2

    public init(services: AppServices, settings: SettingsStore) {
        self.services = services
        self.settings = settings
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
    }

    // MARK: - Derived

    public var canSave: Bool { task != nil }

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
        if isRecording {
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
        levelTask = Task { [weak self] in
            guard let self else { return }
            for await value in self.services.recorder.levels {
                guard self.isRecording else { return }
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

    private func stopRecording() async {
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
            // Transcription keeps running after the panel closes (spec §5.2).
            await services.transcriptionQueue.enqueue(voiceNoteID: note.id)
        } catch {
            report(error)
        }
    }

    // MARK: - Saving

    /// `⌘↩`. Writes note, title, project and mode; assigning a project also makes the task `ready`.
    @discardableResult
    public func save() async -> Bool {
        guard var current = task else { return false }
        if isRecording { await stopRecording() }
        let now = services.clock.now
        current.noteText = noteText
        current.mode = mode
        current.projectID = selectedProjectID
        if !current.titleEditedByUser {
            let transcript = voiceNotes.compactMap(\.transcript).first
            current.title = TitleMaker.title(
                noteText: noteText, transcript: transcript,
                createdAt: current.createdAt)
        }
        current.updatedAt = now
        if selectedProjectID != nil, current.status == .inbox {
            do {
                try current.transition(to: .ready, at: now)
            } catch {
                report(error)
                return false
            }
        }
        do {
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
    public func saveAndSend() async {
        guard selectedProjectID != nil else {
            lastError = "Göndermek için bir proje seç."
            return
        }
        guard await save(), let current = task else { return }
        do {
            try await services.dispatcher.enqueue(taskID: current.id)
        } catch {
            report(error)
            return
        }
        close()
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
    public func dismiss() {
        if isRecording {
            Task { [weak self] in
                await self?.stopRecording()
                self?.close()
            }
            return
        }
        close()
    }

    private func close() {
        levelTask?.cancel()
        levelTask = nil
        tickTask?.cancel()
        tickTask = nil
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
