import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// Review fix round 1, items 3 and 11: deleting never touches a running task or anything outside the four
/// data folders, and nothing is deleted before the user confirms.
@Suite("Delete safety")
struct DeleteSafetyTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func aRunningTaskSurvivesDelete() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let running = ShotTask(projectID: project.id, title: "run", status: .running, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [running], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let capRel = "captures/2026/09/run.png"
        try bundle.writeFile(capRel)
        try await bundle.services.tasks.save(Capture(taskID: running.id, relPath: capRel, width: 8, height: 8))
        let store = LibraryStore(services: bundle.services)

        await store.delete(taskIDs: [running.id])

        #expect(try await bundle.tasks.task(id: running.id) != nil)
        #expect(bundle.fileExists(capRel))
        #expect(store.lastError != nil)
    }

    /// Only paths whose damage the old code would have kept inside this test's own temp root are used
    /// here; `..` itself (which resolves to the parent of the root) is covered by the pure test below.
    @MainActor
    @Test func malformedRelativePathsAreNeverRemoved() async throws {
        let task = ShotTask(title: "t", status: .inbox, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(tasks: [task], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let outside = bundle.root.deletingLastPathComponent()
            .appendingPathComponent("shotcue-sentinel-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try bundle.writeFile("captures/keep.png")
        try bundle.writeFile("shotcue.sqlite")
        try await bundle.services.tasks.save(
            Capture(taskID: task.id, relPath: "captures", thumbRelPath: "", width: 1, height: 1))
        try await bundle.services.tasks.save(
            VoiceNote(taskID: task.id, relPath: "../\(outside.lastPathComponent)", durationSec: 1))
        try await bundle.services.runs.save(Run(taskID: task.id, state: .succeeded, logRelPath: "shotcue.sqlite"))
        let store = LibraryStore(services: bundle.services)

        await store.delete(taskIDs: [task.id])

        #expect(try await bundle.tasks.task(id: task.id) == nil)
        #expect(FileManager.default.fileExists(atPath: bundle.root.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(bundle.fileExists("captures/keep.png"))
        #expect(bundle.fileExists("shotcue.sqlite"))
    }

    @Test func onlyFilesInsideTheDataFoldersAreRemovable() {
        let fileStore = FileStore(rootURL: URL(fileURLWithPath: "/tmp/shotcue-root", isDirectory: true))
        for good in ["captures/2026/09/a.png", "thumbs/a.jpg", "audio/a.m4a", "runs/a.jsonl", " runs/b.jsonl "] {
            let expected = fileStore.absoluteURL(for: good.trimmingCharacters(in: .whitespaces)).standardizedFileURL
            #expect(LibraryStore.removableURL(for: good, in: fileStore) == expected, "\(good)")
        }
        let bad = [
            "", "   ", ".", "..", "../x.png", "captures/../..", "captures/../../x", "captures", "captures/",
            "shotcue.sqlite", "runs/../shotcue.sqlite", "/etc/hosts", "other/a.png",
        ]
        for path in bad {
            #expect(LibraryStore.removableURL(for: path, in: fileStore) == nil, "\(path)")
        }
    }

    @MainActor
    @Test func deleteAsksForConfirmationFirst() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let ready = ShotTask(projectID: project.id, title: "r", status: .ready, createdAt: t0, updatedAt: t0)
        let other = ShotTask(projectID: project.id, title: "o", status: .done, createdAt: t0, updatedAt: t0)
        let running = ShotTask(projectID: project.id, title: "run", status: .running, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [ready, other, running], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let store = LibraryStore(services: bundle.services)
        store.start()
        #expect(await waitUntil("loaded") { store.projects.count == 1 })

        store.requestDelete(taskIDs: [ready.id])
        #expect(store.pendingDeleteIDs == [ready.id])
        #expect(store.isDeleteConfirmationPresented)
        #expect(store.deleteConfirmationTitle == "Görev kalıcı olarak silinsin mi?")
        #expect(try await bundle.tasks.task(id: ready.id) != nil)

        // Dismissing the dialog deletes nothing.
        store.isDeleteConfirmationPresented = false
        #expect(store.pendingDeleteIDs.isEmpty)
        #expect(try await bundle.tasks.task(id: ready.id) != nil)

        store.requestDelete(taskIDs: [ready.id, other.id])
        #expect(store.deleteConfirmationTitle == "2 görev kalıcı olarak silinsin mi?")
        await store.confirmDelete(taskIDs: store.pendingDeleteIDs)
        #expect(store.pendingDeleteIDs.isEmpty)
        #expect(try await bundle.tasks.task(id: ready.id) == nil)
        #expect(try await bundle.tasks.task(id: other.id) == nil)

        // A running task is never offered for deletion.
        store.requestDelete(taskIDs: [running.id])
        #expect(store.pendingDeleteIDs.isEmpty)
        #expect(store.lastError != nil)
        store.stop()
    }

    @MainActor
    @Test func deleteIsUnavailableWhileTheSelectionContainsARunningTask() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let ready = ShotTask(projectID: project.id, title: "r", status: .ready, createdAt: t0, updatedAt: t0)
        let running = ShotTask(projectID: project.id, title: "run", status: .running, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [ready, running], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let store = LibraryStore(services: bundle.services)
        store.start()
        #expect(await waitUntil("loaded") { store.projects.count == 1 })
        store.selection = .project(project.id)

        store.selectedTaskIDs = [ready.id]
        #expect(store.canDeleteSelection)
        store.selectedTaskIDs = [ready.id, running.id]
        #expect(store.canDeleteSelection == false)
        #expect(store.canDelete(taskIDs: [running.id]) == false)
        #expect(store.canDelete(taskIDs: []) == false)
        store.stop()
    }
}
