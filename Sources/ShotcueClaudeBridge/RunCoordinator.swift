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

    /// Outside actor isolation so the nonisolated `liveEvents` and the runner's @Sendable
    /// event callback can reach them.
    private let broadcasters = LockBox<[UUID: RunEventBroadcaster]>([:])
    private let finishedRunIDs = LockBox<Set<UUID>>([])

    private var settings: RunSettings
    private var paused = false
    private var inFlight: [UUID: InFlight] = [:]
    /// Run ids cancelled while in flight but not launched yet (the git phase, for instance).
    private var pendingCancels: Set<UUID> = []
    private var activities: [UUID: any NSObjectProtocol] = [:]

    public init(
        runner: any ClaudeRunner, taskRepository: any TaskRepository,
        projectRepository: any ProjectRepository, runRepository: any RunRepository,
        gitInspector: any GitInspector, fileStore: FileStore, notifier: any Notifier,
        clock: any Clock, settings: RunSettings
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
        guard var task = try? await taskRepository.task(id: taskID),
            task.status == .queued || task.status == .scheduled
        else { return }
        await apply(.ready, to: &task)
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
        if finishedRunIDs.current.contains(runID) {
            return AsyncStream { $0.finish() }
        }
        return broadcaster(for: runID).stream()
    }

    // MARK: - App-facing extras

    public func updateSettings(_ settings: RunSettings) { self.settings = settings }

    /// Launch recovery (spec §8): runs left `starting`/`running` by a crash become `failed`.
    public func recoverInterruptedRuns() async throws -> Int {
        let stale = try await runRepository.activeRuns()
        let count = try await runRepository.markInterruptedRuns(at: clock.now)
        for run in stale {
            guard var task = try await taskRepository.task(id: run.taskID), task.status == .running else { continue }
            await apply(.failed, to: &task)
        }
        return count
    }

    // MARK: - Queue

    private func pumpQueue() async {
        guard !paused else { return }
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
        // The row is gone, or it lost its project (never runnable, so the queue cannot pick it again):
        // there is nothing to run and nothing to report.
        guard let loaded = try? await taskRepository.task(id: taskID), let projectID = loaded.projectID else {
            return
        }
        var task = loaded
        var run = Run(
            id: runID, taskID: taskID, state: .starting, startedAt: clock.now,
            logRelPath: fileStore.runLogRelPath(id: runID))
        try? await runRepository.save(run)

        // A missing or unreadable project row must not leave the task queued: the queue would pick it
        // again at once, forever.
        let project: Project
        do {
            guard let found = try await projectRepository.project(id: projectID) else {
                await failBeforeLaunch(&run, task: &task, message: Self.missingProjectRecordMessage)
                return
            }
            project = found
        } catch {
            await failBeforeLaunch(&run, task: &task, message: Self.unreadableProjectMessage(error))
            return
        }

        // Spec §8: a moved or deleted project directory must not start a run at all.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            await failBeforeLaunch(&run, task: &task, message: Self.missingProjectMessage(path: project.path))
            return
        }

        if pendingCancels.contains(runID) {
            await cancelBeforeLaunch(&run, task: &task)
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
            await cancelBeforeLaunch(&run, task: &task)
            return
        }
        inFlight[taskID]?.launched = true

        let spec = await makeSpec(task: task, project: project, runID: runID)
        run.state = .running
        try? await runRepository.save(run)
        await apply(.running, to: &task)

        let writer = logWriter
        let broadcaster = broadcaster(for: runID)
        let onEvent: @Sendable (RunEvent) -> Void = { event in
            try? writer.append(event, runID: runID)
            broadcaster.send(event)
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
        broadcasters.withLock { $0[runID] = nil }
        finishedRunIDs.withLock { _ = $0.insert(runID) }
        broadcaster.finish()

        run.finishedAt = clock.now
        run.gitHeadAfter = await gitInspector.snapshot(at: project.path)?.head
        let notification = await record(outcome: outcome, into: &run, task: &task)
        try? await runRepository.save(run)
        if let notification { await notifier.notify(notification) }
    }

    /// The run never started (spec §8): the Run row says why, the task goes back to `ready` (the task
    /// never entered `running`; fix the cause and resend) and the user is told.
    private func failBeforeLaunch(_ run: inout Run, task: inout ShotTask, message: String) async {
        run.state = .failed
        run.finishedAt = clock.now
        run.error = message
        await apply(.ready, to: &task)
        try? await runRepository.save(run)
        await notifier.notify(
            AppNotification(kind: .runFailed, title: task.title, body: message, taskID: task.id, runID: run.id))
    }

    /// Cancelled before claude was started: the Run row is cancelled, the task (never `running`) goes back
    /// to `ready`, and nobody is notified — the user asked for it.
    private func cancelBeforeLaunch(_ run: inout Run, task: inout ShotTask) async {
        run.state = .cancelled
        run.finishedAt = clock.now
        run.error = "cancelled"
        await apply(.ready, to: &task)
        try? await runRepository.save(run)
    }

    /// Maps the runner outcome onto the Run row, the task status and the notification (spec §6.4).
    private func record(
        outcome: Result<ClaudeRunResult, any Error>, into run: inout Run,
        task: inout ShotTask
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
                await apply(.done, to: &task)
                return AppNotification(
                    kind: .runDone, title: task.title,
                    body: Self.firstLine(result.result) ?? "Tamamlandı",
                    taskID: task.id, runID: run.id)
            }
            run.state = .failed
            run.error = result.subtype
            await apply(.failed, to: &task)
            return AppNotification(
                kind: .runFailed, title: task.title,
                body: Self.message(for: result), taskID: task.id, runID: run.id)

        case .failure(let error):
            let claudeError = error as? ClaudeRunError
            if claudeError == .cancelled {
                run.state = .cancelled
                run.error = "cancelled"
                await apply(.cancelled, to: &task)
                return nil
            }
            run.state = .failed
            run.error = Self.message(for: error)
            if case .processFailed(let exitCode, _) = claudeError { run.exitCode = exitCode }
            await apply(.failed, to: &task)
            return AppNotification(
                kind: .runFailed, title: task.title,
                body: Self.message(for: error), taskID: task.id, runID: run.id)
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
        let transcripts =
            voiceNotes
            .filter { $0.transcriptState == .done }
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

    /// Every status change goes through `ShotTask.transition` (Plan 00 Task 2); direct assignment
    /// is forbidden. A rejected transition means the row changed underneath us — the Run row still
    /// carries the outcome, so we keep going.
    private func apply(_ status: TaskStatus, to task: inout ShotTask) async {
        do {
            try task.transition(to: status, at: clock.now)
            try await taskRepository.save(task)
        } catch {
            return
        }
    }

    private nonisolated func broadcaster(for runID: UUID) -> RunEventBroadcaster {
        broadcasters.withLock { registry in
            if let existing = registry[runID] { return existing }
            let created = RunEventBroadcaster()
            registry[runID] = created
            return created
        }
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
