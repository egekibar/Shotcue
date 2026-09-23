import Foundation

/// Pure display formatting. Turkish output, no localization files (spec §4.1).
/// Every member is `nonisolated` so it can be called from any isolation domain, including
/// `nonisolated` view helpers; a `nonisolated` member may only call other `nonisolated` members.
public enum Formatting {
    nonisolated public static let placeholder = "—"

    /// "1 dk 24 sn" / "59 sn"; `nil` and non-positive values become "—".
    nonisolated public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return placeholder }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) sn" }
        return "\(total / 60) dk \(total % 60) sn"
    }

    /// "az önce" · "5 dk önce" · "2 sa önce" · "dün" · "17.09".
    /// Future dates collapse to "az önce" so a freshly written `updatedAt` never reads as negative.
    nonisolated public static func relativeDate(
        _ date: Date, now: Date,
        calendar: Calendar = .current
    ) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "az önce" }
        if delta < 3600 { return "\(Int(delta / 60)) dk önce" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(delta / 3600)) sa önce" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "dün"
        }
        return formatted(date, pattern: "dd.MM", calendar: calendar)
    }

    /// "12:00" — used by the scheduled-at row and the daily queue time.
    nonisolated public static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        formatted(date, pattern: "HH:mm", calendar: calendar)
    }

    /// "22.09 12:00" — used by the inspector's "Zamanlandı" line.
    nonisolated public static func dateAndTime(_ date: Date, calendar: Calendar = .current) -> String {
        formatted(date, pattern: "dd.MM HH:mm", calendar: calendar)
    }

    /// "11 tur" / "—".
    nonisolated public static func turns(_ count: Int?) -> String {
        guard let count else { return placeholder }
        return "\(count) tur"
    }

    /// "0:04" for the recording timer and voice-note rows.
    nonisolated public static func stopwatch(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated private static func formatted(_ date: Date, pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
