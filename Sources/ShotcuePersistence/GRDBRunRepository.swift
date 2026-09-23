import Foundation
import GRDB
import ShotcueCore

public final class GRDBRunRepository: RunRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static func fetch(_ db: Database, taskID: UUID) throws -> [Run] {
        try RunRecord
            .filter(RunRecord.Columns.taskId == taskID.dbKey)
            .order(RunRecord.Columns.startedAt)
            .fetchAll(db)
            .map { try $0.model() }
    }

    private static func activeRequest() -> QueryInterfaceRequest<RunRecord> {
        RunRecord
            .filter(RunRecord.activeStates.contains(RunRecord.Columns.state))
            .order(RunRecord.Columns.startedAt)
    }

    public func runs(taskID: UUID) async throws -> [Run] {
        try await database.reader.read { db in try Self.fetch(db, taskID: taskID) }
    }

    public func run(id: UUID) async throws -> Run? {
        try await database.reader.read { db in try RunRecord.fetchOne(db, key: id.dbKey)?.model() }
    }

    public func save(_ run: Run) async throws {
        let record = RunRecord(run)
        try await database.writer.write { db in try record.upsert(db) }
    }

    public func activeRuns() async throws -> [Run] {
        try await database.reader.read { db in
            try Self.activeRequest().fetchAll(db).map { try $0.model() }
        }
    }

    /// Called at launch: any run still `starting`/`running` belongs to a process that
    /// died with the previous app session (spec §8, "Uygulama run ortasında kapandı").
    public func markInterruptedRuns(at now: Date) async throws -> Int {
        try await database.writer.write { db in
            try Self.activeRequest()
                .updateAll(
                    db,
                    RunRecord.Columns.state.set(to: RunState.failed.rawValue),
                    RunRecord.Columns.error.set(to: RunErrorCode.interrupted),
                    RunRecord.Columns.finishedAt.set(to: now.timeIntervalSinceReferenceDate))
        }
    }

    public func observeRuns(taskID: UUID) -> AsyncStream<[Run]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetch(db, taskID: taskID) },
            in: database.reader)
    }
}
