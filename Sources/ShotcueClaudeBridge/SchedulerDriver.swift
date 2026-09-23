import AppKit
import Foundation
import ShotcueCore
import os

/// Applies `SchedulerRules` (spec §6.5). A `DispatchSourceTimer` ticks every `interval` seconds —
/// Foundation's `Timer` is run-loop bound and drifts while the menu bar is interacted with, and
/// `NSBackgroundActivityScheduler` chooses its own time. Waking from sleep ticks immediately so a
/// missed slot runs once (no flood).
public actor SchedulerDriver {
    private let dispatcher: any TaskDispatcher
    private let taskRepository: any TaskRepository
    private let projectRepository: any ProjectRepository
    private let clock: any Clock
    private let calendar: Calendar
    private let interval: TimeInterval

    private let queue = DispatchQueue(label: "com.shotcue.scheduler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wakeObserver: (any NSObjectProtocol)?
    /// How many daily-queue failures were logged (test hook).
    private(set) var dailyFailureReports = 0
    /// Project → the day (start of day) its daily-queue failure was last logged: once per project per day.
    private var dailyFailureLogged: [UUID: Date] = [:]
    private static let log = Logger(subsystem: "com.shotcue.app", category: "scheduler")

    public init(
        dispatcher: any TaskDispatcher, taskRepository: any TaskRepository,
        projectRepository: any ProjectRepository, clock: any Clock,
        calendar: Calendar = .current, interval: TimeInterval = 30
    ) {
        self.dispatcher = dispatcher
        self.taskRepository = taskRepository
        self.projectRepository = projectRepository
        self.clock = clock
        self.calendar = calendar
        self.interval = interval
    }

    /// One reconcile pass. Pausing is the coordinator's concern: the scheduler always enqueues,
    /// and a paused `RunCoordinator` simply does not pump the queue.
    public func tick() async {
        let tasks = (try? await taskRepository.allTasks()) ?? []
        let projects = (try? await projectRepository.allProjects()) ?? []
        let now = clock.now
        let actions = SchedulerRules.dueActions(now: now, calendar: calendar, tasks: tasks, projects: projects)
        for action in actions {
            switch action {
            case .enqueueTask(let taskID):
                try? await dispatcher.enqueue(taskID: taskID)
            case .fireDailyQueue(let projectID):
                let candidates = SchedulerRules.dailyCandidates(projectID: projectID, tasks: tasks)
                var enqueued = 0
                var failure: (any Error)?
                for candidate in candidates {
                    do {
                        try await dispatcher.enqueue(taskID: candidate.id)
                        enqueued += 1
                    } catch {
                        failure = error
                    }
                }
                if let failure { reportDailyFailure(projectID: projectID, error: failure, now: now) }
                // Final review M2: the day's slot is used up only when something was enqueued (or there was
                // nothing to enqueue). When every enqueue failed — claude missing, say — the next tick tries again.
                guard candidates.isEmpty || enqueued > 0 else { continue }
                if var project = try? await projectRepository.project(id: projectID) {
                    project.dailyLastFiredAt = now
                    try? await projectRepository.save(project)
                }
            }
        }
    }

    /// Logs a daily-queue enqueue failure once per project per day, not on every 30 s tick that retries it.
    private func reportDailyFailure(projectID: UUID, error: any Error, now: Date) {
        let day = calendar.startOfDay(for: now)
        guard dailyFailureLogged[projectID] != day else { return }
        dailyFailureLogged[projectID] = day
        dailyFailureReports += 1
        Self.log.error(
            "daily queue of project \(projectID, privacy: .public) could not enqueue: \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
        )
    }

    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        // Explicitly @Sendable: the handler runs on `queue`, never on this actor's executor, so it must not
        // be inferred actor-isolated (SE-0423 would check the executor at runtime). It only hops in.
        source.setEventHandler { @Sendable [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        source.activate()
        timer = source
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.tick() }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}
