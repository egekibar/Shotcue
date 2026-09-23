import Foundation

/// Which queued task starts next (spec §5: manual order, global limit). Tasks of one project run side by side;
/// only a project in `exclusiveProjectIDs` (its git safety net — a branch or a stash per run — would pull the
/// working tree out from under a run already in it) runs one task at a time.
public enum QueuePolicy {
    public static func ordered(_ tasks: [ShotTask]) -> [ShotTask] {
        tasks.sorted { a, b in
            a.sortIndex != b.sortIndex ? a.sortIndex < b.sortIndex : a.createdAt < b.createdAt
        }
    }

    public static func nextRunnable(
        queued: [ShotTask], runningProjectIDs: Set<UUID>, exclusiveProjectIDs: Set<UUID> = [],
        runningCount: Int, maxConcurrent: Int
    ) -> ShotTask? {
        guard runningCount < max(1, maxConcurrent) else { return nil }
        return ordered(queued.filter { $0.status == .queued }).first { task in
            guard let projectID = task.projectID else { return false }
            return !(exclusiveProjectIDs.contains(projectID) && runningProjectIDs.contains(projectID))
        }
    }
}
