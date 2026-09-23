import Foundation

public enum TaskStateError: Error, Equatable, Sendable {
    case invalidTransition(from: TaskStatus, to: TaskStatus)
    case missingProject
    case scheduledDateRequired
}

extension TaskStatus {
    /// Spec §7. Deleting/archiving is not a transition; it removes the row.
    public static let allowedTransitions: [TaskStatus: Set<TaskStatus>] = [
        .inbox: [.ready],
        .ready: [.queued, .scheduled, .inbox],
        .queued: [.running, .ready, .scheduled],
        .scheduled: [.queued, .ready],
        .running: [.done, .failed, .cancelled],
        .done: [.queued, .scheduled],
        .failed: [.queued, .scheduled, .ready],
        .cancelled: [.queued, .scheduled, .ready],
    ]

    public func canTransition(to next: TaskStatus) -> Bool {
        Self.allowedTransitions[self]?.contains(next) ?? false
    }

    /// A running task may only be cancelled, never edited.
    public var isEditable: Bool { self != .running }
}

extension ShotTask {
    /// The only sanctioned way to change `status`. Also maintains `scheduledAt` and `updatedAt`.
    ///
    /// `scheduledAt` only means something while the task is `scheduled`: a caller that schedules sets the date right
    /// before the →scheduled step, and every step to any other status clears it (final review I3) — so a scheduled
    /// task that later fails or is cancelled carries no stale date.
    public mutating func transition(to next: TaskStatus, at now: Date) throws(TaskStateError) {
        guard status.canTransition(to: next) else {
            throw .invalidTransition(from: status, to: next)
        }
        if [.ready, .queued, .scheduled, .running].contains(next), projectID == nil {
            throw .missingProject
        }
        if next == .scheduled, scheduledAt == nil {
            throw .scheduledDateRequired
        }
        if next != .scheduled {
            scheduledAt = nil
        }
        status = next
        updatedAt = now
    }
}
