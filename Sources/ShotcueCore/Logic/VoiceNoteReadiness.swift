import Foundation

/// Whether a task's voice notes can go to Claude (spec §5.2; final review C1). The voice note is the main
/// instruction channel, so a run never starts while one of them has no usable text.
public enum VoiceNoteReadiness: Hashable, Sendable {
    /// Every note has text Claude can read: a finished transcript or text the user typed.
    case ready
    /// At least one note is still waiting for its transcript, and none failed.
    case pending
    /// At least one transcription failed and the user typed nothing for it. Waiting cannot fix it.
    case failed

    public static func of(_ notes: [VoiceNote]) -> VoiceNoteReadiness {
        if notes.contains(where: \.hasFailedWithoutText) { return .failed }
        if notes.contains(where: \.isAwaitingTranscript) { return .pending }
        return .ready
    }
}

extension VoiceNote {
    /// The text a run may use: the user's own (an edited transcript is never overwritten, spec §5.2) or a
    /// finished transcript.
    public var hasUsableText: Bool { editedByUser || transcriptState == .done }

    /// Still waiting for the transcriber.
    public var isAwaitingTranscript: Bool { !editedByUser && transcriptState == .pending }

    /// The transcriber gave up and the user has not typed the text in.
    public var hasFailedWithoutText: Bool { !editedByUser && transcriptState == .failed }
}
