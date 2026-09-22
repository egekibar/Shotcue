import Foundation
import Testing

@testable import ShotcueCore

@Suite("StreamJSONParser")
struct StreamJSONParserTests {
    var fixtureLines: [String] {
        let text = try! String(contentsOf: TestPaths.fixture("sample-stream.jsonl"), encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    @Test func parsesEveryFixtureLineInOrder() throws {
        let events = fixtureLines.compactMap { StreamJSONParser.parse(line: $0) }
        #expect(events.count == 7)
        #expect(events[0] == .initialized(sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73", model: "claude-sonnet-5"))
        #expect(events[1] == .assistantText("Reading the screenshot first."))
        #expect(events[2] == .toolUse(name: "Read", summary: "Read /tmp/shots/a.png"))
        #expect(events[3] == .other(type: "user"))
        #expect(events[4] == .apiRetry(attempt: 1))
        #expect(events[5] == .toolUse(name: "Edit", summary: "Edit /tmp/proj/src/Button.tsx"))
        guard case .result(let r) = events[6] else {
            Issue.record("last event must be result")
            return
        }
        #expect(r.subtype == "success" && r.isError == false && r.isSuccess)
        #expect(r.sessionID == "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
        #expect(r.numTurns == 11 && r.durationMs == 84213)
        #expect(r.totalCostUSD == 0.4137)
        #expect(r.result?.hasPrefix("Fixed the button color.") == true)
        #expect(r.permissionDenials.isEmpty)
    }

    @Test func blankAndGarbageLinesAreNil() {
        #expect(StreamJSONParser.parse(line: "") == nil)
        #expect(StreamJSONParser.parse(line: "   \n") == nil)
        #expect(StreamJSONParser.parse(line: "not json") == nil)
        #expect(StreamJSONParser.parse(line: "{\"no_type\":1}") == nil)
    }

    @Test func limitSubtypesAreDetected() {
        let line =
            "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"num_turns\":30,\"permission_denials\":[{\"tool_name\":\"Bash\"}]}"
        guard case .result(let r)? = StreamJSONParser.parse(line: line) else {
            Issue.record("expected result")
            return
        }
        #expect(r.hitLimit && !r.isSuccess)
        #expect(r.permissionDenials == ["Bash"])
        #expect(ClaudeRunResult(subtype: "error_max_budget_usd", isError: true).hitLimit)
        #expect(!ClaudeRunResult(subtype: "error_during_execution", isError: true).hitLimit)
    }

    @Test func toolSummaryPicksMeaningfulField() {
        #expect(StreamJSONParser.toolSummary(name: "Bash", input: ["command": "git status"]) == "Bash git status")
        #expect(StreamJSONParser.toolSummary(name: "Grep", input: ["pattern": "TODO", "path": "src"]) == "Grep src")
        #expect(StreamJSONParser.toolSummary(name: "WebSearch", input: ["query": "swift 6"]) == "WebSearch swift 6")
        #expect(StreamJSONParser.toolSummary(name: "Custom", input: ["x": 1]) == "Custom")
        let long = String(repeating: "a", count: 200)
        #expect(StreamJSONParser.toolSummary(name: "Bash", input: ["command": long]).count == "Bash ".count + 120)
    }
}
