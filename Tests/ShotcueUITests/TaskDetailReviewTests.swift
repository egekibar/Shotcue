import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// Review fix round 1, item 5: "Günlük kuyruğa al" in the inspector makes the task `ready` (it used to
/// call `unschedule()`, a no-op for inbox/failed/cancelled/done tasks).
@Suite("TaskDetailStore daily queue")
struct TaskDetailDailyQueueTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func started(_ status: TaskStatus, withProject: Bool = true)
        async -> (bundle: FakeBundle, store: TaskDetailStore, task: ShotTask)
    {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(
            projectID: withProject ? project.id : nil, title: "t", status: status,
            scheduledAt: status == .scheduled ? t0.addingTimeInterval(3600) : nil, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let store = TaskDetailStore(services: bundle.services, taskID: task.id)
        await store.start()
        return (bundle, store, task)
    }

    @MainActor
    @Test func tasksWithAReadyEdgeBecomeReady() async throws {
        for status in [TaskStatus.failed, .cancelled, .scheduled, .inbox] {
            let f = await started(status)
            #expect(f.store.canAddToDailyQueue, "\(status)")
            await f.store.addToDailyQueue()
            #expect(try await f.bundle.tasks.task(id: f.task.id)?.status == .ready, "\(status)")
            #expect(f.store.task?.status == .ready, "\(status)")
            #expect(f.store.lastError == nil, "\(status)")
            f.store.stop()
            f.bundle.cleanUp()
        }
    }

    @MainActor
    @Test func aQueuedTaskLeavesTheQueueThroughTheDispatcher() async throws {
        let f = await started(.queued)
        #expect(f.store.canAddToDailyQueue)
        await f.store.addToDailyQueue()
        #expect(f.bundle.dispatcher.cancelledTasks.current == [f.task.id])
        #expect(try await f.bundle.tasks.task(id: f.task.id)?.status == .ready)
        #expect(f.store.lastError == nil)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func tasksWithoutAProjectOrAReadyEdgeAreRefusedWithAReason() async throws {
        let projectless = await started(.inbox, withProject: false)
        #expect(projectless.store.canAddToDailyQueue == false)
        await projectless.store.addToDailyQueue()
        #expect(projectless.store.lastError == "Günlük kuyruğa almak için önce bir proje seç.")
        #expect(try await projectless.bundle.tasks.task(id: projectless.task.id)?.status == .inbox)
        projectless.store.stop()
        projectless.bundle.cleanUp()

        let done = await started(.done)
        #expect(done.store.canAddToDailyQueue == false)
        await done.store.addToDailyQueue()
        #expect(done.store.lastError != nil)
        #expect(try await done.bundle.tasks.task(id: done.task.id)?.status == .done)
        done.store.stop()
        done.bundle.cleanUp()

        for status in [TaskStatus.ready, .running] {
            let f = await started(status)
            #expect(f.store.canAddToDailyQueue == false, "\(status)")
            f.store.stop()
            f.bundle.cleanUp()
        }
    }
}
