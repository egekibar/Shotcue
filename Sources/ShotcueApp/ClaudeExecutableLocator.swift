import Foundation
import ShotcueClaudeBridge
import ShotcueCore
import os

/// Where `claude` lives (spec §6.4), found without ever blocking launch.
///
/// `ClaudeLocator.locate` ends with `zsh -lc "which claude"`, which runs the user's login profile with no
/// time limit; called from `applicationWillFinishLaunching` that could hang the app on the main thread.
/// Here the Settings path and the fixed install locations are checked synchronously (a few
/// `isExecutableFile` calls, the same order as `ClaudeLocator`); only when all of them miss does the login
/// shell run — on a background thread, bounded by `loginShellTimeout`.
nonisolated final class ClaudeExecutableLocator: Sendable {
    enum State: Equatable, Sendable {
        case searching
        case found(URL)
        case missing
    }

    static let loginShellTimeout: TimeInterval = 3

    private let state: OSAllocatedUnfairLock<State>
    private let search: Task<URL?, Never>

    /// `candidates` and `shellArguments` exist so the background path can be exercised; the app passes
    /// neither.
    init(
        preferredPath: String?, candidates: [String] = ClaudeLocator.defaultCandidates,
        shellArguments: [String] = ["-lc", "which claude"]
    ) {
        if let url = Self.fixedLocation(preferredPath: preferredPath, candidates: candidates) {
            state = OSAllocatedUnfairLock(initialState: .found(url))
            search = Task { url }
            return
        }
        let state = OSAllocatedUnfairLock<State>(initialState: .searching)
        self.state = state
        search = Task.detached(priority: .userInitiated) {
            let url = await Self.loginShellLocation(arguments: shellArguments)
            state.withLock { $0 = url.map { .found($0) } ?? .missing }
            AppLog.app.notice("claude login-shell search: \(url?.path ?? "not found", privacy: .public)")
            return url
        }
    }

    /// The answer so far, without waiting. `.searching` only for the first seconds after launch, and only
    /// when `claude` is in none of the fixed locations.
    var current: State { state.withLock { $0 } }

    /// The executable if it is already known; nil while searching or when it is missing.
    var currentExecutable: URL? {
        if case .found(let url) = current { return url }
        return nil
    }

    /// Waits for the background search (at most `loginShellTimeout` plus process teardown).
    func executable() async -> URL? {
        await search.value
    }

    static func fixedLocation(preferredPath: String?, candidates: [String]) -> URL? {
        var paths: [String] = []
        if let preferredPath, !preferredPath.trimmingCharacters(in: .whitespaces).isEmpty {
            paths.append(preferredPath)
        }
        paths += candidates
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        return nil
    }

    /// `zsh -l` reads the user's profile, which is where custom installs (npm prefix, nvm, volta) put
    /// `claude` on PATH. The first absolute path it prints is taken; a timeout counts as "not found".
    static func loginShellLocation(arguments: [String]) async -> URL? {
        let output = await Diagnostics.run(
            URL(fileURLWithPath: "/bin/zsh"), arguments, timeout: loginShellTimeout)
        guard !output.timedOut else { return nil }
        let path =
            output.stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") } ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

/// The runner `RunCoordinator` gets: every call waits for the locator, then goes to one
/// `ProcessClaudeRunner` (one instance, so a cancel finds the process its run started). Nothing found →
/// `ClaudeRunError.notFound`, which the coordinator turns into the spec §8 message.
nonisolated final class DeferredClaudeRunner: ClaudeRunner {
    private let runner: Task<ProcessClaudeRunner?, Never>

    init(locator: ClaudeExecutableLocator) {
        runner = Task { await locator.executable().map { ProcessClaudeRunner(executableURL: $0) } }
    }

    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        guard let runner = await runner.value else { throw ClaudeRunError.notFound }
        return try await runner.run(spec, onEvent: onEvent)
    }

    func cancel(runID: UUID) async {
        await runner.value?.cancel(runID: runID)
    }

    func version() async throws -> String {
        guard let runner = await runner.value else { throw ClaudeRunError.notFound }
        return try await runner.version()
    }
}

/// `DesktopHandoffService` bakes the `claude` path into the `.command` file it writes, but the path may
/// only be known after the background search. The service is therefore built per call with whatever the
/// locator knows by then (`ClaudeFallback` while searching or when missing: the file then fails loudly,
/// matching the red status in Settings).
nonisolated struct ClaudeHandoff: HandoffService {
    let locator: ClaudeExecutableLocator
    let fileStore: FileStore
    let composerRoute: String

    private var base: DesktopHandoffService {
        DesktopHandoffService(
            claudeExecutable: locator.currentExecutable ?? ClaudeFallback.executableURL,
            fileStore: fileStore,
            composerRoute: composerRoute)
    }

    func openInTerminal(sessionID: String) throws {
        try base.openInTerminal(sessionID: sessionID)
    }

    func openInDesktop(sessionID: String) throws {
        try base.openInDesktop(sessionID: sessionID)
    }

    func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws {
        try base.openDesktopComposer(prompt: prompt, projectPath: projectPath, files: files)
    }
}
