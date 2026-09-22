import Foundation
import GRDB

/// Shared conformance for every row type in this module. Records are plain `Sendable`
/// structs whose `CodingKeys` carry the snake_case column names, so the column mapping
/// lives in exactly one place per table.
protocol ShotcueRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

/// Thrown when a stored row cannot be turned back into its Core model, instead of
/// inventing a replacement value (a fresh UUID, a default enum case).
enum PersistenceError: Error, Equatable, Sendable {
    case corruptRow(table: String, column: String, value: String)
}

extension ShotcueRecord {
    /// Dates are stored as Double seconds since 2001-01-01 (`Date`'s own reference date)
    /// in every table. GRDB's default ("YYYY-MM-DD HH:MM:SS.SSS") truncates to
    /// milliseconds, and the 1970 offset moves current timestamps into the next binade,
    /// dropping the last mantissa bit; the reference-date Double is the exact value
    /// `Date` holds, so it round trips exactly and still sorts with ORDER BY.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    /// Turns a stored column value (UUID text, enum raw value) back into its model type,
    /// throwing `PersistenceError.corruptRow` instead of inventing a replacement.
    static func parsed<Value>(
        _ column: some CodingKey, _ stored: String, using transform: (String) -> Value?
    ) throws -> Value {
        guard let value = transform(stored) else {
            throw PersistenceError.corruptRow(table: databaseTableName, column: column.stringValue, value: stored)
        }
        return value
    }
}

extension UUID {
    /// Primary and foreign keys are stored as lowercase UUID strings.
    var dbKey: String { uuidString.lowercased() }
}
