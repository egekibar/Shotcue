import Foundation

/// The schedule form's rules: one-click suggestions, the past-time check, and joining the calendar's day with the
/// time field's hour (pure, tested with a fixed calendar).
public enum ScheduleSuggestions {
    public struct Suggestion: Hashable, Sendable {
        public let label: String
        public let date: Date

        public init(label: String, date: Date) {
            self.label = label
            self.date = date
        }
    }

    /// "This evening at 18:00" is offered only while 18:00 is at least this far away.
    static let eveningLeadTime: TimeInterval = 30 * 60

    /// "In 1 hour" (rounded up to five minutes), "This evening at 18:00" while there is time, "Tomorrow at 09:00", the
    /// times in the locale's clock ("6:00 PM" in US English).
    public static func suggestions(
        now: Date, calendar: Calendar, locale: Locale = LocalizationOverride.locale
    ) -> [Suggestion] {
        func clock(_ date: Date) -> String {
            date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                    timeZone: calendar.timeZone))
        }
        let inAnHour = roundedUpToFiveMinutes(now.addingTimeInterval(3600), calendar: calendar)
        var result = [Suggestion(label: L10n.t("In 1 hour"), date: inAnHour)]
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now),
            evening.timeIntervalSince(now) >= eveningLeadTime
        {
            result.append(Suggestion(label: L10n.t("This evening at \(clock(evening))"), date: evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
            let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        {
            result.append(Suggestion(label: L10n.t("Tomorrow at \(clock(morning))"), date: morning))
        }
        return result
    }

    /// A task cannot be scheduled for now or earlier: it would run at once, which is "Send Now".
    public static func isInPast(_ date: Date, now: Date) -> Bool {
        date <= now
    }

    /// The day of `day` at the hour and minute of `time`.
    public static func combine(day: Date, time: Date, calendar: Calendar) -> Date {
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day) ?? day
    }

    /// The next five-minute mark at or after `date` (seconds dropped): 11:02 → 11:05, 11:00:00 stays.
    static func roundedUpToFiveMinutes(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let wholeMinute = calendar.date(from: parts) else { return date }
        let minute = parts.minute ?? 0
        if minute % 5 == 0 && wholeMinute == date { return date }
        let step = minute % 5 == 0 ? 5 : 5 - minute % 5
        return calendar.date(byAdding: .minute, value: step, to: wholeMinute) ?? date
    }
}
