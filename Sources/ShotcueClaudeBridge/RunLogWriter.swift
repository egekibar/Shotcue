import Foundation
import ShotcueCore

/// Appends one line per `RunEvent` to `runs/<runID>.jsonl` (spec §6.4), in claude's own stream-json
/// shapes: `StreamJSONParser.parse(line:)` reads every line back as the identical event, so the UI
/// replays a finished run exactly like a live one (and `jq` works on the file).
/// A value type so the runner's `@Sendable` event callback can capture it.
public struct RunLogWriter: Sendable {
    public let fileStore: FileStore

    public init(fileStore: FileStore) { self.fileStore = fileStore }

    /// The part of claude's stream-json that `StreamJSONParser` reads; nil keys are left out.
    struct StreamLine: Encodable {
        var type: String
        var subtype: String?
        var sessionID: String?
        var model: String?
        var attempt: Int?
        var message: Message?
        var isError: Bool?
        var result: String?
        var totalCostUSD: Double?
        var numTurns: Int?
        var durationMs: Int?
        var permissionDenials: [Denial]?

        enum CodingKeys: String, CodingKey {
            case type, subtype, model, attempt, message, result
            case sessionID = "session_id"
            case isError = "is_error"
            case totalCostUSD = "total_cost_usd"
            case numTurns = "num_turns"
            case durationMs = "duration_ms"
            case permissionDenials = "permission_denials"
        }
    }

    struct Message: Encodable {
        var role = "assistant"
        var content: [Block]
    }

    struct Block: Encodable {
        var type: String
        var text: String?
        var name: String?
        var input: [String: String]?
    }

    struct Denial: Encodable {
        var toolName: String
        enum CodingKeys: String, CodingKey { case toolName = "tool_name" }
    }

    static func streamLine(for event: RunEvent) -> StreamLine {
        switch event {
        case .initialized(let sessionID, let model):
            return StreamLine(type: "system", subtype: "init", sessionID: sessionID, model: model)
        case .assistantText(let text):
            return StreamLine(type: "assistant", message: Message(content: [Block(type: "text", text: text)]))
        case .toolUse(let name, let summary):
            let block = Block(type: "tool_use", name: name, input: toolInput(name: name, summary: summary))
            return StreamLine(type: "assistant", message: Message(content: [block]))
        case .apiRetry(let attempt):
            return StreamLine(type: "system", subtype: "api_retry", attempt: attempt)
        case .result(let result):
            return StreamLine(
                type: "result", subtype: result.subtype, sessionID: result.sessionID, isError: result.isError,
                result: result.result, totalCostUSD: result.totalCostUSD, numTurns: result.numTurns,
                durationMs: result.durationMs, permissionDenials: result.permissionDenials.map { Denial(toolName: $0) })
        case .other(let type):
            // The parser names unknown system lines "system/<subtype>".
            let systemPrefix = "system/"
            if type.hasPrefix(systemPrefix) {
                return StreamLine(type: "system", subtype: String(type.dropFirst(systemPrefix.count)))
            }
            return StreamLine(type: type)
        }
    }

    /// `StreamJSONParser.toolSummary` renders an empty input as the bare tool name and otherwise
    /// "name value" for the first recognised key, so the text after "name " goes under `command`.
    static func toolInput(name: String, summary: String) -> [String: String] {
        guard summary != name else { return [:] }
        let prefix = name + " "
        return ["command": summary.hasPrefix(prefix) ? String(summary.dropFirst(prefix.count)) : summary]
    }

    /// One line of NDJSON, keys sorted so the output is byte-stable.
    public static func line(for event: RunEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(streamLine(for: event)) else { return #"{"type":"unencodable"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    public func append(_ event: RunEvent, runID: UUID) throws {
        let relPath = fileStore.runLogRelPath(id: runID)
        let url = fileStore.absoluteURL(for: relPath)
        let payload = Data((Self.line(for: event) + "\n").utf8)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            try fileStore.ensureParentDirectory(for: relPath)
            try payload.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }
}
