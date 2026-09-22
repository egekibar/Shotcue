import Foundation
import GRDB
import ShotcueCore

public final class GRDBProjectRepository: ProjectRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Single source of truth for the ordering, shared by the fetch and the observation.
    private static func fetchAll(_ db: Database) throws -> [Project] {
        try ProjectRecord.ordered().fetchAll(db).map { try $0.model() }
    }

    public func allProjects() async throws -> [Project] {
        try await database.reader.read { db in try Self.fetchAll(db) }
    }

    public func project(id: UUID) async throws -> Project? {
        try await database.reader.read { db in
            try ProjectRecord.fetchOne(db, key: id.dbKey)?.model()
        }
    }

    public func save(_ project: Project) async throws {
        let record = ProjectRecord(project)
        try await database.writer.write { db in try record.upsert(db) }
    }

    /// The `task.project_id` foreign key is ON DELETE SET NULL, so the project's tasks
    /// fall back to the inbox instead of disappearing.
    public func deleteProject(id: UUID) async throws {
        _ = try await database.writer.write { db in
            try ProjectRecord.deleteOne(db, key: id.dbKey)
        }
    }

    public func observeProjects() -> AsyncStream<[Project]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetchAll(db) },
            in: database.reader)
    }
}
