import Foundation
import ShotcueClaudeBridge
import ShotcueCore
import os

/// Where one agent CLI (`claude`, `codex`, `agy`) lives (spec §6.4), found without ever blocking launch.
///
/// `ClaudeLocator.locate` ends with `zsh -lc "which claude"`, which runs the user's login profile with no
/// time limit; called from `applicationWillFinishLaunching` that could hang the app on the main thread.
/// Here the Settings path and the fixed install locations are checked synchronously (a few
/// `isExecutableFile` calls, the same order as `ClaudeLocator`); only when all of them miss does the login
/// shell run — on a background thread, bounded by `loginShellTimeout`.
nonisolated final class AgentExecutableLocator: Sendable {
    enum State: Equatable, Sendable {
        case searching
        case found(URL)
        case missing
    }

    static let loginShellTimeout: TimeInterval = 3

    let agent: AgentKind
    private let state: OSAllocatedUnfairLock<State>
    private let search: Task<URL?, Never>

    /// `candidates` and `shellArguments` exist so the background path can be exercised; the app passes
    /// neither and gets the agent's own.
    init(
        agent: AgentKind = .claude, preferredPath: String?, candidates: [String]? = nil,
        shellArguments: [String]? = nil
    ) {
        self.agent = agent
        let candidates = candidates ?? agent.defaultCandidates
        let shellArguments = shellArguments ?? ["-lc", "which \(agent.executableName)"]
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
            AppLog.app.notice(
                "\(agent.executableName, privacy: .public) login-shell search: \(url == nil ? "not found" : "found", privacy: .public) \(url?.path ?? "", privacy: .private)"
            )
            return url
        }
    }

    /// The answer so far, without waiting. `.searching` only for the first seconds after launch, and only
    /// when the CLI is in none of the fixed locations.
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

    /// `zsh -l` reads the user's profile, which is where custom installs (npm prefix, nvm, volta, bun) put
    /// the CLI on PATH. The first absolute path it prints is taken; a timeout counts as "not found".
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

/// One locator per agent, each searching on its own.
nonisolated struct AgentLocators: Sendable {
    let claude: AgentExecutableLocator
    let codex: AgentExecutableLocator
    let antigravity: AgentExecutableLocator

    init(paths: [AgentKind: String]) {
        claude = AgentExecutableLocator(agent: .claude, preferredPath: paths[.claude])
        codex = AgentExecutableLocator(agent: .codex, preferredPath: paths[.codex])
        antigravity = AgentExecutableLocator(agent: .antigravity, preferredPath: paths[.antigravity])
    }

    subscript(agent: AgentKind) -> AgentExecutableLocator {
        switch agent {
        case .claude: claude
        case .codex: codex
        case .antigravity: antigravity
        }
    }

    /// Whether at least one agent CLI exists (waits for the background searches).
    func anyFound() async -> Bool {
        for agent in AgentKind.allCases {
            if await self[agent].executable() != nil { return true }
        }
        return false
    }
}

/// The runner `RunCoordinator` gets: every run goes to the `ProcessClaudeRunner` of its spec's agent, once that
/// agent's locator has answered (one instance per agent, so a cancel finds the process its run started). Nothing
/// found → `ClaudeRunError.notFound`, which the coordinator turns into the spec §8 message for that agent.
nonisolated final class AgentRouterRunner: ClaudeRunner {
    private let runners: [AgentKind: Task<ProcessClaudeRunner?, Never>]

    init(locators: AgentLocators) {
        var runners: [AgentKind: Task<ProcessClaudeRunner?, Never>] = [:]
        for agent in AgentKind.allCases {
            let locator = locators[agent]
            runners[agent] = Task {
                await locator.executable().map { ProcessClaudeRunner(executableURL: $0, agent: agent) }
            }
        }
        self.runners = runners
    }

    private func runner(_ agent: AgentKind) async -> ProcessClaudeRunner? {
        await runners[agent]?.value
    }

    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        guard let runner = await runner(spec.agent) else { throw ClaudeRunError.notFound }
        return try await runner.run(spec, onEvent: onEvent)
    }

    /// The run id says nothing about the agent: every runner hears the cancel. Only the one that runs (or is about to
    /// run) it acts on it.
    func cancel(runID: UUID) async {
        for agent in AgentKind.allCases {
            await runner(agent)?.cancel(runID: runID)
        }
    }

    func version() async throws -> String {
        guard let runner = await runner(.claude) else { throw ClaudeRunError.notFound }
        return try await runner.version()
    }
}

/// The `HandoffService` AppServices gets, around `DesktopHandoffService`.
///
/// - Session ids: Claude Code runs start with `--session-id <uuid lowercased>` (`ClaudeArguments`), while callers
///   may form ids with `UUID.uuidString` (uppercase). Every resume path — the notification's and the
///   Inspector's "Terminalde devam et", the Inspector's "Desktop'ta aç" — goes through here and gets the
///   lowercase spelling (Codex and Antigravity ids are lowercase UUIDs already). The composer takes no session id
///   and is passed through untouched.
/// - The CLI paths: `DesktopHandoffService` bakes the agent's path into the `.command` file it writes, but it may only
///   be known after the locator's background search, so the service is built per call with whatever the
///   locators know by then (`AgentFallback` while searching or when missing: the file then fails loudly,
///   matching the red status in Settings).
nonisolated struct ClaudeHandoff: HandoffService {
    private let makeBase: @Sendable () -> any HandoffService

    init(makeBase: @escaping @Sendable () -> any HandoffService) {
        self.makeBase = makeBase
    }

    init(locators: AgentLocators, fileStore: FileStore, composerRoute: String) {
        self.init {
            DesktopHandoffService(
                claudeExecutable: locators.claude.currentExecutable ?? AgentFallback.executableURL(for: .claude),
                otherExecutables: [
                    .codex: locators.codex.currentExecutable ?? AgentFallback.executableURL(for: .codex),
                    .antigravity: locators.antigravity.currentExecutable
                        ?? AgentFallback.executableURL(for: .antigravity),
                ],
                fileStore: fileStore,
                composerRoute: composerRoute)
        }
    }

    func openInTerminal(agent: AgentKind, sessionID: String, projectPath: String) throws {
        try makeBase().openInTerminal(agent: agent, sessionID: sessionID.lowercased(), projectPath: projectPath)
    }

    func openInDesktop(sessionID: String) throws {
        try makeBase().openInDesktop(sessionID: sessionID.lowercased())
    }

    func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws {
        try makeBase().openDesktopComposer(prompt: prompt, projectPath: projectPath, files: files)
    }
}
