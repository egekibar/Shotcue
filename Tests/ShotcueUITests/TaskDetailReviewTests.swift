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

/// Review fix round 1, item 6: the run log follows the selected run, survives the end of a live run, and a
/// slow replay of an earlier selection never overwrites a newer one.
@Suite("TaskDetailStore run log selection")
struct TaskDetailRunLogTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    static let initLine = #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-5"}"#
    static func textLine(_ text: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":""# + text + #""}]}}"#
    }
    static let resultLine = #"{"type":"result","subtype":"success","is_error":false,"num_turns":3}"#

    @MainActor
    func started(_ status: TaskStatus) async -> (bundle: FakeBundle, store: TaskDetailStore, task: ShotTask) {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "t", status: status, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let store = TaskDetailStore(services: bundle.services, taskID: task.id)
        await store.start()
        return (bundle, store, task)
    }

    @MainActor
    @Test func theLogStaysVisibleWhenTheLiveRunEnds() async throws {
        let f = await started(.running)
        defer { f.bundle.cleanUp() }
        let run = Run(taskID: f.task.id, state: .running, startedAt: t0, logRelPath: "runs/live.jsonl")
        try await f.bundle.runs.save(run)
        #expect(await waitUntil("subscribed") { !f.store.liveEvents.isEmpty })
        f.bundle.dispatcher.emit(runID: run.id, event: .assistantText("bir"))
        f.bundle.dispatcher.emit(runID: run.id, event: .assistantText("iki"))
        #expect(await waitUntil("streamed") { f.store.liveEvents.count == 3 })
        #expect(f.store.isDisplayingLiveRun)

        var ended = run
        ended.state = .succeeded
        ended.finishedAt = t0.addingTimeInterval(60)
        try await f.bundle.runs.save(ended)
        #expect(await waitUntil("ended") { f.store.activeRun == nil })

        #expect(f.store.selectedRunID == run.id)
        #expect(f.store.isDisplayingLiveRun == false)
        #expect(f.store.displayedEvents.count == 3)
        #expect(f.store.displayedEvents.last == .assistantText("iki"))
        f.store.stop()
    }

    @MainActor
    @Test func theEndedRunIsRefreshedFromItsCompleteLogFile() async throws {
        let f = await started(.running)
        defer { f.bundle.cleanUp() }
        let run = Run(taskID: f.task.id, state: .running, startedAt: t0, logRelPath: "runs/full.jsonl")
        try await f.bundle.runs.save(run)
        #expect(await waitUntil("subscribed") { !f.store.liveEvents.isEmpty })
        try f.bundle.writeFile(
            "runs/full.jsonl",
            contents: [Self.initLine, Self.textLine("merhaba"), Self.resultLine].joined(separator: "\n"))

        var ended = run
        ended.state = .succeeded
        try await f.bundle.runs.save(ended)

        #expect(await waitUntil("replayed") { f.store.displayedEvents.count == 3 })
        #expect(f.store.displayedEvents.first == .initialized(sessionID: "s1", model: "claude-sonnet-5"))
        #expect(f.store.displayedEvents.count == 3 && f.store.displayedEvents[1] == .assistantText("merhaba"))
        f.store.stop()
    }

    @MainActor
    @Test func anOlderRunCanBeViewedDuringALiveRun() async throws {
        let f = await started(.running)
        defer { f.bundle.cleanUp() }
        try f.bundle.writeFile("runs/older.jsonl", contents: Self.textLine("eski"))
        let older = Run(
            taskID: f.task.id, state: .failed, startedAt: t0.addingTimeInterval(-3600),
            finishedAt: t0.addingTimeInterval(-3000), logRelPath: "runs/older.jsonl")
        let live = Run(taskID: f.task.id, state: .running, startedAt: t0, logRelPath: "runs/live.jsonl")
        try await f.bundle.runs.save(older)
        try await f.bundle.runs.save(live)
        #expect(await waitUntil("subscribed") { !f.store.liveEvents.isEmpty && f.store.runs.count == 2 })
        #expect(f.store.selectedRunID == live.id)

        await f.store.selectRun(older.id)
        #expect(f.store.isDisplayingLiveRun == false)
        #expect(f.store.displayedEvents == [.assistantText("eski")])

        f.bundle.dispatcher.emit(runID: live.id, event: .assistantText("canlı"))
        #expect(await waitUntil("streamed") { f.store.liveEvents.count == 2 })
        #expect(f.store.displayedEvents == [.assistantText("eski")])

        await f.store.selectRun(live.id)
        #expect(f.store.isDisplayingLiveRun)
        #expect(f.store.displayedEvents == f.store.liveEvents)
        f.store.stop()
    }

    @MainActor
    @Test func aSlowReplayOfAnEarlierSelectionDoesNotWin() async throws {
        let f = await started(.done)
        defer { f.bundle.cleanUp() }
        try f.bundle.writeFile("runs/slow.jsonl", contents: Self.textLine("yavaş"))
        try f.bundle.writeFile("runs/fast.jsonl", contents: Self.textLine("hızlı"))
        let slowRun = Run(
            taskID: f.task.id, state: .succeeded, startedAt: t0.addingTimeInterval(-60),
            logRelPath: "runs/slow.jsonl")
        let fastRun = Run(taskID: f.task.id, state: .succeeded, startedAt: t0, logRelPath: "runs/fast.jsonl")
        try await f.bundle.runs.save(slowRun)
        try await f.bundle.runs.save(fastRun)
        #expect(await waitUntil("runs") { f.store.runs.count == 2 })

        let gate = Gate()
        f.store.logLineReader = { url in
            if url.lastPathComponent == "slow.jsonl" { await gate.wait() }
            return (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        }
        let slowSelection = Task { await f.store.selectRun(slowRun.id) }
        #expect(await waitUntil("slow replay parked") { gate.arrivals.current == 1 })
        await f.store.selectRun(fastRun.id)
        gate.open()
        await slowSelection.value

        #expect(f.store.selectedRunID == fastRun.id)
        #expect(f.store.displayedEvents == [.assistantText("hızlı")])
        f.store.stop()
    }
}
