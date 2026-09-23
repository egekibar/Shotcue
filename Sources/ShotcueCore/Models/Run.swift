import Foundation

public enum RunState: String, Sendable, Codable, CaseIterable {
    case starting, running, succeeded, failed, cancelled
}

/// One headless agent execution of a task. For Claude Code `id` doubles as the session id (`--session-id`); Codex and
/// Antigravity pick their own, recorded in `sessionID`.
public struct Run: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID
    /// The CLI that ran it; rows written before other agents existed are Claude Code runs.
    public var agent: AgentKind
    /// The agent's own session id (Codex `thread_id`, Antigravity `conversation_id`); nil for Claude Code, whose
    /// session id is `id`, and for runs that never got one.
    public var sessionID: String?
    public var state: RunState
    public var startedAt: Date
    public var finishedAt: Date?
    public var numTurns: Int?
    public var costUSD: Double?
    public var resultText: String?
    public var subtype: String?
    public var exitCode: Int32?
    public var error: String?
    public var logRelPath: String
    public var gitHeadBefore: String?
    public var gitDirtyBefore: Bool?
    public var gitHeadAfter: String?
    public var gitBranch: String?

    public init(
        id: UUID = UUID(), taskID: UUID, agent: AgentKind = .claude, sessionID: String? = nil,
        state: RunState = .starting, startedAt: Date = Date(),
        finishedAt: Date? = nil, numTurns: Int? = nil, costUSD: Double? = nil, resultText: String? = nil,
        subtype: String? = nil, exitCode: Int32? = nil, error: String? = nil, logRelPath: String,
        gitHeadBefore: String? = nil, gitDirtyBefore: Bool? = nil, gitHeadAfter: String? = nil,
        gitBranch: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.agent = agent
        self.sessionID = sessionID
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.numTurns = numTurns
        self.costUSD = costUSD
        self.resultText = resultText
        self.subtype = subtype
        self.exitCode = exitCode
        self.error = error
        self.logRelPath = logRelPath
        self.gitHeadBefore = gitHeadBefore
        self.gitDirtyBefore = gitDirtyBefore
        self.gitHeadAfter = gitHeadAfter
        self.gitBranch = gitBranch
    }

    public var isFinished: Bool { state == .succeeded || state == .failed || state == .cancelled }

    /// The id the agent's resume command takes: Claude Code's is the run id itself (the handoff applies the lowercase
    /// `--session-id` spelling), the others' is the one they reported; nil when there is none yet.
    public var resumeSessionID: String? {
        switch agent {
        case .claude: id.uuidString
        case .codex, .antigravity: sessionID
        }
    }
}
