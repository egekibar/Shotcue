import AppKit
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueClaudeBridge

/// Serialized: the wake tests post `NSWorkspace.didWakeNotification`, which every started driver in the
/// process observes.
@Suite("SchedulerDriver", .serialized)
struct SchedulerDriverTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// 2025-09-22 10:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_758_535_200)

    func driver(
        tasks: [ShotTask], projects: [Project], clock: MutableClock,
        dispatcher: FakeTaskDispatcher, interval: TimeInterval = 30
    ) -> (SchedulerDriver, InMemoryProjectRepository) {
        let projectRepository = InMemoryProjectRepository(projects)
        let driver = SchedulerDriver(
            dispatcher: dispatcher,
            taskRepository: InMemoryTaskRepository(tasks),
            projectRepository: projectRepository,
            clock: clock, calendar: utc, interval: interval)
        return (driver, projectRepository)
    }

    /// A one-shot task that is due at `now`; every tick enqueues it again (the fake dispatcher only records).
    func dueTask() -> (Project, ShotTask) {
        let project = Project(name: "crm", path: "/tmp/crm")
        let due = ShotTask(
            projectID: project.id, title: "şimdi", status: .scheduled,
            scheduledAt: now.addingTimeInterval(-60))
        return (project, due)
    }

    func postWake() {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    }

    @Test func dueOneShotTaskIsEnqueuedOnce() async throws {
        let project = Project(name: "crm", path: "/tmp/crm")
        let due = ShotTask(
            projectID: project.id, title: "şimdi", status: .scheduled,
            scheduledAt: now.addingTimeInterval(-60))
        let later = ShotTask(
            projectID: project.id, title: "sonra", status: .scheduled,
            scheduledAt: now.addingTimeInterval(3600))
        let dispatcher = FakeTaskDispatcher()
        let (subject, _) = driver(
            tasks: [due, later], projects: [project],
            clock: MutableClock(now), dispatcher: dispatcher)

        await subject.tick()
        #expect(dispatcher.enqueued.current == [due.id])
    }

    @Test func dailyQueueFiresOncePerDayAndStampsTheProject() async throws {
        let project = Project(
            name: "crm", path: "/tmp/crm", dailyTime: DailyTime(hour: 9, minute: 30),
            dailyEnabled: true)
        let first = ShotTask(projectID: project.id, title: "bir", status: .ready, sortIndex: 1)
        let second = ShotTask(projectID: project.id, title: "iki", status: .ready, sortIndex: 2)
        let queued = ShotTask(projectID: project.id, title: "zaten kuyrukta", status: .queued, sortIndex: 0)
        let dispatcher = FakeTaskDispatcher()
        let clock = MutableClock(now)
        let (subject, projects) = driver(
            tasks: [second, queued, first], projects: [project],
            clock: clock, dispatcher: dispatcher)

        await subject.tick()
        #expect(dispatcher.enqueued.current == [first.id, second.id])
        #expect(try await projects.project(id: project.id)?.dailyLastFiredAt == now)

        // A second tick on the same day must not fire again.
        clock.advance(by: 60)
        await subject.tick()
        #expect(dispatcher.enqueued.current == [first.id, second.id])
    }

    @Test func disabledDailyQueueNeverFires() async throws {
        let project = Project(
            name: "crm", path: "/tmp/crm", dailyTime: DailyTime(hour: 9, minute: 0),
            dailyEnabled: false)
        let task = ShotTask(projectID: project.id, title: "bir", status: .ready)
        let dispatcher = FakeTaskDispatcher()
        let (subject, projects) = driver(
            tasks: [task], projects: [project],
            clock: MutableClock(now), dispatcher: dispatcher)

        await subject.tick()
        #expect(dispatcher.enqueued.current.isEmpty)
        #expect(try await projects.project(id: project.id)?.dailyLastFiredAt == nil)
    }

    @Test func startAndStopAreIdempotent() async throws {
        let (project, due) = dueTask()
        let dispatcher = FakeTaskDispatcher()
        let (subject, _) = driver(tasks: [due], projects: [project], clock: MutableClock(now), dispatcher: dispatcher)
        await subject.start()
        await subject.start()
        // The second start registered nothing more: one wake is one tick is one enqueue.
        postWake()
        await waitUntil("the wake tick enqueued the due task") { !dispatcher.enqueued.current.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(dispatcher.enqueued.current == [due.id])

        await subject.stop()
        await subject.stop()
        // Stopped: the wake observer is gone (and the 30 s timer never fired).
        postWake()
        try await Task.sleep(for: .milliseconds(100))
        #expect(dispatcher.enqueued.current == [due.id])
    }

    @Test func theTimerTicksUntilStopped() async throws {
        let (project, due) = dueTask()
        let dispatcher = FakeTaskDispatcher()
        let (subject, _) = driver(
            tasks: [due], projects: [project], clock: MutableClock(now), dispatcher: dispatcher, interval: 0.05)
        await subject.start()
        await waitUntil("a timer tick enqueued the due task") { !dispatcher.enqueued.current.isEmpty }
        await subject.stop()
        // A tick already handed to the actor may still land; after that the count must stay put.
        try await Task.sleep(for: .milliseconds(200))
        let afterStop = dispatcher.enqueued.current.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(afterStop >= 1)
        #expect(dispatcher.enqueued.current.count == afterStop)
        #expect(dispatcher.enqueued.current.allSatisfy { $0 == due.id })
    }

    @Test func wakingFromSleepTicksAtOnce() async throws {
        let (project, due) = dueTask()
        let dispatcher = FakeTaskDispatcher()
        let (subject, _) = driver(
            tasks: [due], projects: [project], clock: MutableClock(now), dispatcher: dispatcher, interval: 3600)
        await subject.start()
        postWake()
        await waitUntil("the wake tick enqueued the due task") { !dispatcher.enqueued.current.isEmpty }
        await subject.stop()
        #expect(dispatcher.enqueued.current == [due.id])
    }
}
