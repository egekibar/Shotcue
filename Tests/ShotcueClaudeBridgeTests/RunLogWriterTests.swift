import Foundation
import ShotcueCore
import Testing

@testable import ShotcueClaudeBridge

/// One of every `RunEvent` shape `StreamJSONParser` produces, nil optionals and denials included.
private let everyEvent: [RunEvent] = [
    .initialized(sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73", model: "claude-sonnet-5"),
    .initialized(sessionID: nil, model: nil),
    .assistantText("merhaba\nikinci satır \"tırnak\" /tmp/a.png"),
    .assistantText(""),
    .toolUse(name: "Read", summary: "Read /tmp/shots/a.png"),
    .toolUse(name: "Bash", summary: "Bash git status --porcelain"),
    .toolUse(name: "TodoWrite", summary: "TodoWrite"),
    .apiRetry(attempt: 2),
    .apiRetry(attempt: nil),
    .result(
        ClaudeRunResult(
            subtype: "success", isError: false, sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73",
            result: "Özet satırı\nikinci satır", totalCostUSD: 0.4137, numTurns: 11, durationMs: 84213,
            permissionDenials: ["Bash", "WebFetch"])),
    .result(ClaudeRunResult(subtype: ClaudeRunResult.maxTurnsSubtype, isError: true)),
    .other(type: "user"),
    .other(type: "assistant"),
    .other(type: "system/compact_boundary"),
]

@Suite("RunLogWriter")
struct RunLogWriterTests {
    let runID = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!

    func object(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func firstBlock(of object: [String: Any]) throws -> [String: Any] {
        let message = try #require(object["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        return try #require(content.first)
    }

    /// The UI replays a finished run by feeding every log line to `StreamJSONParser`.
    @Test(arguments: everyEvent)
    func streamJSONParserReadsEveryLineBackAsTheSameEvent(_ event: RunEvent) {
        #expect(StreamJSONParser.parse(line: RunLogWriter.line(for: event)) == event)
    }

    @Test func everyEventKindBecomesOneStreamJSONObject() throws {
        let initLine = try object(RunLogWriter.line(for: .initialized(sessionID: "s1", model: "sonnet")))
        #expect(initLine["type"] as? String == "system")
        #expect(initLine["subtype"] as? String == "init")
        #expect(initLine["session_id"] as? String == "s1")
        #expect(initLine["model"] as? String == "sonnet")
        // nil optionals are left out, like claude does.
        let bareInit = try object(RunLogWriter.line(for: .initialized(sessionID: nil, model: nil)))
        #expect(bareInit.keys.sorted() == ["subtype", "type"])

        let text = try object(RunLogWriter.line(for: .assistantText("merhaba")))
        #expect(text["type"] as? String == "assistant")
        let textBlock = try firstBlock(of: text)
        #expect(textBlock["type"] as? String == "text")
        #expect(textBlock["text"] as? String == "merhaba")

        let tool = try object(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")))
        #expect(tool["type"] as? String == "assistant")
        let toolBlock = try firstBlock(of: tool)
        #expect(toolBlock["type"] as? String == "tool_use")
        #expect(toolBlock["name"] as? String == "Read")

        let retry = try object(RunLogWriter.line(for: .apiRetry(attempt: 2)))
        #expect(retry["type"] as? String == "system")
        #expect(retry["subtype"] as? String == "api_retry")
        #expect(retry["attempt"] as? Int == 2)

        #expect(try object(RunLogWriter.line(for: .other(type: "user")))["type"] as? String == "user")
        let system = try object(RunLogWriter.line(for: .other(type: "system/compact_boundary")))
        #expect(system["type"] as? String == "system")
        #expect(system["subtype"] as? String == "compact_boundary")
        // Slashes are not escaped, so paths stay readable in the log.
        #expect(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")).contains("/tmp/a.png"))
    }

    @Test func resultUsesTheCLIKeys() throws {
        let result = ClaudeRunResult(
            subtype: "success", isError: false, sessionID: "s",
            result: "ok", totalCostUSD: 0.42, numTurns: 7, durationMs: 1234, permissionDenials: ["Bash"])
        let line = try object(RunLogWriter.line(for: .result(result)))
        #expect(line["type"] as? String == "result")
        #expect(line["subtype"] as? String == "success")
        #expect(line["is_error"] as? Bool == false)
        #expect(line["session_id"] as? String == "s")
        #expect(line["result"] as? String == "ok")
        #expect(line["total_cost_usd"] as? Double == 0.42)
        #expect(line["num_turns"] as? Int == 7)
        #expect(line["duration_ms"] as? Int == 1234)
        let denials = try #require(line["permission_denials"] as? [[String: Any]])
        #expect(denials.compactMap { $0["tool_name"] as? String } == ["Bash"])
    }

    @Test func appendWritesOneLinePerEventAndCreatesTheDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileStore(rootURL: root)
        let writer = RunLogWriter(fileStore: store)

        try writer.append(.initialized(sessionID: "s", model: "m"), runID: runID)
        try writer.append(.assistantText("bir"), runID: runID)
        try writer.append(.assistantText("iki\nsatır"), runID: runID)

        let url = store.absoluteURL(for: store.runLogRelPath(id: runID))
        #expect(url.path.hasSuffix("runs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        // An embedded newline must not become a second line.
        #expect(StreamJSONParser.parse(line: String(lines[2])) == .assistantText("iki\nsatır"))
    }
}
