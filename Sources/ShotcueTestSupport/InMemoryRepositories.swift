import Foundation
import ShotcueCore

/// Broadcasts a value to any number of AsyncStream subscribers.
public final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private let continuations = Locked<[UUID: AsyncStream<Value>.Continuation]>([:])
    public init() {}
    public func stream(initial: Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            continuation.yield(initial)
            continuation.onTermination = { [continuations] _ in continuations.withLock { $0[id] = nil } }
        }
    }
    public func send(_ value: Value) { continuations.current.values.forEach { $0.yield(value) } }
}

public final class InMemoryProjectRepository: ProjectRepository, @unchecked Sendable {
    public let storage = Locked<[UUID: Project]>([:])
    private let broadcaster = Broadcaster<[Project]>()
    public init(_ projects: [Project] = []) {
        storage.set(Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) }))
    }
    private var sorted: [Project] {
        storage.current.values.sorted {
            $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.createdAt < $1.createdAt
        }
    }
    public func allProjects() async throws -> [Project] { sorted }
    public func project(id: UUID) async throws -> Project? { storage.current[id] }
    public func save(_ project: Project) async throws {
        storage.withLock { $0[project.id] = project }
        broadcaster.send(sorted)
    }
    public func deleteProject(id: UUID) async throws {
        storage.withLock { $0[id] = nil }
        broadcaster.send(sorted)
    }
    public func observeProjects() -> AsyncStream<[Project]> { broadcaster.stream(initial: sorted) }
}

public final class InMemoryTaskRepository: TaskRepository, @unchecked Sendable {
    public let tasksStorage = Locked<[UUID: ShotTask]>([:])
    public let capturesStorage = Locked<[UUID: Capture]>([:])
    public let voiceStorage = Locked<[UUID: VoiceNote]>([:])
    private let broadcaster = Broadcaster<[ShotTask]>()
    public init(_ tasks: [ShotTask] = []) {
        tasksStorage.set(Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }))
    }

    private var all: [ShotTask] { QueuePolicy.ordered(Array(tasksStorage.current.values)) }
    private func notify() { broadcaster.send(all) }

    public func allTasks() async throws -> [ShotTask] { all }
    public func task(id: UUID) async throws -> ShotTask? { tasksStorage.current[id] }
    public func tasks(projectID: UUID?) async throws -> [ShotTask] { all.filter { $0.projectID == projectID } }
    public func tasks(status: TaskStatus) async throws -> [ShotTask] { all.filter { $0.status == status } }
    public func save(_ task: ShotTask) async throws {
        tasksStorage.withLock { $0[task.id] = task }
        notify()
    }
    public func deleteTask(id: UUID) async throws {
        tasksStorage.withLock { $0[id] = nil }
        capturesStorage.withLock { $0 = $0.filter { $0.value.taskID != id } }
        voiceStorage.withLock { $0 = $0.filter { $0.value.taskID != id } }
        notify()
    }
    public func captures(taskID: UUID) async throws -> [Capture] {
        capturesStorage.current.values.filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ capture: Capture) async throws {
        capturesStorage.withLock { $0[capture.id] = capture }
        notify()
    }
    public func moveCaptures(ids: [UUID], toTaskID: UUID) async throws {
        capturesStorage.withLock { for id in ids { $0[id]?.taskID = toTaskID } }
        notify()
    }
    public func voiceNotes(taskID: UUID) async throws -> [VoiceNote] {
        voiceStorage.current.values.filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ voiceNote: VoiceNote) async throws {
        voiceStorage.withLock { $0[voiceNote.id] = voiceNote }
        notify()
    }
    public func search(_ query: String) async throws -> [ShotTask] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        let transcriptsByTask = Dictionary(grouping: voiceStorage.current.values, by: \.taskID)
        return all.filter { task in
            task.title.lowercased().contains(q) || task.noteText.lowercased().contains(q)
                || (transcriptsByTask[task.id] ?? []).contains { ($0.transcript ?? "").lowercased().contains(q) }
        }
    }
    public func observeAllTasks() -> AsyncStream<[ShotTask]> { broadcaster.stream(initial: all) }
    public func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]> {
        let upstream = broadcaster.stream(initial: all)
        return AsyncStream { continuation in
            let task = Task {
                for await list in upstream { continuation.yield(list.filter { $0.projectID == projectID }) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public final class InMemoryRunRepository: RunRepository, @unchecked Sendable {
    public let storage = Locked<[UUID: Run]>([:])
    private let broadcaster = Broadcaster<[Run]>()
    public init(_ runs: [Run] = []) { storage.set(Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })) }
    private var all: [Run] { storage.current.values.sorted { $0.startedAt < $1.startedAt } }
    public func runs(taskID: UUID) async throws -> [Run] { all.filter { $0.taskID == taskID } }
    public func run(id: UUID) async throws -> Run? { storage.current[id] }
    public func save(_ run: Run) async throws {
        storage.withLock { $0[run.id] = run }
        broadcaster.send(all)
    }
    public func activeRuns() async throws -> [Run] { all.filter { $0.state == .starting || $0.state == .running } }
    public func markInterruptedRuns(at now: Date) async throws -> Int {
        var count = 0
        storage.withLock { dict in
            for (id, var run) in dict where run.state == .starting || run.state == .running {
                run.state = .failed
                run.error = RunErrorCode.interrupted
                run.finishedAt = now
                dict[id] = run
                count += 1
            }
        }
        broadcaster.send(all)
        return count
    }
    public func observeRuns(taskID: UUID) -> AsyncStream<[Run]> {
        let upstream = broadcaster.stream(initial: all)
        return AsyncStream { continuation in
            let task = Task {
                for await list in upstream { continuation.yield(list.filter { $0.taskID == taskID }) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
