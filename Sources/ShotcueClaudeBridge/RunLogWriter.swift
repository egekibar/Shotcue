import Foundation
import ShotcueCore

/// Appends one JSON object per `RunEvent` to `runs/<runID>.jsonl` (spec §6.4).
/// A value type so the runner's `@Sendable` event callback can capture it.
public struct RunLogWriter: Sendable {
    public let fileStore: FileStore

    public init(fileStore: FileStore) { self.fileStore = fileStore }

    /// Flat shape so the UI (and a human with `jq`) can read the log without the Core enum.
    struct Record: Encodable {
        var t: String
        var attempt: Int?
        var model: String?
        var name: String?
        var result: ClaudeRunResult?
        var session: String?
        var summary: String?
        var text: String?
        var type: String?
    }

    static func record(for event: RunEvent) -> Record {
        switch event {
        case .initialized(let sessionID, let model):
            return Record(t: "init", model: model, session: sessionID)
        case .assistantText(let text):
            return Record(t: "assistantText", text: text)
        case .toolUse(let name, let summary):
            return Record(t: "toolUse", name: name, summary: summary)
        case .apiRetry(let attempt):
            return Record(t: "apiRetry", attempt: attempt)
        case .result(let result):
            return Record(t: "result", result: result)
        case .other(let type):
            return Record(t: "other", type: type)
        }
    }

    /// One line of NDJSON, keys sorted so the output is byte-stable.
    public static func line(for event: RunEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record(for: event)) else { return #"{"t":"unencodable"}"# }
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
