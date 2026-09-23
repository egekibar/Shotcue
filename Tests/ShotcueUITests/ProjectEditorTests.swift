import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

@Suite("ProjectDraft")
struct ProjectDraftTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2025-09-22 10:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_758_535_200)

    @Test func newDraftDefaults() {
        let d = ProjectDraft.new()
        #expect(d.isNew)
        #expect(d.defaultMode == .implement)
        #expect(d.dailyEnabled == false)
        #expect(d.dailyTime == DailyTime(hour: 2, minute: 0))
        #expect(d.runInBranch == false && d.stashBeforeRun == false)
        #expect(d.defaultModel.isEmpty && d.defaultEffort.isEmpty)
    }

    @Test func unchangedDraftLeavesProjectUntouched() {
        let p = Project(
            name: "crm", path: "/tmp/crm", defaultMode: .analyze, defaultModel: "opus",
            dailyTime: DailyTime(hour: 9, minute: 0), dailyEnabled: true,
            dailyLastFiredAt: now.addingTimeInterval(-86_400), runInBranch: true)
        #expect(ProjectDraft(project: p).apply(to: p, now: now, calendar: utc) == p)
        let plain = Project(name: "x", path: "/tmp/x")
        #expect(ProjectDraft(project: plain).apply(to: plain, now: now, calendar: utc) == plain)
    }

    @Test func enablingAfterTodaysSlotArmsForTomorrow() {
        let p = Project(name: "crm", path: "/tmp/crm")
        var d = ProjectDraft(project: p)
        d.dailyEnabled = true
        d.dailyHour = 9
        d.dailyMinute = 0
        let saved = d.apply(to: p, now: now, calendar: utc)
        #expect(saved.dailyEnabled && saved.dailyTime == DailyTime(hour: 9, minute: 0))
        #expect(saved.dailyLastFiredAt == now)
        #expect(SchedulerRules.dueActions(now: now, calendar: utc, tasks: [], projects: [saved]).isEmpty)
        let tomorrow = now.addingTimeInterval(24 * 3600)
        #expect(
            SchedulerRules.dueActions(now: tomorrow, calendar: utc, tasks: [], projects: [saved])
                == [.fireDailyQueue(projectID: p.id)])
    }

    @Test func enablingBeforeTodaysSlotRunsToday() {
        let p = Project(name: "crm", path: "/tmp/crm", dailyLastFiredAt: now.addingTimeInterval(-3600))
        var d = ProjectDraft(project: p)
        d.dailyEnabled = true
        d.dailyHour = 18
        d.dailyMinute = 30
        let saved = d.apply(to: p, now: now, calendar: utc)
        #expect(saved.dailyLastFiredAt == nil)
        let evening = now.addingTimeInterval(8.5 * 3600 + 60)  // 18:31
        #expect(
            SchedulerRules.dueActions(now: evening, calendar: utc, tasks: [], projects: [saved])
                == [.fireDailyQueue(projectID: p.id)])
    }

    @Test func trimsAndClearsOptionalDefaults() {
        let p = Project(name: "a", path: "/tmp/a", defaultModel: "opus", defaultEffort: "high")
        var d = ProjectDraft(project: p)
        d.name = "  yeni ad  "
        d.path = " /tmp/b "
        d.defaultModel = "  "
        d.defaultEffort = ""
        let saved = d.apply(to: p, now: now, calendar: utc)
        #expect(saved.name == "yeni ad" && saved.path == "/tmp/b")
        #expect(saved.defaultModel == nil && saved.defaultEffort == nil)
    }

    @Test func validation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = ProjectDraft.new()
        #expect(d.validationMessage() == "Proje adı gerekli.")
        d.name = "crm"
        #expect(d.validationMessage() == "Proje klasörü gerekli.")
        d.path = dir.appendingPathComponent("yok").path
        #expect(d.validationMessage()?.hasPrefix("Klasör bulunamadı") == true)
        d.path = dir.path
        #expect(d.validationMessage() == nil)
    }
}

@Suite("LibraryStore project editor")
struct LibraryStoreProjectEditorTests {
    @MainActor
    @Test func creatorFlagOpensAndClosesANewDraft() {
        let f = makeFakeServices()
        let store = LibraryStore(services: f.services)
        store.isProjectCreatorPresented = true
        #expect(store.projectDraft?.isNew == true)
        #expect(store.isProjectCreatorPresented)
        store.isProjectCreatorPresented = false
        #expect(store.projectDraft == nil)
    }

    @MainActor
    @Test func savingANewDraftCreatesAndSelectsTheProject() async throws {
        let f = makeFakeServices()
        defer { f.cleanUp() }
        let store = LibraryStore(services: f.services)
        store.beginCreateProject()
        store.projectFolderPicked(f.root)
        #expect(store.projectDraft?.name == f.root.lastPathComponent)
        #expect(await store.saveProjectDraft())
        #expect(store.projectDraft == nil)
        let saved = try await f.projects.allProjects()
        #expect(saved.count == 1)
        #expect(saved.first?.path == f.root.path)
        #expect(store.selection == .project(try #require(saved.first).id))
    }

    @MainActor
    @Test func editingArmsTheDailyQueueWithTheStoreCalendar() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let clock = MutableClock(Date(timeIntervalSince1970: 1_758_535_200))  // 10:00 UTC
        let project = Project(name: "crm", path: FileManager.default.temporaryDirectory.path)
        let f = makeFakeServices(projects: [project], clock: clock)
        defer { f.cleanUp() }
        let store = LibraryStore(services: f.services)
        store.calendar = utc
        await store.beginEditProject(id: project.id)
        store.projectDraft?.dailyEnabled = true
        store.projectDraft?.dailyHour = 9
        store.projectDraft?.runInBranch = true
        #expect(await store.saveProjectDraft())
        let saved = try #require(try await f.projects.project(id: project.id))
        #expect(saved.runInBranch)
        #expect(saved.dailyEnabled && saved.dailyLastFiredAt == clock.now)
    }

    @MainActor
    @Test func anInvalidDraftStaysOpenAndReportsWhy() async {
        let f = makeFakeServices()
        let store = LibraryStore(services: f.services)
        store.beginCreateProject()
        #expect(await store.saveProjectDraft() == false)
        #expect(store.lastError == "Proje adı gerekli.")
        #expect(store.projectDraft != nil)
    }
}
