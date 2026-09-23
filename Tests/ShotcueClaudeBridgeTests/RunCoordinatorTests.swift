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

/// Measures how many `run` calls overlap; every call holds its slot for `hold`.
final class ConcurrencyProbeRunner: ClaudeRunner, @unchecked Sendable {
    let hold: Duration
    let active = Locked(0)
    let peak = Locked(0)
    let calls = Locked(0)
    init(hold: Duration) { self.hold = hold }
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        let now = active.withLock { count -> Int in
            count += 1
            return count
        }
        peak.withLock { $0 = max($0, now) }
        calls.withLock { $0 += 1 }
        try? await Task.sleep(for: hold)
        active.withLock { $0 -= 1 }
        return ClaudeRunResult(subtype: "success", isError: false)
    }
    func cancel(runID: UUID) async {}
    func version() async throws -> String { "probe" }
}

/// A latch: `wait()` suspends until `open()`. `arrivals` counts the callers that reached it, so a test
/// knows a run is parked there before it acts.
final class Gate: @unchecked Sendable {
    private let state = Locked<(isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
    let arrivals = Locked(0)

    func wait() async {
        arrivals.withLock { $0 += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let all = state.waiting
            state.waiting.removeAll()
            return all
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// The git fake, except that `snapshot` parks on a gate: the run is held in its git phase.
final class GatedGitInspector: GitInspector, @unchecked Sendable {
    let base: FakeGitInspector
    let gate: Gate
    init(base: FakeGitInspector, gate: Gate) {
        self.base = base
        self.gate = gate
    }
    func snapshot(at path: String) async -> GitSnapshot? {
        await gate.wait()
        return await base.snapshot(at: path)
    }
    func createBranch(_ name: String, at path: String) async throws { try await base.createBranch(name, at: path) }
    func stashAll(at path: String) async throws { try await base.stashAll(at: path) }
}

/// Every `run` parks on one gate until the test opens it; `started` lists the runs that reached claude.
final class GatedClaudeRunner: ClaudeRunner, @unchecked Sendable {
    let gate = Gate()
    let started = Locked<[UUID]>([])
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        started.withLock { $0.append(spec.runID) }
        await gate.wait()
        return ClaudeRunResult(subtype: "success", isError: false)
    }
    func cancel(runID: UUID) async {}
    func version() async throws -> String { "gated" }
}

/// Parks every run until it is cancelled, then ends it the way `ProcessClaudeRunner` does: `.cancelled`.
final class CancellableClaudeRunner: ClaudeRunner, @unchecked Sendable {
    private let waiting = Locked<[UUID: CheckedContinuation<Void, Never>]>([:])
    private let cancelledEarly = Locked<Set<UUID>>([])
    let started = Locked<[UUID]>([])
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        started.withLock { $0.append(spec.runID) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = cancelledEarly.withLock { $0.contains(spec.runID) }
            if resumeNow {
                continuation.resume()
            } else {
                waiting.withLock { $0[spec.runID] = continuation }
            }
        }
        throw ClaudeRunError.cancelled
    }
    func cancel(runID: UUID) async {
        cancelledEarly.withLock { _ = $0.insert(runID) }
        let continuation = waiting.withLock { $0.removeValue(forKey: runID) }
        continuation?.resume()
    }
    func version() async throws -> String { "cancellable" }
}

/// The in-memory project repository, except that `project(id:)` parks on a gate.
final class GatedProjectRepository: ProjectRepository, @unchecked Sendable {
    let base: InMemoryProjectRepository
    let gate: Gate
    init(base: InMemoryProjectRepository, gate: Gate) {
        self.base = base
        self.gate = gate
    }
    func allProjects() async throws -> [Project] { try await base.allProjects() }
    func project(id: UUID) async throws -> Project? {
        await gate.wait()
        return try await base.project(id: id)
    }
    func save(_ project: Project) async throws { try await base.save(project) }
    func deleteProject(id: UUID) async throws { try await base.deleteProject(id: id) }
    func observeProjects() -> AsyncStream<[Project]> { base.observeProjects() }
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

    /// `snapshotGate` / `projectGate` park the coordinator's git snapshots / project lookups on that gate.
    /// `holdsQueue` builds the coordinator the way the app does: nothing starts before `resumeQueue()`.
    init(
        projects: [Project], tasks: [ShotTask], runs: [Run] = [], runner: any ClaudeRunner,
        settings: RunSettings = RunSettings(keepAwake: false), snapshotGate: Gate? = nil, projectGate: Gate? = nil,
        holdsQueue: Bool = false
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
        var coordinatorGit: any GitInspector = gitInspector
        if let snapshotGate { coordinatorGit = GatedGitInspector(base: gitInspector, gate: snapshotGate) }
        var coordinatorProjects: any ProjectRepository = projectRepository
        if let projectGate { coordinatorProjects = GatedProjectRepository(base: projectRepository, gate: projectGate) }
        coordinator = RunCoordinator(
            runner: runner, taskRepository: taskRepository,
            projectRepository: coordinatorProjects, runRepository: runRepository,
            gitInspector: coordinatorGit, fileStore: fileStore,
            notifier: notifier, clock: clock, settings: settings, holdsQueueUntilResumed: holdsQueue)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func runs(of taskID: UUID) async -> [Run] { (try? await runRepository.runs(taskID: taskID)) ?? [] }
    func status(of taskID: UUID) async -> TaskStatus? { try? await taskRepository.task(id: taskID)?.status }
}

/// Time-limited: a live stream that never finishes would otherwise hang the whole run.
@Suite("RunCoordinator", .timeLimit(.minutes(1)))
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
        // Spec §5.5: title + one-line summary + cost (final review M1).
        #expect(notification.body == "Özet satırı · $0.42")
        #expect(notification.taskID == task.id)
        #expect(notification.runID == run.id)

        // One log line per forwarded event (the final result is the return value, not an event), in
        // claude's stream-json shape: the UI replays it with StreamJSONParser.
        let log = try String(contentsOf: h.fileStore.absoluteURL(for: run.logRelPath), encoding: .utf8)
        let replayed = log.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { StreamJSONParser.parse(line: String($0)) }
        #expect(replayed == [.assistantText("bakıyorum"), .toolUse(name: "Read", summary: "Read a.png")])
    }

    @Test func aDoneNotificationWithoutACostOrSummaryStaysShort() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Sessiz", status: .ready)
        let runner = FakeClaudeRunner(outcome: .success(ClaudeRunResult(subtype: "success", isError: false)))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run succeeded") { await h.runs(of: task.id).first?.state == .succeeded }
        #expect(h.notifier.sent.current.first?.body == "Tamamlandı")
        #expect(RunCoordinator.doneBody(summary: nil, costUSD: 1.5) == "Tamamlandı · $1.50")
        #expect(RunCoordinator.doneBody(summary: "Bitti.", costUSD: 0.004) == "Bitti. · $0.00")
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
        // Final review I6: the Turkish text comes from the one mapping, with the §8 limit hint.
        #expect(notification.body == RunErrorText.notificationBody(for: RunErrorCode.maxTurns, numTurns: 30))
        #expect(notification.body.contains("tur limitini artırıp"))
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
        #expect(run.error == RunErrorCode.claudeNotLoggedIn)
        #expect(h.notifier.sent.current.first?.body.contains("claude ile tekrar giriş yapın.") == true)
        #expect(h.notifier.sent.current.first?.kind == .runFailed)
    }

    /// Final review I6: the run row keeps a machine code (plus the raw detail worth showing); the notification says it
    /// in Turkish through `RunErrorText`.
    @Test(
        arguments: zip(
            [
                ClaudeRunError.timedOut, .notFound, .noResult, .launchFailed("posix_spawn failed"),
                .processFailed(exitCode: 2, stderr: "boom\nsecond line"),
            ],
            [
                RunErrorCode.timeout, RunErrorCode.claudeNotFound, RunErrorCode.noResult,
                "claude_launch_failed: posix_spawn failed", "claude_failed: boom",
            ]))
    func runnerErrorsAreStoredAsCodes(error: ClaudeRunError, stored: String) async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Kod", status: .ready)
        let h = Harness(projects: [project], tasks: [task], runner: ErrorClaudeRunner(error))
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.error == stored)
        let notification = try #require(h.notifier.sent.current.first)
        #expect(
            notification.body
                == RunErrorText.notificationBody(for: run.error, exitCode: run.exitCode, numTurns: run.numTurns))
        #expect(!notification.body.contains("_"))
    }

    /// claude reports API and auth failures (a rejected key, a usage limit, an overloaded API) as a result with subtype
    /// `success` and `is_error`. The run fails with claude's first result line kept in its code, so the inspector and
    /// the notification say why instead of showing a raw "success".
    @Test func anErrorResultWithSubtypeSuccessKeepsClaudesReason() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Anahtar", status: .ready)
        let runner = FakeClaudeRunner(
            outcome: .success(
                ClaudeRunResult(
                    subtype: "success", isError: true, result: "Invalid API key · Please run /login",
                    totalCostUSD: 0, numTurns: 1)))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.subtype == "success")
        #expect(run.error == "claude_error: Invalid API key · Please run /login")
        #expect(await h.status(of: task.id) == .failed)
        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.kind == .runFailed)
        // A rejected key is a lost session: spec §8's login hint follows claude's line.
        #expect(
            notification.body
                == "claude hata bildirdi: Invalid API key · Please run /login — claude ile tekrar giriş yapın.")
        // The inspector reads the same row: claude's line as the result text (primary), the Turkish text and the
        // login hint under it, and no second copy of the line.
        #expect(run.resultText == "Invalid API key · Please run /login")
        let failure = try #require(RunErrorText.describe(run.error, exitCode: run.exitCode, numTurns: run.numTurns))
        #expect(failure.message == "claude hata bildirdi.")
        #expect(failure.suggestion == "claude ile tekrar giriş yapın.")
        #expect(failure.detail == "Invalid API key · Please run /login")
        #expect(failure.detailIsShown(in: run.resultText))
    }

    /// Only the first non-empty line is kept (a JSON body can follow it); without a result line the code stands alone.
    @Test(
        arguments: zip(
            ["\nAPI Error: 529 Overloaded\n{\"type\":\"error\"}", "", nil] as [String?],
            ["claude_error: API Error: 529 Overloaded", "claude_error", "claude_error"]))
    func anErrorResultKeepsOnlyClaudesFirstLine(result: String?, stored: String) async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Yoğun", status: .ready)
        let runner = FakeClaudeRunner(
            outcome: .success(ClaudeRunResult(subtype: "success", isError: true, result: result)))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.error == stored)
        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.body == RunErrorText.notificationBody(for: run.error, numTurns: run.numTurns))
        #expect(notification.body.hasPrefix("claude hata bildirdi"))
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

    @Test func cancelDuringTheGitPhaseNeverStartsClaude() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Erken iptal", status: .ready)
        let runner = successRunner()
        let gate = Gate()
        let h = Harness(projects: [project], tasks: [task], runner: runner, snapshotGate: gate)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run parked in its git snapshot") { gate.arrivals.current > 0 }
        await h.coordinator.cancel(taskID: task.id)
        gate.open()
        await waitUntil("run cancelled") { await h.runs(of: task.id).first?.state == .cancelled }

        #expect(runner.specs.current.isEmpty)
        #expect(runner.cancelled.current.isEmpty)
        // It never ran, so it is ready to be sent again.
        #expect(await h.status(of: task.id) == .ready)
        #expect(h.notifier.sent.current.isEmpty)
        #expect(await h.runs(of: task.id).first?.error == RunErrorCode.cancelledBeforeLaunch)
    }

    @Test func editsMadeDuringARunSurviveItsEnd() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Eski başlık", status: .ready, sortIndex: 1)
        let runner = successRunner(delay: .milliseconds(150))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("claude started") { !runner.specs.current.isEmpty }
        // The UI saves edits straight to the repository while claude works.
        var edited = try #require(try await h.taskRepository.task(id: task.id))
        edited.title = "Yeni başlık"
        edited.mode = .analyze
        edited.sortIndex = 7
        try await h.taskRepository.save(edited)
        await waitUntil("run finished") { await h.runs(of: task.id).first?.state == .succeeded }

        let final = try #require(try await h.taskRepository.task(id: task.id))
        #expect(final.status == .done)
        #expect(final.title == "Yeni başlık")
        #expect(final.mode == .analyze)
        #expect(final.sortIndex == 7)
        #expect(h.notifier.sent.current.first?.title == "Yeni başlık")
    }

    @Test func theSpecIsBuiltFromTheRowAsItIsAtLaunch() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Eski başlık", status: .ready)
        let runner = successRunner()
        let gate = Gate()
        let h = Harness(projects: [project], tasks: [task], runner: runner, snapshotGate: gate)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run parked in its git snapshot") { gate.arrivals.current > 0 }
        var edited = try #require(try await h.taskRepository.task(id: task.id))
        edited.title = "Yeni başlık"
        try await h.taskRepository.save(edited)
        gate.open()
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let prompt = try #require(runner.specs.current.first?.prompt)
        #expect(prompt.contains("TITLE: Yeni başlık"))
    }

    @Test func aRowDeletedBeforeLaunchNeverStartsClaude() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Silinecek", status: .ready)
        let runner = successRunner()
        let gate = Gate()
        let h = Harness(projects: [project], tasks: [task], runner: runner, snapshotGate: gate)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run parked in its git snapshot") { gate.arrivals.current > 0 }
        try await h.taskRepository.deleteTask(id: task.id)
        gate.open()
        await waitUntil("run cancelled") { await h.runs(of: task.id).first?.state == .cancelled }

        #expect(runner.specs.current.isEmpty)
        // `.running` could not be applied: the deleted row is not brought back.
        #expect(try await h.taskRepository.task(id: task.id) == nil)
        #expect(h.notifier.sent.current.isEmpty)
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

    @Test func theGlobalLimitCapsRunsAcrossProjects() async throws {
        let projects = (1...3).map { Project(name: "p\($0)", path: Harness.makeProjectDirectory("p\($0)")) }
        let tasks = projects.flatMap { project in
            (1...2).map { index in
                ShotTask(
                    projectID: project.id, title: "\(project.name)-\(index)", status: .ready,
                    sortIndex: Double(index))
            }
        }
        let runner = ConcurrencyProbeRunner(hold: .milliseconds(100))
        let h = Harness(
            projects: projects, tasks: tasks, runner: runner,
            settings: RunSettings(maxConcurrent: 2, keepAwake: false))
        defer { h.cleanUp() }

        for task in tasks { try await h.coordinator.enqueue(taskID: task.id) }
        await waitUntil("every task done") {
            ((try? await h.taskRepository.tasks(status: .done)) ?? []).count == tasks.count
        }

        #expect(runner.calls.current == tasks.count)
        // Three projects could run side by side; only the global limit holds them at two.
        #expect(runner.peak.current == 2)
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

    @Test func promptCarriesCaptureAbsolutePathsAndEveryUsableTranscript() async throws {
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
        // The transcriber gave up on this one, but the user typed its text: that text is the note.
        try await h.taskRepository.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/b.m4a", durationSec: 3,
                transcript: "elle yazılan sesli not",
                transcriptState: .failed, editedByUser: true))

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let prompt = try #require(runner.specs.current.first?.prompt)
        let firstPath = h.fileStore.absoluteURL(for: "captures/2026/09/first.png").path
        let secondPath = h.fileStore.absoluteURL(for: "captures/2026/09/second.png").path
        #expect(prompt.contains("- \(firstPath)  (Filtre bozuk)"))
        #expect(prompt.contains("- \(secondPath)"))
        #expect(prompt.contains("tarih filtresi çalışmıyor"))
        #expect(prompt.contains("elle yazılan sesli not"))
        #expect(prompt.contains("Son 7 gün yanlış."))
    }

    /// Final review C1: the voice note is the main instruction channel. A note still waiting for its
    /// transcript, or one that failed with no text from the user, keeps claude from starting at all.
    @Test(
        arguments: zip(
            [TranscriptState.pending, .failed],
            [RunErrorCode.voiceNotePending, RunErrorCode.voiceNoteFailed]))
    func aVoiceNoteWithoutUsableTextNeverStartsClaude(state: TranscriptState, code: String) async throws {
        let project = Project(
            name: "crm", path: Harness.makeProjectDirectory("crm"), runInBranch: true, stashBeforeRun: true)
        let task = ShotTask(projectID: project.id, title: "Sesli görev", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }
        try await h.taskRepository.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/a.m4a", durationSec: 4,
                transcript: "bitmemiş", transcriptState: state))

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        #expect(runner.specs.current.isEmpty)
        // It never ran, so it is ready to be sent again once the note has text.
        #expect(await h.status(of: task.id) == .ready)
        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.error == code)
        #expect(run.finishedAt != nil)
        // Refused before the git steps: the working tree is left exactly as it was.
        #expect(h.gitInspector.branches.current.isEmpty)
        #expect(h.gitInspector.stashes.current.isEmpty)
        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.kind == .runFailed)
        #expect(notification.taskID == task.id)
        #expect(notification.runID == run.id)
        #expect(notification.body.contains("Sesli not"))
    }

    @Test func aTranscriptThatFinishedLetsTheNextSendRun() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Sesli görev", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }
        var note = VoiceNote(taskID: task.id, relPath: "audio/a.m4a", durationSec: 4, transcriptState: .pending)
        try await h.taskRepository.save(note)

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("refused") { await h.runs(of: task.id).first?.state == .failed }
        #expect(runner.specs.current.isEmpty)

        note.transcript = "artık yazıya döküldü"
        note.transcriptState = .done
        try await h.taskRepository.save(note)
        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("ran") { await h.status(of: task.id) == .done }
        #expect(runner.specs.current.count == 1)
        #expect(runner.specs.current.first?.prompt.contains("artık yazıya döküldü") == true)
    }

    @Test func branchAndStashSettingsCallTheInspector() async throws {
        let project = Project(
            name: "crm", path: Harness.makeProjectDirectory("crm"), runInBranch: true, stashBeforeRun: true)
        let task = ShotTask(projectID: project.id, title: "Dalda çalış", status: .ready)
        let h = Harness(projects: [project], tasks: [task], runner: successRunner())
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run succeeded") { await h.runs(of: task.id).first?.state == .succeeded }

        let run = try #require(await h.runs(of: task.id).first)
        let branch = GitOutputParser.branchName(taskID: task.id, runID: run.id)
        #expect(h.gitInspector.branches.current.map(\.name) == [branch])
        #expect(h.gitInspector.branches.current.map(\.path) == [project.path])
        #expect(h.gitInspector.stashes.current == [project.path])
        #expect(run.gitBranch == branch)

        // Final review I4: running the task again makes a branch of its own instead of colliding.
        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("second run succeeded") {
            let runs = await h.runs(of: task.id)
            return runs.count == 2 && runs.allSatisfy { $0.state == .succeeded }
        }
        let names = h.gitInspector.branches.current.map(\.name)
        #expect(names.count == 2)
        #expect(Set(names).count == 2)
    }

    /// Final review I4: with the git safety net turned on, a failing branch or stash step never lets claude start
    /// (it would work on the current branch / on top of the uncommitted changes the user asked to set aside).
    @Test(arguments: ["branch", "stash"])
    func aFailingGitStepFailsBeforeLaunch(step: String) async throws {
        let project = Project(
            name: "crm", path: Harness.makeProjectDirectory("crm"), runInBranch: true, stashBeforeRun: true)
        let task = ShotTask(projectID: project.id, title: "Git bozuk", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }
        let gitError = FakeError("fatal: a branch named 'shotcue/x' already exists")
        if step == "branch" {
            h.gitInspector.branchFailure.set(gitError)
        } else {
            h.gitInspector.stashFailure.set(gitError)
        }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        #expect(runner.specs.current.isEmpty)
        #expect(await h.status(of: task.id) == .ready)
        let run = try #require(await h.runs(of: task.id).first)
        let code = step == "branch" ? RunErrorCode.gitBranchFailed : RunErrorCode.gitStashFailed
        #expect(run.error?.hasPrefix(code) == true)
        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.kind == .runFailed)
        #expect(notification.taskID == task.id)
    }

    @Test func theGitFailureKeepsGitsOwnFirstLine() {
        let error = GitError.commandFailed(
            arguments: ["switch", "-c", "shotcue/x"], exitCode: 128,
            stderr: "fatal: not a git repository (or any of the parent directories): .git\n")
        #expect(
            RunCoordinator.gitDetail(error) == "fatal: not a git repository (or any of the parent directories): .git")
        #expect(
            RunErrorCode.compose(RunErrorCode.gitBranchFailed, detail: RunCoordinator.gitDetail(error))
                == "git_branch_failed: fatal: not a git repository (or any of the parent directories): .git")
        #expect(RunErrorCode.compose(RunErrorCode.gitStashFailed, detail: "  ") == "git_stash_failed")
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

    @Test func liveEventsOfAnUnknownRunFinishAtOnce() async {
        let h = Harness(projects: [], tasks: [], runner: successRunner())
        defer { h.cleanUp() }
        // Unknown ids include every run of an earlier launch.
        var received: [RunEvent] = []
        for await event in h.coordinator.liveEvents(runID: UUID()) { received.append(event) }
        #expect(received.isEmpty)
    }

    @Test func liveEventsOfARunThatNeverStartsFinish() async throws {
        // Never saved in the repository, so the run fails before claude is started.
        let ghost = Project(name: "silinmiş", path: Harness.makeProjectDirectory("ghost"))
        let task = ShotTask(projectID: ghost.id, title: "Sahipsiz", status: .ready)
        let gate = Gate()
        let h = Harness(projects: [], tasks: [task], runner: successRunner(), projectGate: gate)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run parked on its project lookup") { gate.arrivals.current > 0 }
        let runID = try #require(await h.runs(of: task.id).first?.id)
        let stream = h.coordinator.liveEvents(runID: runID)  // subscribed while the run is in flight
        gate.open()

        var received: [RunEvent] = []
        for await event in stream { received.append(event) }
        #expect(received.isEmpty)
        #expect(await h.runs(of: task.id).first?.state == .failed)
    }

    @Test func aStreamOpenedAfterTheBroadcasterFinishedEndsAtOnce() async {
        let broadcaster = RunEventBroadcaster()
        broadcaster.finish()
        var received: [RunEvent] = []
        for await event in broadcaster.stream() { received.append(event) }
        #expect(received.isEmpty)
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

    /// Final review I1: tasks queued before a quit or crash start again after launch recovery, and only then.
    @Test func queuedTasksFromTheLastSessionStartOnceTheQueueIsResumed() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let leftOver = ShotTask(projectID: project.id, title: "Dünden kalan", status: .queued, sortIndex: 1)
        let fresh = ShotTask(projectID: project.id, title: "Yeni", status: .ready, sortIndex: 2)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [leftOver, fresh], runner: runner, holdsQueue: true)
        defer { h.cleanUp() }

        _ = try await h.coordinator.recoverInterruptedRuns()
        // Held until the app resumes it: nothing may start before recovery, whatever pumps meanwhile.
        try await h.coordinator.enqueue(taskID: fresh.id)
        await h.coordinator.updateSettings(RunSettings(maxConcurrent: 3, keepAwake: false))
        await h.coordinator.setPaused(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.specs.current.isEmpty)
        #expect(await h.status(of: leftOver.id) == .queued)

        await h.coordinator.resumeQueue()
        await waitUntil("both ran") {
            let left = await h.status(of: leftOver.id)
            let new = await h.status(of: fresh.id)
            return left == .done && new == .done
        }
        #expect(runner.specs.current.count == 2)
    }

    /// Final review I1 (+ the reviewer's "task stuck running"): a task left `running` with no active run (a
    /// stale whole-row write, or a run row that never got saved) can be neither cancelled nor deleted nor rerun.
    @Test func recoveryFailsARunningTaskThatHasNoActiveRun() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let stuck = ShotTask(projectID: project.id, title: "Takılı", status: .running)
        let finishedRun = Run(
            taskID: stuck.id, state: .succeeded, startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20), logRelPath: "runs/old.jsonl")
        let h = Harness(projects: [project], tasks: [stuck], runs: [finishedRun], runner: successRunner())
        defer { h.cleanUp() }

        #expect(try await h.coordinator.recoverInterruptedRuns() == 1)

        #expect(await h.status(of: stuck.id) == .failed)
        let runs = await h.runs(of: stuck.id)
        #expect(runs.count == 2)
        // The old run keeps its own outcome; the repair is a run row of its own that says why.
        #expect(runs.first { $0.id == finishedRun.id }?.state == .succeeded)
        let repair = try #require(runs.first { $0.id != finishedRun.id })
        #expect(repair.state == .failed)
        #expect(repair.error == "interrupted")
        #expect(repair.finishedAt != nil)
        #expect(try await h.runRepository.activeRuns().isEmpty)
        // Failed goes through `transition`: the task can be rerun.
        #expect(TaskStatus.failed.canTransition(to: .queued))
    }

    /// Final review I1: raising the concurrency limit starts what now fits, without waiting for another send.
    @Test func updateSettingsStartsWhatTheNewLimitAllows() async throws {
        let first = Project(name: "a", path: Harness.makeProjectDirectory("a"))
        let second = Project(name: "b", path: Harness.makeProjectDirectory("b"))
        let a = ShotTask(projectID: first.id, title: "a", status: .ready, sortIndex: 1)
        let b = ShotTask(projectID: second.id, title: "b", status: .ready, sortIndex: 2)
        let runner = GatedClaudeRunner()
        let h = Harness(
            projects: [first, second], tasks: [a, b], runner: runner,
            settings: RunSettings(maxConcurrent: 1, keepAwake: false))
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: a.id)
        try await h.coordinator.enqueue(taskID: b.id)
        await waitUntil("one run started") { runner.started.current.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.started.current.count == 1)

        await h.coordinator.updateSettings(RunSettings(maxConcurrent: 2, keepAwake: false))
        await waitUntil("the second run started") { runner.started.current.count == 2 }
        runner.gate.open()
        await waitUntil("both done") {
            let first = await h.status(of: a.id)
            let second = await h.status(of: b.id)
            return first == .done && second == .done
        }
    }

    /// Final review I2: the quit path reads the runs in flight synchronously, pauses the queue, cancels them and
    /// waits until none is left — without the queue starting the next task in the freed slot.
    @Test func pausingThenCancellingStopsTheRunsWithoutStartingQueuedOnes() async throws {
        let first = Project(name: "a", path: Harness.makeProjectDirectory("a"))
        let second = Project(name: "b", path: Harness.makeProjectDirectory("b"))
        let running = ShotTask(projectID: first.id, title: "çalışan", status: .ready, sortIndex: 1)
        let waiting = ShotTask(projectID: second.id, title: "bekleyen", status: .ready, sortIndex: 2)
        let runner = CancellableClaudeRunner()
        let h = Harness(
            projects: [first, second], tasks: [running, waiting], runner: runner,
            settings: RunSettings(maxConcurrent: 1, keepAwake: false))
        defer { h.cleanUp() }
        #expect(h.coordinator.activeTaskIDs.isEmpty)

        try await h.coordinator.enqueue(taskID: running.id)
        try await h.coordinator.enqueue(taskID: waiting.id)
        await waitUntil("claude started") { runner.started.current.count == 1 }
        #expect(h.coordinator.activeTaskIDs == [running.id])

        await h.coordinator.setPaused(true)
        for taskID in h.coordinator.activeTaskIDs { await h.coordinator.cancel(taskID: taskID) }
        await waitUntil("settled") { h.coordinator.activeTaskIDs.isEmpty }

        #expect(await h.status(of: running.id) == .cancelled)
        #expect(await h.runs(of: running.id).first?.state == .cancelled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.started.current.count == 1)
        #expect(await h.status(of: waiting.id) == .queued)
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
        #expect(run.error == RunErrorCode.compose(RunErrorCode.projectFolderMissing, detail: project.path))
        #expect(h.notifier.sent.current.first?.kind == .runFailed)
    }

    @Test func missingProjectRowFailsTheRunInsteadOfRestartingIt() async throws {
        let present = Project(name: "var", path: Harness.makeProjectDirectory("var"))
        // Never saved in the repository: the queued task points at a project row that is gone.
        let ghost = Project(name: "silinmiş", path: Harness.makeProjectDirectory("ghost"))
        let orphan = ShotTask(projectID: ghost.id, title: "Sahipsiz", status: .ready, sortIndex: 1)
        let normal = ShotTask(projectID: present.id, title: "Normal", status: .ready, sortIndex: 2)
        let runner = successRunner()
        let h = Harness(
            projects: [present], tasks: [orphan, normal], runner: runner,
            settings: RunSettings(maxConcurrent: 1, keepAwake: false))
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: orphan.id)
        try await h.coordinator.enqueue(taskID: normal.id)
        await waitUntil("the other project's task finished") { await h.status(of: normal.id) == .done }

        #expect(runner.specs.current.map { $0.projectPath } == [present.path])
        #expect(await h.status(of: orphan.id) == .ready)
        let runs = await h.runs(of: orphan.id)
        #expect(runs.count == 1)
        #expect(runs.first?.state == .failed)
        #expect(runs.first?.error == RunErrorCode.projectMissing)
        #expect(h.notifier.sent.current.contains { $0.kind == .runFailed && $0.taskID == orphan.id })
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
