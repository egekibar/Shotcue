import Foundation

public struct ScreenshotRef: Hashable, Sendable {
    public var absolutePath: String
    public var label: String?
    public init(absolutePath: String, label: String? = nil) {
        self.absolutePath = absolutePath
        self.label = label
    }
}

public struct PromptInput: Hashable, Sendable {
    public var mode: TaskMode
    public var title: String
    public var projectPath: String
    public var screenshots: [ScreenshotRef]
    public var noteText: String
    public var transcripts: [String]
    public init(
        mode: TaskMode, title: String, projectPath: String, screenshots: [ScreenshotRef],
        noteText: String, transcripts: [String]
    ) {
        self.mode = mode
        self.title = title
        self.projectPath = projectPath
        self.screenshots = screenshots
        self.noteText = noteText
        self.transcripts = transcripts
    }
}

/// Builds the user prompt for `claude -p` (spec §6.4). Screenshots first, then notes, then the contract.
public enum PromptBuilder {
    public static func build(_ input: PromptInput) -> String {
        var lines: [String] = []
        lines.append("TASK TYPE: \(input.mode == .analyze ? "ANALYZE ONLY" : "IMPLEMENT")")
        lines.append("TITLE: \(input.title)")
        lines.append("")
        if input.screenshots.isEmpty {
            lines.append("SCREENSHOTS: none")
        } else {
            lines.append("SCREENSHOTS (read each of these with the Read tool BEFORE doing anything else):")
            for shot in input.screenshots {
                if let label = shot.label, !label.isEmpty {
                    lines.append("- \(shot.absolutePath)  (\(label))")
                } else {
                    lines.append("- \(shot.absolutePath)")
                }
            }
        }
        let note = input.noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("")
            lines.append("NOTE (written by the user):")
            lines.append(note)
        }
        let transcripts = input.transcripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !transcripts.isEmpty {
            lines.append("")
            lines.append(
                "VOICE NOTE (dictated by the user; verbatim transcript, may contain transcription errors, interpret the intent):"
            )
            for t in transcripts { lines.append("\"\(t)\"") }
        }
        lines.append("")
        lines.append("PROJECT: \(input.projectPath)")
        lines.append("")
        lines.append("EXPECTED OUTCOME:")
        lines.append(contentsOf: input.mode == .analyze ? analyzeOutcome : implementOutcome)
        return lines.joined(separator: "\n")
    }

    static let implementOutcome = [
        "1. Do what the note asks; the screenshots are the source of truth for the current UI and behavior.",
        "2. Add or update tests that cover the change and run them.",
        "3. Do NOT commit or push. Do NOT touch unrelated modules.",
        "4. Finish with: a 3-line summary, the list of changed files, and anything you could not do and why.",
    ]

    static let analyzeOutcome = [
        "1. Investigate what the screenshots and note describe: root cause, affected files, relevant code paths.",
        "2. Propose a concrete plan with file paths and the order of changes.",
        "3. Do NOT modify any file. Do NOT run commands that change the working tree.",
        "4. Finish with: a 3-line summary and the list of files you examined.",
    ]

    /// Passed via `--append-system-prompt` on every run (user's own extra instructions are appended after it).
    public static let systemPromptAppend = """
        You are processing a task captured with Shotcue, a macOS screenshot + voice-note tool. \
        The screenshots are UI captures from the running application; read them with the Read tool before editing code. \
        The voice-note transcript is dictated speech: it may contain filler words, Turkish/English code-switching and \
        transcription errors (technical terms may be rendered phonetically). Interpret the intent; do not quote it literally. \
        Always finish with: (1) a 3-line summary, (2) the list of files you changed, (3) what you could NOT do and why. \
        If the task type is ANALYZE ONLY, do not modify any file.
        """
}
