import Foundation

/// Machine codes stored in `Run.error` (final review I6: the database keeps codes, `RunErrorText` turns them into
/// Turkish at display time, for the inspector and the failure notification alike). A stored value is `code` or
/// `code: detail`, where the detail is raw text worth showing as it is (git's stderr, a path).
public enum RunErrorCode {
    // MARK: Ended by the user or the app

    /// The user cancelled a run claude had started.
    public static let cancelled = "cancelled"
    /// Cancelled before claude was started.
    public static let cancelledBeforeLaunch = "cancelled_before_launch"
    /// The app quit or crashed while the run was active; marked at the next launch (spec §8). Also the code of the
    /// run row launch recovery adds for a task left `running` without an active run (I1).
    public static let interrupted = "interrupted"
    /// The run hit the time limit (spec §6.4, Ayarlar > Claude > Zaman aşımı).
    public static let timeout = "timeout"

    // MARK: claude itself

    public static let claudeNotFound = "claude_not_found"
    /// The process could not be started; the detail is the launch error.
    public static let claudeLaunchFailed = "claude_launch_failed"
    /// claude exited asking for a login (spec §8: "claude ile tekrar giriş yapın").
    public static let claudeNotLoggedIn = "claude_not_logged_in"
    /// claude exited non-zero without a result line; the detail is its first stderr line, the exit code is
    /// `Run.exitCode`.
    public static let claudeFailed = "claude_failed"
    /// claude exited 0 without a result line.
    public static let noResult = "no_result"
    /// A result line with a limit or an execution error: claude's own `subtype`, stored as it is.
    public static let maxTurns = ClaudeRunResult.maxTurnsSubtype
    public static let maxBudget = ClaudeRunResult.maxBudgetSubtype
    public static let executionError = ClaudeRunResult.executionErrorSubtype

    // MARK: Refused before claude was started

    /// A voice note of the task was still waiting for its transcript (C1).
    public static let voiceNotePending = "voice_note_pending"
    /// A voice note's transcription failed and the user typed no text for it (C1).
    public static let voiceNoteFailed = "voice_note_failed"
    /// The task's voice notes could not be read, so the run could not prove it carries them (C1).
    public static let voiceNotesUnreadable = "voice_notes_unreadable"
    /// The project runs in a new branch and `git switch -c` failed (I4).
    public static let gitBranchFailed = "git_branch_failed"
    /// The project stashes before a run and `git stash push` failed (I4).
    public static let gitStashFailed = "git_stash_failed"
    /// The task points at a project row that is gone.
    public static let projectMissing = "project_missing"
    /// The project row could not be read; the detail is the error.
    public static let projectUnreadable = "project_unreadable"
    /// The project's folder is missing or moved (spec §8); the detail is the path.
    public static let projectFolderMissing = "project_folder_missing"
    /// The task changed (or was deleted) between the queue and the launch.
    public static let taskChangedBeforeLaunch = "task_changed_before_launch"

    /// Anything else; the detail is the error's description.
    public static let unknownError = "unknown_error"

    // MARK: Stored form

    /// `code`, or `code: detail` when the detail is not empty. The detail is shown as it is, never translated.
    public static func compose(_ code: String, detail: String?) -> String {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? code : "\(code): \(trimmed)"
    }

    /// The code and detail of a stored value; nil when it is free text (rows written before codes existed hold
    /// Turkish sentences or raw stderr).
    public static func parse(_ stored: String) -> (code: String, detail: String?)? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCode(trimmed) { return (trimmed, nil) }
        guard let separator = trimmed.range(of: ": ") else { return nil }
        let code = String(trimmed[..<separator.lowerBound])
        guard isCode(code) else { return nil }
        let detail = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (code, detail.isEmpty ? nil : detail)
    }

    /// A machine token: lowercase ASCII letters, digits and underscores.
    public static func isCode(_ text: String) -> Bool {
        !text.isEmpty
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}
