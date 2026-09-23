import Foundation

public enum ClaudePermissionMode: String, Sendable, Codable, CaseIterable {
    case bypassPermissions, acceptEdits, dontAsk
}

/// Everything the runner needs to build the `claude -p` command line (spec §6.4).
public struct RunSpec: Hashable, Sendable {
    public var runID: UUID
    public var prompt: String
    public var projectPath: String
    public var mode: TaskMode
    public var model: String?
    public var effort: String?
    public var maxTurns: Int
    public var maxBudgetUSD: Double
    public var timeout: TimeInterval
    public var permissionMode: ClaudePermissionMode
    public var addDirs: [String]
    public var systemPromptAppend: String

    public init(
        runID: UUID, prompt: String, projectPath: String, mode: TaskMode, model: String? = nil,
        effort: String? = nil, maxTurns: Int = 50, maxBudgetUSD: Double = 5, timeout: TimeInterval = 1800,
        permissionMode: ClaudePermissionMode = .bypassPermissions, addDirs: [String] = [],
        systemPromptAppend: String = PromptBuilder.systemPromptAppend
    ) {
        self.runID = runID
        self.prompt = prompt
        self.projectPath = projectPath
        self.mode = mode
        self.model = model
        self.effort = effort
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.timeout = timeout
        self.permissionMode = permissionMode
        self.addDirs = addDirs
        self.systemPromptAppend = systemPromptAppend
    }
}

public protocol ClaudeRunner: Sendable {
    /// Streams events while running; resolves with the final result. Throws when the process cannot start,
    /// exits non-zero without a result line, times out, or is cancelled.
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult
    func cancel(runID: UUID) async
    /// Output of `claude --version`, e.g. "2.1.278 (Claude Code)".
    func version() async throws -> String
}

public protocol GitInspector: Sendable {
    func snapshot(at path: String) async -> GitSnapshot?
    func createBranch(_ name: String, at path: String) async throws
    func stashAll(at path: String) async throws
}

/// Hands a finished (or pending) task to the terminal / Claude Desktop (spec §6.4).
public protocol HandoffService: Sendable {
    /// Resumes the session in Terminal from `projectPath`, the run's working directory: claude keeps sessions per
    /// folder and the resumed session's tools must run in the project (final review M6).
    func openInTerminal(sessionID: String, projectPath: String) throws
    func openInDesktop(sessionID: String) throws
    func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws
}

/// UI-facing façade over the run coordinator (implemented by `RunCoordinator` in ShotcueClaudeBridge).
/// UI never imports ShotcueClaudeBridge; it talks to this protocol.
public protocol TaskDispatcher: Sendable {
    /// Moves the task to `queued` (via `transition`) and pumps the queue.
    func enqueue(taskID: UUID) async throws
    /// Cancels the running run of the task (SIGINT) or removes it from the queue (→ `ready`).
    func cancel(taskID: UUID) async
    /// Enqueues every `ready` task of every project in manual order, then pumps.
    func runQueueNow() async
    func setPaused(_ paused: Bool) async
    func isPaused() async -> Bool
    /// Live events of a run in progress; finishes when the run ends. Empty stream for unknown ids.
    func liveEvents(runID: UUID) -> AsyncStream<RunEvent>
}
