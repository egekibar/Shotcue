import Foundation
import GRDB
import ShotcueCore

struct VoiceNoteRecord: ShotcueRecord {
    static let databaseTableName = "voice_note"

    var id: String
    var taskId: String
    var relPath: String
    var durationSec: Double
    var transcript: String?
    var transcriptJson: String?
    var transcriptState: String
    var engine: String?
    var editedByUser: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case relPath = "rel_path"
        case durationSec = "duration_sec"
        case transcript
        case transcriptJson = "transcript_json"
        case transcriptState = "transcript_state"
        case engine
        case editedByUser = "edited_by_user"
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskId = Column(CodingKeys.taskId)
        static let transcript = Column(CodingKeys.transcript)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ note: VoiceNote) {
        id = note.id.dbKey
        taskId = note.taskID.dbKey
        relPath = note.relPath
        durationSec = note.durationSec
        transcript = note.transcript
        transcriptJson = note.transcriptJSON
        transcriptState = note.transcriptState.rawValue
        engine = note.engine
        editedByUser = note.editedByUser
        createdAt = note.createdAt
    }

    var model: VoiceNote {
        VoiceNote(
            id: UUID(uuidString: id) ?? UUID(),
            taskID: UUID(uuidString: taskId) ?? UUID(),
            relPath: relPath,
            durationSec: durationSec,
            transcript: transcript,
            transcriptJSON: transcriptJson,
            transcriptState: TranscriptState(rawValue: transcriptState) ?? .pending,
            engine: engine,
            editedByUser: editedByUser,
            createdAt: createdAt)
    }
}
