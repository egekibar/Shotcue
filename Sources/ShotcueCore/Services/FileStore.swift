import Foundation

/// On-disk layout (spec §6.3). The DB stores paths relative to `rootURL` so the folder can move.
public struct FileStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL }

    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Shotcue", isDirectory: true)
    }

    public static let capturesDir = "captures"
    public static let thumbsDir = "thumbs"
    public static let audioDir = "audio"
    public static let runsDir = "runs"

    public var databaseURL: URL { rootURL.appendingPathComponent("shotcue.sqlite") }

    public func absoluteURL(for relPath: String) -> URL { rootURL.appendingPathComponent(relPath) }

    /// Inverse of `absoluteURL(for:)`; nil when the URL is outside the root.
    public func relativePath(for url: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    public func captureRelPath(id: UUID, date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(
            format: "%@/%04d/%02d/%@.png", Self.capturesDir, c.year ?? 0, c.month ?? 0, id.uuidString.lowercased())
    }
    public func thumbRelPath(id: UUID) -> String { "\(Self.thumbsDir)/\(id.uuidString.lowercased()).jpg" }
    public func audioRelPath(id: UUID) -> String { "\(Self.audioDir)/\(id.uuidString.lowercased()).m4a" }
    public func runLogRelPath(id: UUID) -> String { "\(Self.runsDir)/\(id.uuidString.lowercased()).jsonl" }
    public func promptRelPath(id: UUID) -> String { "\(Self.runsDir)/\(id.uuidString.lowercased())-prompt.md" }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for dir in [Self.capturesDir, Self.thumbsDir, Self.audioDir, Self.runsDir] {
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(dir, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    public func ensureParentDirectory(for relPath: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: absoluteURL(for: relPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }

    // MARK: - Resumable runs (final review M4)

    /// claude wrote at least one event for the run: the run log exists and is not empty. The log is written from
    /// the first event on (claude's `init` carries the session id), so a run without one never started a session.
    public func hasRunLog(_ run: Run, fileManager: FileManager = .default) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: absoluteURL(for: run.logRelPath).path)
        return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
    }

    /// The run "Terminalde devam et" / "Desktop'ta aç" resume: the newest one that actually started claude — still
    /// running, or finished with events in its log. Runs refused or cancelled before launch, claude not found, and
    /// launch-recovery rows have no session (`--resume` would say "No conversation found") and are skipped.
    public func latestLaunchedRun(in runs: [Run], fileManager: FileManager = .default) -> Run? {
        runs.sorted { $0.startedAt > $1.startedAt }.first { run in
            if run.state == .running { return true }
            guard run.isFinished, hasRunLog(run, fileManager: fileManager) else { return false }
            // Codex and Antigravity pick their own session id: a run that ended without one has nothing to resume.
            return run.agent == .claude || resumeSessionID(for: run, fileManager: fileManager) != nil
        }
    }

    /// The id `run`'s resume command takes: the recorded one, else the `init` event at the top of its log — the
    /// coordinator records Codex's and Antigravity's session id when the run ends, so a run still going (or one a
    /// crash cut short) only has it there.
    public func resumeSessionID(for run: Run, fileManager: FileManager = .default) -> String? {
        if let id = run.resumeSessionID { return id }
        guard let handle = try? FileHandle(forReadingFrom: absoluteURL(for: run.logRelPath)) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        for line in head.split(separator: "\n") {
            if case .initialized(let sessionID, _)? = StreamJSONParser.parse(line: String(line)), let sessionID {
                return sessionID
            }
        }
        return nil
    }
}
