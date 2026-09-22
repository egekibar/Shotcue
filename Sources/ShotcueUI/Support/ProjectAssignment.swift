import Foundation
import ShotcueCore

/// Takes a task out of its project without stranding it (review fix round 1, item 2).
///
/// `ready`, `queued` and `scheduled` require a project, and `failed`/`cancelled` can only leave through edges
/// that require one, so clearing the project on such a task would leave it stuck forever. While the project
/// is still set, those tasks therefore first move to `ready`; then the project is cleared and `ready` falls
/// back to `inbox`. A `done` task simply loses its project and stays `done`. A `running` task is never
/// touched (spec §7: it can only be cancelled).
enum ProjectAssignment {
    /// Pure part: `task` with its project cleared. Throws for a `running` task.
    nonisolated static func withoutProject(_ task: ShotTask, now: Date) throws(TaskStateError) -> ShotTask {
        guard task.status.isEditable else { throw .invalidTransition(from: task.status, to: .inbox) }
        var task = task
        if task.projectID != nil, [.queued, .scheduled, .failed, .cancelled].contains(task.status) {
            try task.transition(to: .ready, at: now)
        }
        task.projectID = nil
        if task.status == .ready { try task.transition(to: .inbox, at: now) }
        task.updatedAt = now
        return task
    }

    /// Store-side flow shared by the library and the inspector: a queued task first leaves the queue
    /// through the dispatcher (which owns the queue and moves it to `ready`); the row is then re-read,
    /// detached and saved. Returns the saved task, or nil when it is missing or running.
    static func detach(taskID: UUID, services: AppServices, now: Date) async throws -> ShotTask? {
        guard var task = try await services.tasks.task(id: taskID), task.status.isEditable else { return nil }
        if task.status == .queued {
            await services.dispatcher.cancel(taskID: taskID)
            guard let current = try await services.tasks.task(id: taskID), current.status.isEditable
            else { return nil }
            task = current
        }
        let detached = try withoutProject(task, now: now)
        try await services.tasks.save(detached)
        return detached
    }
}
