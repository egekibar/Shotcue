import Foundation

/// Which queued task starts next (spec §5: manual order, one run per project, global limit).
public enum QueuePolicy {
    public static func ordered(_ tasks: [ShotTask]) -> [ShotTask] {
        tasks.sorted { a, b in
            a.sortIndex != b.sortIndex ? a.sortIndex < b.sortIndex : a.createdAt < b.createdAt
        }
    }

    public static func nextRunnable(
        queued: [ShotTask], runningProjectIDs: Set<UUID>,
        runningCount: Int, maxConcurrent: Int
    ) -> ShotTask? {
        guard runningCount < max(1, maxConcurrent) else { return nil }
        return ordered(queued.filter { $0.status == .queued }).first { task in
            guard let projectID = task.projectID else { return false }
            return !runningProjectIDs.contains(projectID)
        }
    }
}
