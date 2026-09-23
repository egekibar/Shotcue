import Foundation
import ShotcueCore

/// The command line and environment of each agent CLI. Claude Code's live in `ClaudeArguments`; this is the one
/// switch over agents the runner needs, plus Codex's and Antigravity's own flags.
public enum AgentArguments {
    public static func build(spec: RunSpec) -> [String] {
        switch spec.agent {
        case .claude: ClaudeArguments.build(spec: spec)
        case .codex: CodexArguments.build(spec: spec)
        case .antigravity: AntigravityArguments.build(spec: spec)
        }
    }

    /// Every agent gets HOME and a PATH that starts with its own directory (npm installs are `#!/usr/bin/env node`
    /// scripts). API keys are removed so each run uses the CLI's subscription login (Claude, ChatGPT, Google), not an
    /// API key that happens to be in the environment.
    public static func environment(agent: AgentKind, base: [String: String], executableDirectory: String)
        -> [String: String]
    {
        var environment = ClaudeArguments.environment(base: base, claudeDirectory: executableDirectory)
        switch agent {
        case .claude:
            break
        case .codex:
            environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_API_KEY")
        case .antigravity:
            environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
            environment.removeValue(forKey: "GEMINI_API_KEY")
            environment.removeValue(forKey: "GOOGLE_API_KEY")
        }
        return environment
    }

    /// Codex and Antigravity have no system-prompt flag that is safe to rely on: Shotcue's instructions lead the
    /// prompt instead.
    static func promptWithInstructions(_ spec: RunSpec) -> String {
        let instructions = spec.systemPromptAppend.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return spec.prompt }
        return "INSTRUCTIONS:\n\(instructions)\n\n\(spec.prompt)"
    }
}

/// `codex exec` (checked against codex-cli 0.148). Codex has no turn or budget limit; the run's timeout still applies.
public enum CodexArguments {
    public static func build(spec: RunSpec) -> [String] {
        var arguments = [
            "exec", "--json", "--color", "never", "--skip-git-repo-check",
            "--cd", spec.projectPath,
        ]
        if spec.mode == .analyze {
            arguments += ["--sandbox", "read-only"]
        } else if spec.permissionMode == .bypassPermissions {
            arguments.append("--dangerously-bypass-approvals-and-sandbox")
        } else {
            // Writes stay inside the project; the screenshots are read, which every sandbox allows.
            arguments += ["--sandbox", "workspace-write"]
        }
        if let model = spec.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort = spec.effort, !effort.isEmpty {
            arguments += ["--config", "model_reasoning_effort=\"\(effort)\""]
        }
        // Attached, so the model sees the captures without a tool call. `--image` takes several values: the
        // prompt goes after `--` so it is never read as one more.
        for image in spec.images {
            arguments += ["--image", image]
        }
        arguments += ["--", AgentArguments.promptWithInstructions(spec)]
        return arguments
    }
}

/// `agy -p` (checked against Antigravity CLI 1.2.9). No turn or budget limit; `--print-timeout` (5 minutes by default)
/// is raised to the run's own timeout, which Shotcue enforces as well.
public enum AntigravityArguments {
    public static func build(spec: RunSpec) -> [String] {
        var arguments = [
            "-p", AgentArguments.promptWithInstructions(spec),
            "--output-format", "stream-json",
            "--print-timeout", "\(max(60, Int(spec.timeout)))s",
        ]
        for directory in spec.addDirs {
            arguments += ["--add-dir", directory]
        }
        // Nobody answers a permission prompt in print mode, so every run skips them; outside bypass mode the
        // terminal sandbox keeps commands in check. Plan mode reads and proposes (the prompt forbids edits as well).
        if spec.mode == .analyze {
            arguments += ["--mode", "plan", "--sandbox"]
        } else if spec.permissionMode != .bypassPermissions {
            arguments += ["--mode", "accept-edits", "--sandbox"]
        }
        arguments.append("--dangerously-skip-permissions")
        if let model = spec.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort = spec.effort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        return arguments
    }
}
