import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueNotes

/// Fixture: one task with one pending voice note.
struct CoordinatorFixture {
    var repo: InMemoryTaskRepository
    var task: ShotTask
    var note: VoiceNote

    static func make(
        noteText: String = "", titleEditedByUser: Bool = false,
        editedByUser: Bool = false
    ) async throws -> CoordinatorFixture {
        let repo = InMemoryTaskRepository()
        let task = ShotTask(
            projectID: UUID(), title: "Yakalama 22.09 12:00", noteText: noteText,
            status: .ready, titleEditedByUser: titleEditedByUser,
            createdAt: Date(timeIntervalSince1970: 1_790_078_400))
        try await repo.save(task)
        let note = VoiceNote(
            taskID: task.id, relPath: "audio/one.m4a", durationSec: 22,
            transcriptState: .pending, editedByUser: editedByUser)
        try await repo.save(note)
        return CoordinatorFixture(repo: repo, task: task, note: note)
    }

    func temporaryStore() -> FileStore {
        FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("shotcue-coord-\(UUID().uuidString)", isDirectory: true))
    }
}

/// Parks `modelState()` and/or `transcribe` until the test opens the gate, so a test can act while the
/// coordinator is suspended at exactly that point. Being an actor, every call is a real suspension point —
/// like the production `WhisperKitTranscriber`, and unlike `FakeTranscriber`, which never suspends.
actor GatedTranscriber: Transcriber {
    nonisolated let engineName = "gated"
    private(set) var transcribedFiles: [String] = []
    private(set) var modelStateCalls = 0
    private var holdsModelState: Bool
    private var holdsTranscription = true
    /// What `modelState()` answers; captured when the check starts, like a real check racing a download.
    private var reportedState: TranscriberModelState
    private let failsTranscription: Bool
    private var parkedModelStates: [CheckedContinuation<Void, Never>] = []
    private var parkedTranscriptions: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    init(
        holdsModelState: Bool = false, reportedState: TranscriberModelState = .ready,
        failsTranscription: Bool = false
    ) {
        self.holdsModelState = holdsModelState
        self.reportedState = reportedState
        self.failsTranscription = failsTranscription
    }

    func modelState() async -> TranscriberModelState {
        modelStateCalls += 1
        let answer = reportedState
        wakeWatchers()
        if holdsModelState { await withCheckedContinuation { parkedModelStates.append($0) } }
        return answer
    }

    func setReportedState(_ state: TranscriberModelState) {
        reportedState = state
    }

    func downloadModel() async throws {}

    func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        transcribedFiles.append(fileURL.lastPathComponent)
        wakeWatchers()
        if holdsTranscription { await withCheckedContinuation { parkedTranscriptions.append($0) } }
        if failsTranscription { throw FakeError("bad audio") }
        return Transcript(text: "not metni", language: language, engine: engineName)
    }

    /// Releases the parked `modelState()` calls; transcriptions stay parked until `open()`.
    func openModelState() {
        holdsModelState = false
        parkedModelStates.forEach { $0.resume() }
        parkedModelStates.removeAll()
    }

    /// Releases everything parked and lets all later calls through.
    func open() {
        openModelState()
        holdsTranscription = false
        parkedTranscriptions.forEach { $0.resume() }
        parkedTranscriptions.removeAll()
    }

    func waitForTranscriptions(_ count: Int) async {
        while transcribedFiles.count < count { await withCheckedContinuation { watchers.append($0) } }
    }

    func waitForModelStateCalls(_ count: Int) async {
        while modelStateCalls < count { await withCheckedContinuation { watchers.append($0) } }
    }

    private func wakeWatchers() {
        watchers.forEach { $0.resume() }
        watchers.removeAll()
    }
}

/// Fails the way `WhisperKitTranscriber` does when its model cannot be loaded: the state turns `.failed`
/// and the transcription throws.
final class ModelLoadFailingTranscriber: Transcriber, @unchecked Sendable {
    let engineName = "load-failing"
    let state = Locked<TranscriberModelState>(.ready)
    let calls = Locked<[String]>([])

    func modelState() async -> TranscriberModelState { state.current }
    func downloadModel() async throws {}
    func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        calls.withLock { $0.append(fileURL.lastPathComponent) }
        state.set(.failed("model files missing"))
        throw FakeError("model files missing")
    }
}

@Suite("TranscriptionCoordinator")
struct TranscriptionCoordinatorTests {
    // Async repository reads are hoisted into a `let` before `#expect` so a failing expectation
    // shows the value that was actually stored instead of the whole `try await` expression.

    @Test func pendingNoteIsTranscribedAndStored() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcript = Transcript(
            text: "modal açılınca API endpoint'i çağır", language: "tr",
            engine: "whisperkit/openai_whisper-large-v3-v20240930_turbo",
            segments: [
                .init(
                    start: 0, end: 3.2,
                    text: "modal açılınca API endpoint'i çağır",
                    confidence: 0.9)
            ])
        let transcriber = FakeTranscriber(state: .ready, result: .success(transcript))
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()

        let notes = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        let stored = try #require(notes.first { $0.id == fixture.note.id })
        #expect(stored.transcriptState == .done)
        #expect(stored.transcript == "modal açılınca API endpoint'i çağır")
        #expect(stored.engine == "whisperkit/openai_whisper-large-v3-v20240930_turbo")
        let json = try #require(stored.transcriptJSON)
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(decoded == transcript)
        #expect(transcriber.calls.current.first?.language == "tr")
        let processing = await coordinator.isProcessing
        #expect(processing == false)
    }

    @Test func transcribedFileURLComesFromTheFileStore() async throws {
        let fixture = try await CoordinatorFixture.make()
        let store = FileStore(rootURL: URL(fileURLWithPath: "/tmp/shotcue-root"))
        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: store, language: "tr")
        await coordinator.processPending()
        #expect(transcriber.calls.current.first?.fileURL.path == "/tmp/shotcue-root/audio/one.m4a")
    }

    @Test func transcriptionFailureMarksTheNoteFailed() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(state: .ready, result: .failure(FakeError("model missing")))
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()

        let notes = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        let stored = try #require(notes.first { $0.id == fixture.note.id })
        #expect(stored.transcriptState == .failed)
        #expect(stored.transcript == nil)
        #expect(stored.engine == "fake")
    }

    @Test func userEditedNotesAreNeverOverwritten() async throws {
        let repo = InMemoryTaskRepository()
        let task = ShotTask(projectID: UUID(), title: "t", status: .ready)
        try await repo.save(task)
        let note = VoiceNote(
            taskID: task.id, relPath: "audio/edited.m4a", durationSec: 5,
            transcript: "kullanıcının yazdığı metin", transcriptState: .pending,
            editedByUser: true)
        try await repo.save(note)

        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: repo,
            fileStore: FileStore(rootURL: URL(fileURLWithPath: "/tmp")),
            language: "tr")
        await coordinator.processPending()

        let notes = try await repo.voiceNotes(taskID: task.id)
        let stored = try #require(notes.first)
        #expect(stored.transcript == "kullanıcının yazdığı metin")
        #expect(stored.transcriptState == .pending)
        #expect(transcriber.calls.current.isEmpty)
    }

    @Test func titleIsFilledFromTheTranscriptWhenTheNoteIsBlank() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(
                Transcript(
                    text: "Login ekranındaki modal bozuk. Düzelt.",
                    language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Login ekranındaki modal bozuk")
    }

    @Test func titleIsKeptWhenTheUserEditedIt() async throws {
        let fixture = try await CoordinatorFixture.make(titleEditedByUser: true)
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(Transcript(text: "başka bir başlık", language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Yakalama 22.09 12:00")
    }

    @Test func titleIsKeptWhenTheNoteHasText() async throws {
        let fixture = try await CoordinatorFixture.make(noteText: "butonun rengi yanlış")
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(Transcript(text: "başka bir başlık", language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Yakalama 22.09 12:00")
    }

    @Test func titleAutoFillCanBeDisabled() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(Transcript(text: "yeni başlık olmalı", language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr",
            titleMaker: false)
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Yakalama 22.09 12:00")
    }

    @Test func modelNotReadyLeavesTheNotePending() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(state: .notDownloaded)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.enqueue(voiceNoteID: fixture.note.id)
        await coordinator.processPending()

        let pending = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        #expect(pending.first?.transcriptState == .pending)
        #expect(transcriber.calls.current.isEmpty)

        transcriber.state.set(.ready)
        await coordinator.enqueue(voiceNoteID: fixture.note.id)
        let done = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        #expect(done.first?.transcriptState == .done)
        #expect(transcriber.calls.current.count == 1)
    }

    @Test func threeNotesAreProcessedSequentiallyInManualOrder() async throws {
        let repo = InMemoryTaskRepository()
        for index in 0..<3 {
            let task = ShotTask(
                projectID: UUID(), title: "task \(index)", status: .ready,
                sortIndex: Double(index),
                createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
            try await repo.save(task)
            let note = VoiceNote(
                taskID: task.id, relPath: "audio/n\(index).m4a", durationSec: 20,
                transcriptState: .pending)
            try await repo.save(note)
        }
        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: repo,
            fileStore: FileStore(rootURL: URL(fileURLWithPath: "/tmp/shotcue-seq")), language: "tr")
        await coordinator.processPending()

        let names = transcriber.calls.current.map { $0.fileURL.lastPathComponent }
        #expect(names == ["n0.m4a", "n1.m4a", "n2.m4a"])

        var states: [TranscriptState] = []
        for task in try await repo.allTasks() {
            for note in try await repo.voiceNotes(taskID: task.id) { states.append(note.transcriptState) }
        }
        #expect(states == [.done, .done, .done])
    }

    @Test func languageCanBeChangedAtRuntime() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.setLanguage("en")
        await coordinator.processPending()
        #expect(transcriber.calls.current.first?.language == "en")
    }

    @Test func noteSavedWhileAnotherIsTranscribingIsNotLeftPending() async throws {
        // A second recording is saved while the first note is still being transcribed: its `enqueue`
        // finds a run in progress, so that run must pick the new note up before it ends.
        let fixture = try await CoordinatorFixture.make()
        let transcriber = GatedTranscriber()
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        let firstRun = Task { await coordinator.enqueue(voiceNoteID: fixture.note.id) }
        await transcriber.waitForTranscriptions(1)

        let second = VoiceNote(
            taskID: fixture.task.id, relPath: "audio/two.m4a", durationSec: 8, transcriptState: .pending)
        try await fixture.repo.save(second)
        await coordinator.enqueue(voiceNoteID: second.id)
        await transcriber.open()
        await firstRun.value

        let states = try await fixture.repo.voiceNotes(taskID: fixture.task.id).map { $0.transcriptState }
        #expect(states == [.done, .done])
        let files = await transcriber.transcribedFiles
        #expect(files == ["one.m4a", "two.m4a"])
    }

    @Test func overlappingRunsTranscribeEachNoteOnce() async throws {
        // App launch and "model ready" can both call `processPending()`. The second call arrives while the
        // first one is still waiting for `modelState()`; it must not start a parallel run over the same notes.
        let fixture = try await CoordinatorFixture.make()
        let transcriber = GatedTranscriber(holdsModelState: true)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        let firstRun = Task { await coordinator.processPending() }
        await transcriber.waitForModelStateCalls(1)

        let secondRunReturned = Locked(false)
        let secondRun = Task {
            await coordinator.processPending()
            secondRunReturned.set(true)
        }
        // Either the second run parks in `modelState()` too (a parallel run) or it returns right away.
        while await transcriber.modelStateCalls < 2, !secondRunReturned.current { await Task.yield() }
        // Let the runs past `modelState()` while transcriptions stay parked, so the first run cannot store its
        // result before a parallel run scans; then wait until that run transcribes too, or has returned.
        await transcriber.openModelState()
        while await transcriber.transcribedFiles.count < 2, !secondRunReturned.current { await Task.yield() }
        await transcriber.open()
        await firstRun.value
        await secondRun.value

        let files = await transcriber.transcribedFiles
        #expect(files == ["one.m4a"])
        let notes = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        #expect(notes.first?.transcriptState == .done)
    }

    @Test func aModelLoadFailureStopsTheRunAndLeavesEveryNotePending() async throws {
        // Final review M8: a model that cannot be loaded is not the note's fault. Every note — the one that hit the
        // failure included — waits as `pending` for the model, and the model's own `.failed` state carries the
        // error (Settings and the inspector show it and offer the download).
        let repo = InMemoryTaskRepository()
        for index in 0..<3 {
            let task = ShotTask(
                projectID: UUID(), title: "task \(index)", status: .ready, sortIndex: Double(index),
                createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
            try await repo.save(task)
            try await repo.save(
                VoiceNote(taskID: task.id, relPath: "audio/n\(index).m4a", durationSec: 20, transcriptState: .pending))
        }
        let transcriber = ModelLoadFailingTranscriber()
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: repo,
            fileStore: FileStore(rootURL: URL(fileURLWithPath: "/tmp/shotcue-load")), language: "tr")
        await coordinator.processPending()

        #expect(transcriber.calls.current == ["n0.m4a"])
        var states: [TranscriptState] = []
        for task in try await repo.allTasks() {
            for note in try await repo.voiceNotes(taskID: task.id) { states.append(note.transcriptState) }
        }
        #expect(states == [.pending, .pending, .pending])
        #expect(await transcriber.modelState() == .failed("model files missing"))
    }

    @Test func aRescanRequestedWhileTheModelCheckIsInFlightIsNotLost() async throws {
        // The run asks whether the model is ready; before the answer ("not downloaded") arrives, the download
        // finishes and the app calls `processPending()` again. That call only requests a rescan, so the run
        // must honour it instead of stopping on the stale answer.
        let fixture = try await CoordinatorFixture.make()
        let transcriber = GatedTranscriber(holdsModelState: true, reportedState: .notDownloaded)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        let firstRun = Task { await coordinator.processPending() }
        await transcriber.waitForModelStateCalls(1)

        await transcriber.setReportedState(.ready)
        await coordinator.processPending()
        await transcriber.open()
        await firstRun.value

        let notes = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        #expect(notes.first?.transcriptState == .done)
    }

    @Test(arguments: [false, true])
    func aUserEditMadeDuringTranscriptionIsKept(transcriptionFails: Bool) async throws {
        // The result used to be saved over a copy read before the (multi-second) transcription, both on
        // success and on failure.
        let fixture = try await CoordinatorFixture.make()
        let transcriber = GatedTranscriber(failsTranscription: transcriptionFails)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: fixture.repo,
            fileStore: fixture.temporaryStore(), language: "tr")
        let run = Task { await coordinator.processPending() }
        await transcriber.waitForTranscriptions(1)

        var edited = fixture.note
        edited.transcript = "kullanıcının düzelttiği metin"
        edited.editedByUser = true
        try await fixture.repo.save(edited)
        await transcriber.open()
        await run.value

        let stored = try #require(try await fixture.repo.voiceNotes(taskID: fixture.task.id).first)
        #expect(stored == edited)
        let task = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(task.title == "Yakalama 22.09 12:00")
    }
}
