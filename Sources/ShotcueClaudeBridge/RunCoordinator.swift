import Foundation
import ShotcueCore

/// Owns the run queue (spec §5.5, §6.4): at most one run per project, a global concurrency limit,
/// git snapshots around every run, the NDJSON log, notifications and the live event stream.
/// All time decisions live in `SchedulerRules`/`QueuePolicy`; this actor only applies them.
public actor RunCoordinator: TaskDispatcher {
    private struct InFlight: Sendable {
        var runID: UUID
        var projectID: UUID
        /// Set after the last coordinator-side cancel check, when the run is committed to `runner.run`.
        /// Before that a cancel is handled here (`pendingCancels`); after it the runner's own pre-launch
        /// check makes sure a cancelled run never starts claude.
        var launched = false
    }

    private let runner: any ClaudeRunner
    private let taskRepository: any TaskRepository
    private let projectRepository: any ProjectRepository
    private let runRepository: any RunRepository
    private let gitInspector: any GitInspector
    private let fileStore: FileStore
    private let notifier: any Notifier
    private let clock: any Clock
    private let logWriter: RunLogWriter

    /// One broadcaster per run in flight: registered in `start(_:)`, removed when the run ends.
    /// Outside actor isolation so the nonisolated `liveEvents` and the runner's @Sendable
    /// event callback can reach it.
    private let broadcasters = LockBox<[UUID: RunEventBroadcaster]>([:])

    private var settings: RunSettings
    private var paused = false
    /// Nothing starts until `resumeQueue()` (final review I1): at launch the app first marks the runs the last
    /// session left behind, so no run can start before recovery and be taken for one of them.
    private var queueHeld: Bool
    private var inFlight: [UUID: InFlight] = [:]
    /// Run ids cancelled while in flight but not launched yet (the git phase, for instance).
    private var pendingCancels: Set<UUID> = []
    private var activities: [UUID: any NSObjectProtocol] = [:]

    public init(
        runner: any ClaudeRunner, taskRepository: any TaskRepository,
        projectRepository: any ProjectRepository, runRepository: any RunRepository,
        gitInspector: any GitInspector, fileStore: FileStore, notifier: any Notifier,
        clock: any Clock, settings: RunSettings, holdsQueueUntilResumed: Bool = false
    ) {
        self.runner = runner
        self.taskRepository = taskRepository
        self.projectRepository = projectRepository
        self.runRepository = runRepository
        self.gitInspector = gitInspector
        self.fileStore = fileStore
        self.notifier = notifier
        self.clock = clock
        self.settings = settings
        self.queueHeld = holdsQueueUntilResumed
        self.logWriter = RunLogWriter(fileStore: fileStore)
    }

    // MARK: - TaskDispatcher

    public func enqueue(taskID: UUID) async throws {
        guard var task = try await taskRepository.task(id: taskID) else { return }
        try task.transition(to: .queued, at: clock.now)
        try await taskRepository.save(task)
        await pumpQueue()
    }

    public func cancel(taskID: UUID) async {
        if let flight = inFlight[taskID] {
            if flight.launched {
                await runner.cancel(runID: flight.runID)
            } else {
                pendingCancels.insert(flight.runID)
            }
            return
        }
        guard let task = try? await taskRepository.task(id: taskID),
            task.status == .queued || task.status == .scheduled
        else { return }
        await apply(.ready, toTask: task.id)
    }

    public func runQueueNow() async {
        let ready = (try? await taskRepository.tasks(status: .ready)) ?? []
        for task in QueuePolicy.ordered(ready) where task.projectID != nil {
            try? await enqueue(taskID: task.id)
        }
        await pumpQueue()
    }

    public func setPaused(_ paused: Bool) async {
        self.paused = paused
        if !paused { await pumpQueue() }
    }

    public func isPaused() async -> Bool { paused }

    public nonisolated func liveEvents(runID: UUID) -> AsyncStream<RunEvent> {
        // Unknown, already finished, or from an earlier launch: an empty, already-finished stream.
        guard let broadcaster = broadcasters.withLock({ $0[runID] }) else {
            return AsyncStream { $0.finish() }
        }
        return broadcaster.stream()
    }

    // MARK: - App-facing extras

    /// Applies the Claude settings to the next runs, then starts whatever a raised limit now allows.
    public func updateSettings(_ settings: RunSettings) async {
        self.settings = settings
        await pumpQueue()
    }

    /// Starts the queue (final review I1): tasks queued before a quit or crash, and anything queued since launch,
    /// start now. The app calls it after `recoverInterruptedRuns()`, and only once `claude` is known to exist, so
    /// with `claude` missing queued tasks stay queued instead of each failing with "not found".
    public func resumeQueue() async {
        queueHeld = false
        await pumpQueue()
    }

    /// Launch recovery (spec §8): runs left `starting`/`running` by a crash become `failed`. A task left
    /// `running` without any active run (a stale whole-row write, or a run row that was never saved) becomes
    /// `failed` too, with a run row of its own that says so — otherwise it could be neither cancelled nor
    /// deleted nor rerun. Returns how many runs were marked.
    public func recoverInterruptedRuns() async throws -> Int {
        let stale = try await runRepository.activeRuns()
        var count = try await runRepository.markInterruptedRuns(at: clock.now)
        for run in stale {
            guard let task = try await taskRepository.task(id: run.taskID), task.status == .running else { continue }
            await apply(.failed, toTask: task.id)
        }
        let staleTaskIDs = Set(stale.map(\.taskID))
        for task in try await taskRepository.tasks(status: .running) where !staleTaskIDs.contains(task.id) {
            let now = clock.now
            let runID = UUID()
            let repair = Run(
                id: runID, taskID: task.id, state: .failed, startedAt: now, finishedAt: now,
                error: RunErrorCode.interrupted, logRelPath: fileStore.runLogRelPath(id: runID))
            try await runRepository.save(repair)
            await apply(.failed, toTask: task.id)
            count += 1
        }
        return count
    }

    // MARK: - Queue

    private func pumpQueue() async {
        guard !paused, !queueHeld else { return }
        while true {
            let queued = ((try? await taskRepository.tasks(status: .queued)) ?? [])
                .filter { inFlight[$0.id] == nil }
            guard
                let next = QueuePolicy.nextRunnable(
                    queued: queued,
                    runningProjectIDs: Set(inFlight.values.map(\.projectID)),
                    runningCount: inFlight.count,
                    maxConcurrent: settings.maxConcurrent)
            else { return }
            guard start(next) else { return }
        }
    }

    /// Registers the run without suspending, so a reentrant `pumpQueue` cannot double-start it.
    private func start(_ task: ShotTask) -> Bool {
        guard let projectID = task.projectID else { return false }
        let runID = UUID()
        inFlight[task.id] = InFlight(runID: runID, projectID: projectID)
        // Registered before anything can learn the run id; `perform` removes it on every exit.
        broadcasters.withLock { $0[runID] = RunEventBroadcaster() }
        Task { await self.execute(taskID: task.id, runID: runID) }
        return true
    }

    private func finishInFlight(_ taskID: UUID) async {
        inFlight[taskID] = nil
        await pumpQueue()
    }

    // MARK: - One run

    /// One attempt at a queued task. Whatever `perform` does, the slot is released and the queue pumped.
    private func execute(taskID: UUID, runID: UUID) async {
        await perform(taskID: taskID, runID: runID)
        pendingCancels.remove(runID)
        await finishInFlight(taskID)
    }

    private func perform(taskID: UUID, runID: UUID) async {
        // Every exit ends the live stream, the paths that never reach claude included.
        defer { closeLiveEvents(runID) }
        // The row is gone, or it lost its project (never runnable, so the queue cannot pick it again):
        // there is nothing to run and nothing to report.
        guard let queued = try? await taskRepository.task(id: taskID), let projectID = queued.projectID else {
            return
        }
        var run = Run(
            id: runID, taskID: taskID, state: .starting, startedAt: clock.now,
            logRelPath: fileStore.runLogRelPath(id: runID))
        try? await runRepository.save(run)

        // A missing or unreadable project row must not leave the task queued: the queue would pick it
        // again at once, forever.
        let project: Project
        do {
            guard let found = try await projectRepository.project(id: projectID) else {
                await failBeforeLaunch(&run, title: queued.title, message: Self.missingProjectRecordMessage)
                return
            }
            project = found
        } catch {
            await failBeforeLaunch(&run, title: queued.title, message: Self.unreadableProjectMessage(error))
            return
        }

        // Spec §8: a moved or deleted project directory must not start a run at all.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            await failBeforeLaunch(&run, title: queued.title, message: Self.missingProjectMessage(path: project.path))
            return
        }

        if pendingCancels.contains(runID) {
            await cancelBeforeLaunch(&run)
            return
        }
        // Final review C1: the voice note is the main instruction channel, so claude never starts while one
        // of the task's notes has no usable text. Checked before the git steps, so a refusal leaves the
        // working tree as it was.
        if let refusal = await voiceNoteRefusal(taskID: taskID) {
            await failBeforeLaunch(&run, title: queued.title, error: refusal.code, message: refusal.message)
            return
        }
        if project.runInBranch {
            do {
                try await gitInspector.createBranch(GitOutputParser.branchName(for: taskID), at: project.path)
            } catch {
                run.error = "branch: \(error)"
            }
        }
        if project.stashBeforeRun {
            do {
                try await gitInspector.stashAll(at: project.path)
            } catch {
                run.error = [run.error, "stash: \(error)"].compactMap { $0 }.joined(separator: " | ")
            }
        }
        let before = await gitInspector.snapshot(at: project.path)
        run.gitHeadBefore = before?.head
        run.gitDirtyBefore = before?.isDirty
        run.gitBranch = before?.branch

        // Last coordinator-side check (the git phase can take a while); no suspension between it and
        // `launched`, so a cancel lands either here or with the runner.
        if pendingCancels.contains(runID) {
            await cancelBeforeLaunch(&run)
            return
        }
        inFlight[taskID]?.launched = true

        // `running` goes onto a fresh copy of the row. If the row refuses it (deleted, or moved on
        // meanwhile), claude is not started. The spec is built from that same fresh row.
        guard let running = await apply(.running, toTask: taskID) else {
            run.state = .cancelled
            run.finishedAt = clock.now
            run.error = Self.taskChangedBeforeLaunchMessage
            try? await runRepository.save(run)
            return
        }
        let spec = await makeSpec(task: running, project: project, runID: runID)
        run.state = .running
        try? await runRepository.save(run)

        let writer = logWriter
        let broadcaster = broadcasters.withLock { $0[runID] }
        let onEvent: @Sendable (RunEvent) -> Void = { event in
            try? writer.append(event, runID: runID)
            broadcaster?.send(event)
        }
        if settings.keepAwake {
            activities[runID] = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Shotcue run \(runID.uuidString)")
        }

        let outcome: Result<ClaudeRunResult, any Error>
        do {
            outcome = .success(try await runner.run(spec, onEvent: onEvent))
        } catch {
            outcome = .failure(error)
        }

        if let activity = activities.removeValue(forKey: runID) {
            ProcessInfo.processInfo.endActivity(activity)
        }

        run.finishedAt = clock.now
        run.gitHeadAfter = await gitInspector.snapshot(at: project.path)?.head
        let notification = await record(outcome: outcome, into: &run, title: running.title)
        try? await runRepository.save(run)
        if let notification { await notifier.notify(notification) }
    }

    /// The run never started (spec §8): the Run row says why (`error`), the task goes back to `ready` (the
    /// task never entered `running`; fix the cause and resend) and the user is told (`message`).
    private func failBeforeLaunch(_ run: inout Run, title: String, error: String? = nil, message: String) async {
        run.state = .failed
        run.finishedAt = clock.now
        run.error = error ?? message
        let task = await apply(.ready, toTask: run.taskID)
        try? await runRepository.save(run)
        await notifier.notify(
            AppNotification(
                kind: .runFailed, title: task?.title ?? title, body: message, taskID: run.taskID, runID: run.id))
    }

    /// Why the task's voice notes keep the run from starting, or nil when every note has usable text.
    /// Notes that cannot be read also refuse: the run could not show that it carries them.
    private func voiceNoteRefusal(taskID: UUID) async -> (code: String, message: String)? {
        let notes: [VoiceNote]
        do {
            notes = try await taskRepository.voiceNotes(taskID: taskID)
        } catch {
            return (RunErrorCode.voiceNotesUnreadable, Self.voiceNotesUnreadableMessage)
        }
        switch VoiceNoteReadiness.of(notes) {
        case .ready: return nil
        case .pending: return (RunErrorCode.voiceNotePending, Self.voiceNotePendingMessage)
        case .failed: return (RunErrorCode.voiceNoteFailed, Self.voiceNoteFailedMessage)
        }
    }

    /// Cancelled before claude was started: the Run row is cancelled, the task (never `running`) goes back
    /// to `ready`, and nobody is notified — the user asked for it.
    private func cancelBeforeLaunch(_ run: inout Run) async {
        run.state = .cancelled
        run.finishedAt = clock.now
        run.error = "cancelled"
        await apply(.ready, toTask: run.taskID)
        try? await runRepository.save(run)
    }

    /// Maps the runner outcome onto the Run row, the task status and the notification (spec §6.4).
    /// Only the status of the task changes (on a fresh copy); `title` is the fallback when the row is gone.
    private func record(
        outcome: Result<ClaudeRunResult, any Error>, into run: inout Run, title: String
    ) async -> AppNotification? {
        switch outcome {
        case .success(let result):
            run.numTurns = result.numTurns
            run.costUSD = result.totalCostUSD
            run.resultText = result.result
            run.subtype = result.subtype
            run.exitCode = 0
            if result.isSuccess {
                run.state = .succeeded
                let task = await apply(.done, toTask: run.taskID)
                return AppNotification(
                    kind: .runDone, title: task?.title ?? title,
                    body: Self.firstLine(result.result) ?? "Tamamlandı",
                    taskID: run.taskID, runID: run.id)
            }
            run.state = .failed
            run.error = result.subtype
            let task = await apply(.failed, toTask: run.taskID)
            return AppNotification(
                kind: .runFailed, title: task?.title ?? title,
                body: Self.message(for: result), taskID: run.taskID, runID: run.id)

        case .failure(let error):
            let claudeError = error as? ClaudeRunError
            if claudeError == .cancelled {
                run.state = .cancelled
                run.error = "cancelled"
                await apply(.cancelled, toTask: run.taskID)
                return nil
            }
            run.state = .failed
            run.error = Self.message(for: error)
            if case .processFailed(let exitCode, _) = claudeError { run.exitCode = exitCode }
            let task = await apply(.failed, toTask: run.taskID)
            return AppNotification(
                kind: .runFailed, title: task?.title ?? title,
                body: Self.message(for: error), taskID: run.taskID, runID: run.id)
        }
    }

    private func makeSpec(task: ShotTask, project: Project, runID: UUID) async -> RunSpec {
        let captures = (try? await taskRepository.captures(taskID: task.id)) ?? []
        let voiceNotes = (try? await taskRepository.voiceNotes(taskID: task.id)) ?? []
        let screenshots = captures.enumerated().map { index, capture in
            ScreenshotRef(
                absolutePath: fileStore.absoluteURL(for: capture.relPath).path,
                label: index == 0 ? task.title : nil)
        }
        // Only notes with usable text get here (`voiceNoteRefusal`); the user's own text counts.
        let transcripts =
            voiceNotes
            .filter(\.hasUsableText)
            .compactMap(\.transcript)
        let prompt = PromptBuilder.build(
            PromptInput(
                mode: task.mode, title: task.title, projectPath: project.path,
                screenshots: screenshots, noteText: task.noteText, transcripts: transcripts))
        let extra = settings.extraSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunSpec(
            runID: runID,
            prompt: prompt,
            projectPath: project.path,
            mode: task.mode,
            model: task.modelOverride ?? project.defaultModel ?? settings.model,
            effort: project.defaultEffort ?? settings.effort,
            maxTurns: settings.maxTurns,
            maxBudgetUSD: settings.maxBudgetUSD,
            timeout: settings.timeout,
            permissionMode: task.mode == .analyze ? .dontAsk : settings.permissionMode,
            addDirs: [fileStore.rootURL.appendingPathComponent(FileStore.capturesDir, isDirectory: true).path],
            systemPromptAppend: PromptBuilder.systemPromptAppend + (extra.isEmpty ? "" : "\n\n" + extra))
    }

    /// Every status change goes through `ShotTask.transition` (Plan 00 Task 2) — direct assignment is
    /// forbidden — applied to a FRESH copy of the row, so edits made meanwhile (title, order, mode) are
    /// never overwritten with an old copy. Returns the saved row, or nil when the row is gone or refuses
    /// the transition (it changed underneath us); the Run row still carries the outcome.
    @discardableResult
    private func apply(_ status: TaskStatus, toTask taskID: UUID) async -> ShotTask? {
        do {
            guard var task = try await taskRepository.task(id: taskID) else { return nil }
            try task.transition(to: status, at: clock.now)
            try await taskRepository.save(task)
            return task
        } catch {
            NSLog("%@", "Shotcue: task \(taskID.uuidString) could not move to \(status.rawValue): \(error)")
            return nil
        }
    }

    /// Unregisters first, then finishes: a later `liveEvents` finds nothing and gets a finished stream,
    /// and a subscriber that raced in is finished by the broadcaster itself.
    private nonisolated func closeLiveEvents(_ runID: UUID) {
        let broadcaster = broadcasters.withLock { $0.removeValue(forKey: runID) }
        broadcaster?.finish()
    }

    // MARK: - Messages (user-visible, Turkish)

    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        return String(line.prefix(200))
    }

    static func message(for result: ClaudeRunResult) -> String {
        switch result.subtype {
        case ClaudeRunResult.maxTurnsSubtype:
            return "Tur limiti aşıldı (\(result.numTurns.map(String.init) ?? "?") tur)."
        case ClaudeRunResult.maxBudgetSubtype:
            return "Bütçe limiti aşıldı."
        default:
            return firstLine(result.result) ?? "Çalışma hata ile bitti (\(result.subtype))."
        }
    }

    static func missingProjectMessage(path: String) -> String {
        "Proje klasörü bulunamadı: \(path). Ayarlar > Projeler'den yolu düzeltin."
    }

    static let missingProjectRecordMessage = "Proje bulunamadı. Görevi bir projeye atayıp yeniden gönderin."

    static func unreadableProjectMessage(_ error: any Error) -> String {
        "Proje okunamadı: \(error)"
    }

    static let taskChangedBeforeLaunchMessage =
        "Görev, claude başlatılmadan önce değişti ya da silindi; çalıştırılmadı."

    static let voiceNotePendingMessage =
        "Sesli not henüz yazıya dökülmedi; görev gönderilmedi. Transkript bitince yeniden gönder."

    static let voiceNoteFailedMessage =
        "Sesli not yazıya dökülemedi; görev gönderilmedi. Transkripti elle yaz ya da yeniden çevir, sonra yeniden gönder."

    static let voiceNotesUnreadableMessage = "Sesli notlar okunamadı; görev gönderilmedi. Yeniden gönder."

    static func message(for error: any Error) -> String {
        guard let error = error as? ClaudeRunError else { return String(describing: error) }
        switch error {
        case .notFound:
            return "claude bulunamadı. Ayarlar > Claude'dan yolu kontrol edin."
        case .launchFailed(let detail):
            return "claude başlatılamadı: \(detail)"
        case .processFailed(let exitCode, let stderr):
            if stderr.lowercased().contains("not logged in") || stderr.lowercased().contains("login") {
                return "claude ile tekrar giriş yapın."
            }
            return firstLine(stderr) ?? "claude \(exitCode) koduyla çıktı."
        case .timedOut:
            return "Zaman aşımı. Çalışma durduruldu."
        case .cancelled:
            return "İptal edildi."
        case .noResult:
            return "claude sonuç satırı üretmeden çıktı."
        }
    }
}
