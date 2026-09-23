import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

@Suite("LibraryStore")
struct LibraryStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)  // 2026-09-22 12:00 UTC

    /// Two projects, five tasks: 2 in project A (ready + done), 1 in project B (running), 2 in the inbox.
    @MainActor
    func fixture() -> (
        bundle: FakeBundle, store: LibraryStore,
        projectA: Project, projectB: Project, tasks: [ShotTask]
    ) {
        let projectA = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let projectB = Project(name: "api-core", path: "/tmp/api-core", sortIndex: 2048, createdAt: t0)
        let a1 = ShotTask(
            projectID: projectA.id, title: "Buton rengi", noteText: "kırmızı olmalı",
            status: .ready, sortIndex: 1024,
            createdAt: t0.addingTimeInterval(-300), updatedAt: t0.addingTimeInterval(-300))
        let a2 = ShotTask(
            projectID: projectA.id, title: "Login akışı", status: .done, sortIndex: 2048,
            createdAt: t0.addingTimeInterval(-600), updatedAt: t0.addingTimeInterval(-60))
        let b1 = ShotTask(
            projectID: projectB.id, title: "Cache", status: .running, sortIndex: 1024,
            createdAt: t0.addingTimeInterval(-900), updatedAt: t0.addingTimeInterval(-10))
        let i1 = ShotTask(
            title: "Yakalama 1", status: .inbox, sortIndex: 1024,
            createdAt: t0.addingTimeInterval(-100), updatedAt: t0.addingTimeInterval(-100))
        let i2 = ShotTask(
            title: "Yakalama 2", status: .inbox, sortIndex: 2048,
            createdAt: t0.addingTimeInterval(-50), updatedAt: t0.addingTimeInterval(-50))
        let bundle = makeFakeServices(
            projects: [projectA, projectB], tasks: [a1, a2, b1, i1, i2],
            clock: MutableClock(t0))
        return (bundle, LibraryStore(services: bundle.services), projectA, projectB, [a1, a2, b1, i1, i2])
    }

    @MainActor
    @Test func startLoadsProjectsTasksAndCounts() async {
        let f = fixture()
        f.store.start()
        #expect(await waitUntil("projects") { f.store.projects.count == 2 })
        #expect(await waitUntil("counts") { f.store.counts[.inbox] == 2 })
        #expect(f.store.counts[.project(f.projectA.id)] == 2)
        #expect(f.store.counts[.project(f.projectB.id)] == 1)
        #expect(f.store.counts[.status(.ready)] == 1)
        #expect(f.store.counts[.status(.inbox)] == 2)
        #expect(f.store.counts[.status(.cancelled)] == 0)
        // Default selection is the inbox.
        #expect(f.store.selection == .inbox)
        #expect(f.store.tasks.count == 2)
        #expect(f.store.tasks.allSatisfy { $0.projectID == nil })
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func selectionFiltersTheContentList() async {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.counts[.inbox] == 2 }

        f.store.selection = .project(f.projectA.id)
        #expect(f.store.tasks.count == 2)
        #expect(f.store.tasks.allSatisfy { $0.projectID == f.projectA.id })

        f.store.selection = .status(.running)
        #expect(f.store.tasks.map(\.title) == ["Cache"])

        f.store.selection = .inbox
        #expect(f.store.tasks.count == 2)
        // Changing the selection clears the content selection.
        #expect(f.store.selectedTaskIDs.isEmpty)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func sortedTasksHonoursEverySortOrder() async {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        f.store.selection = .project(f.projectA.id)

        f.store.sortOrder = .newest
        #expect(f.store.sortedTasks.map(\.title) == ["Buton rengi", "Login akışı"])

        f.store.sortOrder = .oldest
        #expect(f.store.sortedTasks.map(\.title) == ["Login akışı", "Buton rengi"])

        f.store.sortOrder = .manual
        #expect(f.store.sortedTasks.map(\.sortIndex) == [1024, 2048])

        f.store.sortOrder = .status
        // ready (rank 3) comes before done (rank 6)
        #expect(f.store.sortedTasks.map(\.status) == [.ready, .done])
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func searchDelegatesToTheRepository() async throws {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        // A transcript only the repository can see.
        try await f.bundle.services.tasks.save(
            VoiceNote(
                taskID: f.tasks[0].id, relPath: "audio/a.m4a", durationSec: 4,
                transcript: "cache temizlensin", transcriptState: .done))

        f.store.selection = .project(f.projectA.id)
        f.store.searchText = "cache"
        await f.store.runSearch()
        #expect(f.store.tasks.map(\.id) == [f.tasks[0].id])

        f.store.searchText = "  "
        await f.store.runSearch()
        #expect(f.store.tasks.count == 2)
        f.store.stop()
        f.bundle.cleanUp()
    }

    /// Final review M9: while a search is active the grid shows the live rows, so a status chip or a title that
    /// changes (a run starts, a transcript fills the title) updates without searching again.
    @MainActor
    @Test func searchResultsFollowTheLiveRows() async throws {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        f.store.selection = .project(f.projectA.id)
        f.store.searchText = "Buton"
        await f.store.runSearch()
        #expect(f.store.tasks.map(\.id) == [f.tasks[0].id])

        var changed = try #require(try await f.bundle.services.tasks.task(id: f.tasks[0].id))
        try changed.transition(to: .queued, at: t0)
        changed.title = "Buton rengi (güncel)"
        try await f.bundle.services.tasks.save(changed)

        #expect(await waitUntil("live row") { f.store.tasks.first?.status == .queued })
        #expect(f.store.tasks.map(\.title) == ["Buton rengi (güncel)"])
        #expect(f.store.tasks.map(\.id) == [f.tasks[0].id])

        // A deleted result disappears instead of lingering from the snapshot.
        try await f.bundle.services.tasks.deleteTask(id: f.tasks[0].id)
        #expect(await waitUntil("deleted") { f.store.tasks.isEmpty })
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func sendEnqueuesEverySelectedTask() async {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        await f.store.send(taskIDs: [f.tasks[0].id, f.tasks[1].id])
        #expect(Set(f.bundle.dispatcher.enqueued.current) == Set([f.tasks[0].id, f.tasks[1].id]))
        #expect(f.store.lastError == nil)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func sendAsOneMergesCapturesNotesAndDeletesTheRest() async throws {
        let f = fixture()
        let primary = f.tasks[0]
        let secondary = f.tasks[1]
        let capture = Capture(
            taskID: secondary.id, relPath: "captures/2026/09/b.png",
            width: 100, height: 50)
        let note = VoiceNote(
            taskID: secondary.id, relPath: "audio/b.m4a", durationSec: 3,
            transcript: "ikinci not", transcriptState: .done)
        try await f.bundle.services.tasks.save(capture)
        try await f.bundle.services.tasks.save(note)
        try await f.bundle.services.tasks.save(
            Capture(taskID: primary.id, relPath: "captures/2026/09/a.png", width: 10, height: 10))

        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        await f.store.sendAsOne(taskIDs: [primary.id, secondary.id])

        #expect(try await f.bundle.services.tasks.captures(taskID: primary.id).count == 2)
        #expect(try await f.bundle.services.tasks.voiceNotes(taskID: primary.id).count == 1)
        #expect(try await f.bundle.services.tasks.task(id: secondary.id) == nil)
        #expect(f.bundle.dispatcher.enqueued.current == [primary.id])
        #expect(f.store.selectedTaskIDs == [primary.id])
        // Both notes ended up in the surviving task's note text.
        let merged = try await f.bundle.services.tasks.task(id: primary.id)
        #expect(merged?.noteText.contains("kırmızı olmalı") == true)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func moveFromInboxAssignsProjectAndBecomesReady() async throws {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        let inboxTask = f.tasks[3]
        await f.store.move(taskIDs: [inboxTask.id], toProject: f.projectA.id)

        let moved = try #require(try await f.bundle.services.tasks.task(id: inboxTask.id))
        #expect(moved.projectID == f.projectA.id)
        #expect(moved.status == .ready)
        #expect(moved.updatedAt == t0)

        // Moving back to the inbox clears the project and returns to `inbox`.
        await f.store.move(taskIDs: [inboxTask.id], toProject: nil)
        let back = try #require(try await f.bundle.services.tasks.task(id: inboxTask.id))
        #expect(back.projectID == nil)
        #expect(back.status == .inbox)

        // A running task is never edited (spec §7).
        await f.store.move(taskIDs: [f.tasks[2].id], toProject: f.projectA.id)
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[2].id)?.projectID == f.projectB.id)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func scheduleSetsDateAndStatus() async throws {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        let when = t0.addingTimeInterval(7200)
        await f.store.schedule(taskIDs: [f.tasks[0].id], at: when)

        let scheduled = try #require(try await f.bundle.services.tasks.task(id: f.tasks[0].id))
        #expect(scheduled.status == .scheduled)
        #expect(scheduled.scheduledAt == when)

        // An inbox task cannot be scheduled: inbox only transitions to ready.
        await f.store.schedule(taskIDs: [f.tasks[3].id], at: when)
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[3].id)?.status == .inbox)
        #expect(f.store.lastError != nil)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func addToDailyQueueEnsuresReady() async throws {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        await f.store.addToDailyQueue(taskIDs: [f.tasks[1].id, f.tasks[0].id, f.tasks[3].id])
        // done -> queued is legal but "günlük kuyruğa al" means ready; done has no ready edge, so it is skipped.
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[1].id)?.status == .done)
        // already ready: untouched
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[0].id)?.status == .ready)
        // inbox without a project cannot become ready
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[3].id)?.status == .inbox)

        // With a project it becomes ready.
        await f.store.move(taskIDs: [f.tasks[3].id], toProject: f.projectB.id)
        await f.store.addToDailyQueue(taskIDs: [f.tasks[3].id])
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[3].id)?.status == .ready)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func deleteRemovesRowsAndFiles() async throws {
        let f = fixture()
        let target = f.tasks[0]
        let capRel = "captures/2026/09/del.png"
        let thumbRel = "thumbs/del.jpg"
        let audioRel = "audio/del.m4a"
        let logRel = "runs/del.jsonl"
        try f.bundle.writeFile(capRel)
        try f.bundle.writeFile(thumbRel)
        try f.bundle.writeFile(audioRel)
        try f.bundle.writeFile(logRel)
        try await f.bundle.services.tasks.save(
            Capture(taskID: target.id, relPath: capRel, thumbRelPath: thumbRel, width: 8, height: 8))
        try await f.bundle.services.tasks.save(
            VoiceNote(taskID: target.id, relPath: audioRel, durationSec: 1))
        try await f.bundle.services.runs.save(
            Run(taskID: target.id, state: .succeeded, logRelPath: logRel))

        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        f.store.selectedTaskIDs = [target.id]
        await f.store.delete(taskIDs: [target.id])

        #expect(try await f.bundle.services.tasks.task(id: target.id) == nil)
        #expect(f.bundle.fileExists(capRel) == false)
        #expect(f.bundle.fileExists(thumbRel) == false)
        #expect(f.bundle.fileExists(audioRel) == false)
        #expect(f.bundle.fileExists(logRel) == false)
        #expect(f.store.selectedTaskIDs.isEmpty)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func reorderComputesFractionalIndexAndRenumbersWhenTheGapCollapses() async throws {
        let renumbered = Locked<[UUID?]>([])
        let projectA = Project(name: "acme", path: "/tmp/acme", sortIndex: 1024, createdAt: t0)
        let first = ShotTask(projectID: projectA.id, title: "1", status: .ready, sortIndex: 1024, createdAt: t0)
        let second = ShotTask(projectID: projectA.id, title: "2", status: .ready, sortIndex: 2048, createdAt: t0)
        let moving = ShotTask(projectID: projectA.id, title: "3", status: .ready, sortIndex: 4096, createdAt: t0)
        let bundle = makeFakeServices(
            projects: [projectA], tasks: [first, second, moving],
            clock: MutableClock(t0))
        let store = LibraryStore(services: bundle.services) { projectID in
            renumbered.withLock { $0.append(projectID) }
        }
        store.start()
        _ = await waitUntil("loaded") { store.projects.count == 1 }
        // `store.tasks` is filtered by the sidebar selection (default: inbox); show the project so the
        // "tight saved" wait below can see its rows.
        store.selection = .project(projectA.id)

        await store.reorder(taskID: moving.id, before: first.id, after: second.id)
        #expect(try await bundle.services.tasks.task(id: moving.id)?.sortIndex == 1536)
        #expect(renumbered.current.isEmpty)

        // Dropping at the very top and the very bottom.
        await store.reorder(taskID: moving.id, before: nil, after: first.id)
        #expect(try await bundle.services.tasks.task(id: moving.id)?.sortIndex == 1024 - SortIndex.step)
        await store.reorder(taskID: moving.id, before: second.id, after: nil)
        #expect(try await bundle.services.tasks.task(id: moving.id)?.sortIndex == 2048 + SortIndex.step)

        // Exhausted gap triggers the renumber closure with the project id.
        var tight = second
        tight.sortIndex = 1024 + 1e-9
        try await bundle.services.tasks.save(tight)
        _ = await waitUntil("tight saved") {
            store.tasks.contains { $0.id == tight.id && $0.sortIndex < 1025 }
        }
        await store.reorder(taskID: moving.id, before: first.id, after: tight.id)
        #expect(renumbered.current == [projectA.id])
        store.stop()
        bundle.cleanUp()
    }

    @MainActor
    @Test func createAndDeleteProject() async throws {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }

        await f.store.createProject(name: "new-app", path: "/tmp/new-app")
        #expect(await waitUntil("created") { f.store.projects.count == 3 })
        let created = try #require(f.store.projects.first { $0.name == "new-app" })
        #expect(created.sortIndex == 2048 + SortIndex.step)
        #expect(f.store.selection == .project(created.id))

        // Deleting a project sends its tasks back to the inbox instead of deleting them.
        await f.store.deleteProject(id: f.projectA.id)
        #expect(await waitUntil("deleted") { f.store.projects.count == 2 })
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[0].id)?.projectID == nil)
        #expect(try await f.bundle.services.tasks.task(id: f.tasks[0].id)?.status == .inbox)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func queueControlsReachTheDispatcher() async {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        await f.store.runQueueNow()
        #expect(f.bundle.dispatcher.runQueueCalls.current == 1)

        await f.store.setPaused(true)
        #expect(f.bundle.dispatcher.paused.current == true)
        #expect(f.store.isPaused == true)
        await f.store.setPaused(false)
        #expect(f.store.isPaused == false)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func singleSelectionBuildsADetailStore() async {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        #expect(f.store.detailStore == nil)

        f.store.selectedTaskIDs = [f.tasks[0].id]
        #expect(f.store.detailStore?.taskID == f.tasks[0].id)

        f.store.selectedTaskIDs = [f.tasks[0].id, f.tasks[1].id]
        #expect(f.store.detailStore == nil)

        f.store.selectedTaskIDs = []
        #expect(f.store.detailStore == nil)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func gridSelectionHandlesCommandAndShiftClicks() async {
        let f = fixture()
        f.store.start()
        _ = await waitUntil("loaded") { f.store.projects.count == 2 }
        f.store.selection = .project(f.projectA.id)
        f.store.sortOrder = .manual
        let ordered = f.store.sortedTasks.map(\.id)

        f.store.toggleSelection(taskID: ordered[0], extend: false, range: false)
        #expect(f.store.selectedTaskIDs == [ordered[0]])

        f.store.toggleSelection(taskID: ordered[1], extend: true, range: false)
        #expect(f.store.selectedTaskIDs == Set(ordered))

        f.store.toggleSelection(taskID: ordered[1], extend: true, range: false)
        #expect(f.store.selectedTaskIDs == [ordered[0]])

        f.store.toggleSelection(taskID: ordered[1], extend: false, range: true)
        #expect(f.store.selectedTaskIDs == Set(ordered))

        f.store.toggleSelection(taskID: ordered[1], extend: false, range: false)
        #expect(f.store.selectedTaskIDs == [ordered[1]])
        f.store.stop()
        f.bundle.cleanUp()
    }
}
