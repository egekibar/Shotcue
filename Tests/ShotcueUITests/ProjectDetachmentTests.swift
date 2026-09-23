import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// Review fix round 1, item 2: taking a task out of its project never leaves it in a status it cannot
/// leave (`ready`/`queued`/`scheduled` need a project; `failed`/`cancelled` only leave through such edges).
@Suite("Project detachment")
struct ProjectDetachmentTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func task(_ status: TaskStatus, in project: Project, title: String) -> ShotTask {
        ShotTask(
            projectID: project.id, title: title, status: status,
            scheduledAt: status == .scheduled ? t0.addingTimeInterval(3600) : nil,
            createdAt: t0, updatedAt: t0)
    }

    @MainActor
    @Test func movingToTheInboxNeverStrandsATask() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let movable: [ShotTask] = [
            task(.queued, in: project, title: "q"), task(.scheduled, in: project, title: "s"),
            task(.failed, in: project, title: "f"), task(.cancelled, in: project, title: "c"),
            task(.ready, in: project, title: "r"),
        ]
        let done = task(.done, in: project, title: "d")
        let running = task(.running, in: project, title: "run")
        let bundle = makeFakeServices(
            projects: [project], tasks: movable + [done, running], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let store = LibraryStore(services: bundle.services)
        store.start()
        #expect(await waitUntil("loaded") { store.projects.count == 1 })

        await store.move(taskIDs: Set((movable + [done, running]).map(\.id)), toProject: nil)

        for original in movable {
            let saved = try #require(try await bundle.tasks.task(id: original.id))
            #expect(saved.projectID == nil, "\(original.title)")
            #expect(saved.status == .inbox, "\(original.title)")
            #expect(saved.scheduledAt == nil, "\(original.title)")
        }
        let savedDone = try #require(try await bundle.tasks.task(id: done.id))
        #expect(savedDone.projectID == nil && savedDone.status == .done)
        let savedRunning = try #require(try await bundle.tasks.task(id: running.id))
        #expect(savedRunning.projectID == project.id && savedRunning.status == .running)
        // The queued one left the queue through the dispatcher, which owns it.
        #expect(bundle.dispatcher.cancelledTasks.current == [movable[0].id])
        #expect(store.lastError == nil)

        // A detached task is usable again: giving it a project makes it ready.
        await store.move(taskIDs: [movable[2].id], toProject: project.id)
        #expect(try await bundle.tasks.task(id: movable[2].id)?.status == .ready)
        store.stop()
    }

    @MainActor
    @Test func deletingAProjectWithARunningTaskIsRefused() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let running = task(.running, in: project, title: "run")
        let ready = task(.ready, in: project, title: "r")
        let bundle = makeFakeServices(projects: [project], tasks: [running, ready], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let store = LibraryStore(services: bundle.services)

        await store.deleteProject(id: project.id)

        #expect(store.lastError != nil)
        #expect(try await bundle.projects.project(id: project.id) != nil)
        #expect(try await bundle.tasks.task(id: ready.id)?.projectID == project.id)
        #expect(try await bundle.tasks.task(id: ready.id)?.status == .ready)
    }

    @MainActor
    @Test func deletingAProjectDetachesItsTasksFromTheRepository() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let queued = task(.queued, in: project, title: "q")
        let failed = task(.failed, in: project, title: "f")
        let done = task(.done, in: project, title: "d")
        let bundle = makeFakeServices(
            projects: [project], tasks: [queued, failed, done], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        // Never started: there is no stream snapshot, so the tasks must come from the repository.
        let store = LibraryStore(services: bundle.services)

        await store.deleteProject(id: project.id)

        #expect(try await bundle.projects.project(id: project.id) == nil)
        for original in [queued, failed] {
            let saved = try #require(try await bundle.tasks.task(id: original.id))
            #expect(saved.projectID == nil && saved.status == .inbox, "\(original.title)")
        }
        let savedDone = try #require(try await bundle.tasks.task(id: done.id))
        #expect(savedDone.projectID == nil && savedDone.status == .done)
        #expect(bundle.dispatcher.cancelledTasks.current == [queued.id])
        #expect(store.lastError == nil)
    }

    @MainActor
    @Test func clearingTheProjectInTheInspectorNeverStrandsATask() async throws {
        for status in [TaskStatus.queued, .scheduled, .failed, .cancelled, .ready] {
            let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
            let original = task(status, in: project, title: status.rawValue)
            let bundle = makeFakeServices(projects: [project], tasks: [original], clock: MutableClock(t0))
            let store = TaskDetailStore(services: bundle.services, taskID: original.id)
            await store.start()

            await store.setProject(nil)

            let saved = try #require(try await bundle.tasks.task(id: original.id))
            #expect(saved.projectID == nil && saved.status == .inbox, "\(status)")
            #expect(store.task?.status == .inbox, "\(status)")
            #expect(store.lastError == nil, "\(status)")
            store.stop()
            bundle.cleanUp()
        }
    }

    @Test func withoutProjectIsPureAndRefusesARunningTask() throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let scheduled = ShotTask(
            projectID: project.id, title: "s", status: .scheduled, scheduledAt: t0.addingTimeInterval(60),
            createdAt: t0, updatedAt: t0)
        let later = t0.addingTimeInterval(120)
        let detached = try ProjectAssignment.withoutProject(scheduled, now: later)
        #expect(detached.status == .inbox && detached.projectID == nil && detached.scheduledAt == nil)
        #expect(detached.updatedAt == later)

        let running = ShotTask(projectID: project.id, title: "r", status: .running, createdAt: t0, updatedAt: t0)
        #expect(throws: TaskStateError.self) { try ProjectAssignment.withoutProject(running, now: later) }
    }
}
