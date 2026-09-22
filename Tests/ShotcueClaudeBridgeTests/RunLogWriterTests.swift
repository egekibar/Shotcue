import Foundation
import ShotcueCore
import Testing

@testable import ShotcueClaudeBridge

@Suite("RunLogWriter")
struct RunLogWriterTests {
    let runID = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!

    func object(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func everyEventKindBecomesOneJSONObject() throws {
        #expect(
            try object(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")))["t"] as? String
                == "toolUse")
        #expect(
            try object(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")))["name"] as? String
                == "Read")
        #expect(try object(RunLogWriter.line(for: .assistantText("merhaba")))["text"] as? String == "merhaba")
        #expect(try object(RunLogWriter.line(for: .apiRetry(attempt: 2)))["attempt"] as? Int == 2)
        #expect(try object(RunLogWriter.line(for: .other(type: "user")))["type"] as? String == "user")
        let initLine = try object(RunLogWriter.line(for: .initialized(sessionID: "s1", model: "sonnet")))
        #expect(initLine["t"] as? String == "init")
        #expect(initLine["session"] as? String == "s1")
        #expect(initLine["model"] as? String == "sonnet")
        // Slashes are not escaped, so paths stay readable in the log.
        #expect(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")).contains("/tmp/a.png"))
    }

    @Test func resultIsNested() throws {
        let result = ClaudeRunResult(
            subtype: "success", isError: false, sessionID: "s",
            result: "ok", totalCostUSD: 0.42, numTurns: 7, durationMs: 1234)
        let line = try object(RunLogWriter.line(for: .result(result)))
        #expect(line["t"] as? String == "result")
        let nested = try #require(line["result"] as? [String: Any])
        #expect(nested["subtype"] as? String == "success")
        #expect(nested["numTurns"] as? Int == 7)
        #expect(nested["totalCostUSD"] as? Double == 0.42)
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
        #expect(try object(String(lines[2]))["text"] as? String == "iki\nsatır")
    }
}
