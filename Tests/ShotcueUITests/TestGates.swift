import Foundation
import ShotcueCore
import ShotcueTestSupport

@testable import ShotcueUI

/// One-shot latch that parks async calls at a known point: `wait()` suspends until `open()`.
/// `arrivals` counts the callers that reached the gate, so a test can wait until a store is parked
/// inside a service call before acting on it.
nonisolated final class Gate: @unchecked Sendable {
    private let state = Locked<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    let arrivals = Locked(0)

    func wait() async {
        arrivals.withLock { $0 += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Delegates to an `InMemoryTaskRepository` but can park `task(id:)` and `save(_ task:)` on gates, so a
/// test can act while a store is suspended inside a repository call (the plain fakes never suspend).
nonisolated final class GatedTaskRepository: TaskRepository, @unchecked Sendable {
    let base: InMemoryTaskRepository
    let readGate: Gate?
    let saveGate: Gate?

    init(base: InMemoryTaskRepository, readGate: Gate? = nil, saveGate: Gate? = nil) {
        self.base = base
        self.readGate = readGate
        self.saveGate = saveGate
    }

    func allTasks() async throws -> [ShotTask] { try await base.allTasks() }
    func task(id: UUID) async throws -> ShotTask? {
        await readGate?.wait()
        return try await base.task(id: id)
    }
    func tasks(projectID: UUID?) async throws -> [ShotTask] { try await base.tasks(projectID: projectID) }
    func tasks(status: TaskStatus) async throws -> [ShotTask] { try await base.tasks(status: status) }
    func save(_ task: ShotTask) async throws {
        await saveGate?.wait()
        try await base.save(task)
    }
    func deleteTask(id: UUID) async throws { try await base.deleteTask(id: id) }
    func captures(taskID: UUID) async throws -> [Capture] { try await base.captures(taskID: taskID) }
    func save(_ capture: Capture) async throws { try await base.save(capture) }
    func moveCaptures(ids: [UUID], toTaskID: UUID) async throws {
        try await base.moveCaptures(ids: ids, toTaskID: toTaskID)
    }
    func voiceNotes(taskID: UUID) async throws -> [VoiceNote] { try await base.voiceNotes(taskID: taskID) }
    func save(_ voiceNote: VoiceNote) async throws { try await base.save(voiceNote) }
    func search(_ query: String) async throws -> [ShotTask] { try await base.search(query) }
    func observeAllTasks() -> AsyncStream<[ShotTask]> { base.observeAllTasks() }
    func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]> { base.observeTasks(projectID: projectID) }
}

extension AppServices {
    /// The same services with a different task repository (e.g. a `GatedTaskRepository`).
    func replacingTasks(_ tasks: any TaskRepository) -> AppServices {
        AppServices(
            projects: projects, tasks: tasks, runs: runs, capture: capture, thumbnails: thumbnails,
            permissions: permissions, recorder: recorder, transcriber: transcriber,
            transcriptionQueue: transcriptionQueue, dispatcher: dispatcher, handoff: handoff,
            fileStore: fileStore, clock: clock)
    }
}
