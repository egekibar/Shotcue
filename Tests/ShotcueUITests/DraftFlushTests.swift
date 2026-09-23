import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// Review fix round 2, N1: drafts are flushed before any action hands the task on, and a draft commit only
/// writes its own field onto a fresh read of the row.
@Suite("Draft flushing")
struct DraftFlushTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func inspected(_ status: TaskStatus = .ready, dispatcher: Bool = false)
        async -> (
            bundle: FakeBundle, store: TaskDetailStore, task: ShotTask, project: Project,
            dispatcher: RecordingDispatcher?
        )
    {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(
            projectID: project.id, title: "Buton rengi", noteText: "eski not", status: status,
            scheduledAt: status == .scheduled ? t0.addingTimeInterval(3600) : nil, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let recording = dispatcher ? RecordingDispatcher(tasks: bundle.tasks, clock: bundle.clock) : nil
        let services = recording.map { bundle.services.replacingDispatcher($0) } ?? bundle.services
        let store = TaskDetailStore(services: services, taskID: task.id)
        await store.start()
        return (bundle, store, task, project, recording)
    }

    @MainActor
    @Test func sendNowPersistsTheTypedNoteBeforeDispatching() async throws {
        let f = await inspected(dispatcher: true)
        defer { f.bundle.cleanUp() }
        f.store.editNote("göndermeden önce yazıldı")

        await f.store.sendNow()

        #expect(f.dispatcher?.enqueuedNotes.current == ["göndermeden önce yazıldı"])
        #expect(try await f.bundle.tasks.task(id: f.task.id)?.noteText == "göndermeden önce yazıldı")
        f.store.stop()
    }

    /// Final review I2: the quit path asks whether the inspector holds text that was never committed.
    @MainActor
    @Test func uncommittedDraftsAreVisibleToTheQuitPath() async throws {
        let f = await inspected()
        defer { f.bundle.cleanUp() }
        #expect(f.store.hasUncommittedDrafts == false)
        f.store.editTitle("yarım başlık")
        #expect(f.store.hasUncommittedDrafts)

        await f.store.commitDrafts()
        #expect(f.store.hasUncommittedDrafts == false)
        #expect(try await f.bundle.tasks.task(id: f.task.id)?.title == "yarım başlık")
        f.store.stop()
    }

    @MainActor
    @Test func everyInspectorActionFlushesTheDraftsFirst() async throws {
        let later = t0.addingTimeInterval(7200)
        let actions: [(name: String, status: TaskStatus, run: (TaskDetailStore, UUID) async -> Void)] = [
            ("retry", .failed, { store, _ in await store.retry() }),
            ("schedule", .ready, { store, _ in await store.schedule(at: later) }),
            ("unschedule", .scheduled, { store, _ in await store.unschedule() }),
            ("addToDailyQueue", .failed, { store, _ in await store.addToDailyQueue() }),
            ("setMode", .ready, { store, _ in await store.setMode(.analyze) }),
            ("setModelOverride", .ready, { store, _ in await store.setModelOverride("opus") }),
            ("setProject", .ready, { store, projectID in await store.setProject(projectID) }),
            ("cancel", .queued, { store, _ in await store.cancel() }),
        ]
        for action in actions {
            let f = await inspected(action.status)
            f.store.editNote("\(action.name) notu")
            await action.run(f.store, f.project.id)
            #expect(
                try await f.bundle.tasks.task(id: f.task.id)?.noteText == "\(action.name) notu", "\(action.name)")
            f.store.stop()
            f.bundle.cleanUp()
        }
    }

    @MainActor
    @Test func libraryActionsOnTheInspectedTaskFlushItsDraftsFirst() async throws {
        let later = t0.addingTimeInterval(7200)
        let actions: [(name: String, run: (LibraryStore, ShotTask, ShotTask, Project) async -> Void)] = [
            ("send", { library, task, _, _ in await library.send(taskIDs: [task.id]) }),
            ("sendAsOne", { library, task, other, _ in await library.sendAsOne(taskIDs: [task.id, other.id]) }),
            ("move", { library, task, _, project in await library.move(taskIDs: [task.id], toProject: project.id) }),
            ("schedule", { library, task, _, _ in await library.schedule(taskIDs: [task.id], at: later) }),
            ("addToDailyQueue", { library, task, _, _ in await library.addToDailyQueue(taskIDs: [task.id]) }),
            (
                "reorder",
                { library, task, other, _ in await library.reorder(taskID: task.id, before: nil, after: other.id) }
            ),
        ]
        for action in actions {
            let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
            let task = ShotTask(
                projectID: project.id, title: "İncelenen", status: .failed, sortIndex: 1024, createdAt: t0,
                updatedAt: t0)
            let other = ShotTask(
                projectID: project.id, title: "Diğer", status: .ready, sortIndex: 2048, createdAt: t0, updatedAt: t0)
            let bundle = makeFakeServices(projects: [project], tasks: [task, other], clock: MutableClock(t0))
            let library = LibraryStore(services: bundle.services)
            library.start()
            #expect(await waitUntil("loaded") { library.projects.count == 1 })
            library.selection = .project(project.id)
            library.selectedTaskIDs = [task.id]
            let detail = try #require(library.detailStore)
            #expect(await waitUntil("detail loaded") { detail.task != nil })
            detail.editNote("\(action.name) notu")

            await action.run(library, task, other, project)

            let saved = try await bundle.tasks.task(id: task.id)
            #expect(saved?.noteText.contains("\(action.name) notu") == true, "\(action.name)")
            library.stop()
            bundle.cleanUp()
        }
    }

    @MainActor
    @Test func deletingTheSelectedTaskWithAPendingDraftDoesNotResurrectIt() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "Silinecek", status: .ready, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let library = LibraryStore(services: bundle.services)
        library.start()
        #expect(await waitUntil("loaded") { library.projects.count == 1 })
        library.selection = .project(project.id)
        library.selectedTaskIDs = [task.id]
        let detail = try #require(library.detailStore)
        #expect(await waitUntil("detail loaded") { detail.task != nil })
        detail.editNote("yarım taslak")

        library.requestDelete(taskIDs: [task.id])
        await library.confirmDelete(taskIDs: library.pendingDeleteIDs)
        // The inspector goes away afterwards and commits whatever it still holds.
        await detail.commitDrafts()

        #expect(try await bundle.tasks.task(id: task.id) == nil)
        library.stop()
    }

    @MainActor
    @Test func aTeardownCommitDoesNotRevertARemoteStatusChange() async throws {
        let f = await inspected()
        defer { f.bundle.cleanUp() }
        f.store.editNote("kapanırken kaydedilecek")
        // Torn down: the store no longer follows the stream, so its cached row goes stale.
        f.store.stop()
        var queued = try #require(try await f.bundle.tasks.task(id: f.task.id))
        try queued.transition(to: .queued, at: t0)
        try await f.bundle.tasks.save(queued)

        await f.store.commitDrafts()

        let saved = try #require(try await f.bundle.tasks.task(id: f.task.id))
        #expect(saved.status == .queued)
        #expect(saved.noteText == "kapanırken kaydedilecek")
    }

    @MainActor
    @Test func aDraftCommittedAgainstARunningTaskIsKeptWithAReason() async throws {
        let f = await inspected()
        defer { f.bundle.cleanUp() }
        f.store.editNote("yarım kalan not")
        // The queue starts the task before the field loses focus.
        var running = try #require(try await f.bundle.tasks.task(id: f.task.id))
        try running.transition(to: .queued, at: t0)
        try running.transition(to: .running, at: t0)
        try await f.bundle.tasks.save(running)

        await f.store.commit(.note)

        #expect(f.store.lastError == "Görev çalışırken not kaydedilemedi.")
        #expect(f.store.noteDraft == "yarım kalan not")
        let saved = try #require(try await f.bundle.tasks.task(id: f.task.id))
        #expect(saved.noteText == "eski not")
        #expect(saved.status == .running)
        f.store.stop()
    }
}

/// Review fix round 2, N2: the task stream is ignored only while the store's own write is in flight (no
/// timestamp filter), and a detach is stamped after the dispatcher's own write.
@Suite("Task stream during local writes")
struct TaskStreamLocalWriteTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func aRemoteWriteWithAnOlderTimestampIsApplied() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "Yerel", status: .ready, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let store = TaskDetailStore(services: bundle.services, taskID: task.id)
        await store.start()
        bundle.clock.advance(by: 60)
        await store.setMode(.analyze)
        #expect(store.task?.updatedAt == t0.addingTimeInterval(60))

        // Another writer with an older clock (or a wall-clock step back) changes the row.
        var remote = try #require(try await bundle.tasks.task(id: task.id))
        remote.title = "Uzaktan"
        remote.updatedAt = t0.addingTimeInterval(30)
        try await bundle.tasks.save(remote)

        #expect(await waitUntil("applied") { store.task?.title == "Uzaktan" })
        store.stop()
    }

    @MainActor
    @Test func anEmissionDuringALocalSaveDoesNotRollItBack() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "t", status: .ready, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let gate = Gate()
        let gated = GatedTaskRepository(base: bundle.tasks, saveGate: gate)
        let store = TaskDetailStore(services: bundle.services.replacingTasks(gated), taskID: task.id)
        await store.start()
        try await Task.sleep(for: .milliseconds(20))
        store.editNote("yerel değişiklik")

        let committing = Task { await store.commit(.note) }
        #expect(await waitUntil("parked in save") { gate.arrivals.current == 1 })
        // Another write broadcasts the row as the database still holds it (without the local change).
        try await bundle.tasks.save(ShotTask(title: "başka görev", createdAt: t0, updatedAt: t0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.task?.noteText == "yerel değişiklik")
        #expect(store.noteDraft == "yerel değişiklik")

        gate.open()
        await committing.value
        #expect(try await bundle.tasks.task(id: task.id)?.noteText == "yerel değişiklik")
        #expect(await waitUntil("settled") { store.task?.noteText == "yerel değişiklik" })
        store.stop()
    }

    @MainActor
    @Test func detachIsStampedAfterTheDispatchersOwnWrite() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let queued = ShotTask(projectID: project.id, title: "q", status: .queued, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [queued], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let dispatcher = RecordingDispatcher(tasks: bundle.tasks, clock: bundle.clock)
        let library = LibraryStore(services: bundle.services.replacingDispatcher(dispatcher))

        await library.move(taskIDs: [queued.id], toProject: nil)

        let saved = try #require(try await bundle.tasks.task(id: queued.id))
        #expect(dispatcher.cancelled.current == [queued.id])
        #expect(saved.status == .inbox && saved.projectID == nil)
        #expect(saved.updatedAt == t0.addingTimeInterval(5))
    }
}
