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
}
