import Foundation
import GRDB
import ShotcueCore
import Testing

@testable import ShotcuePersistence

@Suite("Record round trips")
struct RecordRoundTripTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)  // 2025-09-22 00:13:20 UTC
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func projectRecordRoundTrips() async throws {
        let database = try AppDatabase.inMemory()
        let project = Project(
            name: "crm", path: "/Users/me/Projects/crm", defaultMode: .analyze,
            defaultModel: "opus", defaultEffort: "high",
            dailyTime: DailyTime(hour: 9, minute: 30), dailyEnabled: true,
            dailyLastFiredAt: epoch, runInBranch: true, stashBeforeRun: true,
            sortIndex: 1024, createdAt: epoch)
        let decoded = try await database.writer.write { db -> Project in
            try ProjectRecord(project).upsert(db)
            let record = try #require(try ProjectRecord.fetchOne(db, key: project.id.dbKey))
            return record.model
        }
        #expect(decoded == project)
    }

    @Test func idsAreStoredAsLowercaseUUIDStrings() async throws {
        let database = try AppDatabase.inMemory()
        let id = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!
        let stored = try await database.writer.write { db -> String in
            try ProjectRecord(
                Project(
                    id: id, name: "p", path: "/tmp/p", sortIndex: 1024,
                    createdAt: epoch)
            ).upsert(db)
            return try String.fetchOne(db, sql: "SELECT id FROM project") ?? ""
        }
        #expect(stored == "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
    }

    @Test func datesAreStoredAsSecondsSince1970() async throws {
        let database = try AppDatabase.inMemory()
        let seconds = try await database.writer.write { db -> Double in
            try ProjectRecord(
                Project(
                    name: "p", path: "/tmp/p", sortIndex: 1024,
                    createdAt: epoch)
            ).upsert(db)
            return try Double.fetchOne(db, sql: "SELECT created_at FROM project") ?? 0
        }
        #expect(seconds == 1_758_500_000)
    }

    @Test func enumsAreStoredAsRawValues() async throws {
        let database = try AppDatabase.inMemory()
        let row = try await database.writer.write { db -> [String] in
            try TaskRecord(
                ShotTask(
                    title: "t", status: .scheduled, mode: .analyze,
                    sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
            ).upsert(db)
            let row = try #require(try Row.fetchOne(db, sql: "SELECT status, mode FROM task"))
            return [row["status"] as String? ?? "", row["mode"] as String? ?? ""]
        }
        #expect(row == ["scheduled", "analyze"])
    }

    @Test func taskCaptureVoiceNoteAndRunRoundTrip() async throws {
        let database = try AppDatabase.inMemory()
        let project = Project(name: "crm", path: "/tmp/crm", sortIndex: 1024, createdAt: epoch)
        let task = ShotTask(
            projectID: project.id, title: "Önbelleği temizle", noteText: "Şu BUTON",
            status: .ready, mode: .implement, modelOverride: "sonnet",
            sortIndex: 2048, scheduledAt: epoch, titleEditedByUser: true,
            createdAt: epoch, updatedAt: epoch)
        let capture = Capture(
            taskID: task.id, relPath: "captures/2026/09/a.png",
            thumbRelPath: "thumbs/a.jpg", width: 1200, height: 800, scale: 2,
            createdAt: epoch)
        let note = VoiceNote(
            taskID: task.id, relPath: "audio/a.m4a", durationSec: 4.25,
            transcript: "Önbelleği TEMİZLE", transcriptJSON: "{\"text\":\"x\"}",
            transcriptState: .done, engine: "whisperkit/turbo", editedByUser: true,
            createdAt: epoch)
        let run = Run(
            taskID: task.id, state: .succeeded, startedAt: epoch,
            finishedAt: epoch.addingTimeInterval(42), numTurns: 7, costUSD: 0.42,
            resultText: "ok", subtype: "success", exitCode: 0, error: nil,
            logRelPath: "runs/a.jsonl", gitHeadBefore: "abc", gitDirtyBefore: true,
            gitHeadAfter: "def", gitBranch: "main")

        let decoded = try await database.writer.write { db -> (ShotTask, Capture, VoiceNote, Run) in
            try ProjectRecord(project).upsert(db)
            try TaskRecord(task).upsert(db)
            try CaptureRecord(capture).upsert(db)
            try VoiceNoteRecord(note).upsert(db)
            try RunRecord(run).upsert(db)
            return (
                try #require(try TaskRecord.fetchOne(db, key: task.id.dbKey)).model,
                try #require(try CaptureRecord.fetchOne(db, key: capture.id.dbKey)).model,
                try #require(try VoiceNoteRecord.fetchOne(db, key: note.id.dbKey)).model,
                try #require(try RunRecord.fetchOne(db, key: run.id.dbKey)).model
            )
        }
        #expect(decoded.0 == task)
        #expect(decoded.1 == capture)
        #expect(decoded.2 == note)
        #expect(decoded.3 == run)
    }

    @Test func upsertUpdatesInPlaceWithoutCascadingChildrenAway() async throws {
        let database = try AppDatabase.inMemory()
        let task = ShotTask(title: "before", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        let capture = Capture(
            taskID: task.id, relPath: "captures/a.png", width: 10, height: 10,
            createdAt: epoch)
        let result = try await database.writer.write { db -> (Int, String, Int) in
            try TaskRecord(task).upsert(db)
            try CaptureRecord(capture).upsert(db)
            var edited = task
            edited.title = "after"
            try TaskRecord(edited).upsert(db)
            let stored = try #require(try TaskRecord.fetchOne(db, key: task.id.dbKey))
            return (try TaskRecord.fetchCount(db), stored.title, try CaptureRecord.fetchCount(db))
        }
        #expect(result == (1, "after", 1))
    }

    @Test func captureRelativePathSurvivesRoundTrip() async throws {
        let database = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-rel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileStore(rootURL: root)
        try store.ensureDirectories()

        let task = ShotTask(title: "t", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        let captureID = UUID()
        let relPath = store.captureRelPath(id: captureID, date: epoch, calendar: utc)
        try store.ensureParentDirectory(for: relPath)
        try FileManager.default.copyItem(
            at: TestPaths.fixture("sample.png"),
            to: store.absoluteURL(for: relPath))

        let stored = try await database.writer.write { db -> Capture in
            try TaskRecord(task).upsert(db)
            try CaptureRecord(
                Capture(
                    id: captureID, taskID: task.id, relPath: relPath,
                    width: 8, height: 8, createdAt: epoch)
            ).upsert(db)
            return try #require(try CaptureRecord.fetchOne(db, key: captureID.dbKey)).model
        }
        #expect(stored.relPath == relPath)
        #expect(stored.relPath.hasPrefix("captures/2025/09/"))
        #expect(store.relativePath(for: store.absoluteURL(for: relPath)) == relPath)
        #expect(FileManager.default.fileExists(atPath: store.absoluteURL(for: relPath).path))
    }
}
