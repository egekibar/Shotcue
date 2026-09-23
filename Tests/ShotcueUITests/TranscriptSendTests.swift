import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// Final review C1: a task is never handed to the dispatcher while one of its voice notes has no usable text.
/// A pending transcript is waited for while the model can produce it; otherwise the send is refused in Turkish.
@Suite("Sending with voice notes")
struct TranscriptSendTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)
    static let fast: Duration = .milliseconds(10)

    func freshDefaults() -> UserDefaults {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-send-\(UUID().uuidString)").path
        return UserDefaults(suiteName: path)!
    }

    struct Fixture {
        let bundle: FakeBundle
        let project: Project
        let task: ShotTask
    }

    func fixture(model: TranscriberModelState = .ready, status: TaskStatus = .ready) -> Fixture {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(
            projectID: project.id, title: "Sesli görev", status: status, sortIndex: 1024,
            createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(
            projects: [project], tasks: [task], permissions: [.microphone: .granted],
            transcriberState: model, clock: MutableClock(t0))
        return Fixture(bundle: bundle, project: project, task: task)
    }

    @discardableResult
    func addNote(
        _ bundle: FakeBundle, to taskID: UUID, state: TranscriptState, transcript: String? = nil
    ) async throws -> VoiceNote {
        let note = VoiceNote(
            taskID: taskID, relPath: "audio/\(UUID().uuidString).m4a", durationSec: 4,
            transcript: transcript, transcriptState: state, createdAt: t0)
        try await bundle.services.tasks.save(note)
        return note
    }

    /// What the transcription coordinator does when it finishes a note.
    func finishTranscript(_ bundle: FakeBundle, noteID: UUID, text: String) {
        bundle.tasks.voiceStorage.withLock { storage in
            storage[noteID]?.transcript = text
            storage[noteID]?.transcriptState = .done
        }
    }

    func failTranscript(_ bundle: FakeBundle, noteID: UUID) {
        bundle.tasks.voiceStorage.withLock { $0[noteID]?.transcriptState = .failed }
    }

    // MARK: - The gate

    @MainActor
    @Test func theGateDecidesFromTheNotesAndTheModel() async throws {
        let f = fixture()
        let gate = TranscriptGate(services: f.bundle.services, timeout: .seconds(1), pollInterval: Self.fast)
        #expect(await gate.decide(taskID: f.task.id) == .send)

        try await addNote(f.bundle, to: f.task.id, state: .done, transcript: "bitti")
        #expect(await gate.decide(taskID: f.task.id) == .send)

        let pending = try await addNote(f.bundle, to: f.task.id, state: .pending)
        #expect(await gate.decide(taskID: f.task.id) == .wait)

        f.bundle.transcriber.state.set(.notDownloaded)
        guard case .refuse(let missing) = await gate.decide(taskID: f.task.id) else {
            Issue.record("a pending note without a model must be refused")
            return
        }
        #expect(missing.contains("Ayarlar > Ses"))
        #expect(missing.contains("indirilmedi"))

        f.bundle.transcriber.state.set(.downloading(progress: 0.4))
        guard case .refuse(let downloading) = await gate.decide(taskID: f.task.id) else {
            Issue.record("a pending note while the model downloads must be refused")
            return
        }
        #expect(downloading.contains("%40"))

        failTranscript(f.bundle, noteID: pending.id)
        f.bundle.transcriber.state.set(.ready)
        #expect(await gate.decide(taskID: f.task.id) == .refuse(TranscriptGate.failedMessage))
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func waitingEndsWhenTheTranscriptLandsFailsOrTimesOut() async throws {
        let f = fixture()
        let second = ShotTask(projectID: f.project.id, title: "ikinci", status: .ready, createdAt: t0, updatedAt: t0)
        let third = ShotTask(projectID: f.project.id, title: "üçüncü", status: .ready, createdAt: t0, updatedAt: t0)
        try await f.bundle.services.tasks.save(second)
        try await f.bundle.services.tasks.save(third)
        let landing = try await addNote(f.bundle, to: f.task.id, state: .pending)
        let failing = try await addNote(f.bundle, to: second.id, state: .pending)
        try await addNote(f.bundle, to: third.id, state: .pending)
        let gate = TranscriptGate(services: f.bundle.services, timeout: .milliseconds(400), pollInterval: Self.fast)

        let waiting = Task { await gate.waitForTranscripts(of: [f.task.id, second.id, third.id]) }
        try await Task.sleep(for: .milliseconds(60))
        finishTranscript(f.bundle, noteID: landing.id, text: "yazıya döküldü")
        failTranscript(f.bundle, noteID: failing.id)
        let outcomes = await waiting.value

        #expect(outcomes[f.task.id] == .send)
        #expect(outcomes[second.id] == .refuse(TranscriptGate.failedMessage))
        #expect(outcomes[third.id] == .refuse(TranscriptGate.timeoutMessage))
        // The queue was asked to work on every pending note.
        #expect(await waitUntil("nudged") { f.bundle.transcriptionQueue.enqueued.current.count == 3 })
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func aModelThatStopsBeingReadyEndsTheWait() async throws {
        let f = fixture()
        try await addNote(f.bundle, to: f.task.id, state: .pending)
        let gate = TranscriptGate(services: f.bundle.services, timeout: .seconds(5), pollInterval: Self.fast)
        let waiting = Task { await gate.waitForTranscripts(of: [f.task.id]) }
        try await Task.sleep(for: .milliseconds(40))
        f.bundle.transcriber.state.set(.failed("model files missing"))
        let outcome = await waiting.value[f.task.id]
        guard case .refuse(let message) = outcome else {
            Issue.record("expected a refusal, got \(String(describing: outcome))")
            return
        }
        #expect(message.contains("yüklenemedi"))
        f.bundle.cleanUp()
    }

    // MARK: - Quick panel ⌘⇧↩

    @MainActor
    func panel(_ f: Fixture, recorder: (any AudioRecorder)? = nil) async -> QuickPanelStore {
        var services = f.bundle.services
        if let recorder { services = services.replacingRecorder(recorder) }
        let settings = SettingsStore(defaults: freshDefaults())
        settings.lastUsedProjectID = f.project.id.uuidString
        let store = QuickPanelStore(services: services, settings: settings)
        store.transcriptWaitTimeout = .seconds(2)
        store.transcriptPollInterval = Self.fast
        await store.capture(taskID: f.task.id)
        return store
    }

    @MainActor
    @Test func thePanelRefusesWhenTheModelIsMissingAndStaysOpen() async throws {
        let f = fixture(model: .notDownloaded)
        let store = await panel(f)
        let closed = Locked(0)
        store.onClose = { closed.withLock { $0 += 1 } }
        await store.toggleRecording()
        await store.toggleRecording()

        await store.saveAndSend()

        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)
        #expect(store.lastError?.contains("Ayarlar > Ses") == true)
        #expect(closed.current == 0)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func thePanelRefusesAFailedTranscript() async throws {
        let f = fixture()
        try await addNote(f.bundle, to: f.task.id, state: .failed)
        let store = await panel(f)
        await store.saveAndSend()
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)
        #expect(store.lastError == TranscriptGate.failedMessage)
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func thePanelClosesAtOnceAndSendsWhenTheTranscriptLands() async throws {
        let f = fixture()
        let store = await panel(f)
        let closed = Locked(0)
        store.onClose = { closed.withLock { $0 += 1 } }
        await store.toggleRecording()
        await store.toggleRecording()
        let note = try #require(store.voiceNotes.first)

        await store.saveAndSend()
        #expect(closed.current == 1)
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)

        finishTranscript(f.bundle, noteID: note.id, text: "butonu kırmızı yap")
        await store.backgroundSend?.value
        #expect(f.bundle.dispatcher.enqueued.current == [f.task.id])
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func aBackgroundSendThatCannotGoOutIsReported() async throws {
        let f = fixture()
        let store = await panel(f)
        let reports = Locked<[(title: String, message: String, taskID: UUID)]>([])
        store.onSendFailure = { title, message, taskID in reports.withLock { $0.append((title, message, taskID)) } }
        await store.toggleRecording()
        await store.toggleRecording()
        let note = try #require(store.voiceNotes.first)

        await store.saveAndSend()
        failTranscript(f.bundle, noteID: note.id)
        await store.backgroundSend?.value

        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)
        #expect(reports.current.map(\.message) == [TranscriptGate.failedMessage])
        #expect(reports.current.first?.taskID == f.task.id)
        #expect(reports.current.first?.title.isEmpty == false)
        f.bundle.cleanUp()
    }

    /// Stop recording, then ⌘⇧↩ at once: the send used to run while the recorder was still finishing, before
    /// the voice note row existed, so the run went out without it.
    @MainActor
    @Test func aSendRightAfterStoppingWaitsForTheRecordingToBeStored() async throws {
        let f = fixture()
        let stopGate = Gate()
        let recorder = GatedAudioRecorder(stopGate: stopGate)
        let store = await panel(f, recorder: recorder)
        await store.toggleRecording()

        let stopping = Task { await store.toggleRecording() }
        #expect(await waitUntil("parked in recorder.stop") { stopGate.arrivals.current == 1 })
        let sending = Task { await store.saveAndSend() }
        try await Task.sleep(for: .milliseconds(80))
        // Still waiting for the recording: nothing was sent without it.
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)

        stopGate.open()
        await stopping.value
        await sending.value
        let notes = try await f.bundle.services.tasks.voiceNotes(taskID: f.task.id)
        #expect(notes.count == 1)
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)

        finishTranscript(f.bundle, noteID: try #require(notes.first?.id), text: "yazıya döküldü")
        await store.backgroundSend?.value
        #expect(f.bundle.dispatcher.enqueued.current == [f.task.id])
        f.bundle.cleanUp()
    }

    // MARK: - Inspector

    @MainActor
    func inspector(_ f: Fixture) async -> TaskDetailStore {
        let store = TaskDetailStore(services: f.bundle.services, taskID: f.task.id)
        store.transcriptWaitTimeout = .seconds(2)
        store.transcriptWaitPollInterval = Self.fast
        await store.start()
        return store
    }

    @MainActor
    @Test func theInspectorWaitsVisiblyForAPendingTranscript() async throws {
        let f = fixture()
        let note = try await addNote(f.bundle, to: f.task.id, state: .pending)
        let store = await inspector(f)

        let sending = Task { await store.sendNow() }
        #expect(await waitUntil("waiting") { store.isWaitingForTranscript })
        #expect(store.canSend == false)
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)

        finishTranscript(f.bundle, noteID: note.id, text: "tamam")
        await sending.value
        #expect(store.isWaitingForTranscript == false)
        #expect(f.bundle.dispatcher.enqueued.current == [f.task.id])
        store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func theInspectorRefusesWithoutAModelAndOnAFailedTranscript() async throws {
        let f = fixture(model: .notDownloaded, status: .failed)
        let note = try await addNote(f.bundle, to: f.task.id, state: .pending)
        let store = await inspector(f)

        await store.retry()
        #expect(store.lastError?.contains("indirilmedi") == true)
        #expect(store.isWaitingForTranscript == false)

        store.lastError = nil
        failTranscript(f.bundle, noteID: note.id)
        await store.sendNow()
        #expect(store.lastError == TranscriptGate.failedMessage)
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)
        store.stop()
        f.bundle.cleanUp()
    }

    // MARK: - Library

    @MainActor
    func library(_ f: Fixture) async -> LibraryStore {
        let store = LibraryStore(services: f.bundle.services)
        store.transcriptWaitTimeout = .seconds(2)
        store.transcriptWaitPollInterval = Self.fast
        store.start()
        _ = await waitUntil("loaded") { store.projects.count == 1 }
        return store
    }

    @MainActor
    @Test func sendingSeparatelyWaitsForPendingNotesAndReportsTheRest() async throws {
        let f = fixture()
        let ready = ShotTask(projectID: f.project.id, title: "hazır", status: .ready, createdAt: t0, updatedAt: t0)
        let broken = ShotTask(projectID: f.project.id, title: "bozuk", status: .ready, createdAt: t0, updatedAt: t0)
        try await f.bundle.services.tasks.save(ready)
        try await f.bundle.services.tasks.save(broken)
        let pending = try await addNote(f.bundle, to: f.task.id, state: .pending)
        try await addNote(f.bundle, to: broken.id, state: .failed)
        let store = await library(f)

        let sending = Task { await store.send(taskIDs: [f.task.id, ready.id, broken.id]) }
        #expect(await waitUntil("waiting") { store.waitingForTranscriptIDs == [f.task.id] })
        #expect(f.bundle.dispatcher.enqueued.current == [ready.id])

        finishTranscript(f.bundle, noteID: pending.id, text: "tamam")
        await sending.value
        #expect(store.waitingForTranscriptIDs.isEmpty)
        #expect(f.bundle.dispatcher.enqueued.current == [ready.id, f.task.id])
        #expect(store.lastError?.contains("bozuk") == true)
        #expect(store.lastError?.contains(TranscriptGate.failedMessage) == true)
        store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func mergingIsRefusedBeforeAnythingMovesWhenANoteCannotBeUsed() async throws {
        let f = fixture()
        let other = ShotTask(projectID: f.project.id, title: "diğer", status: .ready, createdAt: t0, updatedAt: t0)
        try await f.bundle.services.tasks.save(other)
        try await addNote(f.bundle, to: other.id, state: .failed)
        let store = await library(f)

        await store.sendAsOne(taskIDs: [f.task.id, other.id])

        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)
        #expect(try await f.bundle.services.tasks.task(id: other.id) != nil)
        #expect(try await f.bundle.services.tasks.voiceNotes(taskID: other.id).count == 1)
        #expect(store.lastError?.contains(TranscriptGate.failedMessage) == true)
        store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func mergingWaitsForAPendingNoteBeforeTheMergedTaskIsSent() async throws {
        let f = fixture()
        let other = ShotTask(projectID: f.project.id, title: "diğer", status: .ready, createdAt: t0, updatedAt: t0)
        try await f.bundle.services.tasks.save(other)
        let pending = try await addNote(f.bundle, to: other.id, state: .pending)
        let store = await library(f)

        let merging = Task { await store.sendAsOne(taskIDs: [f.task.id, other.id]) }
        #expect(await waitUntil("waiting") { !store.waitingForTranscriptIDs.isEmpty })
        #expect(f.bundle.dispatcher.enqueued.current.isEmpty)

        finishTranscript(f.bundle, noteID: pending.id, text: "tamam")
        await merging.value
        #expect(f.bundle.dispatcher.enqueued.current.count == 1)
        #expect(store.lastError == nil)
        store.stop()
        f.bundle.cleanUp()
    }
}

/// `FakeAudioRecorder`, except that `stop()` parks on a gate: the recording is still being finished.
nonisolated final class GatedAudioRecorder: AudioRecorder, @unchecked Sendable {
    let base = FakeAudioRecorder()
    let stopGate: Gate
    init(stopGate: Gate) { self.stopGate = stopGate }
    var levels: AsyncStream<Float> { base.levels }
    func start(writingTo url: URL) async throws { try await base.start(writingTo: url) }
    func stop() async throws -> RecordingInfo {
        await stopGate.wait()
        return try await base.stop()
    }
}

extension AppServices {
    /// The same services with a different recorder (e.g. a `GatedAudioRecorder`).
    func replacingRecorder(_ recorder: any AudioRecorder) -> AppServices {
        AppServices(
            projects: projects, tasks: tasks, runs: runs, capture: capture, thumbnails: thumbnails,
            permissions: permissions, recorder: recorder, transcriber: transcriber,
            transcriptionQueue: transcriptionQueue, dispatcher: dispatcher, handoff: handoff,
            fileStore: fileStore, clock: clock, diff: diff)
    }
}
