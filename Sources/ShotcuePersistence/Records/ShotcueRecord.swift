import Foundation
import GRDB

/// Shared conformance for every row type in this module. Records are plain `Sendable`
/// structs whose `CodingKeys` carry the snake_case column names, so the column mapping
/// lives in exactly one place per table.
protocol ShotcueRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

extension ShotcueRecord {
    /// Dates are stored as Double seconds since 1970 in every table. GRDB's default
    /// ("YYYY-MM-DD HH:MM:SS.SSS") truncates to milliseconds, which breaks exact
    /// round trips; Double round trips exactly and still sorts with ORDER BY.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension UUID {
    /// Primary and foreign keys are stored as lowercase UUID strings.
    var dbKey: String { uuidString.lowercased() }
}
