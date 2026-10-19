import Foundation
import Testing

@testable import ShotcueCore

@Suite("ScheduleSuggestions")
struct ScheduleSuggestionsTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func at(_ hour: Int, _ minute: Int, day: Int = 22) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func morningOffersAnHourLaterThisEveningAndTomorrow() {
        let suggestions = ScheduleSuggestions.suggestions(now: at(10, 2), calendar: cal)
        #expect(suggestions.map(\.label) == ["1 saat sonra", "Bu akşam 18:00", "Yarın 09:00"])
        // "1 saat sonra" lands on a round five minutes, never earlier than an hour.
        #expect(suggestions[0].date == at(11, 5))
        #expect(suggestions[1].date == at(18, 0))
        #expect(suggestions[2].date == at(9, 0, day: 23))
    }

    @Test func anHourLaterOnTheDotStaysPut() {
        #expect(ScheduleSuggestions.suggestions(now: at(10, 0), calendar: cal)[0].date == at(11, 0))
    }

    /// Less than half an hour before 18:00, "this evening" is no longer worth offering.
    @Test func thisEveningDisappearsCloseTo18() {
        let late = ScheduleSuggestions.suggestions(now: at(17, 40), calendar: cal)
        #expect(late.map(\.label) == ["1 saat sonra", "Yarın 09:00"])
        #expect(ScheduleSuggestions.suggestions(now: at(17, 30), calendar: cal).map(\.label).contains("Bu akşam 18:00"))
        #expect(!ScheduleSuggestions.suggestions(now: at(21, 0), calendar: cal).map(\.label).contains("Bu akşam 18:00"))
    }

    @Test func pastAndPresentCannotBeScheduled() {
        let now = at(10, 0)
        #expect(ScheduleSuggestions.isInPast(at(9, 59), now: now))
        #expect(ScheduleSuggestions.isInPast(now, now: now))
        #expect(!ScheduleSuggestions.isInPast(at(10, 1), now: now))
    }

    /// The calendar picks the day and the time field the hour: each keeps the other's part.
    @Test func combiningKeepsTheDayOfOneAndTheTimeOfTheOther() {
        let day = at(23, 59, day: 30)
        let time = at(14, 30, day: 1)
        #expect(ScheduleSuggestions.combine(day: day, time: time, calendar: cal) == at(14, 30, day: 30))
    }
}
