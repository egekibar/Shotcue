import Foundation
import GRDB

/// Normalisation used by `GRDBTaskRepository.search(_:)` on both sides of the LIKE
/// comparison. SQLite's built-in `lower()` and `LIKE` fold ASCII only, so Turkish
/// letters would never match case-insensitively.
enum SearchText {
    /// Case- and diacritic-insensitive form. The two `replacingOccurrences` calls map
    /// the Turkish dotless "ı" and the ASCII "I" onto "i" before folding, because
    /// `.diacriticInsensitive` leaves U+0131 (ı) alone while turning "İ" into "I".
    /// Examples: "ÖNBELLEĞİ" -> "onbellegi", "IŞIK" -> "isik", "LOGIN" -> "login".
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "I", with: "i")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: nil)
    }
}

/// Custom SQL functions registered on every connection by `AppDatabase.configuration`.
enum SQLFunctions {
    /// `shotcue_fold(text)` — the SQL-side counterpart of `SearchText.normalized(_:)`.
    static let fold = DatabaseFunction("shotcue_fold", argumentCount: 1, pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]) else { return nil }
        return SearchText.normalized(text)
    }
}
