import Foundation
import GRDB
import ShotcueCore

struct TaskRecord: ShotcueRecord {
    static let databaseTableName = "task"

    var id: String
    var projectId: String?
    var title: String
    var titleEditedByUser: Bool
    var noteText: String
    var status: String
    var mode: String
    var modelOverride: String?
    var sortIndex: Double
    var scheduledAt: Date?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case title
        case titleEditedByUser = "title_edited_by_user"
        case noteText = "note_text"
        case status
        case mode
        case modelOverride = "model_override"
        case sortIndex = "sort_index"
        case scheduledAt = "scheduled_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let projectId = Column(CodingKeys.projectId)
        static let title = Column(CodingKeys.title)
        static let noteText = Column(CodingKeys.noteText)
        static let status = Column(CodingKeys.status)
        static let sortIndex = Column(CodingKeys.sortIndex)
        static let scheduledAt = Column(CodingKeys.scheduledAt)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ task: ShotTask) {
        id = task.id.dbKey
        projectId = task.projectID?.dbKey
        title = task.title
        titleEditedByUser = task.titleEditedByUser
        noteText = task.noteText
        status = task.status.rawValue
        mode = task.mode.rawValue
        modelOverride = task.modelOverride
        sortIndex = task.sortIndex
        scheduledAt = task.scheduledAt
        createdAt = task.createdAt
        updatedAt = task.updatedAt
    }

    var model: ShotTask {
        ShotTask(
            id: UUID(uuidString: id) ?? UUID(),
            projectID: projectId.flatMap(UUID.init(uuidString:)),
            title: title,
            noteText: noteText,
            status: TaskStatus(rawValue: status) ?? .inbox,
            mode: TaskMode(rawValue: mode) ?? .implement,
            modelOverride: modelOverride,
            sortIndex: sortIndex,
            scheduledAt: scheduledAt,
            titleEditedByUser: titleEditedByUser,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    /// Manual order (`QueuePolicy.ordered` in Core uses the same rule: sortIndex, then createdAt).
    static func ordered() -> QueryInterfaceRequest<TaskRecord> {
        TaskRecord.order(Columns.sortIndex, Columns.createdAt)
    }
}
