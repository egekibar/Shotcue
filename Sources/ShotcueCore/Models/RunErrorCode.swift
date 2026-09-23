import Foundation

/// Machine codes stored in `Run.error` (final review I6: the database keeps codes, the UI and the
/// notifications turn them into Turkish at display time).
public enum RunErrorCode {
    /// The app quit or crashed while the run was active; marked at the next launch (spec §8). Also the code of
    /// the run row launch recovery adds for a task left `running` without an active run (I1).
    public static let interrupted = "interrupted"
    /// A voice note of the task was still waiting for its transcript (C1).
    public static let voiceNotePending = "voice_note_pending"
    /// A voice note's transcription failed and the user typed no text for it (C1).
    public static let voiceNoteFailed = "voice_note_failed"
    /// The task's voice notes could not be read, so the run could not prove it carries them (C1).
    public static let voiceNotesUnreadable = "voice_notes_unreadable"
    /// The project runs in a new branch and `git switch -c` failed; claude was not started (I4).
    public static let gitBranchFailed = "git_branch_failed"
    /// The project stashes before a run and `git stash push` failed; claude was not started (I4).
    public static let gitStashFailed = "git_stash_failed"

    /// `code`, or `code: detail` when a raw detail (git's first stderr line, a path) helps the user; the detail is
    /// shown as it is, never translated.
    public static func compose(_ code: String, detail: String?) -> String {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? code : "\(code): \(trimmed)"
    }
}
