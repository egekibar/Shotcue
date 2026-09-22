import Foundation

public enum RunState: String, Sendable, Codable, CaseIterable {
    case starting, running, succeeded, failed, cancelled
}

/// One headless Claude Code execution of a task. `id` doubles as the Claude session id (`--session-id`).
public struct Run: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID
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
        id: UUID = UUID(), taskID: UUID, state: RunState = .starting, startedAt: Date = Date(),
        finishedAt: Date? = nil, numTurns: Int? = nil, costUSD: Double? = nil, resultText: String? = nil,
        subtype: String? = nil, exitCode: Int32? = nil, error: String? = nil, logRelPath: String,
        gitHeadBefore: String? = nil, gitDirtyBefore: Bool? = nil, gitHeadAfter: String? = nil,
        gitBranch: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
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
}
