import Foundation
import GRDB
import ShotcueCore

struct RunRecord: ShotcueRecord {
    static let databaseTableName = "run"

    var id: String
    var taskId: String
    var state: String
    var startedAt: Date
    var finishedAt: Date?
    var numTurns: Int?
    var costUsd: Double?
    var resultText: String?
    var subtype: String?
    var exitCode: Int32?
    var error: String?
    var logRelPath: String
    var gitHeadBefore: String?
    var gitDirtyBefore: Bool?
    var gitHeadAfter: String?
    var gitBranch: String?

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case state
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case numTurns = "num_turns"
        case costUsd = "cost_usd"
        case resultText = "result_text"
        case subtype
        case exitCode = "exit_code"
        case error
        case logRelPath = "log_rel_path"
        case gitHeadBefore = "git_head_before"
        case gitDirtyBefore = "git_dirty_before"
        case gitHeadAfter = "git_head_after"
        case gitBranch = "git_branch"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskId = Column(CodingKeys.taskId)
        static let state = Column(CodingKeys.state)
        static let startedAt = Column(CodingKeys.startedAt)
        static let finishedAt = Column(CodingKeys.finishedAt)
        static let error = Column(CodingKeys.error)
    }

    /// The two states a run can be in while its process is alive.
    static let activeStates = [RunState.starting.rawValue, RunState.running.rawValue]

    init(_ run: Run) {
        id = run.id.dbKey
        taskId = run.taskID.dbKey
        state = run.state.rawValue
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        numTurns = run.numTurns
        costUsd = run.costUSD
        resultText = run.resultText
        subtype = run.subtype
        exitCode = run.exitCode
        error = run.error
        logRelPath = run.logRelPath
        gitHeadBefore = run.gitHeadBefore
        gitDirtyBefore = run.gitDirtyBefore
        gitHeadAfter = run.gitHeadAfter
        gitBranch = run.gitBranch
    }

    func model() throws -> Run {
        try Run(
            id: Self.parsed(CodingKeys.id, id, using: UUID.init(uuidString:)),
            taskID: Self.parsed(CodingKeys.taskId, taskId, using: UUID.init(uuidString:)),
            state: Self.parsed(CodingKeys.state, state, using: RunState.init(rawValue:)),
            startedAt: startedAt,
            finishedAt: finishedAt,
            numTurns: numTurns,
            costUSD: costUsd,
            resultText: resultText,
            subtype: subtype,
            exitCode: exitCode,
            error: error,
            logRelPath: logRelPath,
            gitHeadBefore: gitHeadBefore,
            gitDirtyBefore: gitDirtyBefore,
            gitHeadAfter: gitHeadAfter,
            gitBranch: gitBranch)
    }
}
