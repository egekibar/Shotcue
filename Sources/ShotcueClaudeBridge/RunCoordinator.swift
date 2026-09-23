import Foundation
import ShotcueCore
import os

/// Owns the run queue (spec §5.5, §6.4): a global concurrency limit (tasks of one project run side by side,
/// except in a project with the git safety net, which runs one at a time),
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
    /// The tasks with a run in flight, mirrored outside actor isolation: the app's quit path must decide
    /// synchronously whether there are runs to stop (final review I2).
    private let inFlightTaskIDs = LockBox<Set<UUID>>([])

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

    /// The tasks whose run is in flight (from the git phase until its row is saved), readable synchronously.
    /// Empty once every run's outcome is recorded.
    public nonisolated var activeTaskIDs: Set<UUID> { inFlightTaskIDs.current }

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
            guard inFlight.count < max(1, settings.maxConcurrent) else { return }
            // Both reads suspend; the `inFlight` filter and `start` below must not, or a reentrant pump could
            // start the same task twice.
            let exclusive = await exclusiveProjectIDs()
            let queued = ((try? await taskRepository.tasks(status: .queued)) ?? [])
                .filter { inFlight[$0.id] == nil }
            guard
                let next = QueuePolicy.nextRunnable(
                    queued: queued,
                    runningProjectIDs: Set(inFlight.values.map(\.projectID)),
                    exclusiveProjectIDs: exclusive,
                    runningCount: inFlight.count,
                    maxConcurrent: settings.maxConcurrent)
            else { return }
            guard start(next) else { return }
        }
    }

    /// Projects whose git safety net (a branch or a stash per run) rewrites the working tree: one run at a time.
    /// An unreadable project list counts every project as exclusive — the old, safe rule.
    private func exclusiveProjectIDs() async -> Set<UUID> {
        guard let projects = try? await projectRepository.allProjects() else {
            return Set(inFlight.values.map(\.projectID))
        }
        return Set(projects.filter { $0.runInBranch || $0.stashBeforeRun }.map(\.id))
    }

    /// Registers the run without suspending, so a reentrant `pumpQueue` cannot double-start it.
    private func start(_ task: ShotTask) -> Bool {
        guard let projectID = task.projectID else { return false }
        let runID = UUID()
        inFlight[task.id] = InFlight(runID: runID, projectID: projectID)
        inFlightTaskIDs.withLock { _ = $0.insert(task.id) }
        // Registered before anything can learn the run id; `perform` removes it on every exit.
        broadcasters.withLock { $0[runID] = RunEventBroadcaster() }
        Task { await self.execute(taskID: task.id, runID: runID) }
        return true
    }

    private func finishInFlight(_ taskID: UUID) async {
        inFlight[taskID] = nil
        inFlightTaskIDs.withLock { _ = $0.remove(taskID) }
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
                await failBeforeLaunch(&run, title: queued.title, error: RunErrorCode.projectMissing)
                return
            }
            project = found
            run.agent = AgentKind.resolve(project: found.agent, default: settings.defaultAgent)
        } catch {
            await failBeforeLaunch(
                &run, title: queued.title,
                error: RunErrorCode.compose(RunErrorCode.projectUnreadable, detail: Self.detail(of: error)))
            return
        }

        // Spec §8: a moved or deleted project directory must not start a run at all.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            await failBeforeLaunch(
                &run, title: queued.title,
                error: RunErrorCode.compose(RunErrorCode.projectFolderMissing, detail: project.path))
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
            await failBeforeLaunch(&run, title: queued.title, error: refusal)
            return
        }
        // Final review I4: the opt-in git safety net fails closed. When the user asked for a branch or a stash and
        // that step fails, claude is not started — it would work on the current branch, on top of the changes the
        // user wanted set aside. The branch name is unique per run, so a re-run never collides with an old branch.
        if project.runInBranch {
            do {
                try await gitInspector.createBranch(
                    GitOutputParser.branchName(taskID: taskID, runID: runID), at: project.path)
            } catch {
                await failBeforeLaunch(
                    &run, title: queued.title,
                    error: RunErrorCode.compose(RunErrorCode.gitBranchFailed, detail: Self.gitDetail(error)))
                return
            }
        }
        if project.stashBeforeRun {
            do {
                try await gitInspector.stashAll(at: project.path)
            } catch {
                await failBeforeLaunch(
                    &run, title: queued.title,
                    error: RunErrorCode.compose(RunErrorCode.gitStashFailed, detail: Self.gitDetail(error)))
                return
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
            run.error = RunErrorCode.taskChangedBeforeLaunch
            try? await runRepository.save(run)
            return
        }
        let spec = await makeSpec(task: running, project: project, runID: runID)
        run.state = .running
        try? await runRepository.save(run)

        let writer = logWriter
        let broadcaster = broadcasters.withLock { $0[runID] }
        // Codex and Antigravity pick their own session id and report it in their first event.
        let reportedSessionID = LockBox<String?>(nil)
        let onEvent: @Sendable (RunEvent) -> Void = { event in
            if case .initialized(let sessionID?, _) = event {
                reportedSessionID.withLock { if $0 == nil { $0 = sessionID } }
            }
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
        if run.agent != .claude {
            let resultSessionID = try? outcome.get().sessionID
            run.sessionID = reportedSessionID.current ?? resultSessionID
        }
        run.gitHeadAfter = await gitInspector.snapshot(at: project.path)?.head
        let notification = await record(outcome: outcome, into: &run, title: running.title)
        try? await runRepository.save(run)
        if let notification { await notifier.notify(notification) }
    }

    /// The run never started (spec §8): the Run row keeps the machine code (`error`), the task goes back to
    /// `ready` (the task never entered `running`; fix the cause and resend) and the user is told in Turkish
    /// (`RunErrorText`, the same text the inspector shows).
    private func failBeforeLaunch(_ run: inout Run, title: String, error: String) async {
        run.state = .failed
        run.finishedAt = clock.now
        run.error = error
        let task = await apply(.ready, toTask: run.taskID)
        try? await runRepository.save(run)
        await notifier.notify(
            AppNotification(
                kind: .runFailed, title: task?.title ?? title,
                body: RunErrorText.notificationBody(for: error, agent: run.agent),
                taskID: run.taskID, runID: run.id))
    }

    /// The code of why the task's voice notes keep the run from starting, or nil when every note has usable
    /// text. Notes that cannot be read also refuse: the run could not show that it carries them.
    private func voiceNoteRefusal(taskID: UUID) async -> String? {
        let notes: [VoiceNote]
        do {
            notes = try await taskRepository.voiceNotes(taskID: taskID)
        } catch {
            return RunErrorCode.voiceNotesUnreadable
        }
        switch VoiceNoteReadiness.of(notes) {
        case .ready: return nil
        case .pending: return RunErrorCode.voiceNotePending
        case .failed: return RunErrorCode.voiceNoteFailed
        }
    }

    /// Cancelled before claude was started: the Run row is cancelled, the task (never `running`) goes back
    /// to `ready`, and nobody is notified — the user asked for it.
    private func cancelBeforeLaunch(_ run: inout Run) async {
        run.state = .cancelled
        run.finishedAt = clock.now
        run.error = RunErrorCode.cancelledBeforeLaunch
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
                    body: Self.doneBody(summary: Self.firstLine(result.result)),
                    taskID: run.taskID, runID: run.id)
            }
            // A limit stop, an execution error, or an API or auth failure (final review I6; `errorCode(for:)`).
            run.state = .failed
            run.error = Self.errorCode(for: result)
            let task = await apply(.failed, toTask: run.taskID)
            return AppNotification(
                kind: .runFailed, title: task?.title ?? title,
                body: RunErrorText.notificationBody(for: run.error, numTurns: run.numTurns, agent: run.agent),
                taskID: run.taskID, runID: run.id)

        case .failure(let error):
            let claudeError = error as? ClaudeRunError
            if claudeError == .cancelled {
                run.state = .cancelled
                run.error = RunErrorCode.cancelled
                await apply(.cancelled, toTask: run.taskID)
                return nil
            }
            run.state = .failed
            run.error = Self.errorCode(for: error)
            if case .processFailed(let exitCode, _) = claudeError { run.exitCode = exitCode }
            let task = await apply(.failed, toTask: run.taskID)
            return AppNotification(
                kind: .runFailed, title: task?.title ?? title,
                body: RunErrorText.notificationBody(for: run.error, exitCode: run.exitCode, agent: run.agent),
                taskID: run.taskID, runID: run.id)
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
        let agent = AgentKind.resolve(project: project.agent, default: settings.defaultAgent)
        let defaults = settings.defaults(for: agent)
        return RunSpec(
            runID: runID,
            agent: agent,
            prompt: prompt,
            projectPath: project.path,
            mode: task.mode,
            // A value meant for another agent (a task's "opus" after its project moved to Codex) is skipped.
            model: AgentModelChoices.resolveModel(
                [task.modelOverride, project.defaultModel, defaults.model], for: agent),
            effort: AgentModelChoices.resolveEffort([project.defaultEffort, defaults.effort], for: agent),
            maxTurns: settings.maxTurns,
            maxBudgetUSD: settings.maxBudgetUSD,
            timeout: settings.timeout,
            permissionMode: task.mode == .analyze ? .dontAsk : settings.permissionMode,
            addDirs: [fileStore.rootURL.appendingPathComponent(FileStore.capturesDir, isDirectory: true).path],
            images: screenshots.map(\.absolutePath),
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
            // A repository error's description can carry the row's values: private (final review I5).
            Self.log.error(
                "task \(taskID, privacy: .public) could not move to \(status.rawValue, privacy: .public): \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
            )
            return nil
        }
    }

    private static let log = Logger(subsystem: "com.shotcue.app", category: "runs")

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

    /// Spec §5.5: the "done" notification carries the one-line summary. The run's cost is recorded but never shown:
    /// on a subscription it is only an API-price estimate, and a dollar figure reads like a bill.
    static func doneBody(summary: String?) -> String {
        summary ?? "Tamamlandı"
    }

    /// The first line git printed (its stderr), which says what is wrong; otherwise the error's own description.
    static func gitDetail(_ error: any Error) -> String {
        let text: String
        if case .commandFailed(_, _, let stderr) = error as? GitError {
            text = stderr
        } else {
            text = String(describing: error)
        }
        return String((firstLine(text) ?? text).prefix(200))
    }

    /// The first stderr line that reads as the failure itself ("Error: …"). Codex logs warnings to stderr before it
    /// (a models-cache note, an MCP server that needs a login), so its first line is rarely the reason.
    static func errorLine(_ stderr: String) -> String? {
        let line = stderr.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("error:") }
        return line.map { String($0.prefix(200)) }
    }

    /// An error's first line, as the raw detail under a code.
    static func detail(of error: any Error) -> String {
        let text = String(describing: error)
        return String((firstLine(text) ?? text).prefix(200))
    }

    /// The code stored for a result that is not a success (final review I6): claude's own subtype for a limit stop or
    /// an execution error. claude reports API and auth failures (a rejected key, a usage limit, an overloaded API) as
    /// subtype `success` with `is_error`; their code keeps claude's first result line, which says what went wrong.
    static func errorCode(for result: ClaudeRunResult) -> String {
        if result.subtype == ClaudeRunResult.successSubtype {
            return RunErrorCode.compose(RunErrorCode.claudeError, detail: firstLine(result.result))
        }
        return RunErrorCode.isCode(result.subtype) ? result.subtype : RunErrorCode.executionError
    }

    /// The code stored for a runner failure (final review I6); `RunErrorText` turns it into Turkish. The login
    /// check keeps the spec §8 message for an expired session.
    static func errorCode(for error: any Error) -> String {
        guard let error = error as? ClaudeRunError else {
            return RunErrorCode.compose(RunErrorCode.unknownError, detail: detail(of: error))
        }
        switch error {
        case .notFound:
            return RunErrorCode.claudeNotFound
        case .launchFailed(let reason):
            return RunErrorCode.compose(RunErrorCode.claudeLaunchFailed, detail: firstLine(reason))
        case .processFailed(_, let stderr):
            let lowered = stderr.lowercased()
            if lowered.contains("not logged in") || lowered.contains("login") {
                return RunErrorCode.compose(RunErrorCode.claudeNotLoggedIn, detail: nil)
            }
            return RunErrorCode.compose(RunErrorCode.claudeFailed, detail: errorLine(stderr) ?? firstLine(stderr))
        case .timedOut:
            return RunErrorCode.timeout
        case .cancelled:
            return RunErrorCode.cancelled
        case .noResult:
            return RunErrorCode.noResult
        }
    }
}
