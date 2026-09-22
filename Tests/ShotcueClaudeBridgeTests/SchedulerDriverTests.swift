import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueClaudeBridge

@Suite("SchedulerDriver")
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
        dispatcher: FakeTaskDispatcher
    ) -> (SchedulerDriver, InMemoryProjectRepository) {
        let projectRepository = InMemoryProjectRepository(projects)
        let driver = SchedulerDriver(
            dispatcher: dispatcher,
            taskRepository: InMemoryTaskRepository(tasks),
            projectRepository: projectRepository,
            clock: clock, calendar: utc, interval: 30)
        return (driver, projectRepository)
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
        let dispatcher = FakeTaskDispatcher()
        let (subject, _) = driver(tasks: [], projects: [], clock: MutableClock(now), dispatcher: dispatcher)
        await subject.start()
        await subject.start()
        await subject.stop()
        await subject.stop()
        // The timer fires no earlier than `interval`, so nothing should have been dispatched.
        #expect(dispatcher.enqueued.current.isEmpty)
    }
}
