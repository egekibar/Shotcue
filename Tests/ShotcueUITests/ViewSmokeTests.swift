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

@Suite("TaskInspectorView")
struct TaskInspectorViewTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func inspectorIsWiredToItsDetailStore() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(
            projectID: project.id, title: "Buton rengi", noteText: "kırmızı olmalı",
            status: .ready, sortIndex: 1024, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        try await bundle.services.tasks.save(
            Capture(
                taskID: task.id, relPath: "captures/2026/09/a.png", thumbRelPath: "thumbs/a.jpg",
                width: 800, height: 600, createdAt: t0))
        let store = TaskDetailStore(services: bundle.services, taskID: task.id)
        await store.start()

        let cache = ThumbnailCache(fileStore: bundle.services.fileStore)
        let view = TaskInspectorView(store: store, thumbnails: cache)
        #expect(view.store === store)
        #expect(view.thumbnails === cache)
        #expect(view.store.captures.count == 1)
        #expect(view.store.project?.name == "acme-web")
        store.stop()
        bundle.cleanUp()
    }

    @MainActor
    @Test func runLogRendersEveryEventKindAndFormatsTheResult() {
        let result = ClaudeRunResult(
            subtype: "success", isError: false, sessionID: "s1",
            result: "Fixed the button color.", totalCostUSD: 0.4137,
            numTurns: 11, durationMs: 84_213, permissionDenials: [])
        let events: [RunEvent] = [
            .initialized(sessionID: "s1", model: "claude-sonnet-5"),
            .assistantText("Reading the screenshot first."),
            .toolUse(name: "Read", summary: "Read /tmp/a.png"),
            .apiRetry(attempt: 1),
            .other(type: "user"),
            .result(result),
        ]
        let live = RunLogView(events: events, isLive: true)
        #expect(live.events.count == 6)
        #expect(live.isLive)

        let replay = RunLogView(events: events)
        #expect(replay.isLive == false)

        // The row text each event maps to is a pure function, so it is asserted directly.
        #expect(RunLogView.line(for: events[0]) == "başladı · claude-sonnet-5")
        #expect(RunLogView.line(for: events[1]) == "Reading the screenshot first.")
        #expect(RunLogView.line(for: events[2]) == "Read /tmp/a.png")
        #expect(RunLogView.line(for: events[3]) == "API yeniden deneme (1)")
        #expect(RunLogView.line(for: events[4]) == "user")
        #expect(RunLogView.line(for: events[5]) == "bitti · $0.41 · 11 tur · 1 dk 24 sn")
        #expect(RunLogView.symbol(for: events[2]) == "wrench.and.screwdriver")
        #expect(RunLogView.symbol(for: events[5]) == "checkmark.seal.fill")

        let failure = ClaudeRunResult(
            subtype: "error_max_turns", isError: true, numTurns: 30,
            permissionDenials: ["Bash"])
        #expect(RunLogView.line(for: .result(failure)) == "limit aşıldı (error_max_turns) · 30 tur")
        #expect(RunLogView.symbol(for: .result(failure)) == "exclamationmark.triangle.fill")
    }
}

@Suite("QuickPanelView")
struct QuickPanelViewTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func panelIsWiredToItsStore() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(title: "Yakalama 22.09 12:00", status: .inbox, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(
            projects: [project], tasks: [task],
            permissions: [.microphone: .granted], clock: MutableClock(t0))
        try await bundle.services.tasks.save(
            Capture(
                taskID: task.id, relPath: "captures/2026/09/a.png", thumbRelPath: "thumbs/a.jpg",
                width: 800, height: 600, createdAt: t0))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "panel-\(UUID().uuidString)")!)
        let store = QuickPanelStore(services: bundle.services, settings: settings)
        await store.capture(taskID: task.id)

        let cache = ThumbnailCache(fileStore: bundle.services.fileStore)
        let view = QuickPanelView(store: store, thumbnails: cache)
        #expect(view.store === store)
        #expect(view.thumbnails === cache)
        #expect(view.store.selectedProjectID == project.id)
        #expect(view.store.canRecord)
        bundle.cleanUp()
    }

    @MainActor
    @Test func levelMeterClampsItsInput() {
        #expect(LevelMeterView(level: 0.5).level == 0.5)
        #expect(LevelMeterView(level: -1).litBars == 0)
        #expect(LevelMeterView(level: 2).litBars == 14)
        #expect(LevelMeterView(level: 0.5, barCount: 10).litBars == 5)
        #expect(LevelMeterView(level: 0).litBars == 0)
    }
}

@Suite("SettingsView")
struct SettingsViewTests {
    @MainActor
    @Test func settingsViewIsWiredToBothStoresAndItsCallback() async {
        let bundle = makeFakeServices(permissions: [.screenRecording: .granted])
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "settings-\(UUID().uuidString)")!)
        let permissions = PermissionsStore(services: bundle.services)
        await permissions.refresh()
        let downloads = Locked(0)

        let view = SettingsView(
            settings: settings,
            permissions: permissions,
            projects: [Project(name: "acme-web", path: "/tmp/acme-web", createdAt: Date())],
            claudeVersion: "2.1.278 (Claude Code)",
            transcriberState: .notDownloaded,
            onDownloadModel: { downloads.withLock { $0 += 1 } })

        #expect(view.settings === settings)
        #expect(view.permissions === permissions)
        #expect(view.projects.count == 1)
        #expect(view.claudeVersion == "2.1.278 (Claude Code)")
        view.onDownloadModel()
        #expect(downloads.current == 1)
        bundle.cleanUp()
    }

    @MainActor
    @Test func transcriberStateCopyCoversEveryCase() {
        #expect(SettingsView.modelStateLabel(.notDownloaded) == "İndirilmedi")
        #expect(SettingsView.modelStateLabel(.downloading(progress: 0.42)) == "İndiriliyor… %42")
        #expect(SettingsView.modelStateLabel(.ready) == "Hazır")
        #expect(SettingsView.modelStateLabel(.failed("disk dolu")) == "Hata: disk dolu")
        #expect(SettingsView.permissionModeLabel(.bypassPermissions) == "bypassPermissions (sormaz, uygular)")
        #expect(SettingsView.permissionModeLabel(.acceptEdits) == "acceptEdits (düzenlemeleri kabul eder)")
        #expect(SettingsView.permissionModeLabel(.dontAsk) == "dontAsk (yalnızca okuma)")
    }
}

@Suite("OnboardingView")
struct OnboardingViewTests {
    @MainActor
    @Test func onboardingReflectsPermissionStateAndCallsBack() async {
        let bundle = makeFakeServices(
            permissions: [
                .screenRecording: .notDetermined,
                .microphone: .notDetermined,
                .notifications: .notDetermined,
            ],
            grantOnRequest: true)
        let permissions = PermissionsStore(services: bundle.services)
        await permissions.refresh()
        let done = Locked(0)
        let view = OnboardingView(permissions: permissions, onDone: { done.withLock { $0 += 1 } })

        #expect(view.permissions === permissions)
        #expect(permissions.allGranted == false)
        // Screen recording is the gate for finishing onboarding.
        #expect(view.canFinish == false)

        await permissions.request(.screenRecording)
        #expect(permissions.state(of: .screenRecording) == .granted)
        #expect(view.canFinish == true)

        view.onDone()
        #expect(done.current == 1)
        bundle.cleanUp()
    }
}

@Suite("ProjectEditorView")
struct ProjectEditorViewTests {
    @MainActor
    @Test func editorHoldsTheLibraryStore() {
        let f = makeFakeServices()
        let store = LibraryStore(services: f.services)
        store.beginCreateProject()
        let view = ProjectEditorView(store: store)
        #expect(view.store === store)
    }
}
