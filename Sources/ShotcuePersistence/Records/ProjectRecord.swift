import Foundation
import GRDB
import ShotcueCore

struct ProjectRecord: ShotcueRecord {
    static let databaseTableName = "project"

    var id: String
    var name: String
    var path: String
    var agent: String?
    var defaultMode: String
    var defaultModel: String?
    var defaultEffort: String?
    var dailyTime: String?
    var dailyEnabled: Bool
    var dailyLastFiredAt: Date?
    var runInBranch: Bool
    var stashBeforeRun: Bool
    var sortIndex: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case agent
        case defaultMode = "default_mode"
        case defaultModel = "default_model"
        case defaultEffort = "default_effort"
        case dailyTime = "daily_time"
        case dailyEnabled = "daily_enabled"
        case dailyLastFiredAt = "daily_last_fired_at"
        case runInBranch = "run_in_branch"
        case stashBeforeRun = "stash_before_run"
        case sortIndex = "sort_index"
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let sortIndex = Column(CodingKeys.sortIndex)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ project: Project) {
        id = project.id.dbKey
        name = project.name
        path = project.path
        agent = project.agent?.rawValue
        defaultMode = project.defaultMode.rawValue
        defaultModel = project.defaultModel
        defaultEffort = project.defaultEffort
        dailyTime = project.dailyTime?.formatted
        dailyEnabled = project.dailyEnabled
        dailyLastFiredAt = project.dailyLastFiredAt
        runInBranch = project.runInBranch
        stashBeforeRun = project.stashBeforeRun
        sortIndex = project.sortIndex
        createdAt = project.createdAt
    }

    func model() throws -> Project {
        try Project(
            id: Self.parsed(CodingKeys.id, id, using: UUID.init(uuidString:)),
            name: name,
            path: path,
            agent: AgentKind(stored: agent),
            defaultMode: Self.parsed(CodingKeys.defaultMode, defaultMode, using: TaskMode.init(rawValue:)),
            defaultModel: defaultModel,
            defaultEffort: defaultEffort,
            dailyTime: dailyTime.flatMap(DailyTime.init(parsing:)),
            dailyEnabled: dailyEnabled,
            dailyLastFiredAt: dailyLastFiredAt,
            runInBranch: runInBranch,
            stashBeforeRun: stashBeforeRun,
            sortIndex: sortIndex,
            createdAt: createdAt)
    }

    /// Projects are shown in manual order; `created_at` breaks ties deterministically.
    static func ordered() -> QueryInterfaceRequest<ProjectRecord> {
        ProjectRecord.order(Columns.sortIndex, Columns.createdAt)
    }
}
