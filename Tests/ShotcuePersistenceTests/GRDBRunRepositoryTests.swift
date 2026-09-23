import Foundation
import GRDB
import ShotcueCore
import Testing

@testable import ShotcuePersistence

@Suite("GRDBRunRepository")
struct GRDBRunRepositoryTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    struct Fixture {
        let database: AppDatabase
        let runs: GRDBRunRepository
        let task: ShotTask
    }

    /// The `run` table has a NOT NULL foreign key to `task`, so every fixture
    /// inserts its parent task row first.
    func makeFixture(extraTasks: [ShotTask] = []) throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let task = ShotTask(title: "t", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try database.writer.write { db in
            for row in [task] + extraTasks { try TaskRecord(row).upsert(db) }
        }
        return Fixture(database: database, runs: GRDBRunRepository(database: database), task: task)
    }

    @Test func runsAreOrderedByStartedAt() async throws {
        let other = ShotTask(title: "other", sortIndex: 2048, createdAt: epoch, updatedAt: epoch)
        let fixture = try makeFixture(extraTasks: [other])
        let late = Run(
            taskID: fixture.task.id, state: .succeeded,
            startedAt: epoch.addingTimeInterval(60), logRelPath: "runs/late.jsonl")
        let early = Run(
            taskID: fixture.task.id, state: .failed, startedAt: epoch,
            logRelPath: "runs/early.jsonl")
        let foreign = Run(
            taskID: other.id, state: .succeeded, startedAt: epoch,
            logRelPath: "runs/foreign.jsonl")
        for run in [late, early, foreign] { try await fixture.runs.save(run) }
        #expect(try await fixture.runs.runs(taskID: fixture.task.id).map(\.id) == [early.id, late.id])
        #expect(try await fixture.runs.run(id: foreign.id)?.taskID == other.id)
        #expect(try await fixture.runs.run(id: UUID()) == nil)
    }

    @Test func activeRunsAreStartingOrRunning() async throws {
        let fixture = try makeFixture()
        let starting = Run(
            taskID: fixture.task.id, state: .starting, startedAt: epoch,
            logRelPath: "runs/a.jsonl")
        let running = Run(
            taskID: fixture.task.id, state: .running,
            startedAt: epoch.addingTimeInterval(1), logRelPath: "runs/b.jsonl")
        let done = Run(
            taskID: fixture.task.id, state: .succeeded,
            startedAt: epoch.addingTimeInterval(2), logRelPath: "runs/c.jsonl")
        let cancelled = Run(
            taskID: fixture.task.id, state: .cancelled,
            startedAt: epoch.addingTimeInterval(3), logRelPath: "runs/d.jsonl")
        for run in [starting, running, done, cancelled] { try await fixture.runs.save(run) }
        #expect(try await fixture.runs.activeRuns().map(\.id) == [starting.id, running.id])
    }

    @Test func markInterruptedRunsFailsActiveRowsAndCountsThem() async throws {
        let fixture = try makeFixture()
        let starting = Run(
            taskID: fixture.task.id, state: .starting, startedAt: epoch,
            logRelPath: "runs/a.jsonl")
        let running = Run(
            taskID: fixture.task.id, state: .running,
            startedAt: epoch.addingTimeInterval(1), logRelPath: "runs/b.jsonl")
        let done = Run(
            taskID: fixture.task.id, state: .succeeded,
            startedAt: epoch.addingTimeInterval(2), resultText: "ok",
            logRelPath: "runs/c.jsonl")
        for run in [starting, running, done] { try await fixture.runs.save(run) }
        let now = epoch.addingTimeInterval(120)
        #expect(try await fixture.runs.markInterruptedRuns(at: now) == 2)
        #expect(try await fixture.runs.activeRuns().isEmpty)
        let marked = try #require(try await fixture.runs.run(id: running.id))
        #expect(marked.state == .failed)
        #expect(marked.error == "interrupted")
        #expect(marked.finishedAt == now)
        let untouched = try #require(try await fixture.runs.run(id: done.id))
        #expect(untouched.state == .succeeded)
        #expect(untouched.error == nil)
        #expect(untouched.finishedAt == nil)
        #expect(try await fixture.runs.markInterruptedRuns(at: now) == 0)
    }

    @Test func observeRunsEmitsCurrentValueThenChanges() async throws {
        let fixture = try makeFixture()
        var iterator = fixture.runs.observeRuns(taskID: fixture.task.id).makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        let run = Run(
            taskID: fixture.task.id, state: .running, startedAt: epoch,
            logRelPath: "runs/a.jsonl")
        try await fixture.runs.save(run)
        #expect(await iterator.next()?.map(\.state) == [.running])
        var finished = run
        finished.state = .succeeded
        finished.finishedAt = epoch.addingTimeInterval(5)
        try await fixture.runs.save(finished)
        #expect(await iterator.next()?.map(\.state) == [.succeeded])
    }
}
