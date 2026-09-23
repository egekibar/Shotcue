import AppKit
import Foundation
import ShotcueCore

public enum HandoffError: Error, Equatable, Sendable {
    case openFailed(String)
    /// A session id that is not a UUID never reaches a shell script (final review M6).
    case invalidSessionID(String)
}

/// Hands a session to the terminal or to Claude Desktop (spec §6.4, research 04 §3).
/// Deep links never auto-send: they fill the composer, the user presses Enter.
public struct DesktopHandoffService: HandoffService {
    /// Opens a file or URL; `NSWorkspace.shared.open` in the app, a recorder in tests.
    public typealias Opener = @Sendable (URL) -> Bool

    /// Claude Desktop silently truncates `q` at 14 336 characters; we stay below it.
    public static let composerPromptLimit = 14_000

    public let claudeExecutable: URL
    public let fileStore: FileStore
    /// `code/new` keeps the project context; `cowork/new` is the fallback when file
    /// attachments matter (research 04 §3.3-5).
    public let composerRoute: String
    private let open: Opener

    public init(
        claudeExecutable: URL, fileStore: FileStore, composerRoute: String = "code/new",
        open: @escaping Opener = { NSWorkspace.shared.open($0) }
    ) {
        self.claudeExecutable = claudeExecutable
        self.fileStore = fileStore
        self.composerRoute = composerRoute
        self.open = open
    }

    public func openInTerminal(sessionID: String, projectPath: String) throws {
        guard let session = UUID(uuidString: sessionID) else { throw HandoffError.invalidSessionID(sessionID) }
        let url = try Self.writeResumeCommand(
            claudeExecutable: claudeExecutable, sessionID: session.uuidString.lowercased(),
            projectPath: projectPath, fileStore: fileStore)
        guard open(url) else { throw HandoffError.openFailed(url.path) }
    }

    public func openInDesktop(sessionID: String) throws {
        let url = Self.resumeURL(sessionID: sessionID)
        guard open(url) else { throw HandoffError.openFailed(url.absoluteString) }
    }

    public func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws {
        let payload = try Self.composerPayload(prompt: prompt, files: files, fileStore: fileStore)
        let url = Self.composerURL(
            route: composerRoute, prompt: payload.text,
            projectPath: projectPath, files: payload.files)
        guard open(url) else { throw HandoffError.openFailed(url.absoluteString) }
    }

    // MARK: - File preparation (tested against a temporary FileStore)

    /// Writes `runs/<sessionID>-resume.command` with mode 755 and returns its URL.
    static func writeResumeCommand(
        claudeExecutable: URL, sessionID: String, projectPath: String, fileStore: FileStore
    ) throws -> URL {
        let relPath = "\(FileStore.runsDir)/\(sessionID)-resume.command"
        try fileStore.ensureParentDirectory(for: relPath)
        let url = fileStore.absoluteURL(for: relPath)
        try commandFileContents(claudeExecutable: claudeExecutable, sessionID: sessionID, projectPath: projectPath)
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A prompt longer than `composerPromptLimit` is written to `runs/<uuid>-prompt.md`; the composer
    /// then gets a Read instruction instead and the file is attached as well.
    static func composerPayload(prompt: String, files: [String], fileStore: FileStore) throws
        -> (text: String, files: [String])
    {
        guard prompt.count > composerPromptLimit else { return (prompt, files) }
        let relPath = fileStore.promptRelPath(id: UUID())
        try fileStore.ensureParentDirectory(for: relPath)
        let url = fileStore.absoluteURL(for: relPath)
        try prompt.write(to: url, atomically: true, encoding: .utf8)
        return (longPromptNotice(path: url.path), files + [url.path])
    }

    // MARK: - Pure parts (unit tested without opening anything)

    /// `cd` into the project first (claude keeps sessions per folder, and the resumed session's tools must run
    /// there), then resume. Every path is single-quoted; the session id is a validated UUID.
    public static func commandFileContents(claudeExecutable: URL, sessionID: String, projectPath: String) -> String {
        "#!/bin/zsh\n"
            + "cd -- \(shellQuoted(projectPath)) || exit 1\n"
            + "\(shellQuoted(claudeExecutable.path)) --resume \(sessionID)\n"
    }

    /// `text` as one zsh word: single quotes, each embedded `'` written as `'\''`.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func longPromptNotice(path: String) -> String {
        "The full task description did not fit here. Read it first with the Read tool: \(path)"
    }

    public static func resumeURL(sessionID: String) -> URL {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/resume"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url ?? URL(string: "claude://code/resume")!
    }

    public static func composerURL(route: String, prompt: String, projectPath: String, files: [String]) -> URL {
        var components = URLComponents()
        components.scheme = "claude"
        let parts = route.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        components.host = parts.first.map(String.init) ?? "code"
        components.path = "/" + (parts.count > 1 ? String(parts[1]) : "new")
        var items = [URLQueryItem(name: "q", value: String(prompt.prefix(composerPromptLimit)))]
        items.append(URLQueryItem(name: "folder", value: projectPath))
        items += files.map { URLQueryItem(name: "file", value: $0) }
        components.queryItems = items
        // URLComponents leaves `+` as it is, and a query decoder reads it as a space (final review M6).
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(string: "claude://code/new")!
    }
}
