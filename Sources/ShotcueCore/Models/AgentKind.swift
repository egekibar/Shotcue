import Foundation

/// The coding agent CLI a run goes to. Stored as its raw value (project default, run row, settings).
public enum AgentKind: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Anthropic's Claude Code, `claude -p`.
    case claude
    /// OpenAI's Codex CLI, `codex exec --json`.
    case codex
    /// Google's Antigravity CLI, `agy -p --output-format stream-json`.
    case antigravity

    public var id: String { rawValue }

    /// Product name for the UI.
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    /// The executable's name, as the user types it in a terminal.
    public var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        }
    }

    /// Fixed install locations checked in order (after the path set in Settings), before the login shell.
    public var defaultCandidates: [String] {
        switch self {
        case .claude:
            ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            // The Homebrew cask and npm installs, then the copy the ChatGPT app ships.
            [
                "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
            ]
        case .antigravity:
            ["~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        }
    }

    /// Only Claude Code enforces Shotcue's turn and budget limits; the other CLIs have no such flags.
    public var supportsTurnAndBudgetLimits: Bool { self == .claude }

    /// Only Claude Code has a desktop app that resumes a CLI session by id (`claude://code/resume`).
    public var supportsDesktopResume: Bool { self == .claude }

    /// The effective agent: the project's own choice, else the global default.
    public static func resolve(project: AgentKind?, default fallback: AgentKind) -> AgentKind {
        project ?? fallback
    }

    /// A stored raw value, tolerating unknown or empty ones (nil).
    public init?(stored: String?) {
        guard let stored, let kind = AgentKind(rawValue: stored.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        self = kind
    }
}

/// Model and effort choices offered per agent. "" means "inherit" (task → project → settings → CLI default).
public enum AgentModelChoices {
    public static func aliases(for agent: AgentKind) -> [String] {
        switch agent {
        case .claude: ClaudeModelChoices.aliases
        case .codex: ["", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
        case .antigravity:
            [
                "", "gemini-3.1-pro-high", "gemini-3.1-pro-low", "gemini-3.8-flash-high",
                "gemini-3.8-flash-medium", "claude-opus-4-6-thinking", "claude-sonnet-4-6",
            ]
        }
    }

    /// The agent's aliases, plus a stored value that is not one of them so the picker can still show and keep it.
    public static func options(for agent: AgentKind, including stored: String?) -> [String] {
        let aliases = aliases(for: agent)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !aliases.contains(trimmed) else { return aliases }
        return aliases + [trimmed]
    }

    /// Reasoning effort values each CLI accepts; "" = not set.
    public static func efforts(for agent: AgentKind) -> [String] {
        switch agent {
        case .claude: ["", "low", "medium", "high", "xhigh", "max"]
        case .codex: ["", "low", "medium", "high", "xhigh"]
        case .antigravity: ["", "low", "medium", "high"]
        }
    }

    /// Whether `model` may go to `agent`: a value that is one of ANOTHER agent's own choices (a task's "opus" after its
    /// project moved to Codex) does not; anything else (a full model id typed earlier) is passed through.
    public static func model(_ model: String?, appliesTo agent: AgentKind) -> Bool {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return false
        }
        if aliases(for: agent).contains(model) { return true }
        return !AgentKind.allCases.contains { $0 != agent && aliases(for: $0).contains(model) }
    }

    /// The first model in the chain (task, project, settings) that applies to `agent`; nil = the CLI's default.
    public static func resolveModel(_ chain: [String?], for agent: AgentKind) -> String? {
        chain.compactMap { $0 }.first { model($0, appliesTo: agent) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first effort in the chain the agent accepts; nil = not set.
    public static func resolveEffort(_ chain: [String?], for agent: AgentKind) -> String? {
        let accepted = efforts(for: agent).filter { !$0.isEmpty }
        return chain.lazy.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { accepted.contains($0) }
    }
}
