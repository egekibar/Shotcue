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

    @Test func costUsesTwoDecimalsAndDashForNil() {
        #expect(Formatting.cost(0.4137) == "$0.41")
        #expect(Formatting.cost(0) == "$0.00")
        #expect(Formatting.cost(12.5) == "$12.50")
        #expect(Formatting.cost(nil) == "—")
    }

    @Test func durationSplitsMinutesAndSeconds() {
        #expect(Formatting.duration(84.213) == "1 dk 24 sn")
        #expect(Formatting.duration(59.4) == "59 sn")
        #expect(Formatting.duration(3600) == "60 dk 0 sn")
        #expect(Formatting.duration(0) == "—")
        #expect(Formatting.duration(nil) == "—")
    }

    @Test func relativeDateIsTurkishAndCoarse() {
        #expect(Formatting.relativeDate(now.addingTimeInterval(-30), now: now, calendar: utc) == "az önce")
        #expect(Formatting.relativeDate(now.addingTimeInterval(30), now: now, calendar: utc) == "az önce")
        #expect(Formatting.relativeDate(now.addingTimeInterval(-300), now: now, calendar: utc) == "5 dk önce")
        #expect(Formatting.relativeDate(now.addingTimeInterval(-7200), now: now, calendar: utc) == "2 sa önce")
        #expect(Formatting.relativeDate(now.addingTimeInterval(-90_000), now: now, calendar: utc) == "dün")
        #expect(Formatting.relativeDate(now.addingTimeInterval(-5 * 86_400), now: now, calendar: utc) == "17.09")
    }

    @Test func clockTimeFormatsHourMinute() {
        #expect(Formatting.clockTime(now, calendar: utc) == "12:00")
    }

    @Test func statusLabelsAndRanksCoverEveryCase() {
        #expect(
            TaskStatus.allCases.map(StatusPresentation.label(for:)) == [
                "Gelen", "Hazır", "Kuyrukta", "Zamanlandı", "Çalışıyor", "Bitti", "Hata", "İptal",
            ])
        #expect(TaskStatus.allCases.allSatisfy { !StatusPresentation.symbol(for: $0).isEmpty })
        #expect(Set(TaskStatus.allCases.map(StatusPresentation.rank(for:))).count == TaskStatus.allCases.count)
        #expect(StatusPresentation.rank(for: .running) < StatusPresentation.rank(for: .queued))
        #expect(StatusPresentation.rank(for: .queued) < StatusPresentation.rank(for: .done))
        #expect(StatusPresentation.tint(for: TaskStatus.failed) == Color.red)
    }

    @Test func runStateLabelsAreTurkish() {
        #expect(
            RunState.allCases.map(StatusPresentation.label(for:)) == [
                "Başlıyor", "Çalışıyor", "Başarılı", "Hata", "İptal",
            ])
        #expect(StatusPresentation.symbol(for: RunState.succeeded) == "checkmark.seal.fill")
    }

    @Test func sortOrderAndViewModeHaveTurkishLabels() {
        #expect(SortOrder.allCases.map(\.label) == ["En yeni", "En eski", "Manuel", "Duruma göre"])
        #expect(ViewMode.allCases.map(\.label) == ["Izgara", "Liste"])
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
