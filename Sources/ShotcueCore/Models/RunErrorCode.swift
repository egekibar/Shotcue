import Foundation

/// Machine codes stored in `Run.error` (final review I6: the database keeps codes, the UI and the
/// notifications turn them into Turkish at display time).
public enum RunErrorCode {
    /// A voice note of the task was still waiting for its transcript (C1).
    public static let voiceNotePending = "voice_note_pending"
    /// A voice note's transcription failed and the user typed no text for it (C1).
    public static let voiceNoteFailed = "voice_note_failed"
    /// The task's voice notes could not be read, so the run could not prove it carries them (C1).
    public static let voiceNotesUnreadable = "voice_notes_unreadable"
}
