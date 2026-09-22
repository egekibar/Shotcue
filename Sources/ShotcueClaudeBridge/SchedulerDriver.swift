import AppKit
import Foundation
import ShotcueCore

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
                for candidate in SchedulerRules.dailyCandidates(projectID: projectID, tasks: tasks) {
                    try? await dispatcher.enqueue(taskID: candidate.id)
                }
                if var project = try? await projectRepository.project(id: projectID) {
                    project.dailyLastFiredAt = now
                    try? await projectRepository.save(project)
                }
            }
        }
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
