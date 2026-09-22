import Foundation
import GRDB

/// Owns the SQLite connection for the whole app. `open(at:)` is used by the app
/// (WAL `DatabasePool`, concurrent reads); `inMemory()` is used by tests.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Foreign keys on (GRDB's default) plus the `shotcue_fold` SQL function on
    /// every connection, including the ones a `DatabasePool` opens lazily for reads.
    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: SQLFunctions.fold)
        }
        return config
    }

    /// Opens (creating if needed) the database at `url`, creating its parent directory,
    /// switching the journal to WAL and running every pending migration.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var config = configuration
        config.journalMode = .wal
        let pool = try DatabasePool(path: url.path, configuration: config)
        try migrator.migrate(pool)
        return AppDatabase(writer: pool)
    }

    /// A private in-memory database with the same schema. Every call returns a fresh one.
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue)
        return AppDatabase(writer: queue)
    }
}
