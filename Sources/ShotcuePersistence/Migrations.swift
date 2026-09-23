import Foundation
import GRDB

extension AppDatabase {
    /// Numbered migrations. Never edit an existing migration after it shipped — add "v2".
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("default_mode", .text).notNull()
                t.column("default_model", .text)
                t.column("default_effort", .text)
                t.column("daily_time", .text)
                t.column("daily_enabled", .integer).notNull().defaults(to: false)
                t.column("daily_last_fired_at", .double)
                t.column("run_in_branch", .integer).notNull().defaults(to: false)
                t.column("stash_before_run", .integer).notNull().defaults(to: false)
                t.column("sort_index", .double).notNull().defaults(to: 0)
                t.column("created_at", .double).notNull()
            }

            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                // Deleting a project moves its tasks back to the inbox instead of losing them.
                t.column("project_id", .text).references("project", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("title_edited_by_user", .integer).notNull().defaults(to: false)
                t.column("note_text", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("model_override", .text)
                t.column("sort_index", .double).notNull().defaults(to: 0)
                t.column("scheduled_at", .double)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(
                index: "task_on_project_id_status", on: "task",
                columns: ["project_id", "status"])
            try db.create(index: "task_on_scheduled_at", on: "task", columns: ["scheduled_at"])

            try db.create(table: "capture") { t in
                t.primaryKey("id", .text)
                t.column("task_id", .text).notNull().references("task", onDelete: .cascade)
                t.column("rel_path", .text).notNull()
                t.column("thumb_rel_path", .text)
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("scale", .double).notNull().defaults(to: 2)
                t.column("created_at", .double).notNull()
            }
            try db.create(index: "capture_on_task_id", on: "capture", columns: ["task_id"])

            try db.create(table: "voice_note") { t in
                t.primaryKey("id", .text)
                t.column("task_id", .text).notNull().references("task", onDelete: .cascade)
                t.column("rel_path", .text).notNull()
                t.column("duration_sec", .double).notNull()
                t.column("transcript", .text)
                t.column("transcript_json", .text)
                t.column("transcript_state", .text).notNull()
                t.column("engine", .text)
                t.column("edited_by_user", .integer).notNull().defaults(to: false)
                t.column("created_at", .double).notNull()
            }
            try db.create(index: "voice_note_on_task_id", on: "voice_note", columns: ["task_id"])

            try db.create(table: "run") { t in
                // `run.id` doubles as the Claude Code session id (`--session-id`).
                t.primaryKey("id", .text)
                t.column("task_id", .text).notNull().references("task", onDelete: .cascade)
                t.column("state", .text).notNull()
                t.column("started_at", .double).notNull()
                t.column("finished_at", .double)
                t.column("num_turns", .integer)
                t.column("cost_usd", .double)
                t.column("result_text", .text)
                t.column("subtype", .text)
                t.column("exit_code", .integer)
                t.column("error", .text)
                t.column("log_rel_path", .text).notNull()
                t.column("git_head_before", .text)
                t.column("git_dirty_before", .integer)
                t.column("git_head_after", .text)
                t.column("git_branch", .text)
            }
            try db.create(
                index: "run_on_task_id_started_at", on: "run",
                columns: ["task_id", "started_at"])
        }

        return migrator
    }
}
