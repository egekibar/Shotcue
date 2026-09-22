import Foundation
import ShotcueCore
import Testing
import UserNotifications

@testable import ShotcueClaudeBridge

@Suite("UserNotificationNotifier")
struct UserNotificationNotifierTests {
    let taskID = UUID()
    let runID = UUID()

    @Test func doneNotificationUsesTheRunDoneCategory() throws {
        let request = UserNotificationNotifier.request(
            for: AppNotification(
                kind: .runDone, title: "Buton rengi", body: "Özet satırı", taskID: taskID, runID: runID))
        #expect(request.identifier == runID.uuidString)
        #expect(request.content.title == "Buton rengi")
        #expect(request.content.body == "Özet satırı")
        #expect(request.content.categoryIdentifier == UserNotificationNotifier.runDoneCategory)
        #expect(request.content.interruptionLevel == .active)
        #expect(request.content.userInfo[UserNotificationNotifier.taskIDKey] as? String == taskID.uuidString)
        #expect(request.content.userInfo[UserNotificationNotifier.runIDKey] as? String == runID.uuidString)
        #expect(request.trigger == nil)
    }

    @Test func failedNotificationIsTimeSensitive() {
        let request = UserNotificationNotifier.request(
            for: AppNotification(
                kind: .runFailed, title: "Uzun iş", body: "Tur limiti aşıldı (30 tur).",
                taskID: taskID, runID: runID))
        #expect(request.content.categoryIdentifier == UserNotificationNotifier.runFailedCategory)
        #expect(request.content.interruptionLevel == .timeSensitive)
    }

    @Test func categoriesCarryTheActionsPlan06Matches() throws {
        let categories = UserNotificationNotifier.categories()
        #expect(categories.count == 2)
        let done = try #require(categories.first { $0.identifier == UserNotificationNotifier.runDoneCategory })
        #expect(
            done.actions.map(\.identifier) == [
                UserNotificationNotifier.openAction,
                UserNotificationNotifier.terminalAction,
            ])
        #expect(done.actions.map(\.title) == ["Aç", "Terminalde devam et"])
        let failed = try #require(categories.first { $0.identifier == UserNotificationNotifier.runFailedCategory })
        #expect(
            failed.actions.map(\.identifier) == [
                UserNotificationNotifier.openAction,
                UserNotificationNotifier.retryAction,
            ])
        #expect(failed.actions.map(\.title) == ["Aç", "Yeniden çalıştır"])
        #expect(UserNotificationNotifier.runDoneCategory == "RUN_DONE")
        #expect(UserNotificationNotifier.runFailedCategory == "RUN_FAILED")
    }

    @Test func identifierFallsBackWhenThereIsNoRun() {
        let request = UserNotificationNotifier.request(
            for: AppNotification(
                kind: .runDone, title: "t", body: "b"))
        #expect(!request.identifier.isEmpty)
        #expect(request.content.userInfo.isEmpty)
    }
}
