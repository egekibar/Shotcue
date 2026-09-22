import Foundation
import GRDB
import ShotcueCore
import Testing

@testable import ShotcuePersistence

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test func inMemoryCreatesEverySpecTable() async throws {
        let database = try AppDatabase.inMemory()
        let names = try await database.reader.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(Set(names).isSuperset(of: ["project", "task", "capture", "voice_note", "run"]))
    }

    @Test func tablesHaveTheSpecColumnsInOrder() async throws {
        let database = try AppDatabase.inMemory()
        let columns = try await database.reader.read { db -> [String: [String]] in
            var result: [String: [String]] = [:]
            for table in ["project", "task", "capture", "voice_note", "run"] {
                result[table] =
                    try Row
                    .fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
            }
            return result
        }
        #expect(
            columns["project"] == [
                "id", "name", "path", "default_mode", "default_model",
                "default_effort", "daily_time", "daily_enabled",
                "daily_last_fired_at", "run_in_branch", "stash_before_run",
                "sort_index", "created_at",
            ])
        #expect(
            columns["task"] == [
                "id", "project_id", "title", "title_edited_by_user", "note_text",
                "status", "mode", "model_override", "sort_index", "scheduled_at",
                "created_at", "updated_at",
            ])
        #expect(
            columns["capture"] == [
                "id", "task_id", "rel_path", "thumb_rel_path", "width",
                "height", "scale", "created_at",
            ])
        #expect(
            columns["voice_note"] == [
                "id", "task_id", "rel_path", "duration_sec", "transcript",
                "transcript_json", "transcript_state", "engine",
                "edited_by_user", "created_at",
            ])
        #expect(
            columns["run"] == [
                "id", "task_id", "state", "started_at", "finished_at", "num_turns",
                "cost_usd", "result_text", "subtype", "exit_code", "error",
                "log_rel_path", "git_head_before", "git_dirty_before",
                "git_head_after", "git_branch",
            ])
    }

    @Test func specIndexesExist() async throws {
        let database = try AppDatabase.inMemory()
        let names = try await database.reader.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'")
        }
        #expect(
            Set(names) == [
                "task_on_project_id_status", "task_on_scheduled_at",
                "capture_on_task_id", "voice_note_on_task_id",
                "run_on_task_id_started_at",
            ])
    }

    @Test func foreignKeysAreEnabled() async throws {
        let database = try AppDatabase.inMemory()
        let enabled = try await database.reader.read { db -> Bool in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
        }
        #expect(enabled)
        let orphanAccepted = try await database.writer.write { db -> Bool in
            do {
                try db.execute(
                    sql: """
                        INSERT INTO capture (id, task_id, rel_path, width, height, scale, created_at)
                        VALUES ('a', 'missing-task', 'captures/a.png', 1, 1, 2, 0)
                        """)
                return true
            } catch {
                return false
            }
        }
        #expect(orphanAccepted == false)
    }

    @Test func runningMigrationsTwiceIsIdempotent() async throws {
        let database = try AppDatabase.inMemory()
        try AppDatabase.migrator.migrate(database.writer)
        let applied = try await database.reader.read { db in
            try AppDatabase.migrator.appliedIdentifiers(db)
        }
        #expect(applied == ["v1"])
    }

    @Test func openCreatesParentDirectoriesAndUsesWALPool() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(at: FileStore(rootURL: root).databaseURL)
        #expect(database.writer is DatabasePool)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("shotcue.sqlite").path))
        let journal = try await database.reader.read { db -> String in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
        #expect(journal == "wal")
    }

    @Test func foldFunctionIsRegisteredOnEveryConnection() async throws {
        let database = try AppDatabase.inMemory()
        let folded = try await database.reader.read { db -> String in
            try String.fetchOne(db, sql: "SELECT shotcue_fold('ÖNBELLEĞİ Işık')") ?? ""
        }
        #expect(folded == "onbellegi isik")
    }

    @Test func searchTextFoldsTurkishCaseAndDiacritics() {
        #expect(SearchText.normalized("ÖNBELLEĞİ") == SearchText.normalized("önbelleği"))
        #expect(SearchText.normalized("IŞIK") == SearchText.normalized("ışık"))
        #expect(SearchText.normalized("İstanbul") == "istanbul")
        #expect(SearchText.normalized("LOGIN") == "login")
        #expect(SearchText.normalized("Şu BUTON çalışmıyor") == "su buton calismiyor")
    }
}
