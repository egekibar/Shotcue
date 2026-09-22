import AppKit
import Foundation
import Observation
import ShotcueCore

/// Backs the task inspector (spec §5.4): images, title, note, transcript, project, mode, model,
/// scheduling, run history, the live/recorded run log and the handoff actions.
@MainActor
@Observable
public final class TaskDetailStore {
    public let taskID: UUID

    public private(set) var task: ShotTask?
    public private(set) var captures: [Capture] = []
    public private(set) var voiceNotes: [VoiceNote] = []
    public private(set) var runs: [Run] = []
    public private(set) var projects: [Project] = []
    /// Events of the run currently in flight, newest last. Grows while the run streams.
    public private(set) var liveEvents: [RunEvent] = []
    /// Events replayed from `runs/<id>.jsonl` for a finished run.
    public private(set) var selectedRunEvents: [RunEvent] = []
    public private(set) var selectedRunID: UUID?

    public var scheduleDate: Date
    public var isSchedulePresented = false
    public var lastError: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var streams: [Task<Void, Never>] = []
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// The run whose live events stream into `liveEvents`. Observed: `displayedEvents` depends on it.
    private var liveRunID: UUID?
    /// Bumped by every `start()` and `stop()`. A `start()` whose reload outlived a `stop()` (or a newer
    /// `start()`) sees a different value and does not subscribe, so no stream outlives the store's use.
    @ObservationIgnored private var generation = 0
    /// Between `start()` and `stop()`. The live-event subscription is only opened while started.
    @ObservationIgnored private var isStarted = false
    /// Bumped whenever the displayed run changes; a replay that finishes under an older token is dropped.
    @ObservationIgnored private var selectionToken = 0
    /// How often voice notes are re-read while a transcript is pending. GRDB's task observation does not see
    /// voice-note writes, so a transcript finishing in the background only shows up through this poll.
    /// Internal so tests can shorten it.
    @ObservationIgnored var transcriptPollInterval: Duration = .milliseconds(1500)
    @ObservationIgnored private var transcriptPollTask: Task<Void, Never>?

    /// Whether the pending-transcript poll is running (test hook).
    var isPollingTranscripts: Bool { transcriptPollTask != nil }

    public init(services: AppServices, taskID: UUID) {
        self.services = services
        self.taskID = taskID
        self.scheduleDate = services.clock.now.addingTimeInterval(3600)
    }

    // MARK: - Lifecycle

    /// Loads the task with its attachments, then subscribes to the task and run streams.
    ///
    /// Stream loops hold the store weakly and re-bind `self` per element, so a store that is dropped
    /// without `stop()` is not kept alive by a stream that never ends.
    public func start() async {
        // A start whose task was cancelled before it ran (the library already dropped this store) is a no-op.
        guard !Task.isCancelled else { return }
        generation += 1
        let startGeneration = generation
        isStarted = true
        await reload()
        guard startGeneration == generation, !Task.isCancelled, streams.isEmpty else { return }
        let runStream = services.runs.observeRuns(taskID: taskID)
        let taskStream = services.tasks.observeAllTasks()
        let projectStream = services.projects.observeProjects()
        streams.append(
            Task { [weak self] in
                for await list in runStream {
                    guard let self else { return }
                    self.runs = list.sorted { $0.startedAt > $1.startedAt }
                    self.syncLiveSubscription()
                }
            })
        streams.append(
            Task { [weak self] in
                for await list in taskStream {
                    guard let self else { return }
                    guard let updated = list.first(where: { $0.id == self.taskID }) else { continue }
                    self.task = updated
                    // Captures and voice notes have no stream of their own: re-read them on every emission.
                    await self.refreshAttachments()
                }
            })
        streams.append(
            Task { [weak self] in
                for await list in projectStream {
                    guard let self else { return }
                    self.projects = list
                }
            })
    }

    public func stop() {
        generation += 1
        isStarted = false
        for stream in streams { stream.cancel() }
        streams.removeAll()
        liveTask?.cancel()
        liveTask = nil
        liveRunID = nil
        syncTranscriptPolling()
    }

    public func reload() async {
        do {
            task = try await services.tasks.task(id: taskID)
            captures = try await services.tasks.captures(taskID: taskID)
            voiceNotes = try await services.tasks.voiceNotes(taskID: taskID)
            runs = try await services.runs.runs(taskID: taskID).sorted { $0.startedAt > $1.startedAt }
            projects = try await services.projects.allProjects()
            if let scheduled = task?.scheduledAt { scheduleDate = scheduled }
            syncLiveSubscription()
            syncTranscriptPolling()
        } catch {
            report(error)
        }
    }

    /// Re-reads captures and voice notes, which the task stream does not carry.
    private func refreshAttachments() async {
        do {
            captures = try await services.tasks.captures(taskID: taskID)
            voiceNotes = try await services.tasks.voiceNotes(taskID: taskID)
        } catch {
            report(error)
        }
        syncTranscriptPolling()
    }

    /// Polls voice notes every `transcriptPollInterval` while one is `pending` and the store is started;
    /// stops by itself once none is pending. Read failures are skipped silently (the next tick retries).
    private func syncTranscriptPolling() {
        guard isStarted, voiceNotes.contains(where: { $0.transcriptState == .pending }) else {
            transcriptPollTask?.cancel()
            transcriptPollTask = nil
            return
        }
        guard transcriptPollTask == nil else { return }
        transcriptPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.transcriptPollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if let notes = try? await self.services.tasks.voiceNotes(taskID: self.taskID) {
                    guard !Task.isCancelled else { return }
                    self.voiceNotes = notes
                }
                self.syncTranscriptPolling()
            }
        }
    }

    // MARK: - Derived

    public var project: Project? {
        guard let id = task?.projectID else { return nil }
        return projects.first { $0.id == id }
    }

    public var activeRun: Run? {
        runs.first { $0.state == .starting || $0.state == .running }
    }

    public var latestRun: Run? { runs.first }

    /// The claude session id to resume: `run.id` doubles as `--session-id` (spec §6.3).
    public var sessionID: String? { latestRun?.id.uuidString }

    /// What `RunLogView` renders: the live stream while the selected run is the live one, otherwise the
    /// selected run's replay (which keeps an ended live run's events on screen).
    public var displayedEvents: [RunEvent] {
        isDisplayingLiveRun ? liveEvents : selectedRunEvents
    }

    /// True while the selected run is the one streaming live events (the log then auto-scrolls).
    public var isDisplayingLiveRun: Bool {
        guard let liveRunID else { return false }
        return selectedRunID == liveRunID
    }

    public var isEditable: Bool { task?.status.isEditable ?? false }

    public var canSend: Bool {
        guard let task else { return false }
        return task.projectID != nil && task.status.canTransition(to: .queued)
    }

    public var canCancel: Bool {
        guard let task else { return false }
        return task.status == .running || task.status == .queued || task.status == .scheduled
    }

    public var firstTranscript: String? {
        voiceNotes.compactMap(\.transcript).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func absoluteURL(for relPath: String) -> URL {
        services.fileStore.absoluteURL(for: relPath)
    }

    // MARK: - Editing

    public func updateNote(_ text: String) async {
        guard var current = task, current.status.isEditable else { return }
        current.noteText = text
        if !current.titleEditedByUser {
            current.title = TitleMaker.title(
                noteText: text, transcript: firstTranscript,
                createdAt: current.createdAt)
        }
        current.updatedAt = services.clock.now
        await save(current)
    }

    /// An empty title hands control back to `TitleMaker`; anything else pins the title.
    public func updateTitle(_ text: String) async {
        guard var current = task, current.status.isEditable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            current.titleEditedByUser = false
            current.title = TitleMaker.title(
                noteText: current.noteText, transcript: firstTranscript,
                createdAt: current.createdAt)
        } else {
            current.titleEditedByUser = true
            current.title = trimmed
        }
        current.updatedAt = services.clock.now
        await save(current)
    }

    /// Spec §5.2: once the user edits a transcript it is never overwritten by the transcriber again.
    public func updateTranscript(voiceNoteID: UUID, text: String) async {
        guard var note = voiceNotes.first(where: { $0.id == voiceNoteID }) else { return }
        note.transcript = text
        note.editedByUser = true
        note.transcriptState = .done
        do {
            try await services.tasks.save(note)
            voiceNotes = try await services.tasks.voiceNotes(taskID: taskID)
        } catch {
            report(error)
            return
        }
        syncTranscriptPolling()
        // The auto title falls back to the transcript when there is no written note.
        if var current = task, !current.titleEditedByUser,
            current.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            current.title = TitleMaker.title(noteText: "", transcript: text, createdAt: current.createdAt)
            current.updatedAt = services.clock.now
            await save(current)
        }
    }

    public func setMode(_ mode: TaskMode) async {
        guard var current = task, current.status.isEditable else { return }
        current.mode = mode
        current.updatedAt = services.clock.now
        await save(current)
    }

    public func setModelOverride(_ model: String?) async {
        guard var current = task, current.status.isEditable else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        current.modelOverride = (trimmed?.isEmpty ?? true) ? nil : trimmed
        current.updatedAt = services.clock.now
        await save(current)
    }

    public func setProject(_ projectID: UUID?) async {
        guard var current = task, current.status.isEditable else { return }
        let now = services.clock.now
        guard let projectID else {
            // Clearing the project never strands the task (`ProjectAssignment`).
            do {
                if let detached = try await ProjectAssignment.detach(taskID: taskID, services: services, now: now) {
                    task = detached
                }
            } catch {
                report(error)
            }
            return
        }
        let cameFromInbox = current.projectID == nil
        current.projectID = projectID
        current.updatedAt = now
        if cameFromInbox, current.status == .inbox {
            do {
                try current.transition(to: .ready, at: now)
            } catch {
                report(error)
                return
            }
        }
        await save(current)
    }

    // MARK: - Dispatch

    public func sendNow() async {
        do {
            try await services.dispatcher.enqueue(taskID: taskID)
        } catch {
            report(error)
        }
    }

    public func schedule(at date: Date) async {
        guard var current = task else { return }
        current.scheduledAt = date
        do {
            try current.transition(to: .scheduled, at: services.clock.now)
        } catch {
            report(error)
            return
        }
        scheduleDate = date
        await save(current)
    }

    public func unschedule() async {
        guard var current = task, current.status == .scheduled || current.status == .queued else { return }
        do {
            try current.transition(to: .ready, at: services.clock.now)
        } catch {
            report(error)
            return
        }
        await save(current)
    }

    public func cancel() async {
        await services.dispatcher.cancel(taskID: taskID)
    }

    /// Whether "Günlük kuyruğa al" can do something: the task has a project and an edge to `ready`.
    public var canAddToDailyQueue: Bool {
        guard let task, task.projectID != nil, task.status != .ready else { return false }
        return task.status.canTransition(to: .ready)
    }

    /// "Günlük kuyruğa al" (spec §6.5): makes the task `ready` so the project's daily queue picks it up.
    /// Mirrors `LibraryStore.addToDailyQueue(taskIDs:)`; a queued task leaves the queue through the
    /// dispatcher, which owns the queue.
    public func addToDailyQueue() async {
        guard var current = task, current.status != .ready else { return }
        guard current.projectID != nil else {
            lastError = "Günlük kuyruğa almak için önce bir proje seç."
            return
        }
        guard current.status.canTransition(to: .ready) else {
            lastError = "\(StatusPresentation.label(for: current.status)) durumundaki görev günlük kuyruğa alınamaz."
            return
        }
        if current.status == .queued {
            await services.dispatcher.cancel(taskID: taskID)
            do {
                guard let fresh = try await services.tasks.task(id: taskID) else { return }
                current = fresh
            } catch {
                report(error)
                return
            }
            // The dispatcher already moved it to `ready`; or it started running meanwhile.
            guard current.status != .ready, current.status.canTransition(to: .ready) else {
                task = current
                return
            }
        }
        do {
            try current.transition(to: .ready, at: services.clock.now)
        } catch {
            report(error)
            return
        }
        await save(current)
    }

    /// "Yeniden çalıştır": failed/cancelled/done all have an edge to `queued`.
    public func retry() async {
        do {
            try await services.dispatcher.enqueue(taskID: taskID)
        } catch {
            report(error)
        }
    }

    // MARK: - Handoff

    public func openInTerminal() async {
        guard let sessionID else {
            lastError = "Devam ettirilecek bir oturum yok."
            return
        }
        do { try services.handoff.openInTerminal(sessionID: sessionID) } catch { report(error) }
    }

    public func openInDesktop() async {
        guard let sessionID else {
            lastError = "Devam ettirilecek bir oturum yok."
            return
        }
        do { try services.handoff.openInDesktop(sessionID: sessionID) } catch { report(error) }
    }

    /// Builds the same prompt the runner would send and opens it in Claude Desktop's composer.
    public func openComposer() async {
        guard task != nil else { return }
        let files = captures.map { services.fileStore.absoluteURL(for: $0.relPath).path }
        do {
            try services.handoff.openDesktopComposer(
                prompt: composerPrompt(),
                projectPath: project?.path ?? "",
                files: files)
        } catch {
            report(error)
        }
    }

    /// Pure, so a test can read the prompt without touching the handoff service.
    public func composerPrompt() -> String {
        guard let task else { return "" }
        let input = PromptInput(
            mode: task.mode,
            title: task.title,
            projectPath: project?.path ?? "",
            screenshots: captures.map {
                ScreenshotRef(absolutePath: services.fileStore.absoluteURL(for: $0.relPath).path)
            },
            noteText: task.noteText,
            transcripts: voiceNotes.compactMap(\.transcript))
        return PromptBuilder.build(input)
    }

    // MARK: - Attachments

    /// `⌘C` on a capture. Returns false when the PNG is missing instead of trapping.
    @discardableResult
    public func copyImage(captureID: UUID) -> Bool {
        guard let capture = captures.first(where: { $0.id == captureID }),
            let image = NSImage(contentsOf: services.fileStore.absoluteURL(for: capture.relPath))
        else {
            lastError = "Görsel dosyası bulunamadı."
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    public func revealInFinder(captureID: UUID) {
        guard let capture = captures.first(where: { $0.id == captureID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            [services.fileStore.absoluteURL(for: capture.relPath)])
    }

    /// Plays the recording in the system player; ShotcueUI never links AVFoundation.
    public func openAudio(voiceNoteID: UUID) {
        guard let note = voiceNotes.first(where: { $0.id == voiceNoteID }) else { return }
        NSWorkspace.shared.open(services.fileStore.absoluteURL(for: note.relPath))
    }

    public func retranscribe(voiceNoteID: UUID) async {
        guard var note = voiceNotes.first(where: { $0.id == voiceNoteID }) else { return }
        note.transcriptState = .pending
        note.editedByUser = false
        do {
            try await services.tasks.save(note)
            voiceNotes = try await services.tasks.voiceNotes(taskID: taskID)
        } catch {
            report(error)
            return
        }
        syncTranscriptPolling()
        await services.transcriptionQueue.enqueue(voiceNoteID: voiceNoteID)
    }

    // MARK: - Run log

    /// Shows a run's log: the live events for the live run, otherwise the parsed `runs/<id>.jsonl`.
    /// A replay that finishes after the selection moved on is discarded.
    public func selectRun(_ runID: UUID?) async {
        selectionToken += 1
        let token = selectionToken
        selectedRunID = runID
        guard let runID, let run = runs.first(where: { $0.id == runID }) else {
            selectedRunEvents = []
            return
        }
        guard runID != liveRunID else { return }
        let events = await replay(logRelPath: run.logRelPath)
        guard token == selectionToken else { return }
        selectedRunEvents = events
    }

    /// Reads a run log's lines off the main actor. Internal seam: tests substitute a slow reader to prove a
    /// stale replay cannot overwrite a newer selection.
    @ObservationIgnored var logLineReader: @Sendable (URL) async -> [String] = { url in
        await Task.detached(priority: .utility) { () -> [String] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.components(separatedBy: "\n")
        }.value
    }

    /// Reads and parses the NDJSON log. Unparsable lines are skipped (spec §6.4).
    private func replay(logRelPath: String) async -> [RunEvent] {
        let lines = await logLineReader(services.fileStore.absoluteURL(for: logRelPath))
        return lines.compactMap { StreamJSONParser.parse(line: $0) }
    }

    /// Subscribes to `liveEvents(runID:)` when a run starts and tears the subscription down when it ends.
    private func syncLiveSubscription() {
        guard isStarted, let active = activeRun else {
            endLiveSubscription()
            return
        }
        guard liveRunID != active.id else { return }
        liveTask?.cancel()
        liveRunID = active.id
        liveEvents = []
        selectionToken += 1
        selectedRunID = active.id
        let events = services.dispatcher.liveEvents(runID: active.id)
        liveTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.liveEvents.append(event)
            }
        }
    }

    /// The live run ended (or the store stopped). If it was on screen, its streamed events stay there, and
    /// the complete log file then replaces them unless the selection moved on meanwhile (the stream may
    /// have missed events from before the subscription, or the final result line).
    private func endLiveSubscription() {
        liveTask?.cancel()
        liveTask = nil
        guard let ended = liveRunID else { return }
        liveRunID = nil
        guard selectedRunID == ended else { return }
        selectionToken += 1
        let token = selectionToken
        selectedRunEvents = liveEvents
        guard isStarted, let logRelPath = runs.first(where: { $0.id == ended })?.logRelPath else { return }
        Task { [weak self] in
            guard let self else { return }
            let replayed = await self.replay(logRelPath: logRelPath)
            guard token == self.selectionToken, !replayed.isEmpty else { return }
            self.selectedRunEvents = replayed
        }
    }

    // MARK: - Plumbing

    private func save(_ updated: ShotTask) async {
        do {
            try await services.tasks.save(updated)
            task = updated
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        if let stateError = error as? TaskStateError {
            lastError = LibraryStore.message(for: stateError)
        } else {
            lastError = error.localizedDescription
        }
    }
}
