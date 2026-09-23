import Foundation
import ShotcueCore
import os

/// Background transcription queue (spec §5.2: "Panel kapansa da transkripsiyon devam eder").
/// Runs notes one at a time — WhisperKit is batch and holds the whole model in memory.
public actor TranscriptionCoordinator: TranscriptionQueue {
    private let transcriber: any Transcriber
    private let taskRepository: any TaskRepository
    private let fileStore: FileStore
    private let titleMaker: Bool
    private var language: String
    private var processing = false
    /// Set when `processPending()` is called during a run (a note saved mid-run), so the run rescans before ending.
    private var rescanRequested = false

    public init(
        transcriber: any Transcriber, taskRepository: any TaskRepository, fileStore: FileStore,
        language: String, titleMaker: Bool = true
    ) {
        self.transcriber = transcriber
        self.taskRepository = taskRepository
        self.fileStore = fileStore
        self.language = language
        self.titleMaker = titleMaker
    }

    public var isProcessing: Bool { processing }

    public func setLanguage(_ newLanguage: String) {
        language = newLanguage
    }

    /// Called right after a recording is saved. When the model is not ready the note simply stays
    /// `pending`; `processPending()` picks it up once the download finishes.
    public func enqueue(voiceNoteID: UUID) async {
        guard await transcriber.modelState() == .ready else { return }
        await processPending()
    }

    /// Transcribes every `pending` voice note, oldest task first. A per-file error marks that one note
    /// `.failed` (audio is kept, spec §8) and the queue goes on. A model that is not ready, or stops being
    /// ready mid-run (it cannot be loaded), ends the run and leaves the remaining notes `pending`.
    ///
    /// The run is claimed before the first `await`, so a second call arriving while this one waits for
    /// the transcriber cannot start a parallel run over the same notes; that call only asks the running
    /// one to rescan, which picks up notes saved mid-run instead of leaving them `pending`. The rescan is
    /// honoured even when this pass stopped on a "not ready" answer that the call has made stale.
    public func processPending() async {
        guard !processing else {
            rescanRequested = true
            return
        }
        processing = true
        defer { processing = false }

        repeat {
            rescanRequested = false
            for pending in await pendingNotes() {
                guard await transcriber.modelState() == .ready else { break }
                await transcribe(note: pending.note, in: pending.task)
            }
        } while rescanRequested
    }

    // MARK: - Internals

    private struct PendingNote {
        var note: VoiceNote
        var task: ShotTask
    }

    /// `TaskRepository` has no "all voice notes" query, so walk tasks → notes (spec §6.3 schema).
    /// `allTasks()` already returns manual order (`QueuePolicy.ordered`).
    private func pendingNotes() async -> [PendingNote] {
        guard let tasks = try? await taskRepository.allTasks() else { return [] }
        var result: [PendingNote] = []
        for task in tasks {
            guard let notes = try? await taskRepository.voiceNotes(taskID: task.id) else { continue }
            for note in notes where note.transcriptState == .pending && !note.editedByUser {
                result.append(PendingNote(note: note, task: task))
            }
        }
        return result
    }

    private func transcribe(note: VoiceNote, in task: ShotTask) async {
        // Re-read: the user may have edited the transcript while an earlier note was running.
        let current = await storedNote(note.id, taskID: task.id) ?? note
        guard current.transcriptState == .pending, !current.editedByUser else { return }

        let fileURL = fileStore.absoluteURL(for: current.relPath)
        let transcript = try? await transcriber.transcribe(fileURL: fileURL, language: language)
        // Final review M8: when the model itself could not be loaded, the note is not at fault — it stays `pending`
        // for the model (the run stops at the next readiness check), and the model's `.failed` state carries the
        // error that Settings and the inspector show. Only a per-file error (the model still ready) fails the note.
        if transcript == nil, await transcriber.modelState() != .ready {
            Self.log.error("the transcription model could not be loaded; pending voice notes wait for it")
            return
        }

        // Re-read after the (multi-second) transcription: a deletion, an edit or a state change made
        // meanwhile wins, and the result is dropped instead of being saved over it.
        guard var updated = await storedNote(note.id, taskID: task.id),
            updated.transcriptState == .pending, !updated.editedByUser
        else { return }
        if let transcript {
            updated.transcript = transcript.text
            updated.transcriptJSON = Self.encode(transcript)
            updated.transcriptState = .done
            updated.engine = transcript.engine
            try? await taskRepository.save(updated)
            await autoFillTitle(for: task, transcript: transcript.text)
        } else {
            updated.transcriptState = .failed
            updated.engine = transcriber.engineName
            try? await taskRepository.save(updated)
        }
    }

    /// The note as stored now; nil when it is gone or cannot be read.
    private func storedNote(_ id: UUID, taskID: UUID) async -> VoiceNote? {
        (try? await taskRepository.voiceNotes(taskID: taskID))?.first { $0.id == id }
    }

    /// Spec §5.4: the title follows the note, then the transcript, and stops once the user edits it.
    private func autoFillTitle(for task: ShotTask, transcript: String) async {
        guard titleMaker else { return }
        let current = (try? await taskRepository.task(id: task.id)) ?? task
        guard current.titleEditedByUser == false,
            current.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        var updated = current
        updated.title = TitleMaker.title(
            noteText: current.noteText, transcript: transcript,
            createdAt: current.createdAt)
        updated.updatedAt = Date()
        try? await taskRepository.save(updated)
    }

    private static let log = Logger(subsystem: "com.shotcue.app", category: "transcription")

    static func encode(_ transcript: Transcript) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(transcript) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
