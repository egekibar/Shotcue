import Foundation
import ShotcueCore
import ShotcueTestSupport
import SwiftUI
import Testing

@testable import ShotcueUI

@Suite("MenuBarView")
struct MenuBarViewTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func viewIsWiredToItsStoreAndCallbacks() async {
        let projectID = UUID()
        let bundle = makeFakeServices(
            tasks: [
                ShotTask(
                    projectID: projectID, title: "Buton rengi", status: .running,
                    createdAt: t0, updatedAt: t0)
            ],
            clock: MutableClock(t0))
        let store = MenuBarStore(services: bundle.services)
        store.start()
        _ = await waitUntil("recent") { store.recentTasks.count == 1 }

        let hits = Locked<[String]>([])
        let view = MenuBarView(
            store: store,
            openLibrary: { hits.withLock { $0.append("library") } },
            openSettings: { hits.withLock { $0.append("settings") } },
            quit: { hits.withLock { $0.append("quit") } })

        #expect(view.store === store)
        view.openLibrary()
        view.openSettings()
        view.quit()
        #expect(hits.current == ["library", "settings", "quit"])
        #expect(store.runningCount == 1)
        store.stop()
        bundle.cleanUp()
    }
}

@Suite("LibraryView")
struct LibraryViewTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func libraryViewHoldsTheStoreAndShipsTheFallbackReorderPath() async {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(
            projectID: project.id, title: "Buton rengi", status: .ready,
            sortIndex: 1024, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let store = LibraryStore(services: bundle.services)
        store.start()
        _ = await waitUntil("loaded") { store.projects.count == 1 }

        let cache = ThumbnailCache(fileStore: bundle.services.fileStore)
        let view = LibraryView(store: store, thumbnails: cache)
        #expect(view.store === store)
        #expect(view.thumbnails === cache)
        // macOS 26 drag & drop is the shipped path; the macOS 27 `reorderable()` path is opt-in.
        #expect(LibraryView.useNativeReorder == false)

        store.selection = .project(project.id)
        #expect(store.sortedTasks.count == 1)
        store.stop()
        bundle.cleanUp()
    }

    @MainActor
    @Test func cardAndChipTakeTheirInputsWithoutTouchingDisk() {
        let bundle = makeFakeServices()
        let task = ShotTask(
            projectID: UUID(), title: "Cache temizle", status: .running,
            createdAt: t0, updatedAt: t0)
        let cache = ThumbnailCache(fileStore: bundle.services.fileStore)
        let card = TaskCardView(
            task: task, thumbnailURL: nil, isSelected: true,
            cache: cache, voiceSeconds: 4.2)
        #expect(card.task.id == task.id)
        #expect(card.isSelected)
        #expect(card.voiceSeconds == 4.2)

        let chip = StatusChip(status: .running)
        #expect(chip.status == .running)
        #expect(StatusPresentation.label(for: chip.status) == "Çalışıyor")
        bundle.cleanUp()
    }

    @MainActor
    @Test func dropOnAProjectRowMovesEverySelectedTask() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let inboxA = ShotTask(title: "A", status: .inbox, sortIndex: 1024, createdAt: t0, updatedAt: t0)
        let inboxB = ShotTask(title: "B", status: .inbox, sortIndex: 2048, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(
            projects: [project], tasks: [inboxA, inboxB],
            clock: MutableClock(t0))
        let store = LibraryStore(services: bundle.services)
        store.start()
        _ = await waitUntil("loaded") { store.tasks.count == 2 }

        // Exactly what `.dropDestination` hands to the view.
        let item = TaskDragItem(taskIDs: [inboxA.id, inboxB.id])
        await store.move(taskIDs: Set(item.taskIDs), toProject: project.id)

        #expect(try await bundle.services.tasks.task(id: inboxA.id)?.status == .ready)
        #expect(try await bundle.services.tasks.task(id: inboxB.id)?.projectID == project.id)
        store.stop()
        bundle.cleanUp()
    }
}
