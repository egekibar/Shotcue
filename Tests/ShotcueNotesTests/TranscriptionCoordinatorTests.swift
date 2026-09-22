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
}
