import Foundation
import GRDB
import ShotcueCore

struct CaptureRecord: ShotcueRecord {
    static let databaseTableName = "capture"

    var id: String
    var taskId: String
    var relPath: String
    var thumbRelPath: String?
    var width: Int
    var height: Int
    var scale: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case relPath = "rel_path"
        case thumbRelPath = "thumb_rel_path"
        case width
        case height
        case scale
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskId = Column(CodingKeys.taskId)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ capture: Capture) {
        id = capture.id.dbKey
        taskId = capture.taskID.dbKey
        relPath = capture.relPath
        thumbRelPath = capture.thumbRelPath
        width = capture.width
        height = capture.height
        scale = capture.scale
        createdAt = capture.createdAt
    }

    var model: Capture {
        Capture(
            id: UUID(uuidString: id) ?? UUID(),
            taskID: UUID(uuidString: taskId) ?? UUID(),
            relPath: relPath,
            thumbRelPath: thumbRelPath,
            width: width,
            height: height,
            scale: scale,
            createdAt: createdAt)
    }
}
