import Foundation
import ShotcueCore
import ShotcueTestSupport
import SwiftUI
import Testing

@testable import ShotcueUI

@Suite("Formatting")
struct FormattingTests {
    /// 2026-09-22 12:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_790_078_400)
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The schedule form's summary line names the day in the locale's language and order.
    @Test func scheduleSummaryNamesTheDay() {
        // 2026-09-22 is a Tuesday.
        #expect(Formatting.scheduleSummary(now, calendar: utc, locale: turkish) == "22 Eylül Salı 12:00")
        #expect(
            Formatting.scheduleSummary(now, calendar: utc, locale: american)
                == "Tuesday, September 22 at 12:00\u{202F}PM")
    }

    let turkish = Locale(identifier: "tr_TR")
    let american = Locale(identifier: "en_US")

    @Test func durationSplitsMinutesAndSeconds() {
        #expect(Formatting.duration(84.213) == "1 min 24 s")
        #expect(Formatting.duration(59.4) == "59 s")
        #expect(Formatting.duration(3600) == "60 min 0 s")
        #expect(Formatting.duration(0) == "—")
        #expect(Formatting.duration(nil) == "—")
    }

    @Test func relativeDateIsCoarse() {
        func relative(_ offset: TimeInterval, _ locale: Locale = Locale(identifier: "tr_TR")) -> String {
            Formatting.relativeDate(now.addingTimeInterval(offset), now: now, calendar: utc, locale: locale)
        }
        #expect(relative(-30) == "just now")
        #expect(relative(30) == "just now")
        #expect(relative(-300) == "5 min ago")
        #expect(relative(-7200) == "2 h ago")
        #expect(relative(-90_000) == "yesterday")
        // Older dates follow the locale's day-month order.
        #expect(relative(-5 * 86_400) == "17.09")
        #expect(relative(-5 * 86_400, american) == "09/17")
    }

    /// The clock follows the locale's 12/24-hour convention.
    @Test func clockTimeFollowsTheLocale() {
        #expect(Formatting.clockTime(now, calendar: utc, locale: turkish) == "12:00")
        // macOS puts a narrow no-break space (U+202F) before AM/PM.
        #expect(Formatting.clockTime(now, calendar: utc, locale: american) == "12:00\u{202F}PM")
    }

    @Test func turnsAgreeWithTheCount() {
        #expect(Formatting.turns(11) == "11 turns")
        #expect(Formatting.turns(1) == "1 turn")
        #expect(Formatting.turns(nil) == "—")
    }

    @Test func statusLabelsAndRanksCoverEveryCase() {
        #expect(
            TaskStatus.allCases.map(StatusPresentation.label(for:)) == [
                "Inbox", "Ready", "Queued", "Scheduled", "Running", "Done", "Failed", "Cancelled",
            ])
        #expect(TaskStatus.allCases.allSatisfy { !StatusPresentation.symbol(for: $0).isEmpty })
        #expect(Set(TaskStatus.allCases.map(StatusPresentation.rank(for:))).count == TaskStatus.allCases.count)
        #expect(StatusPresentation.rank(for: .running) < StatusPresentation.rank(for: .queued))
        #expect(StatusPresentation.rank(for: .queued) < StatusPresentation.rank(for: .done))
        #expect(StatusPresentation.tint(for: TaskStatus.failed) == Color.red)
    }

    @Test func runStateLabelsCoverEveryCase() {
        #expect(
            RunState.allCases.map(StatusPresentation.label(for:)) == [
                "Starting", "Running", "Succeeded", "Failed", "Cancelled",
            ])
        #expect(StatusPresentation.symbol(for: RunState.succeeded) == "checkmark.seal.fill")
    }

    @Test func sortOrderAndViewModeHaveLabels() {
        #expect(SortOrder.allCases.map(\.label) == ["Newest", "Oldest", "Manual", "By Status"])
        #expect(ViewMode.allCases.map(\.label) == ["Grid", "List"])
        #expect(ViewMode.grid.symbol == "square.grid.2x2")
        #expect(ViewMode.list.symbol == "list.bullet")
    }

    @Test func sidebarSelectionIsHashableAcrossCases() {
        let id = UUID()
        var counts: [SidebarSelection: Int] = [:]
        counts[.inbox] = 5
        counts[.project(id)] = 12
        counts[.status(.running)] = 1
        #expect(counts[.inbox] == 5)
        #expect(counts[.project(id)] == 12)
        #expect(counts[.project(UUID())] == nil)
        #expect(counts[.status(.running)] == 1)
        #expect(counts[.status(.done)] == nil)
        #expect(SidebarSelection.inbox != SidebarSelection.status(.inbox))
    }

    @MainActor
    @Test func fakeServicesBundleWiresEveryProtocol() async throws {
        let bundle = makeFakeServices()
        #expect(try await bundle.services.projects.allProjects().isEmpty)
        #expect(try await bundle.services.tasks.allTasks().isEmpty)
        #expect(bundle.services.clock.now == MutableClock().now)
        #expect(bundle.services.fileStore.rootURL.lastPathComponent.hasPrefix("shotcue-ui-test-"))
        bundle.cleanUp()
    }
}
