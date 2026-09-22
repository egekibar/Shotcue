import Foundation

/// Tolerant NDJSON parser for `claude -p --output-format stream-json --verbose`.
/// Unknown shapes become `.other`; unparsable lines return nil so a log line never kills a run.
public enum StreamJSONParser {
    public static func parse(line: String) -> RunEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }

        switch type {
        case "system":
            let subtype = object["subtype"] as? String ?? ""
            switch subtype {
            case "init":
                return .initialized(sessionID: object["session_id"] as? String, model: object["model"] as? String)
            case "api_retry": return .apiRetry(attempt: object["attempt"] as? Int)
            default: return .other(type: "system/\(subtype)")
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { return .other(type: type) }
            if let tool = content.first(where: { ($0["type"] as? String) == "tool_use" }) {
                let name = tool["name"] as? String ?? "?"
                let input = tool["input"] as? [String: Any] ?? [:]
                return .toolUse(name: name, summary: toolSummary(name: name, input: input))
            }
            let texts = content.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }
            return texts.isEmpty ? .other(type: type) : .assistantText(texts.joined(separator: "\n"))
        case "result":
            return .result(makeResult(object))
        default:
            return .other(type: type)
        }
    }

    /// "Read /tmp/a.png", "Bash git status"; falls back to the bare tool name. Values are capped at 120 chars.
    public static func toolSummary(name: String, input: [String: Any]) -> String {
        for key in ["file_path", "path", "command", "pattern", "query", "url", "notebook_path"] {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(name) \(value.prefix(120))"
            }
        }
        return name
    }

    static func makeResult(_ object: [String: Any]) -> ClaudeRunResult {
        let denials = (object["permission_denials"] as? [[String: Any]] ?? [])
            .compactMap { $0["tool_name"] as? String }
        return ClaudeRunResult(
            subtype: object["subtype"] as? String ?? "unknown",
            isError: object["is_error"] as? Bool ?? false,
            sessionID: object["session_id"] as? String,
            result: object["result"] as? String,
            totalCostUSD: object["total_cost_usd"] as? Double,
            numTurns: object["num_turns"] as? Int,
            durationMs: object["duration_ms"] as? Int,
            permissionDenials: denials)
    }
}
