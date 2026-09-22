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
    /// Saves of this task that have not returned yet; task-stream emissions are ignored meanwhile.
    @ObservationIgnored private var localWritesInFlight = 0

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
                    // While this store's own write of the row is in flight, an emission cannot be told
                    // apart from an echo of the row before that write; the write's own emission follows
                    // once it lands and carries the result.
                    guard self.localWritesInFlight == 0 else { continue }
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

    // MARK: - Text drafts

    /// An inspector text field that edits through a draft.
    public enum EditableField: Hashable, Sendable {
        case title
        case note
        case transcript(UUID)
    }

    /// Uncommitted text per field. A draft exists only while its field has edits that were not committed;
    /// otherwise the field shows the model value. Bindings write here on every keystroke, so typing never
    /// triggers a save and incoming model updates never rewrite text under the cursor.
    private var drafts: [EditableField: String] = [:]

    public var titleDraft: String { drafts[.title] ?? task?.title ?? "" }
    public var noteDraft: String { drafts[.note] ?? task?.noteText ?? "" }

    public func transcriptDraft(for voiceNoteID: UUID) -> String {
        drafts[.transcript(voiceNoteID)] ?? voiceNotes.first { $0.id == voiceNoteID }?.transcript ?? ""
    }

    public func editTitle(_ text: String) {
        guard isEditable else { return }
        drafts[.title] = text
    }

    public func editNote(_ text: String) {
        guard isEditable else { return }
        drafts[.note] = text
    }

    public func editTranscript(voiceNoteID: UUID, text: String) {
        drafts[.transcript(voiceNoteID)] = text
    }

    /// Normalises and persists one field's draft (on submit, when the field loses focus, and before any
    /// action that hands the task on). A no-op when the field has no uncommitted edits. The draft stays
    /// on screen until its write lands; keys typed meanwhile form a newer draft that is kept. When the
    /// task cannot take the text (it started running) the draft is kept and `lastError` says why.
    public func commit(_ field: EditableField) async {
        guard let text = drafts[field] else { return }
        let outcome: FieldWrite
        switch field {
        case .title: outcome = await writeTitle(text)
        case .note: outcome = await writeNote(text)
        case .transcript(let voiceNoteID): outcome = await writeTranscript(voiceNoteID: voiceNoteID, text: text)
        }
        switch outcome {
        case .saved, .missing:
            if drafts[field] == text { drafts[field] = nil }
        case .notEditable, .failed:
            break
        }
    }

    /// Commits every field with uncommitted edits (e.g. when the inspector goes away).
    public func commitDrafts() async {
        for field in Array(drafts.keys) {
            await commit(field)
        }
    }

    /// Forgets uncommitted text, e.g. for a task that is being deleted (committing it would re-insert the row).
    func discardDrafts() {
        drafts.removeAll()
    }

    // MARK: - Editing

    public func updateNote(_ text: String) async {
        await writeNote(text)
    }

    /// An empty title hands control back to `TitleMaker`; anything else pins the title.
    public func updateTitle(_ text: String) async {
        await writeTitle(text)
    }

    /// Spec §5.2: once the user edits a transcript it is never overwritten by the transcriber again.
    public func updateTranscript(voiceNoteID: UUID, text: String) async {
        await writeTranscript(voiceNoteID: voiceNoteID, text: text)
    }

    /// What happened to a single-field write.
    private enum FieldWrite {
        case saved, missing, notEditable, failed
    }

    /// Applies one field's change to a fresh read of the row and saves it, so a stale cached copy never
    /// overwrites a newer status or project (e.g. after a teardown) and a deleted row is never re-inserted
    /// (`save` is an upsert). A task that is no longer editable is left alone and reported.
    private func writeField(notEditableMessage: String, _ change: (inout ShotTask) -> Void) async -> FieldWrite {
        let fresh: ShotTask
        do {
            guard let row = try await services.tasks.task(id: taskID) else { return .missing }
            fresh = row
        } catch {
            report(error)
            return .failed
        }
        guard fresh.status.isEditable else {
            task = fresh
            lastError = notEditableMessage
            return .notEditable
        }
        var updated = fresh
        change(&updated)
        updated.updatedAt = services.clock.now
        return await save(updated) ? .saved : .failed
    }

    @discardableResult
    private func writeNote(_ text: String) async -> FieldWrite {
        await writeField(notEditableMessage: "Görev çalışırken not kaydedilemedi.") { task in
            task.noteText = text
            if !task.titleEditedByUser {
                task.title = TitleMaker.title(noteText: text, transcript: firstTranscript, createdAt: task.createdAt)
            }
        }
    }

    @discardableResult
    private func writeTitle(_ text: String) async -> FieldWrite {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return await writeField(notEditableMessage: "Görev çalışırken başlık kaydedilemedi.") { task in
            if trimmed.isEmpty {
                task.titleEditedByUser = false
                task.title = TitleMaker.title(
                    noteText: task.noteText, transcript: firstTranscript, createdAt: task.createdAt)
            } else {
                task.titleEditedByUser = true
                task.title = trimmed
            }
        }
    }

    /// Writes the voice-note row from a fresh read; the auto title then follows the transcript when the
    /// task has no written note, is not pinned and is still editable.
    @discardableResult
    private func writeTranscript(voiceNoteID: UUID, text: String) async -> FieldWrite {
        do {
            let notes = try await services.tasks.voiceNotes(taskID: taskID)
            guard var note = notes.first(where: { $0.id == voiceNoteID }) else { return .missing }
            note.transcript = text
            note.editedByUser = true
            note.transcriptState = .done
            try await services.tasks.save(note)
            voiceNotes = try await services.tasks.voiceNotes(taskID: taskID)
        } catch {
            report(error)
            return .failed
        }
        syncTranscriptPolling()
        if let fresh = try? await services.tasks.task(id: taskID), fresh.status.isEditable, !fresh.titleEditedByUser,
            fresh.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            var updated = fresh
            updated.title = TitleMaker.title(noteText: "", transcript: text, createdAt: fresh.createdAt)
            updated.updatedAt = services.clock.now
            await save(updated)
        }
        return .saved
    }

    public func setMode(_ mode: TaskMode) async {
        await commitDrafts()
        guard var current = task, current.status.isEditable else { return }
        current.mode = mode
        current.updatedAt = services.clock.now
        await save(current)
    }

    public func setModelOverride(_ model: String?) async {
        await commitDrafts()
        guard var current = task, current.status.isEditable else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        current.modelOverride = (trimmed?.isEmpty ?? true) ? nil : trimmed
        current.updatedAt = services.clock.now
        await save(current)
    }

    public func setProject(_ projectID: UUID?) async {
        await commitDrafts()
        guard var current = task, current.status.isEditable else { return }
        let now = services.clock.now
        guard let projectID else {
            // Clearing the project never strands the task (`ProjectAssignment`).
            do {
                if let detached = try await ProjectAssignment.detach(taskID: taskID, services: services) {
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
    //
    // Every action first commits the drafts: on macOS a click on a button does not take focus from a
    // text view, so no focus-loss commit has run, and the task must not be handed on without the text.

    public func sendNow() async {
        await commitDrafts()
        do {
            try await services.dispatcher.enqueue(taskID: taskID)
        } catch {
            report(error)
        }
    }

    public func schedule(at date: Date) async {
        await commitDrafts()
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
        await commitDrafts()
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
        await commitDrafts()
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
        await commitDrafts()
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
        await commitDrafts()
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

    /// Shows the change at once, then persists it; a failed save rolls the change back unless something
    /// newer has replaced it meanwhile. Task-stream emissions are ignored while the write is in flight.
    @discardableResult
    private func save(_ updated: ShotTask) async -> Bool {
        let previous = task
        task = updated
        localWritesInFlight += 1
        defer { localWritesInFlight -= 1 }
        do {
            try await services.tasks.save(updated)
            return true
        } catch {
            if task == updated { task = previous }
            report(error)
            return false
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
