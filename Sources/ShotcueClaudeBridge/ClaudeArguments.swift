import Foundation
import ShotcueCore

/// Pure construction of the `claude -p` command line and its environment (spec §6.4).
/// Everything version-sensitive lives here so a CLI upgrade touches one file.
public enum ClaudeArguments {
    /// Analyze mode is locked down to read-only tools.
    public static let analyzeAllowedTools =
        "Read,Glob,Grep,WebFetch,WebSearch,Bash(git log *),Bash(git diff *),Bash(git status *),Bash(git show *)"

    /// `CLAUDE_CODE_ENTRYPOINT` for our runs. `claude -p` records `sdk-cli` in the transcript, and Claude Desktop
    /// leaves `sdk-*` transcripts out of its CLI session list; `cli` is rewritten to `sdk-cli` in print mode,
    /// so the tag is our own name (verified against CLI 2.1.280 and Desktop 2.7032.0).
    public static let entrypoint = "shotcue"

    /// System paths appended after the `claude` binary's own directory.
    public static let systemPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func build(spec: RunSpec) -> [String] {
        let analyze = spec.mode == .analyze
        var arguments: [String] = [
            "-p", spec.prompt,
            "--session-id", spec.runID.uuidString.lowercased(),
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompts", "none",
            "--max-turns", "\(spec.maxTurns)",
            "--max-budget-usd", String(format: "%.2f", spec.maxBudgetUSD),
            "--append-system-prompt", spec.systemPromptAppend,
        ]
        for directory in spec.addDirs {
            arguments += ["--add-dir", directory]
        }
        arguments += [
            "--permission-mode", analyze ? ClaudePermissionMode.dontAsk.rawValue : spec.permissionMode.rawValue,
        ]
        if analyze {
            arguments += ["--allowedTools", analyzeAllowedTools]
        }
        if let model = spec.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort = spec.effort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        return arguments
    }

    /// `claude` must see HOME (keychain + ~/.claude) and a PATH that contains its own directory.
    /// `ANTHROPIC_API_KEY` is removed so the run bills the user's subscription login, not an API key.
    /// The entrypoint tag keeps the run visible in Claude Desktop (see `entrypoint`).
    public static func environment(base: [String: String], claudeDirectory: String) -> [String: String] {
        var environment = base
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "\(claudeDirectory):\(systemPath)"
        environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        return environment
    }
}
