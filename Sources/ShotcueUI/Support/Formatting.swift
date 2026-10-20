import Foundation
import ShotcueCore

/// Pure display formatting in the app's language (words from `L10n`) and its locale's date and time conventions
/// (patterns from templates, so "17.09" in Turkish is "9/17" in US English and the clock follows the 12/24-hour setting).
/// Every member is `nonisolated` so it can be called from any isolation domain, including
/// `nonisolated` view helpers; a `nonisolated` member may only call other `nonisolated` members.
public enum Formatting {
    nonisolated public static let placeholder = "—"

    /// "1 min 24 s" / "59 s" ("1 dk 24 sn"); `nil` and non-positive values become "—".
    nonisolated public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return placeholder }
        let total = Int(seconds.rounded())
        if total < 60 { return L10n.t("\(total) s") }
        return L10n.t("\(total / 60) min \(total % 60) s")
    }

    /// "just now" · "5 min ago" · "2 h ago" · "yesterday" · "17.09" (the date in the locale's day-month order).
    /// Future dates collapse to "just now" so a freshly written `updatedAt` never reads as negative.
    nonisolated public static func relativeDate(
        _ date: Date, now: Date,
        calendar: Calendar = .current, locale: Locale = LocalizationOverride.locale
    ) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return L10n.t("just now") }
        if delta < 3600 { return L10n.t("\(Int(delta / 60)) min ago") }
        if calendar.isDate(date, inSameDayAs: now) { return L10n.t("\(Int(delta / 3600)) h ago") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return L10n.t("yesterday")
        }
        return formatted(date, template: "dMM", calendar: calendar, locale: locale)
    }

    /// "12:00" or "12:00 PM" — used by the scheduled-at row and the daily queue time.
    nonisolated public static func clockTime(
        _ date: Date, calendar: Calendar = .current, locale: Locale = LocalizationOverride.locale
    ) -> String {
        formatted(date, template: "jmm", calendar: calendar, locale: locale)
    }

    /// "22.09 12:00" — used by the inspector's "Zamanlandı" line.
    nonisolated public static func dateAndTime(
        _ date: Date, calendar: Calendar = .current, locale: Locale = LocalizationOverride.locale
    ) -> String {
        formatted(date, template: "dMMjmm", calendar: calendar, locale: locale)
    }

    /// "22 Eylül Salı 12:00" / "Tuesday, September 22 at 12:00 PM" — the schedule form's summary line.
    nonisolated public static func scheduleSummary(
        _ date: Date, calendar: Calendar = .current, locale: Locale = LocalizationOverride.locale
    ) -> String {
        formatted(date, template: "EEEEdMMMMjmm", calendar: calendar, locale: locale)
    }

    /// "11 turns" ("11 tur"), "1 turn", "—".
    nonisolated public static func turns(_ count: Int?) -> String {
        guard let count else { return placeholder }
        return count == 1 ? L10n.t("1 turn") : L10n.t("\(count) turns")
    }

    /// "0:04" for the recording timer and voice-note rows.
    nonisolated public static func stopwatch(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated private static func formatted(
        _ date: Date, template: String, calendar: Calendar, locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
