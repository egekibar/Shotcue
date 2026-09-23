import Foundation

/// Turns one agent CLI's NDJSON stdout into `RunEvent`s, line by line. Stateful (Codex's final answer is its last
/// message, Antigravity streams text in deltas), so the runner keeps one value per run behind a lock.
/// Every agent's events are logged in Claude's stream-json shape (`RunLogWriter`), so a finished run replays through
/// `StreamJSONParser` whichever agent ran it.
public protocol AgentStreamParser: Sendable {
    /// The events one stdout line carries (often none). Unparsable lines give none: a log line never kills a run.
    mutating func consume(line: String) -> [RunEvent]
}

public enum AgentStreamParsers {
    public static func make(for agent: AgentKind) -> any AgentStreamParser {
        switch agent {
        case .claude: ClaudeStreamParser()
        case .codex: CodexStreamParser()
        case .antigravity: AntigravityStreamParser()
        }
    }

    /// One NDJSON line as an object; nil for blank or malformed lines.
    static func object(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "run_command git status": the tool name and the first recognised input value, capped at 120 characters
    /// (the same shape as `StreamJSONParser.toolSummary`, which reads it back from the log).
    static func toolSummary(name: String, input: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(name) \(value.prefix(120))"
            }
        }
        return name
    }
}

/// `claude -p --output-format stream-json --verbose`: one event per line, see `StreamJSONParser`.
public struct ClaudeStreamParser: AgentStreamParser {
    public init() {}

    public mutating func consume(line: String) -> [RunEvent] {
        StreamJSONParser.parse(line: line).map { [$0] } ?? []
    }
}

/// `codex exec --json` (checked against codex-cli 0.148): `thread.started` carries the session id, `item.*` lines
/// carry messages and tool calls, `turn.completed` / `turn.failed` end the run. The answer is the last agent message.
public struct CodexStreamParser: AgentStreamParser {
    private var threadID: String?
    private var lastMessage: String?
    private var announcedItems: Set<String> = []
    private var toolCalls = 0

    public init() {}

    /// Model turns, counted like Claude's `num_turns`: one per tool call, plus the final answer.
    private var turns: Int { toolCalls + 1 }

    public mutating func consume(line: String) -> [RunEvent] {
        guard let object = AgentStreamParsers.object(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            threadID = object["thread_id"] as? String
            return [.initialized(sessionID: threadID, model: nil)]
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return [] }
            return itemEvents(item, completed: type == "item.completed")
        case "turn.completed":
            return [
                .result(
                    ClaudeRunResult(
                        subtype: ClaudeRunResult.successSubtype, isError: false, sessionID: threadID,
                        result: lastMessage, numTurns: turns))
            ]
        case "turn.failed":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "turn failed"
            return [
                .result(
                    ClaudeRunResult(
                        subtype: ClaudeRunResult.successSubtype, isError: true, sessionID: threadID,
                        result: message, numTurns: turns))
            ]
        case "error":
            // A stream error: codex retries on its own ("Reconnecting… 2/5") and ends with `turn.failed` or a
            // non-zero exit when it gives up.
            let message = object["message"] as? String ?? ""
            return message.lowercased().contains("reconnecting") ? [.apiRetry(attempt: nil)] : [.other(type: type)]
        default:
            return [.other(type: type)]
        }
    }

    private mutating func itemEvents(_ item: [String: Any], completed: Bool) -> [RunEvent] {
        let id = item["id"] as? String ?? UUID().uuidString
        let itemType = item["type"] as? String ?? ""
        switch itemType {
        case "agent_message":
            guard completed, let text = item["text"] as? String, !text.isEmpty else { return [] }
            lastMessage = text
            return [.assistantText(text)]
        case "reasoning", "todo_list":
            return []
        default:
            // A tool call (command, file change, MCP tool, web search): announced once, when it is first seen.
            guard !announcedItems.contains(id) else { return [] }
            announcedItems.insert(id)
            toolCalls += 1
            return [.toolUse(name: Self.toolName(itemType, item), summary: Self.toolSummary(itemType, item))]
        }
    }

    static func toolName(_ itemType: String, _ item: [String: Any]) -> String {
        switch itemType {
        case "command_execution": "Bash"
        case "file_change": "Edit"
        case "web_search": "WebSearch"
        case "mcp_tool_call": (item["tool"] as? String).map { "mcp \($0)" } ?? "mcp"
        default: itemType
        }
    }

    static func toolSummary(_ itemType: String, _ item: [String: Any]) -> String {
        let name = toolName(itemType, item)
        if itemType == "file_change", let changes = item["changes"] as? [[String: Any]] {
            let paths = changes.compactMap { $0["path"] as? String }.joined(separator: ", ")
            return paths.isEmpty ? name : "\(name) \(paths.prefix(120))"
        }
        return AgentStreamParsers.toolSummary(name: name, input: item, keys: ["command", "query", "server"])
    }
}

/// `agy -p … --output-format stream-json` (checked against Antigravity CLI 1.2.9): `init` carries the conversation id,
/// `step_update` lines carry tool steps and the answer in `text_delta` pieces, `result` ends the run.
public struct AntigravityStreamParser: AgentStreamParser {
    private var conversationID: String?
    /// Text deltas of agent-response steps still streaming, by step index.
    private var pendingText: [Int: String] = [:]
    private var announcedSteps: Set<Int> = []

    public init() {}

    /// Input keys of Antigravity's tools, in the order the summary prefers them.
    static let toolInputKeys = [
        "CommandLine", "AbsolutePath", "TargetFile", "DirectoryPath", "SearchPath", "Query", "Url", "Pattern",
    ]

    public mutating func consume(line: String) -> [RunEvent] {
        guard let object = AgentStreamParsers.object(line), let event = object["event"] as? String else { return [] }
        switch event {
        case "init":
            conversationID = object["conversation_id"] as? String
            return [.initialized(sessionID: conversationID, model: nil)]
        case "step_update":
            guard let step = object["step_update"] as? [String: Any] else { return [] }
            return stepEvents(step)
        case "result":
            guard let result = object["result"] as? [String: Any] else { return [] }
            return [.result(Self.makeResult(result, fallbackSessionID: conversationID))]
        default:
            return [.other(type: event)]
        }
    }

    private mutating func stepEvents(_ step: [String: Any]) -> [RunEvent] {
        let index = step["step_index"] as? Int ?? -1
        let done = (step["state"] as? String) == "DONE"
        switch step["step_type"] as? String {
        case "agent_response":
            if let delta = step["text_delta"] as? String { pendingText[index, default: ""] += delta }
            guard done, let text = pendingText.removeValue(forKey: index) else { return [] }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.assistantText(trimmed)]
        case "tool":
            guard !announcedSteps.contains(index) else { return [] }
            announcedSteps.insert(index)
            let name = step["tool_name"] as? String ?? "?"
            let info = step["tool_info"] as? [String: Any]
            let input = info?["parameters"] as? [String: Any] ?? [:]
            return [
                .toolUse(
                    name: name,
                    summary: AgentStreamParsers.toolSummary(name: name, input: input, keys: Self.toolInputKeys))
            ]
        default:
            return []
        }
    }

    /// `status` SUCCESS is a success; anything else is reported like Claude's API failures (`is_error`, subtype
    /// `success`), with the CLI's error line as the result text.
    static func makeResult(_ result: [String: Any], fallbackSessionID: String?) -> ClaudeRunResult {
        let succeeded = (result["status"] as? String) == "SUCCESS"
        let response = (result["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = (result["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = result["duration_seconds"] as? Double
        return ClaudeRunResult(
            subtype: ClaudeRunResult.successSubtype,
            isError: !succeeded,
            sessionID: result["conversation_id"] as? String ?? fallbackSessionID,
            result: succeeded ? response : (error?.isEmpty == false ? error : (result["status"] as? String)),
            numTurns: result["num_turns"] as? Int,
            durationMs: seconds.map { Int($0 * 1000) })
    }
}
