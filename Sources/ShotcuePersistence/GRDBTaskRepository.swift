import Foundation
import GRDB
import ShotcueCore

public final class GRDBTaskRepository: TaskRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Shared queries

    private static func fetchAll(_ db: Database) throws -> [ShotTask] {
        try TaskRecord.ordered().fetchAll(db).map(\.model)
    }

    /// `projectID == nil` is the inbox: GRDB turns `Column == nil` into `project_id IS NULL`.
    private static func fetch(_ db: Database, projectID: UUID?) throws -> [ShotTask] {
        let request: QueryInterfaceRequest<TaskRecord>
        if let projectID {
            request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == projectID.dbKey)
        } else {
            request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == nil)
        }
        return try request.fetchAll(db).map(\.model)
    }

    // MARK: - Tasks

    public func allTasks() async throws -> [ShotTask] {
        try await database.reader.read { db in try Self.fetchAll(db) }
    }

    public func task(id: UUID) async throws -> ShotTask? {
        try await database.reader.read { db in try TaskRecord.fetchOne(db, key: id.dbKey)?.model }
    }

    public func tasks(projectID: UUID?) async throws -> [ShotTask] {
        try await database.reader.read { db in try Self.fetch(db, projectID: projectID) }
    }

    public func tasks(status: TaskStatus) async throws -> [ShotTask] {
        try await database.reader.read { db in
            try TaskRecord.ordered()
                .filter(TaskRecord.Columns.status == status.rawValue)
                .fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ task: ShotTask) async throws {
        let record = TaskRecord(task)
        try await database.writer.write { db in try record.upsert(db) }
    }

    /// `capture`, `voice_note` and `run` rows go away through ON DELETE CASCADE.
    /// The files on disk are the caller's job (see `FileStore` in ShotcueCore).
    public func deleteTask(id: UUID) async throws {
        _ = try await database.writer.write { db in try TaskRecord.deleteOne(db, key: id.dbKey) }
    }

    // MARK: - Captures

    public func captures(taskID: UUID) async throws -> [Capture] {
        try await database.reader.read { db in
            try CaptureRecord
                .filter(CaptureRecord.Columns.taskId == taskID.dbKey)
                .order(CaptureRecord.Columns.createdAt)
                .fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ capture: Capture) async throws {
        let record = CaptureRecord(capture)
        try await database.writer.write { db in try record.upsert(db) }
    }

    /// One `UPDATE … WHERE id IN (…)` statement, so every capture moves atomically.
    public func moveCaptures(ids: [UUID], toTaskID: UUID) async throws {
        guard !ids.isEmpty else { return }
        let keys = ids.map(\.dbKey)
        let target = toTaskID.dbKey
        _ = try await database.writer.write { db in
            try CaptureRecord
                .filter(keys.contains(CaptureRecord.Columns.id))
                .updateAll(db, CaptureRecord.Columns.taskId.set(to: target))
        }
    }

    // MARK: - Voice notes

    public func voiceNotes(taskID: UUID) async throws -> [VoiceNote] {
        try await database.reader.read { db in
            try VoiceNoteRecord
                .filter(VoiceNoteRecord.Columns.taskId == taskID.dbKey)
                .order(VoiceNoteRecord.Columns.createdAt)
                .fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ voiceNote: VoiceNote) async throws {
        let record = VoiceNoteRecord(voiceNote)
        try await database.writer.write { db in try record.upsert(db) }
    }

    // MARK: - Search

    /// `nil` means "no filter" (empty or whitespace-only query). Both sides of every
    /// LIKE go through `shotcue_fold`, so Turkish case and diacritics match; `%`, `_`
    /// and `\` in the user's query are escaped so they are matched literally.
    static func searchRequest(_ query: String) -> SQLRequest<TaskRecord>? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = SearchText.normalized(trimmed)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let sql: SQL = """
            SELECT DISTINCT task.* FROM task
            LEFT JOIN voice_note ON voice_note.task_id = task.id
            WHERE shotcue_fold(task.title) LIKE \(pattern) ESCAPE '\\'
               OR shotcue_fold(task.note_text) LIKE \(pattern) ESCAPE '\\'
               OR shotcue_fold(COALESCE(voice_note.transcript, '')) LIKE \(pattern) ESCAPE '\\'
            ORDER BY task.sort_index, task.created_at
            """
        return SQLRequest<TaskRecord>(literal: sql)
    }

    public func search(_ query: String) async throws -> [ShotTask] {
        guard let request = Self.searchRequest(query) else { return try await allTasks() }
        return try await database.reader.read { db in
            try request.fetchAll(db).map(\.model)
        }
    }

    // MARK: - Observation

    public func observeAllTasks() -> AsyncStream<[ShotTask]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetchAll(db) },
            in: database.reader)
    }

    public func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetch(db, projectID: projectID) },
            in: database.reader)
    }
}
