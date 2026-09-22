import Foundation
import Testing

@testable import ShotcueCore

@Suite("SchedulerRules")
struct SchedulerRulesTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2025-09-22 10:00:00 UTC (yıl kuralları etkilemez)
    let now = Date(timeIntervalSince1970: 1_758_535_200)
    let pid = UUID()

    func project(time: String?, enabled: Bool = true, lastFired: Date? = nil) -> Project {
        Project(
            id: pid, name: "p", path: "/tmp/p", dailyTime: time.flatMap(DailyTime.init(parsing:)),
            dailyEnabled: enabled, dailyLastFiredAt: lastFired)
    }

    @Test func oneShotTasksDueWhenScheduledAtPassed() {
        let due = ShotTask(projectID: pid, title: "a", status: .scheduled, scheduledAt: now.addingTimeInterval(-1))
        let later = ShotTask(projectID: pid, title: "b", status: .scheduled, scheduledAt: now.addingTimeInterval(60))
        let notScheduled = ShotTask(projectID: pid, title: "c", status: .ready, scheduledAt: now.addingTimeInterval(-1))
        let actions = SchedulerRules.dueActions(
            now: now, calendar: cal, tasks: [due, later, notScheduled], projects: [])
        #expect(actions == [.enqueueTask(due.id)])
    }

    @Test func dailyFiresOncePerDayAfterItsTime() {
        #expect(
            SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [project(time: "09:30")])
                == [.fireDailyQueue(projectID: pid)])
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [project(time: "10:30")]) == [])
        let firedToday = project(time: "09:30", lastFired: now.addingTimeInterval(-600))
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [firedToday]) == [])
    }

    @Test func dailyCatchesUpAfterSleepButOnlyOnce() {
        let lateEvening = now.addingTimeInterval(13 * 3600)  // 23:00 same day
        let firedYesterday = project(time: "09:00", lastFired: now.addingTimeInterval(-24 * 3600))
        #expect(
            SchedulerRules.dueActions(now: lateEvening, calendar: cal, tasks: [], projects: [firedYesterday])
                == [.fireDailyQueue(projectID: pid)])
    }

    @Test func disabledOrMissingTimeNeverFires() {
        #expect(
            SchedulerRules.dueActions(
                now: now, calendar: cal, tasks: [], projects: [project(time: "09:00", enabled: false)]) == [])
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [project(time: nil)]) == [])
    }

    @Test func todaysFireDateUsesCalendarDay() {
        let fire = SchedulerRules.todaysFireDate(DailyTime(hour: 9, minute: 30), now: now, calendar: cal)
        #expect(fire == Date(timeIntervalSince1970: 1_758_533_400))  // 2025-09-22 09:30 UTC
    }

    @Test func dailyCandidatesAreReadyTasksOfProjectInOrder() {
        let other = UUID()
        let r2 = ShotTask(projectID: pid, title: "r2", status: .ready, sortIndex: 2)
        let r1 = ShotTask(projectID: pid, title: "r1", status: .ready, sortIndex: 1)
        let q = ShotTask(projectID: pid, title: "q", status: .queued, sortIndex: 0)
        let foreign = ShotTask(projectID: other, title: "f", status: .ready, sortIndex: 0)
        #expect(
            SchedulerRules.dailyCandidates(projectID: pid, tasks: [r2, q, foreign, r1]).map(\.id) == [r1.id, r2.id])
    }
}
