import Foundation

public enum ScheduledAction: Hashable, Sendable {
    case enqueueTask(UUID)
    case fireDailyQueue(projectID: UUID)
}

/// Pure time rules (spec §6.5). The driver applies actions: `enqueueTask` → `transition(to: .queued)`;
/// `fireDailyQueue` → enqueue `dailyCandidates` in order and set `project.dailyLastFiredAt = now`.
public enum SchedulerRules {
    public static func dueActions(now: Date, calendar: Calendar, tasks: [ShotTask], projects: [Project])
        -> [ScheduledAction]
    {
        var actions: [ScheduledAction] = []
        for task in tasks where task.status == .scheduled {
            if let at = task.scheduledAt, at <= now { actions.append(.enqueueTask(task.id)) }
        }
        for project in projects where project.dailyEnabled {
            guard let time = project.dailyTime,
                let fire = todaysFireDate(time, now: now, calendar: calendar),
                fire <= now
            else { continue }
            if let last = project.dailyLastFiredAt, calendar.isDate(last, inSameDayAs: now) { continue }
            actions.append(.fireDailyQueue(projectID: project.id))
        }
        return actions
    }

    public static func todaysFireDate(_ time: DailyTime, now: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components)
    }

    /// Ready tasks of the project in manual order; queued ones are already in the queue.
    public static func dailyCandidates(projectID: UUID, tasks: [ShotTask]) -> [ShotTask] {
        QueuePolicy.ordered(tasks.filter { $0.projectID == projectID && $0.status == .ready })
    }
}
