import Foundation
import GRDB
import ShotcueCore
import Testing

@testable import ShotcuePersistence

@Suite("GRDBTaskRepository")
struct GRDBTaskRepositoryTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    struct Fixture {
        let database: AppDatabase
        let projects: GRDBProjectRepository
        let tasks: GRDBTaskRepository
    }

    func makeFixture() throws -> Fixture {
        let database = try AppDatabase.inMemory()
        return Fixture(
            database: database,
            projects: GRDBProjectRepository(database: database),
            tasks: GRDBTaskRepository(database: database))
    }

    @Test func inboxIsTasksWithNullProject() async throws {
        let fixture = try makeFixture()
        let project = Project(name: "crm", path: "/tmp/crm", sortIndex: 1024, createdAt: epoch)
        try await fixture.projects.save(project)
        let inbox = ShotTask(title: "inbox", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        let assigned = ShotTask(
            projectID: project.id, title: "assigned", status: .ready,
            sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try await fixture.tasks.save(inbox)
        try await fixture.tasks.save(assigned)
        #expect(try await fixture.tasks.tasks(projectID: nil).map(\.id) == [inbox.id])
        #expect(try await fixture.tasks.tasks(projectID: project.id).map(\.id) == [assigned.id])
        #expect(try await fixture.tasks.allTasks().count == 2)
        #expect(try await fixture.tasks.task(id: inbox.id)?.title == "inbox")
        #expect(try await fixture.tasks.task(id: UUID()) == nil)
    }

    @Test func statusFilterAndOrdering() async throws {
        let fixture = try makeFixture()
        let readyLate = ShotTask(
            title: "ready-late", status: .ready, sortIndex: 3072,
            createdAt: epoch, updatedAt: epoch)
        let readyTie2 = ShotTask(
            title: "ready-tie2", status: .ready, sortIndex: 1024,
            createdAt: epoch.addingTimeInterval(9), updatedAt: epoch)
        let readyTie1 = ShotTask(
            title: "ready-tie1", status: .ready, sortIndex: 1024,
            createdAt: epoch.addingTimeInterval(1), updatedAt: epoch)
        let done = ShotTask(
            title: "done", status: .done, sortIndex: 512,
            createdAt: epoch, updatedAt: epoch)
        for task in [readyLate, readyTie2, readyTie1, done] { try await fixture.tasks.save(task) }
        #expect(
            try await fixture.tasks.tasks(status: .ready).map(\.title)
                == ["ready-tie1", "ready-tie2", "ready-late"])
        #expect(try await fixture.tasks.tasks(status: .queued).isEmpty)
        #expect(
            try await fixture.tasks.allTasks().map(\.title)
                == ["done", "ready-tie1", "ready-tie2", "ready-late"])
    }

    @Test func deleteTaskCascadesCapturesVoiceNotesAndRuns() async throws {
        let fixture = try makeFixture()
        let task = ShotTask(title: "t", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try await fixture.tasks.save(task)
        try await fixture.tasks.save(
            Capture(
                taskID: task.id, relPath: "captures/a.png",
                width: 1, height: 1, createdAt: epoch))
        try await fixture.tasks.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/a.m4a",
                durationSec: 1, createdAt: epoch))
        try await fixture.database.writer.write { db in
            try RunRecord(Run(taskID: task.id, startedAt: epoch, logRelPath: "runs/a.jsonl")).upsert(db)
        }
        try await fixture.tasks.deleteTask(id: task.id)
        #expect(try await fixture.tasks.task(id: task.id) == nil)
        #expect(try await fixture.tasks.captures(taskID: task.id).isEmpty)
        #expect(try await fixture.tasks.voiceNotes(taskID: task.id).isEmpty)
        let remainingRuns = try await fixture.database.reader.read { db in try RunRecord.fetchCount(db) }
        #expect(remainingRuns == 0)
    }

    @Test func moveCapturesRetargetsInOneTransaction() async throws {
        let fixture = try makeFixture()
        let source = ShotTask(title: "source", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        let target = ShotTask(title: "target", sortIndex: 2048, createdAt: epoch, updatedAt: epoch)
        try await fixture.tasks.save(source)
        try await fixture.tasks.save(target)
        let first = Capture(
            taskID: source.id, relPath: "captures/a.png", width: 1, height: 1,
            createdAt: epoch)
        let second = Capture(
            taskID: source.id, relPath: "captures/b.png", width: 1, height: 1,
            createdAt: epoch.addingTimeInterval(1))
        try await fixture.tasks.save(first)
        try await fixture.tasks.save(second)
        try await fixture.tasks.moveCaptures(ids: [first.id, second.id], toTaskID: target.id)
        #expect(try await fixture.tasks.captures(taskID: source.id).isEmpty)
        #expect(try await fixture.tasks.captures(taskID: target.id).map(\.id) == [first.id, second.id])
    }

    @Test func searchCoversTitleNoteAndTranscriptCaseInsensitively() async throws {
        let fixture = try makeFixture()
        let byTitle = ShotTask(
            title: "Login ekranı bozuk", sortIndex: 1024,
            createdAt: epoch, updatedAt: epoch)
        let byNote = ShotTask(
            title: "ikinci", noteText: "Şu BUTON çalışmıyor", sortIndex: 2048,
            createdAt: epoch, updatedAt: epoch)
        let byTranscript = ShotTask(title: "ucuncu", sortIndex: 3072, createdAt: epoch, updatedAt: epoch)
        let unrelated = ShotTask(title: "alakasiz", sortIndex: 4096, createdAt: epoch, updatedAt: epoch)
        for task in [byTitle, byNote, byTranscript, unrelated] { try await fixture.tasks.save(task) }
        try await fixture.tasks.save(
            VoiceNote(
                taskID: byTranscript.id, relPath: "audio/a.m4a",
                durationSec: 3, transcript: "Önbelleği TEMİZLE lütfen",
                transcriptState: .done, createdAt: epoch))
        #expect(try await fixture.tasks.search("LOGIN").map(\.id) == [byTitle.id])
        #expect(try await fixture.tasks.search("buton").map(\.id) == [byNote.id])
        #expect(try await fixture.tasks.search("ÖNBELLEĞİ").map(\.id) == [byTranscript.id])
        #expect(try await fixture.tasks.search("temizle").map(\.id) == [byTranscript.id])
        #expect(try await fixture.tasks.search("").count == 4)
        #expect(try await fixture.tasks.search("   ").count == 4)
        #expect(try await fixture.tasks.search("yokboyleseykesin").isEmpty)
        #expect(try await fixture.tasks.search("%").isEmpty)
        #expect(try await fixture.tasks.search("_").isEmpty)
    }

    @Test func searchReturnsEachTaskOnceDespiteMultipleVoiceNotes() async throws {
        let fixture = try makeFixture()
        let task = ShotTask(title: "tek", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try await fixture.tasks.save(task)
        try await fixture.tasks.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/a.m4a", durationSec: 1,
                transcript: "cache temizle", transcriptState: .done,
                createdAt: epoch))
        try await fixture.tasks.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/b.m4a", durationSec: 1,
                transcript: "cache yine", transcriptState: .done,
                createdAt: epoch.addingTimeInterval(1)))
        #expect(try await fixture.tasks.search("cache").map(\.id) == [task.id])
    }

    @Test func observeTasksEmitsFilteredListsInOrder() async throws {
        let fixture = try makeFixture()
        let project = Project(name: "crm", path: "/tmp/crm", sortIndex: 1024, createdAt: epoch)
        try await fixture.projects.save(project)
        var iterator = fixture.tasks.observeTasks(projectID: project.id).makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await fixture.tasks.save(
            ShotTask(
                projectID: project.id, title: "second", status: .ready,
                sortIndex: 2048, createdAt: epoch, updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["second"])
        try await fixture.tasks.save(
            ShotTask(
                projectID: project.id, title: "first", status: .ready,
                sortIndex: 1024, createdAt: epoch, updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["first", "second"])
        try await fixture.tasks.save(
            ShotTask(
                title: "inbox", sortIndex: 1, createdAt: epoch,
                updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["first", "second"])
    }

    @Test func observeAllTasksEmitsCurrentValueThenChanges() async throws {
        let fixture = try makeFixture()
        var iterator = fixture.tasks.observeAllTasks().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await fixture.tasks.save(
            ShotTask(
                title: "x", sortIndex: 1024, createdAt: epoch,
                updatedAt: epoch))
        #expect(await iterator.next()?.count == 1)
    }

    @Test func capturesAndVoiceNotesAreOrderedByCreatedAt() async throws {
        let fixture = try makeFixture()
        let task = ShotTask(title: "t", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try await fixture.tasks.save(task)
        let second = Capture(
            taskID: task.id, relPath: "captures/b.png", width: 1, height: 1,
            createdAt: epoch.addingTimeInterval(10))
        let first = Capture(
            taskID: task.id, relPath: "captures/a.png", width: 1, height: 1,
            createdAt: epoch)
        try await fixture.tasks.save(second)
        try await fixture.tasks.save(first)
        #expect(
            try await fixture.tasks.captures(taskID: task.id).map(\.relPath)
                == ["captures/a.png", "captures/b.png"])
        let noteLate = VoiceNote(
            taskID: task.id, relPath: "audio/b.m4a", durationSec: 1,
            createdAt: epoch.addingTimeInterval(10))
        let noteEarly = VoiceNote(
            taskID: task.id, relPath: "audio/a.m4a", durationSec: 1,
            createdAt: epoch)
        try await fixture.tasks.save(noteLate)
        try await fixture.tasks.save(noteEarly)
        #expect(
            try await fixture.tasks.voiceNotes(taskID: task.id).map(\.relPath)
                == ["audio/a.m4a", "audio/b.m4a"])
    }
}
