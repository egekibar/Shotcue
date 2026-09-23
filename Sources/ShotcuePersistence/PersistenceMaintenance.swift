import Foundation
import GRDB
import ShotcueCore

/// One-off repairs the UI triggers, kept out of the repositories because they are not
/// part of the Core protocols.
public enum PersistenceMaintenance {
    /// Rewrites `sort_index` of one list (a project, or the inbox when `projectID` is nil)
    /// to the even steps `SortIndex.renumbered(count:)` produces, keeping the current
    /// order. Call this when `SortIndex.needsRenumber(before, after)` is true after a
    /// drag and drop. Runs in a single transaction and touches no other column.
    public static func renumberSortIndexes(in database: AppDatabase, projectID: UUID?) async throws {
        try await database.writer.write { db in
            let request: QueryInterfaceRequest<TaskRecord>
            if let projectID {
                request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == projectID.dbKey)
            } else {
                request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == nil)
            }
            let records = try request.fetchAll(db)
            let indexes = SortIndex.renumbered(count: records.count)
            for (record, index) in zip(records, indexes) {
                try TaskRecord
                    .filter(TaskRecord.Columns.id == record.id)
                    .updateAll(db, TaskRecord.Columns.sortIndex.set(to: index))
            }
        }
    }
}
