import Foundation
import Testing

@testable import ShotcueCore

/// Final review C1: a run never starts while one of the task's voice notes has no usable text.
@Suite("Voice note readiness")
struct VoiceNoteReadinessTests {
    let taskID = UUID()

    func note(_ state: TranscriptState, editedByUser: Bool = false, transcript: String? = nil) -> VoiceNote {
        VoiceNote(
            taskID: taskID, relPath: "audio/\(UUID().uuidString).m4a", durationSec: 3,
            transcript: transcript, transcriptState: state, editedByUser: editedByUser)
    }

    @Test func aTaskWithoutVoiceNotesIsReady() {
        #expect(VoiceNoteReadiness.of([]) == .ready)
    }

    @Test func finishedTranscriptsAreReady() {
        #expect(VoiceNoteReadiness.of([note(.done, transcript: "bir"), note(.done, transcript: "")]) == .ready)
    }

    @Test func aPendingTranscriptIsPending() {
        #expect(VoiceNoteReadiness.of([note(.done, transcript: "bir"), note(.pending)]) == .pending)
    }

    @Test func aFailedTranscriptWithoutUserTextIsFailed() {
        #expect(VoiceNoteReadiness.of([note(.failed)]) == .failed)
    }

    @Test func aFailureWinsOverAPendingNote() {
        // Waiting cannot fix the failed note, so the send is refused at once.
        #expect(VoiceNoteReadiness.of([note(.pending), note(.failed)]) == .failed)
    }

    @Test func textTheUserTypedIsAlwaysUsable() {
        #expect(VoiceNoteReadiness.of([note(.failed, editedByUser: true, transcript: "elle yazdım")]) == .ready)
        #expect(VoiceNoteReadiness.of([note(.pending, editedByUser: true, transcript: "elle yazdım")]) == .ready)
        #expect(note(.failed, editedByUser: true).hasUsableText)
        #expect(!note(.failed).hasUsableText)
        #expect(!note(.pending).hasUsableText)
        #expect(note(.done).hasUsableText)
    }
}
