import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// Review fix round 1, item 1: stores never leak stream subscriptions and survive stop → start.
@Suite("Store lifecycle")
struct StoreLifecycleTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func projectWithTask() -> (bundle: FakeBundle, project: Project, task: ShotTask) {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(
            projectID: project.id, title: "Buton rengi", status: .ready, sortIndex: 1024,
            createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        return (bundle, project, task)
    }

    @MainActor
    @Test func stoppingADetailStoreDuringStartLeavesNoSubscriptions() async throws {
        let f = projectWithTask()
        defer { f.bundle.cleanUp() }
        let gate = Gate()
        let gated = GatedTaskRepository(base: f.bundle.tasks, readGate: gate)
        let store = TaskDetailStore(services: f.bundle.services.replacingTasks(gated), taskID: f.task.id)

        let starting = Task { await store.start() }
        #expect(await waitUntil("parked in reload") { gate.arrivals.current == 1 })
        store.stop()
        gate.open()
        await starting.value

        // Whatever the streams would deliver now must not reach the stopped store.
        try await f.bundle.runs.save(
            Run(taskID: f.task.id, state: .succeeded, startedAt: t0, logRelPath: "runs/late.jsonl"))
        var renamed = f.task
        renamed.title = "Yeni başlık"
        try await f.bundle.tasks.save(renamed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.runs.isEmpty)
        #expect(store.task?.title == "Buton rengi")
    }

    @MainActor
    @Test func aStoppedDetailStoreCanStartAgain() async throws {
        let f = projectWithTask()
        defer { f.bundle.cleanUp() }
        let store = TaskDetailStore(services: f.bundle.services, taskID: f.task.id)
        await store.start()
        store.stop()
        await store.start()
        try await f.bundle.runs.save(
            Run(taskID: f.task.id, state: .succeeded, startedAt: t0, logRelPath: "runs/again.jsonl"))
        #expect(await waitUntil("streams live again") { store.runs.count == 1 })
        store.stop()
    }

    @MainActor
    @Test func restartingTheLibraryRebuildsALiveDetailStore() async throws {
        let f = projectWithTask()
        defer { f.bundle.cleanUp() }
        let store = LibraryStore(services: f.bundle.services)
        store.start()
        #expect(await waitUntil("loaded") { store.projects.count == 1 })
        store.selection = .project(f.project.id)
        store.selectedTaskIDs = [f.task.id]
        let first = try #require(store.detailStore)

        store.stop()
        #expect(store.detailStore == nil)

        store.start()
        let second = try #require(store.detailStore)
        #expect(second !== first)
        #expect(await waitUntil("detail loaded") { second.task?.id == f.task.id })

        var renamed = f.task
        renamed.title = "Yeni başlık"
        try await f.bundle.tasks.save(renamed)
        #expect(await waitUntil("detail follows the stream") { second.task?.title == "Yeni başlık" })
        // The dropped store never went live (its start task was cancelled before it ran).
        #expect(first.task?.title != "Yeni başlık")
        store.stop()
    }

    @MainActor
    @Test func unstoppedStoresAreNotKeptAliveByTheirStreams() async throws {
        let f = projectWithTask()
        defer { f.bundle.cleanUp() }
        weak var weakDetail: TaskDetailStore?
        weak var weakLibrary: LibraryStore?
        weak var weakMenu: MenuBarStore?
        do {
            let detail = TaskDetailStore(services: f.bundle.services, taskID: f.task.id)
            await detail.start()
            let library = LibraryStore(services: f.bundle.services)
            library.start()
            let menu = MenuBarStore(services: f.bundle.services)
            menu.start()
            // Let every stream task reach its `for await` suspension while the stores are alive.
            try await Task.sleep(for: .milliseconds(50))
            weakDetail = detail
            weakLibrary = library
            weakMenu = menu
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(weakDetail == nil)
        #expect(weakLibrary == nil)
        #expect(weakMenu == nil)
    }
}
