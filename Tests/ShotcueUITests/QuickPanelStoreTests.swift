import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

@Suite("QuickPanelStore")
struct QuickPanelStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)
    /// Stable project ids: "the last used project" must be the same project across two fixtures (two panel
    /// sessions), as it is across launches in the app.
    let projectAID = UUID(uuidString: "0A0A0A0A-0000-4000-8000-00000000000A")!
    let projectBID = UUID(uuidString: "0B0B0B0B-0000-4000-8000-00000000000B")!

    /// A private suite per test. The suite name is an absolute path in the temporary directory, so the
    /// backing plist is written there instead of piling up in ~/Library/Preferences.
    func freshDefaults() -> UserDefaults {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-panel-\(UUID().uuidString)").path
        return UserDefaults(suiteName: path)!
    }

    @MainActor
    func fixture(lastUsed: UUID? = nil)
        async throws -> (
            bundle: FakeBundle, store: QuickPanelStore, settings: SettingsStore,
            task: ShotTask, projectA: Project, projectB: Project
        )
    {
        let projectA = Project(
            id: projectAID, name: "acme-web", path: "/tmp/acme-web", defaultMode: .implement,
            sortIndex: 1024, createdAt: t0)
        let projectB = Project(
            id: projectBID, name: "api-core", path: "/tmp/api-core", defaultMode: .analyze,
            sortIndex: 2048, createdAt: t0)
        let task = ShotTask(
            title: "Yakalama 22.09 12:00", status: .inbox, sortIndex: 1024,
            createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(
            projects: [projectA, projectB], tasks: [task],
            permissions: [.microphone: .granted], clock: MutableClock(t0))
        try await bundle.services.tasks.save(
            Capture(
                taskID: task.id, relPath: "captures/2026/09/a.png",
                thumbRelPath: "thumbs/a.jpg", width: 800, height: 600, createdAt: t0))
        let settings = SettingsStore(defaults: freshDefaults())
        if let lastUsed { settings.lastUsedProjectID = lastUsed.uuidString }
        let store = QuickPanelStore(services: bundle.services, settings: settings)
        await store.capture(taskID: task.id)
        return (bundle, store, settings, task, projectA, projectB)
    }

    @MainActor
    @Test func defaultProjectIsTheLastUsedOne() async throws {
        let f = try await fixture(lastUsed: nil)
        // No memory yet: the first project in manual order wins.
        #expect(f.store.selectedProjectID == f.projectA.id)
        #expect(f.store.mode == .implement)
        #expect(f.store.thumbnailURL?.lastPathComponent == "a.jpg")
        #expect(f.store.microphoneState == .granted)
        #expect(f.store.canRecord == true)
        f.bundle.cleanUp()

        let g = try await fixture(lastUsed: f.projectB.id)
        #expect(g.store.selectedProjectID == g.projectB.id)
        // Mode follows the project default (api-core is an analyze project).
        #expect(g.store.mode == .analyze)
        g.bundle.cleanUp()
    }

    @MainActor
    @Test func projectNumberShortcutsPickProjectsInOrder() async throws {
        let f = try await fixture()
        f.store.selectProject(atShortcut: 2)
        #expect(f.store.selectedProjectID == f.projectB.id)
        #expect(f.store.mode == .analyze)
        f.store.selectProject(atShortcut: 9)
        #expect(f.store.selectedProjectID == f.projectB.id)  // out of range: unchanged
        #expect(f.store.projectShortcutIndex(for: f.projectA.id) == 1)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func recordingCreatesAPendingVoiceNoteAndEnqueuesTranscription() async throws {
        let f = try await fixture()
        await f.store.toggleRecording()
        #expect(f.store.isRecording == true)
        #expect(f.bundle.recorder.startedURLs.current.count == 1)
        let startedURL = try #require(f.bundle.recorder.startedURLs.current.first)
        #expect(startedURL.path.contains("/audio/"))
        #expect(startedURL.pathExtension == "m4a")

        f.bundle.recorder.emitLevel(0.42)
        #expect(await waitUntil("level") { f.store.level == 0.42 })
        #expect(await waitUntil("ticks") { f.store.recordingSeconds > 0 })

        await f.store.toggleRecording()
        #expect(f.store.isRecording == false)
        #expect(f.store.level == 0)
        #expect(f.store.voiceNotes.count == 1)

        let saved = try #require(try await f.bundle.services.tasks.voiceNotes(taskID: f.task.id).first)
        #expect(saved.transcriptState == .pending)
        #expect(saved.durationSec == 3.5)
        #expect(saved.editedByUser == false)
        #expect(saved.relPath == f.bundle.services.fileStore.audioRelPath(id: saved.id))
        #expect(f.bundle.transcriptionQueue.enqueued.current == [saved.id])
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func saveWritesNoteTitleProjectModeAndRemembersTheProject() async throws {
        let f = try await fixture()
        f.store.noteText = "Butonun rengi yanlış. Kırmızı olmalı."
        f.store.selectedProjectID = f.projectB.id
        f.store.mode = .analyze
        #expect(await f.store.save() == true)

        let saved = try #require(try await f.bundle.services.tasks.task(id: f.task.id))
        #expect(saved.noteText == "Butonun rengi yanlış. Kırmızı olmalı.")
        #expect(saved.title == "Butonun rengi yanlış")
        #expect(saved.projectID == f.projectB.id)
        #expect(saved.mode == .analyze)
        #expect(saved.status == .ready)
        #expect(saved.updatedAt == t0)
        #expect(f.settings.lastUsedProjectID == f.projectB.id.uuidString)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func saveWithoutAProjectLeavesTheTaskInTheInbox() async throws {
        let f = try await fixture()
        f.store.selectedProjectID = nil
        f.store.noteText = "sonra bakarım"
        #expect(await f.store.save() == true)
        let saved = try #require(try await f.bundle.services.tasks.task(id: f.task.id))
        #expect(saved.status == .inbox)
        #expect(saved.projectID == nil)
        #expect(f.settings.lastUsedProjectID == nil)
        f.bundle.cleanUp()
    }

    /// Review fix round 1, item 2: clearing the project on a second save sends the task back to the inbox.
    @MainActor
    @Test func aProjectlessSaveNeverLeavesTheTaskReady() async throws {
        let f = try await fixture()
        f.store.selectedProjectID = f.projectA.id
        #expect(await f.store.save())
        #expect(try await f.bundle.services.tasks.task(id: f.task.id)?.status == .ready)

        f.store.selectedProjectID = nil
        #expect(await f.store.save())
        let saved = try #require(try await f.bundle.services.tasks.task(id: f.task.id))
        #expect(saved.projectID == nil)
        #expect(saved.status == .inbox)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func saveAndCloseWritesThenClosesWithoutEnqueueing() async throws {
        let f = try await fixture()
        let closed = Locked(0)
        f.store.onClose = { closed.withLock { $0 += 1 } }
        f.store.noteText = "sadece kaydet"
        await f.store.saveAndClose()

        let saved = try #require(try await f.bundle.services.tasks.task(id: f.task.id))
        #expect(saved.noteText == "sadece kaydet")
        #expect(saved.status == .ready)
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)
        #expect(closed.current == 1)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func saveAndSendEnqueuesAndCloses() async throws {
        let f = try await fixture()
        let closed = Locked(0)
        f.store.onClose = { closed.withLock { $0 += 1 } }
        f.store.noteText = "gönder"
        await f.store.saveAndSend()
        #expect(f.bundle.dispatcher.enqueued.current == [f.task.id])
        #expect(closed.current == 1)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func saveAndSendWithoutAProjectWarnsAndStaysOpen() async throws {
        let f = try await fixture()
        let closed = Locked(0)
        f.store.onClose = { closed.withLock { $0 += 1 } }
        f.store.selectedProjectID = nil
        await f.store.saveAndSend()
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)
        #expect(f.store.lastError != nil)
        #expect(closed.current == 0)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func saveAndScheduleMovesToScheduled() async throws {
        let f = try await fixture()
        let when = t0.addingTimeInterval(7200)
        await f.store.saveAndSchedule(at: when)
        let saved = try #require(try await f.bundle.services.tasks.task(id: f.task.id))
        #expect(saved.status == .scheduled)
        #expect(saved.scheduledAt == when)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func dismissLeavesTheCaptureUntouchedInTheInbox() async throws {
        let f = try await fixture()
        let closed = Locked(0)
        f.store.onClose = { closed.withLock { $0 += 1 } }
        f.store.noteText = "kaydedilmemeli"
        f.store.selectedProjectID = f.projectA.id
        f.store.dismiss()

        let untouched = try #require(try await f.bundle.services.tasks.task(id: f.task.id))
        #expect(untouched.status == .inbox)
        #expect(untouched.projectID == nil)
        #expect(untouched.noteText == "")
        #expect(closed.current == 1)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func dismissWhileRecordingStillStoresTheNote() async throws {
        let f = try await fixture()
        await f.store.toggleRecording()
        f.store.dismiss()
        #expect(await waitUntil("stopped") { f.store.isRecording == false })
        #expect(
            await waitUntil("note saved") {
                f.store.voiceNotes.count == 1
            })
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func microphoneDenialDisablesRecording() async throws {
        let bundle = makeFakeServices(
            projects: [], tasks: [ShotTask(title: "x")],
            permissions: [.microphone: .denied], grantOnRequest: false,
            clock: MutableClock(t0))
        let taskID = try #require(try await bundle.services.tasks.allTasks().first?.id)
        let store = QuickPanelStore(
            services: bundle.services,
            settings: SettingsStore(defaults: freshDefaults()))
        await store.capture(taskID: taskID)
        #expect(store.microphoneState == .denied)
        #expect(store.canRecord == false)
        await store.toggleRecording()
        #expect(store.isRecording == false)
        #expect(bundle.recorder.startedURLs.current.isEmpty)
        #expect(store.lastError != nil)

        await store.requestMicrophone()
        #expect(store.microphoneState == .denied)
        bundle.cleanUp()
    }
}
