import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueClaudeBridge

/// `FakeClaudeRunner` can only fail with `FakeError`; the cancelled/timeout mapping needs a
/// runner that throws `ClaudeRunError`.
final class ErrorClaudeRunner: ClaudeRunner, @unchecked Sendable {
    let error: ClaudeRunError
    let cancelled = Locked<[UUID]>([])
    init(_ error: ClaudeRunError) { self.error = error }
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        onEvent(.assistantText("başladı"))
        throw error
    }
    func cancel(runID: UUID) async { cancelled.withLock { $0.append(runID) } }
    func version() async throws -> String { "2.1.278 (Claude Code)" }
}

struct Harness {
    static let head = "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7"

    /// The coordinator refuses to run when the project directory is missing (spec §8),
    /// so every fixture project points at a directory that really exists.
    static func makeProjectDirectory(_ name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-project-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    let clock: MutableClock
    let projectRepository: InMemoryProjectRepository
    let taskRepository: InMemoryTaskRepository
    let runRepository: InMemoryRunRepository
    let gitInspector: FakeGitInspector
    let notifier: FakeNotifier
    let fileStore: FileStore
    let coordinator: RunCoordinator
    let root: URL

    init(
        projects: [Project], tasks: [ShotTask], runs: [Run] = [], runner: any ClaudeRunner,
        settings: RunSettings = RunSettings(keepAwake: false)
    ) {
        clock = MutableClock()
        projectRepository = InMemoryProjectRepository(projects)
        taskRepository = InMemoryTaskRepository(tasks)
        runRepository = InMemoryRunRepository(runs)
        gitInspector = FakeGitInspector(
            snapshots: Dictionary(
                uniqueKeysWithValues: projects.map {
                    ($0.path, GitSnapshot(head: Harness.head, isDirty: false, branch: "main"))
                }))
        notifier = FakeNotifier()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-coord-\(UUID().uuidString)", isDirectory: true)
        fileStore = FileStore(rootURL: root)
        coordinator = RunCoordinator(
            runner: runner, taskRepository: taskRepository,
            projectRepository: projectRepository, runRepository: runRepository,
            gitInspector: gitInspector, fileStore: fileStore,
            notifier: notifier, clock: clock, settings: settings)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func runs(of taskID: UUID) async -> [Run] { (try? await runRepository.runs(taskID: taskID)) ?? [] }
    func status(of taskID: UUID) async -> TaskStatus? { try? await taskRepository.task(id: taskID)?.status }
}

@Suite("RunCoordinator")
struct RunCoordinatorTests {
    func successRunner(delay: Duration = .zero) -> FakeClaudeRunner {
        FakeClaudeRunner(
            events: [.assistantText("bakıyorum"), .toolUse(name: "Read", summary: "Read a.png")],
            outcome: .success(
                ClaudeRunResult(
                    subtype: "success", isError: false,
                    result: "Özet satırı\nikinci satır",
                    totalCostUSD: 0.42, numTurns: 7, durationMs: 1234)),
            eventDelay: delay)
    }

    @Test func enqueueRunsTheTaskAndFillsTheRunRow() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Buton rengi", noteText: "Kırmızı olmalı.", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run succeeded") { await h.runs(of: task.id).first?.state == .succeeded }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.numTurns == 7)
        #expect(run.costUSD == 0.42)
        #expect(run.resultText == "Özet satırı\nikinci satır")
        #expect(run.subtype == "success")
        #expect(run.exitCode == 0)
        #expect(run.finishedAt != nil)
        #expect(run.gitHeadBefore == Harness.head)
        #expect(run.gitHeadAfter == Harness.head)
        #expect(run.gitDirtyBefore == false)
        #expect(run.gitBranch == "main")
        #expect(run.logRelPath == h.fileStore.runLogRelPath(id: run.id))
        // The Run id IS the Claude session id: it is what the runner receives as --session-id.
        #expect(runner.specs.current.first?.runID == run.id)
        #expect(await h.status(of: task.id) == .done)

        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.kind == .runDone)
        #expect(notification.title == "Buton rengi")
        #expect(notification.body == "Özet satırı")
        #expect(notification.taskID == task.id)
        #expect(notification.runID == run.id)

        // One log line per forwarded event (the final result is the return value, not an event).
        let log = try String(contentsOf: h.fileStore.absoluteURL(for: run.logRelPath), encoding: .utf8)
        #expect(log.split(separator: "\n", omittingEmptySubsequences: true).count == 2)
        #expect(log.contains("\"t\":\"toolUse\""))
    }

    @Test func limitResultFailsTheTaskAndNotifies() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Uzun iş", status: .ready)
        let runner = FakeClaudeRunner(
            events: [],
            outcome: .success(
                ClaudeRunResult(
                    subtype: ClaudeRunResult.maxTurnsSubtype,
                    isError: true, numTurns: 30)))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.subtype == ClaudeRunResult.maxTurnsSubtype)
        #expect(run.error == ClaudeRunResult.maxTurnsSubtype)
        #expect(await h.status(of: task.id) == .failed)
        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.kind == .runFailed)
        #expect(notification.body == "Tur limiti aşıldı (30 tur).")
    }

    @Test func cancelledRunnerErrorMapsToCancelledWithoutANotification() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "İptal", status: .ready)
        let h = Harness(projects: [project], tasks: [task], runner: ErrorClaudeRunner(.cancelled))
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run cancelled") { await h.runs(of: task.id).first?.state == .cancelled }

        #expect(await h.status(of: task.id) == .cancelled)
        #expect(h.notifier.sent.current.isEmpty)
    }

    @Test func processFailureRecordsExitCodeAndAuthHint() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Auth", status: .ready)
        let runner = ErrorClaudeRunner(.processFailed(exitCode: 1, stderr: "Error: not logged in. Run 'claude login'."))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.exitCode == 1)
        #expect(run.error == "claude ile tekrar giriş yapın.")
        #expect(h.notifier.sent.current.first?.kind == .runFailed)
    }

    @Test func cancelForwardsToTheRunnerWhileRunningAndUnqueuesOtherwise() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let running = ShotTask(projectID: project.id, title: "Çalışan", status: .ready, sortIndex: 1)
        let runner = successRunner(delay: .milliseconds(120))
        let h = Harness(projects: [project], tasks: [running], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: running.id)
        await waitUntil("task running") { await h.status(of: running.id) == .running }
        let runID = try #require(await h.runs(of: running.id).first?.id)
        await h.coordinator.cancel(taskID: running.id)
        #expect(runner.cancelled.current == [runID])

        // A queued (not yet started) task goes back to `ready` instead.
        await h.coordinator.setPaused(true)
        let queued = ShotTask(projectID: project.id, title: "Kuyrukta", status: .ready, sortIndex: 2)
        try await h.taskRepository.save(queued)
        try await h.coordinator.enqueue(taskID: queued.id)
        #expect(await h.status(of: queued.id) == .queued)
        await h.coordinator.cancel(taskID: queued.id)
        #expect(await h.status(of: queued.id) == .ready)
    }

    @Test func oneRunPerProjectAndTheGlobalLimitAreRespected() async throws {
        let first = Project(name: "a", path: Harness.makeProjectDirectory("a"))
        let second = Project(name: "b", path: Harness.makeProjectDirectory("b"))
        let tasks = [
            ShotTask(projectID: first.id, title: "a1", status: .ready, sortIndex: 1),
            ShotTask(projectID: first.id, title: "a2", status: .ready, sortIndex: 2),
            ShotTask(projectID: second.id, title: "b1", status: .ready, sortIndex: 3),
            ShotTask(projectID: second.id, title: "b2", status: .ready, sortIndex: 4),
        ]
        let h = Harness(
            projects: [first, second], tasks: tasks,
            runner: successRunner(delay: .milliseconds(40)),
            settings: RunSettings(maxConcurrent: 2, keepAwake: false))
        defer { h.cleanUp() }

        for task in tasks { try await h.coordinator.enqueue(taskID: task.id) }

        var peak = 0
        var everDoubledUpOnOneProject = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let running = (try? await h.taskRepository.tasks(status: .running)) ?? []
            peak = max(peak, running.count)
            if Set(running.compactMap(\.projectID)).count != running.count { everDoubledUpOnOneProject = true }
            if ((try? await h.taskRepository.tasks(status: .done)) ?? []).count == tasks.count { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let done = (try? await h.taskRepository.tasks(status: .done)) ?? []
        #expect(done.count == 4)
        #expect(peak >= 1)
        #expect(peak <= 2)
        #expect(everDoubledUpOnOneProject == false)
    }

    @Test func pausedQueueDoesNotStartRuns() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Beklet", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        await h.coordinator.setPaused(true)
        #expect(await h.coordinator.isPaused())
        try await h.coordinator.enqueue(taskID: task.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.status(of: task.id) == .queued)
        #expect(runner.specs.current.isEmpty)

        await h.coordinator.setPaused(false)
        await waitUntil("run succeeded after resume") { await h.status(of: task.id) == .done }
    }

    @Test func runQueueNowEnqueuesEveryReadyTaskInManualOrder() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let tasks = [
            ShotTask(projectID: project.id, title: "üçüncü", status: .ready, sortIndex: 3),
            ShotTask(projectID: project.id, title: "birinci", status: .ready, sortIndex: 1),
            ShotTask(projectID: project.id, title: "ikinci", status: .ready, sortIndex: 2),
            ShotTask(title: "projesiz", status: .inbox, sortIndex: 0),
        ]
        let runner = successRunner()
        let h = Harness(
            projects: [project], tasks: tasks, runner: runner,
            settings: RunSettings(maxConcurrent: 1, keepAwake: false))
        defer { h.cleanUp() }

        await h.coordinator.runQueueNow()
        await waitUntil("all three finished") { runner.specs.current.count == 3 }

        let titles = runner.specs.current.compactMap { spec in
            spec.prompt.components(separatedBy: "\n").first { $0.hasPrefix("TITLE: ") }
        }
        #expect(titles == ["TITLE: birinci", "TITLE: ikinci", "TITLE: üçüncü"])
        #expect(await h.status(of: tasks[3].id) == .inbox)
    }

    @Test func analyzeModeLocksTheRunDown() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "İncele", status: .ready, mode: .analyze)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let spec = try #require(runner.specs.current.first)
        #expect(spec.mode == .analyze)
        #expect(spec.permissionMode == .dontAsk)
        #expect(spec.prompt.hasPrefix("TASK TYPE: ANALYZE ONLY"))
        let arguments = ClaudeArguments.build(spec: spec)
        #expect(arguments.contains("--allowedTools"))
        let modeIndex = try #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(arguments[modeIndex + 1] == "dontAsk")
    }

    @Test func specCarriesSettingsProjectDefaultsAndCaptureDirectory() async throws {
        let project = Project(
            name: "crm", path: Harness.makeProjectDirectory("crm"), defaultModel: "sonnet", defaultEffort: "medium")
        let task = ShotTask(projectID: project.id, title: "Model", status: .ready, modelOverride: "opus")
        let runner = successRunner()
        let settings = RunSettings(
            maxTurns: 12, maxBudgetUSD: 3.5, timeout: 600,
            permissionMode: .acceptEdits, model: "haiku", effort: "low",
            extraSystemPrompt: "Türkçe cevap ver.", keepAwake: false)
        let h = Harness(projects: [project], tasks: [task], runner: runner, settings: settings)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let spec = try #require(runner.specs.current.first)
        #expect(spec.model == "opus")  // task override wins over project and settings
        #expect(spec.effort == "medium")  // project default wins over settings
        #expect(spec.maxTurns == 12)
        #expect(spec.maxBudgetUSD == 3.5)
        #expect(spec.timeout == 600)
        #expect(spec.permissionMode == .acceptEdits)
        #expect(spec.projectPath == project.path)
        #expect(spec.addDirs == [h.fileStore.rootURL.appendingPathComponent("captures", isDirectory: true).path])
        #expect(spec.systemPromptAppend.hasPrefix(PromptBuilder.systemPromptAppend))
        #expect(spec.systemPromptAppend.hasSuffix("\n\nTürkçe cevap ver."))
    }

    @Test func promptCarriesCaptureAbsolutePathsAndTranscripts() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Filtre bozuk", noteText: "Son 7 gün yanlış.", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }
        try await h.taskRepository.save(
            Capture(
                taskID: task.id, relPath: "captures/2026/09/first.png",
                width: 100, height: 50,
                createdAt: Date(timeIntervalSince1970: 1)))
        try await h.taskRepository.save(
            Capture(
                taskID: task.id, relPath: "captures/2026/09/second.png",
                width: 100, height: 50,
                createdAt: Date(timeIntervalSince1970: 2)))
        try await h.taskRepository.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/a.m4a", durationSec: 3,
                transcript: "tarih filtresi çalışmıyor",
                transcriptState: .done))
        try await h.taskRepository.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/b.m4a", durationSec: 3,
                transcript: "bu henüz yazıya dökülmedi",
                transcriptState: .pending))

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let prompt = try #require(runner.specs.current.first?.prompt)
        let firstPath = h.fileStore.absoluteURL(for: "captures/2026/09/first.png").path
        let secondPath = h.fileStore.absoluteURL(for: "captures/2026/09/second.png").path
        #expect(prompt.contains("- \(firstPath)  (Filtre bozuk)"))
        #expect(prompt.contains("- \(secondPath)"))
        #expect(prompt.contains("tarih filtresi çalışmıyor"))
        #expect(!prompt.contains("bu henüz yazıya dökülmedi"))
        #expect(prompt.contains("Son 7 gün yanlış."))
    }

    @Test func branchAndStashSettingsCallTheInspector() async throws {
        let project = Project(
            name: "crm", path: Harness.makeProjectDirectory("crm"), runInBranch: true, stashBeforeRun: true)
        let task = ShotTask(projectID: project.id, title: "Dalda çalış", status: .ready)
        let h = Harness(projects: [project], tasks: [task], runner: successRunner())
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run succeeded") { await h.runs(of: task.id).first?.state == .succeeded }

        #expect(h.gitInspector.branches.current.map(\.name) == [GitOutputParser.branchName(for: task.id)])
        #expect(h.gitInspector.branches.current.map(\.path) == [project.path])
        #expect(h.gitInspector.stashes.current == [project.path])
        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.gitBranch == GitOutputParser.branchName(for: task.id))
    }

    @Test func liveEventsStreamsAndFinishes() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Canlı", status: .ready)
        let runner = FakeClaudeRunner(
            events: [.assistantText("bir"), .assistantText("iki"), .assistantText("üç")],
            outcome: .success(ClaudeRunResult(subtype: "success", isError: false)),
            eventDelay: .milliseconds(80))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run row created") { await h.runs(of: task.id).first != nil }
        let runID = try #require(await h.runs(of: task.id).first?.id)

        let stream = h.coordinator.liveEvents(runID: runID)
        var received: [RunEvent] = []
        for await event in stream { received.append(event) }  // finishes when the run ends

        #expect(!received.isEmpty)
        #expect(received.allSatisfy { if case .assistantText = $0 { return true } else { return false } })
        #expect(await h.status(of: task.id) == .done)

        // Subscribing to a finished run yields an empty, already-finished stream.
        var afterwards: [RunEvent] = []
        for await event in h.coordinator.liveEvents(runID: runID) { afterwards.append(event) }
        #expect(afterwards.isEmpty)
    }

    @Test func recoverInterruptedRunsFailsLeftoverRuns() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let interrupted = ShotTask(projectID: project.id, title: "Yarım kalan", status: .running)
        let finished = ShotTask(projectID: project.id, title: "Biten", status: .done)
        let staleRun = Run(taskID: interrupted.id, state: .running, logRelPath: "runs/a.jsonl")
        let oldRun = Run(taskID: finished.id, state: .succeeded, logRelPath: "runs/b.jsonl")
        let h = Harness(
            projects: [project], tasks: [interrupted, finished], runs: [staleRun, oldRun],
            runner: successRunner())
        defer { h.cleanUp() }

        #expect(try await h.coordinator.recoverInterruptedRuns() == 1)
        #expect(await h.status(of: interrupted.id) == .failed)
        #expect(await h.status(of: finished.id) == .done)
        let recovered = try #require(await h.runs(of: interrupted.id).first)
        #expect(recovered.state == .failed)
        #expect(recovered.error == "interrupted")
        #expect(try await h.runRepository.activeRuns().isEmpty)
    }

    @Test func missingProjectDirectoryFailsBeforeTheRunnerIsCalled() async throws {
        let project = Project(name: "taşınmış", path: "/tmp/shotcue-does-not-exist-\(UUID().uuidString)")
        let task = ShotTask(projectID: project.id, title: "Kayıp proje", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        #expect(runner.specs.current.isEmpty)
        // The task never ran, so it returns to `ready` instead of `failed`.
        #expect(await h.status(of: task.id) == .ready)
        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.error == RunCoordinator.missingProjectMessage(path: project.path))
        #expect(h.notifier.sent.current.first?.kind == .runFailed)
    }

    @Test func updateSettingsAppliesToTheNextRun() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Ayar", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        await h.coordinator.updateSettings(RunSettings(maxTurns: 99, maxBudgetUSD: 1.25, keepAwake: false))
        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let spec = try #require(runner.specs.current.first)
        #expect(spec.maxTurns == 99)
        #expect(spec.maxBudgetUSD == 1.25)
    }
}
