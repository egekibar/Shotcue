# Shotcue v1 — Plan 01: Persistence (GRDB)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ShotcuePersistence` modülünü kurmak: GRDB.swift 7.11 üzerinde `AppDatabase` (WAL `DatabasePool` + numaralı migration'lar), spec §6.3'teki beş tablonun kayıt tipleri, Plan 00 Task 10'daki `ProjectRepository` / `TaskRepository` / `RunRepository` protokollerinin GRDB implementasyonları, `ValueObservation` → `AsyncStream` köprüsü ve `sort_index` yeniden numaralandırma yardımcısı — hepsi Swift Testing testleriyle.

**Architecture:** Modül dışa üç repository sınıfı, bir `AppDatabase` ve bir `PersistenceMaintenance` enum'u verir; bunların dışındaki her şey (kayıt tipleri, SQL fonksiyonu, observation köprüsü) `internal` kalır. Domain modelleri (`Project`, `ShotTask`, `Capture`, `VoiceNote`, `Run`) hiçbir GRDB protokolüne uymaz; her tablo için ayrı bir `*Record` tipi var ve dönüşüm `init(_ model:)` / `var model:` çiftiyle yapılır. Böylece `ShotcueCore` GRDB'den tamamen bağımsız kalır (Global Constraints) ve kolon adları (`snake_case`) `CodingKeys` içinde tek yerde toplanır. Okuma/yazma `any DatabaseWriter` / `any DatabaseReader` üzerinden async yapılır; canlı akışlar `ValueObservation.tracking { … }.values(in:)` dizisini bir `Task` içinde tüketip `AsyncStream`'e yazan tek bir köprü fonksiyonundan geçer.

**Tech Stack:** Swift 6.4 (CLT 27.0, SDK 27.0), SwiftPM, Swift Testing, macOS 26.0, `GRDB.swift` 7.11.1 (ürün `GRDB`, SQLite + `DatabaseMigrator` + `ValueObservation`). `Package.swift` Plan 00 Task 0'da sabitlendi ve bu planda **değiştirilmez**: `ShotcuePersistence` target'ı `ShotcueCore` + `.product(name: "GRDB", package: "GRDB.swift")`'e, `ShotcuePersistenceTests` target'ı `ShotcuePersistence` + `ShotcueTestSupport`'a bağlıdır.

**Spec:** `docs/superpowers/specs/2026-09-22-shotcue-design.md` (§4, §6.3, §7, §11; araştırma: `docs/research/01-macos-platform-and-tooling.md` §7)

## Global Constraints

- `// swift-tools-version: 6.4`, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v6]`.
- UI/App target'ları `.defaultIsolation(MainActor.self)`; servis/test target'ları `.defaultIsolation(nil)`; tüm target'larda `NonisolatedNonsendingByDefault` ve `InferIsolatedConformances` upcoming feature'ları.
- **Xcode yok.** `xcodebuild`, `actool`, `.xcassets`, `#Preview` makrosu ve `#Preview` içeren bağımlılıklar **yasak** (CLT'de `PreviewsMacros` eklentisi yok, derleme kırılır). Yalnızca `swift build`, `swift test`, `swift-format`, `codesign`, `iconutil`, `plutil`.
- Bağımlılık: yalnızca `https://github.com/groue/GRDB.swift.git` `from: "7.11.0"` ve `https://github.com/argmaxinc/argmax-oss-swift.git` `from: "1.1.0"`. Başka paket eklenmez.
- Bundle id `com.shotcue.app`; `LSUIElement` true; `LSMinimumSystemVersion` 26.0; depolama kökü `~/Library/Application Support/Shotcue/`.
- İmza: self-signed "Shotcue Dev" (ad-hoc `--sign -` yalnızca sertifika yoksa uyarıyla); App Sandbox **kapalı**; Hardened Runtime **açık**; entitlement `com.apple.security.device.audio-input = true`.
- Kod, identifier'lar ve commit mesajları İngilizce; UI metinleri Türkçe literal; Swift Testing (`import Testing`, `#expect`, `#require`); XCTest kullanılmaz.
- Domain görev tipi **`ShotTask`** (Swift'in `Task` tipiyle çakışmasın diye). Çalışma kaydı `Run`, ekran görüntüsü `Capture`, ses notu `VoiceNote`, proje `Project`.
- `ShotcueCore` yalnızca `Foundation` import eder. AppKit/SwiftUI/AVFoundation/GRDB Core'a giremez.
- Her task `swift test` yeşilken commit'lenir. Commit mesajı sonu: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

---

## Dosya haritası

```
Sources/ShotcuePersistence/
  ShotcuePersistence.swift          # Plan 00'dan gelen yer tutucu (ShotcuePersistenceInfo) — DOKUNULMAZ
  SearchText.swift                  # SearchText.normalized(_:), SQLFunctions.fold  (Task 1)
  Migrations.swift                  # AppDatabase.migrator, migration "v1"          (Task 1)
  AppDatabase.swift                 # AppDatabase.open(at:) / .inMemory() / writer / reader (Task 1)
  Records/ShotcueRecord.swift       # ShotcueRecord protokolü, Date stratejisi, UUID.dbKey (Task 2)
  Records/ProjectRecord.swift       # ProjectRecord + Project dönüşümü              (Task 2)
  Records/TaskRecord.swift          # TaskRecord + ShotTask dönüşümü + ordered()    (Task 2)
  Records/CaptureRecord.swift       # CaptureRecord + Capture dönüşümü              (Task 2)
  Records/VoiceNoteRecord.swift     # VoiceNoteRecord + VoiceNote dönüşümü          (Task 2)
  Records/RunRecord.swift           # RunRecord + Run dönüşümü                      (Task 2)
  ObservationBridge.swift           # ValueObservation -> AsyncStream köprüsü        (Task 3)
  GRDBProjectRepository.swift       # ProjectRepository implementasyonu             (Task 3)
  GRDBTaskRepository.swift          # TaskRepository implementasyonu                (Task 4)
  GRDBRunRepository.swift           # RunRepository implementasyonu                 (Task 5)
  PersistenceMaintenance.swift      # renumberSortIndexes(in:projectID:)            (Task 6)

Tests/ShotcuePersistenceTests/
  SmokeTests.swift                  # Plan 00'dan gelen yer tutucu — DOKUNULMAZ
  TestPaths.swift                   # Plan 00 Task 0'daki helper'ın kopyası         (Task 1)
  AppDatabaseTests.swift            # @Suite("AppDatabase")                         (Task 1)
  RecordRoundTripTests.swift        # @Suite("Record round trips")                  (Task 2)
  GRDBProjectRepositoryTests.swift  # @Suite("GRDBProjectRepository")               (Task 3)
  GRDBTaskRepositoryTests.swift     # @Suite("GRDBTaskRepository")                  (Task 4)
  GRDBRunRepositoryTests.swift      # @Suite("GRDBRunRepository")                   (Task 5)
  PersistenceMaintenanceTests.swift # @Suite("PersistenceMaintenance")              (Task 6)
  TaskRepositoryContractTests.swift # @Suite("Task repository contract")            (Task 7)
```

Bu plan **yalnızca** `Sources/ShotcuePersistence/**` ve `Tests/ShotcuePersistenceTests/**` altına yazar. `Package.swift`, `Makefile`, `ShotcueCore` ve `ShotcueTestSupport` değiştirilmez.

**Kapsam dışı (bilinçli):** Spec §7'deki durum makinesi geçiş kuralları (`TaskStatus.transition(to:)`) Plan 00 Task 2'de `ShotcueCore` içinde yaşar ve orada test edilir; bu modül yalnızca `status` / `state` alanlarını `rawValue` olarak saklar, geçiş doğrulaması yapmaz. Ayarlar `UserDefaults`'ta tutulur (spec §6.3 son cümlesi), DB'de değil. Ekran görüntüsü / ses dosyalarının kendisi diskte kalır; DB yalnızca göreli yol saklar ve dosya silme çağıranın işidir (`deleteTask` yalnızca satırları düşürür).

---

## Doğrulanmış GRDB API'leri

Aşağıdaki semboller bu makinede (`swift 6.4`, `GRDB.swift 7.11.1`) scratchpad'de bir paket kurulup **derlenerek ve çalıştırılarak** doğrulandı (40 çalışma zamanı kontrolü + 39 Swift Testing testi yeşil). Planın içindeki kod blokları o doğrulanmış kaynaktan alınmıştır; imzalar tahmin değildir.

| Alan | Doğrulanan sembol |
|---|---|
| Bağlantı | `DatabaseQueue(configuration:)`, `DatabasePool(path:configuration:)`, `any DatabaseWriter`, `any DatabaseReader` |
| Konfigürasyon | `Configuration()`, `Configuration.foreignKeysEnabled` (varsayılan `true`), `Configuration.journalMode = .wal`, `Configuration.prepareDatabase { @Sendable (Database) throws -> Void }` |
| SQL fonksiyonu | `DatabaseFunction(_:argumentCount:pure:function:)` (tip `Sendable`), `Database.add(function:)`, `String.fromDatabaseValue(_:)` |
| Migration | `DatabaseMigrator()`, `registerMigration(_:migrate:)`, `migrate(_ writer: any DatabaseWriter)`, `appliedIdentifiers(_ db: Database)` |
| Şema DSL | `Database.create(table:body:)`, `TableDefinition.primaryKey(_:_:)`, `.column(_:_:)`, `ColumnDefinition.notNull()`, `.defaults(to:)`, `.references(_:onDelete:)` (`.cascade`, `.setNull`), `Database.create(index:on:columns:)` |
| Kayıt | `FetchableRecord`, `PersistableRecord`, `databaseTableName`, `Column(_ codingKey: any CodingKey)`, özel `CodingKeys` ile snake_case eşleme |
| Tarih | `databaseDateEncodingStrategy(for:) -> DatabaseDateEncodingStrategy` / `databaseDateDecodingStrategy(for:) -> DatabaseDateDecodingStrategy`, `.timeIntervalSince1970` (her iki yönde tam yuvarlak dönüş) |
| Yazma | `PersistableRecord.upsert(_ db:)` (`ON CONFLICT DO UPDATE` — `INSERT OR REPLACE` **değil**, alt satırları CASCADE ile silmez), `TableRecord.deleteOne(_:key:)`, `QueryInterfaceRequest.updateAll(_:_:)`, `Column.set(to:)` |
| Okuma | `TableRecord.fetchOne(_:key:)`, `.fetchAll(_:)`, `.fetchCount(_:)`, `order(_ orderings:…)`, `filter(_:)`, `Column == nil` → `IS NULL`, `[String].contains(Column)` → `IN (…)` |
| Ham SQL | `SQL` string interpolation, `SQLRequest<Record>(literal:)`, `String.fetchAll(_:sql:)`, `String.fetchOne(_:sql:)`, `Double.fetchOne(_:sql:)`, `Bool.fetchOne(_:sql:)`, `Row.fetchAll(_:sql:)`, `Row` subscript'i `$0["name"] as String?` |
| Introspection | `Database.tableExists(_:)`, `Database.columns(in:)`, `Database.indexes(on:)` |
| Observation | `ValueObservation.tracking { (Database) throws -> Value }`, `ValueObservation<ValueReducers.Fetch<Value>>`, `.values(in: any DatabaseReader)` → `AsyncValueObservation<Value>` (`AsyncSequence`, throwing; varsayılan `scheduling: .task`, `bufferingPolicy: .unbounded`) |

**Karar — tarih formatı:** Tüm `Date` kolonları `Double` (1970'ten beri geçen saniye) olarak saklanır; kodlama ve kod çözme stratejisi `ShotcueRecord` extension'ında bir kez `.timeIntervalSince1970` olarak verilir. Gerekçe: GRDB'nin varsayılanı olan `"YYYY-MM-DD HH:MM:SS.SSS"` metni milisaniyeye yuvarlar, bu da model round-trip testlerini (`#expect(decoded == original)`) kırar; `.iso8601` ise saniyeye yuvarlar. `Double` tam yuvarlak dönüş verir, `ORDER BY` doğal olarak sıralanır ve `markInterruptedRuns` gibi yerlerde `Column.set(to: now.timeIntervalSince1970)` ile doğrudan yazılabilir.

**Karar — Türkçe arama:** SQLite'ın `lower()` ve `LIKE`'ı yalnızca ASCII harflerde büyük/küçük harf katlaması yapar, dolayısıyla `İ`, `ı`, `Ş`, `Ğ`, `Ü`, `Ö`, `Ç` için arama çalışmaz. Çözüm: `shotcue_fold` adında özel bir SQL fonksiyonu her bağlantıya kaydedilir (`Configuration.prepareDatabase`) ve `SearchText.normalized(_:)` ile hem kolon hem sorgu tarafı aynı şekilde normalize edilir. Normalizasyon Türkçe noktasız `ı` ve noktalı `İ`'yi düz `i`'ye indirir, ardından `folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])` uygular. Bu, büyük/küçük harf duyarsızlığını **aksan duyarsızlığıyla birlikte** verir: `"ÖNBELLEĞİ"` ↔ `"önbelleği"` ↔ `"onbellegi"`, `"IŞIK"` ↔ `"ışık"`, `"LOGIN"` ↔ `"login"`. Bu bilinçli bir üst-küme; `InMemoryTaskRepository` (Plan 00) sade `lowercased()` kullanır, bu yüzden Task 7'deki eşitlik testi ASCII sorgu terimleriyle çalışır ve fark Task 7'de açıkça yazılıdır.

**Bilinen ortam tuzağı:** CLT 27 + SwiftPM'in `swiftbuild` build sistemi, artımlı derlemede bazen `external macro implementation type 'TestingMacros.SuiteDeclarationMacro' could not be found` hatası verir. Bu bir kod hatası **değildir**; `swift test`'i tekrar çalıştırmak ya da `rm -rf .build/out .build/manifest.pif .build/debug && swift test` düzeltir. Testler kırmızıysa önce bunu ele.

---

### Task 1: AppDatabase, migration v1 ve Türkçe arama fonksiyonu

**Files:**
- Create: `Sources/ShotcuePersistence/SearchText.swift`
- Create: `Sources/ShotcuePersistence/Migrations.swift`
- Create: `Sources/ShotcuePersistence/AppDatabase.swift`
- Create: `Tests/ShotcuePersistenceTests/TestPaths.swift`
- Test: `Tests/ShotcuePersistenceTests/AppDatabaseTests.swift`

**Interfaces:**
- Consumes: `FileStore(rootURL: URL)` ve `FileStore.databaseURL` (Plan 00 Task 9; test `AppDatabase.open(at:)`'e verilecek URL'i bununla kurar). Başka Core API'si kullanılmaz.
- Produces:
  - `public final class AppDatabase: Sendable`
  - `public static func open(at url: URL) throws -> AppDatabase` — üst dizinleri yaratır, WAL modunda `DatabasePool` açar, migration'ları uygular.
  - `public static func inMemory() throws -> AppDatabase` — testler için `DatabaseQueue`, migration'lar uygulanmış.
  - `public let writer: any DatabaseWriter`
  - `public var reader: any DatabaseReader { writer }`
  - `static var migrator: DatabaseMigrator` (internal; testler `@testable import` ile görür)
  - `enum SearchText { static func normalized(_ text: String) -> String }` (internal)
  - `enum SQLFunctions { static let fold: DatabaseFunction }` (internal, SQL adı `shotcue_fold`)

- [ ] **Step 1: TestPaths helper'ını kopyala**

`Tests/ShotcuePersistenceTests/TestPaths.swift` (Plan 00 Task 0'daki dosyanın birebir kopyası; her test target'ında ayrı bir kopya olur):

```swift
import Foundation

enum TestPaths {
    /// Tests/Fixtures dizini. Her test target'ı Tests/<Target>Tests/ altında olduğu için iki üst dizin.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestPaths.swift
            .deletingLastPathComponent()   // <Target>Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
}
```

- [ ] **Step 2: Başarısız testi yaz**

`Tests/ShotcuePersistenceTests/AppDatabaseTests.swift`:

```swift
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
                result[table] = try Row
                    .fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
            }
            return result
        }
        #expect(columns["project"] == ["id", "name", "path", "default_mode", "default_model",
                                       "default_effort", "daily_time", "daily_enabled",
                                       "daily_last_fired_at", "run_in_branch", "stash_before_run",
                                       "sort_index", "created_at"])
        #expect(columns["task"] == ["id", "project_id", "title", "title_edited_by_user", "note_text",
                                    "status", "mode", "model_override", "sort_index", "scheduled_at",
                                    "created_at", "updated_at"])
        #expect(columns["capture"] == ["id", "task_id", "rel_path", "thumb_rel_path", "width",
                                       "height", "scale", "created_at"])
        #expect(columns["voice_note"] == ["id", "task_id", "rel_path", "duration_sec", "transcript",
                                          "transcript_json", "transcript_state", "engine",
                                          "edited_by_user", "created_at"])
        #expect(columns["run"] == ["id", "task_id", "state", "started_at", "finished_at", "num_turns",
                                   "cost_usd", "result_text", "subtype", "exit_code", "error",
                                   "log_rel_path", "git_head_before", "git_dirty_before",
                                   "git_head_after", "git_branch"])
    }

    @Test func specIndexesExist() async throws {
        let database = try AppDatabase.inMemory()
        let names = try await database.reader.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'")
        }
        #expect(Set(names) == ["task_on_project_id_status", "task_on_scheduled_at",
                               "capture_on_task_id", "voice_note_on_task_id",
                               "run_on_task_id_started_at"])
    }

    @Test func foreignKeysAreEnabled() async throws {
        let database = try AppDatabase.inMemory()
        let enabled = try await database.reader.read { db -> Bool in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
        }
        #expect(enabled)
        let orphanAccepted = try await database.writer.write { db -> Bool in
            do {
                try db.execute(sql: """
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
```

- [ ] **Step 3: Testin derlenmediğini gör**

Run: `make test FILTER=AppDatabaseTests 2>&1 | grep -m3 "error:"`
Expected: `cannot find 'AppDatabase' in scope` ve `cannot find 'SearchText' in scope`.

- [ ] **Step 4: SearchText.swift'i yaz**

`Sources/ShotcuePersistence/SearchText.swift`:

```swift
import Foundation
import GRDB

/// Normalisation used by `GRDBTaskRepository.search(_:)` on both sides of the LIKE
/// comparison. SQLite's built-in `lower()` and `LIKE` fold ASCII only, so Turkish
/// letters would never match case-insensitively.
enum SearchText {
    /// Case- and diacritic-insensitive form. The two `replacingOccurrences` calls map
    /// the Turkish dotless "ı" and the ASCII "I" onto "i" before folding, because
    /// `.diacriticInsensitive` leaves U+0131 (ı) alone while turning "İ" into "I".
    /// Examples: "ÖNBELLEĞİ" -> "onbellegi", "IŞIK" -> "isik", "LOGIN" -> "login".
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "I", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }
}

/// Custom SQL functions registered on every connection by `AppDatabase.configuration`.
enum SQLFunctions {
    /// `shotcue_fold(text)` — the SQL-side counterpart of `SearchText.normalized(_:)`.
    static let fold = DatabaseFunction("shotcue_fold", argumentCount: 1, pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]) else { return nil }
        return SearchText.normalized(text)
    }
}
```

- [ ] **Step 5: Migrations.swift'i yaz**

`Sources/ShotcuePersistence/Migrations.swift` (spec §6.3 tabloları ve indeksleri; `id` kolonları küçük harfli UUID metni, tarihler `Double` saniye):

```swift
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
            try db.create(index: "task_on_project_id_status", on: "task",
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
            try db.create(index: "run_on_task_id_started_at", on: "run",
                          columns: ["task_id", "started_at"])
        }

        return migrator
    }
}
```

- [ ] **Step 6: AppDatabase.swift'i yaz**

`Sources/ShotcuePersistence/AppDatabase.swift`:

```swift
import Foundation
import GRDB

/// Owns the SQLite connection for the whole app. `open(at:)` is used by the app
/// (WAL `DatabasePool`, concurrent reads); `inMemory()` is used by tests.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Foreign keys on (GRDB's default) plus the `shotcue_fold` SQL function on
    /// every connection, including the ones a `DatabasePool` opens lazily for reads.
    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: SQLFunctions.fold)
        }
        return config
    }

    /// Opens (creating if needed) the database at `url`, creating its parent directory,
    /// switching the journal to WAL and running every pending migration.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var config = configuration
        config.journalMode = .wal
        let pool = try DatabasePool(path: url.path, configuration: config)
        try migrator.migrate(pool)
        return AppDatabase(writer: pool)
    }

    /// A private in-memory database with the same schema. Every call returns a fresh one.
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue)
        return AppDatabase(writer: queue)
    }
}
```

- [ ] **Step 7: Testleri çalıştır**

Run: `make test FILTER=AppDatabaseTests 2>&1 | tail -3`
Expected: `Test run with 8 tests … passed`. `TestingMacros … not found` çıkarsa komutu bir kez daha çalıştır (yukarıdaki "Bilinen ortam tuzağı").

- [ ] **Step 8: Commit**

```bash
make format && git add Sources/ShotcuePersistence/SearchText.swift \
  Sources/ShotcuePersistence/Migrations.swift \
  Sources/ShotcuePersistence/AppDatabase.swift \
  Tests/ShotcuePersistenceTests/TestPaths.swift \
  Tests/ShotcuePersistenceTests/AppDatabaseTests.swift
git commit -m "feat(persistence): add AppDatabase, schema migration v1 and Turkish text folding

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Kayıt tipleri ve model dönüşümleri

**Files:**
- Create: `Sources/ShotcuePersistence/Records/ShotcueRecord.swift`
- Create: `Sources/ShotcuePersistence/Records/ProjectRecord.swift`
- Create: `Sources/ShotcuePersistence/Records/TaskRecord.swift`
- Create: `Sources/ShotcuePersistence/Records/CaptureRecord.swift`
- Create: `Sources/ShotcuePersistence/Records/VoiceNoteRecord.swift`
- Create: `Sources/ShotcuePersistence/Records/RunRecord.swift`
- Test: `Tests/ShotcuePersistenceTests/RecordRoundTripTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 1 ve Task 9'daki imzalar birebir):
  - `Project(id:name:path:defaultMode:defaultModel:defaultEffort:dailyTime:dailyEnabled:dailyLastFiredAt:runInBranch:stashBeforeRun:sortIndex:createdAt:)`, alanları `id: UUID, name: String, path: String, defaultMode: TaskMode, defaultModel: String?, defaultEffort: String?, dailyTime: DailyTime?, dailyEnabled: Bool, dailyLastFiredAt: Date?, runInBranch: Bool, stashBeforeRun: Bool, sortIndex: Double, createdAt: Date`
  - `DailyTime(hour:minute:)`, `DailyTime(parsing: String)`, `DailyTime.formatted -> String`
  - `ShotTask(id:projectID:title:noteText:status:mode:modelOverride:sortIndex:scheduledAt:titleEditedByUser:createdAt:updatedAt:)`
  - `Capture(id:taskID:relPath:thumbRelPath:width:height:scale:createdAt:)`
  - `VoiceNote(id:taskID:relPath:durationSec:transcript:transcriptJSON:transcriptState:engine:editedByUser:createdAt:)`
  - `Run(id:taskID:state:startedAt:finishedAt:numTurns:costUSD:resultText:subtype:exitCode:error:logRelPath:gitHeadBefore:gitDirtyBefore:gitHeadAfter:gitBranch:)`
  - `TaskMode` (`analyze`, `implement`), `TaskStatus` (`inbox, ready, queued, scheduled, running, done, failed, cancelled`), `RunState` (`starting, running, succeeded, failed, cancelled`), `TranscriptState` (`pending, done, failed`) — hepsi `String` rawValue'lu
  - `FileStore(rootURL:)`, `FileStore.captureRelPath(id:date:calendar:)`, `FileStore.absoluteURL(for:)`, `FileStore.relativePath(for:)`, `FileStore.ensureDirectories()`, `FileStore.ensureParentDirectory(for:)`
- Produces (hepsi internal; testler `@testable import` ile görür):
  - `protocol ShotcueRecord: Codable, FetchableRecord, PersistableRecord, Sendable` + `Date` kodlama/çözme stratejisi
  - `extension UUID { var dbKey: String }` — küçük harfli UUID metni
  - `ProjectRecord(_ project: Project)` / `var model: Project`
  - `TaskRecord(_ task: ShotTask)` / `var model: ShotTask` / `static func ordered() -> QueryInterfaceRequest<TaskRecord>`
  - `CaptureRecord(_ capture: Capture)` / `var model: Capture`
  - `VoiceNoteRecord(_ note: VoiceNote)` / `var model: VoiceNote`
  - `RunRecord(_ run: Run)` / `var model: Run`
  - her kayıtta `enum Columns` (kullanılan kolonlar `Column(CodingKeys.x)` ile)

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcuePersistenceTests/RecordRoundTripTests.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore
import Testing
@testable import ShotcuePersistence

@Suite("Record round trips")
struct RecordRoundTripTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)   // 2025-09-22 00:13:20 UTC
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func projectRecordRoundTrips() async throws {
        let database = try AppDatabase.inMemory()
        let project = Project(name: "crm", path: "/Users/me/Projects/crm", defaultMode: .analyze,
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
            try ProjectRecord(Project(id: id, name: "p", path: "/tmp/p", sortIndex: 1024,
                                      createdAt: epoch)).upsert(db)
            return try String.fetchOne(db, sql: "SELECT id FROM project") ?? ""
        }
        #expect(stored == "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
    }

    @Test func datesAreStoredAsSecondsSince1970() async throws {
        let database = try AppDatabase.inMemory()
        let seconds = try await database.writer.write { db -> Double in
            try ProjectRecord(Project(name: "p", path: "/tmp/p", sortIndex: 1024,
                                      createdAt: epoch)).upsert(db)
            return try Double.fetchOne(db, sql: "SELECT created_at FROM project") ?? 0
        }
        #expect(seconds == 1_758_500_000)
    }

    @Test func enumsAreStoredAsRawValues() async throws {
        let database = try AppDatabase.inMemory()
        let row = try await database.writer.write { db -> [String] in
            try TaskRecord(ShotTask(title: "t", status: .scheduled, mode: .analyze,
                                    sortIndex: 1024, createdAt: epoch, updatedAt: epoch)).upsert(db)
            let row = try #require(try Row.fetchOne(db, sql: "SELECT status, mode FROM task"))
            return [row["status"] as String? ?? "", row["mode"] as String? ?? ""]
        }
        #expect(row == ["scheduled", "analyze"])
    }

    @Test func taskCaptureVoiceNoteAndRunRoundTrip() async throws {
        let database = try AppDatabase.inMemory()
        let project = Project(name: "crm", path: "/tmp/crm", sortIndex: 1024, createdAt: epoch)
        let task = ShotTask(projectID: project.id, title: "Önbelleği temizle", noteText: "Şu BUTON",
                            status: .ready, mode: .implement, modelOverride: "sonnet",
                            sortIndex: 2048, scheduledAt: epoch, titleEditedByUser: true,
                            createdAt: epoch, updatedAt: epoch)
        let capture = Capture(taskID: task.id, relPath: "captures/2026/09/a.png",
                              thumbRelPath: "thumbs/a.jpg", width: 1200, height: 800, scale: 2,
                              createdAt: epoch)
        let note = VoiceNote(taskID: task.id, relPath: "audio/a.m4a", durationSec: 4.25,
                             transcript: "Önbelleği TEMİZLE", transcriptJSON: "{\"text\":\"x\"}",
                             transcriptState: .done, engine: "whisperkit/turbo", editedByUser: true,
                             createdAt: epoch)
        let run = Run(taskID: task.id, state: .succeeded, startedAt: epoch,
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
        let capture = Capture(taskID: task.id, relPath: "captures/a.png", width: 10, height: 10,
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
        try FileManager.default.copyItem(at: TestPaths.fixture("sample.png"),
                                         to: store.absoluteURL(for: relPath))

        let stored = try await database.writer.write { db -> Capture in
            try TaskRecord(task).upsert(db)
            try CaptureRecord(Capture(id: captureID, taskID: task.id, relPath: relPath,
                                      width: 8, height: 8, createdAt: epoch)).upsert(db)
            return try #require(try CaptureRecord.fetchOne(db, key: captureID.dbKey)).model
        }
        #expect(stored.relPath == relPath)
        #expect(stored.relPath.hasPrefix("captures/2025/09/"))
        #expect(store.relativePath(for: store.absoluteURL(for: relPath)) == relPath)
        #expect(FileManager.default.fileExists(atPath: store.absoluteURL(for: relPath).path))
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=RecordRoundTripTests 2>&1 | grep -m3 "error:"`
Expected: `cannot find 'ProjectRecord' in scope`, `cannot find 'TaskRecord' in scope`, `value of type 'UUID' has no member 'dbKey'`.

- [ ] **Step 3: ShotcueRecord.swift'i yaz**

`Sources/ShotcuePersistence/Records/ShotcueRecord.swift`:

```swift
import Foundation
import GRDB

/// Shared conformance for every row type in this module. Records are plain `Sendable`
/// structs whose `CodingKeys` carry the snake_case column names, so the column mapping
/// lives in exactly one place per table.
protocol ShotcueRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

extension ShotcueRecord {
    /// Dates are stored as Double seconds since 1970 in every table. GRDB's default
    /// ("YYYY-MM-DD HH:MM:SS.SSS") truncates to milliseconds, which breaks exact
    /// round trips; Double round trips exactly and still sorts with ORDER BY.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension UUID {
    /// Primary and foreign keys are stored as lowercase UUID strings.
    var dbKey: String { uuidString.lowercased() }
}
```

- [ ] **Step 4: ProjectRecord.swift'i yaz**

`Sources/ShotcuePersistence/Records/ProjectRecord.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

struct ProjectRecord: ShotcueRecord {
    static let databaseTableName = "project"

    var id: String
    var name: String
    var path: String
    var defaultMode: String
    var defaultModel: String?
    var defaultEffort: String?
    var dailyTime: String?
    var dailyEnabled: Bool
    var dailyLastFiredAt: Date?
    var runInBranch: Bool
    var stashBeforeRun: Bool
    var sortIndex: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case defaultMode = "default_mode"
        case defaultModel = "default_model"
        case defaultEffort = "default_effort"
        case dailyTime = "daily_time"
        case dailyEnabled = "daily_enabled"
        case dailyLastFiredAt = "daily_last_fired_at"
        case runInBranch = "run_in_branch"
        case stashBeforeRun = "stash_before_run"
        case sortIndex = "sort_index"
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let sortIndex = Column(CodingKeys.sortIndex)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ project: Project) {
        id = project.id.dbKey
        name = project.name
        path = project.path
        defaultMode = project.defaultMode.rawValue
        defaultModel = project.defaultModel
        defaultEffort = project.defaultEffort
        dailyTime = project.dailyTime?.formatted
        dailyEnabled = project.dailyEnabled
        dailyLastFiredAt = project.dailyLastFiredAt
        runInBranch = project.runInBranch
        stashBeforeRun = project.stashBeforeRun
        sortIndex = project.sortIndex
        createdAt = project.createdAt
    }

    var model: Project {
        Project(id: UUID(uuidString: id) ?? UUID(),
                name: name,
                path: path,
                defaultMode: TaskMode(rawValue: defaultMode) ?? .implement,
                defaultModel: defaultModel,
                defaultEffort: defaultEffort,
                dailyTime: dailyTime.flatMap(DailyTime.init(parsing:)),
                dailyEnabled: dailyEnabled,
                dailyLastFiredAt: dailyLastFiredAt,
                runInBranch: runInBranch,
                stashBeforeRun: stashBeforeRun,
                sortIndex: sortIndex,
                createdAt: createdAt)
    }

    /// Projects are shown in manual order; `created_at` breaks ties deterministically.
    static func ordered() -> QueryInterfaceRequest<ProjectRecord> {
        ProjectRecord.order(Columns.sortIndex, Columns.createdAt)
    }
}
```

- [ ] **Step 5: TaskRecord.swift'i yaz**

`Sources/ShotcuePersistence/Records/TaskRecord.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

struct TaskRecord: ShotcueRecord {
    static let databaseTableName = "task"

    var id: String
    var projectId: String?
    var title: String
    var titleEditedByUser: Bool
    var noteText: String
    var status: String
    var mode: String
    var modelOverride: String?
    var sortIndex: Double
    var scheduledAt: Date?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case title
        case titleEditedByUser = "title_edited_by_user"
        case noteText = "note_text"
        case status
        case mode
        case modelOverride = "model_override"
        case sortIndex = "sort_index"
        case scheduledAt = "scheduled_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let projectId = Column(CodingKeys.projectId)
        static let title = Column(CodingKeys.title)
        static let noteText = Column(CodingKeys.noteText)
        static let status = Column(CodingKeys.status)
        static let sortIndex = Column(CodingKeys.sortIndex)
        static let scheduledAt = Column(CodingKeys.scheduledAt)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ task: ShotTask) {
        id = task.id.dbKey
        projectId = task.projectID?.dbKey
        title = task.title
        titleEditedByUser = task.titleEditedByUser
        noteText = task.noteText
        status = task.status.rawValue
        mode = task.mode.rawValue
        modelOverride = task.modelOverride
        sortIndex = task.sortIndex
        scheduledAt = task.scheduledAt
        createdAt = task.createdAt
        updatedAt = task.updatedAt
    }

    var model: ShotTask {
        ShotTask(id: UUID(uuidString: id) ?? UUID(),
                 projectID: projectId.flatMap(UUID.init(uuidString:)),
                 title: title,
                 noteText: noteText,
                 status: TaskStatus(rawValue: status) ?? .inbox,
                 mode: TaskMode(rawValue: mode) ?? .implement,
                 modelOverride: modelOverride,
                 sortIndex: sortIndex,
                 scheduledAt: scheduledAt,
                 titleEditedByUser: titleEditedByUser,
                 createdAt: createdAt,
                 updatedAt: updatedAt)
    }

    /// Manual order (`QueuePolicy.ordered` in Core uses the same rule: sortIndex, then createdAt).
    static func ordered() -> QueryInterfaceRequest<TaskRecord> {
        TaskRecord.order(Columns.sortIndex, Columns.createdAt)
    }
}
```

- [ ] **Step 6: CaptureRecord.swift ve VoiceNoteRecord.swift'i yaz**

`Sources/ShotcuePersistence/Records/CaptureRecord.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

struct CaptureRecord: ShotcueRecord {
    static let databaseTableName = "capture"

    var id: String
    var taskId: String
    var relPath: String
    var thumbRelPath: String?
    var width: Int
    var height: Int
    var scale: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case relPath = "rel_path"
        case thumbRelPath = "thumb_rel_path"
        case width
        case height
        case scale
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskId = Column(CodingKeys.taskId)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ capture: Capture) {
        id = capture.id.dbKey
        taskId = capture.taskID.dbKey
        relPath = capture.relPath
        thumbRelPath = capture.thumbRelPath
        width = capture.width
        height = capture.height
        scale = capture.scale
        createdAt = capture.createdAt
    }

    var model: Capture {
        Capture(id: UUID(uuidString: id) ?? UUID(),
                taskID: UUID(uuidString: taskId) ?? UUID(),
                relPath: relPath,
                thumbRelPath: thumbRelPath,
                width: width,
                height: height,
                scale: scale,
                createdAt: createdAt)
    }
}
```

`Sources/ShotcuePersistence/Records/VoiceNoteRecord.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

struct VoiceNoteRecord: ShotcueRecord {
    static let databaseTableName = "voice_note"

    var id: String
    var taskId: String
    var relPath: String
    var durationSec: Double
    var transcript: String?
    var transcriptJson: String?
    var transcriptState: String
    var engine: String?
    var editedByUser: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case relPath = "rel_path"
        case durationSec = "duration_sec"
        case transcript
        case transcriptJson = "transcript_json"
        case transcriptState = "transcript_state"
        case engine
        case editedByUser = "edited_by_user"
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskId = Column(CodingKeys.taskId)
        static let transcript = Column(CodingKeys.transcript)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ note: VoiceNote) {
        id = note.id.dbKey
        taskId = note.taskID.dbKey
        relPath = note.relPath
        durationSec = note.durationSec
        transcript = note.transcript
        transcriptJson = note.transcriptJSON
        transcriptState = note.transcriptState.rawValue
        engine = note.engine
        editedByUser = note.editedByUser
        createdAt = note.createdAt
    }

    var model: VoiceNote {
        VoiceNote(id: UUID(uuidString: id) ?? UUID(),
                  taskID: UUID(uuidString: taskId) ?? UUID(),
                  relPath: relPath,
                  durationSec: durationSec,
                  transcript: transcript,
                  transcriptJSON: transcriptJson,
                  transcriptState: TranscriptState(rawValue: transcriptState) ?? .pending,
                  engine: engine,
                  editedByUser: editedByUser,
                  createdAt: createdAt)
    }
}
```

- [ ] **Step 7: RunRecord.swift'i yaz**

`Sources/ShotcuePersistence/Records/RunRecord.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

struct RunRecord: ShotcueRecord {
    static let databaseTableName = "run"

    var id: String
    var taskId: String
    var state: String
    var startedAt: Date
    var finishedAt: Date?
    var numTurns: Int?
    var costUsd: Double?
    var resultText: String?
    var subtype: String?
    var exitCode: Int32?
    var error: String?
    var logRelPath: String
    var gitHeadBefore: String?
    var gitDirtyBefore: Bool?
    var gitHeadAfter: String?
    var gitBranch: String?

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case state
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case numTurns = "num_turns"
        case costUsd = "cost_usd"
        case resultText = "result_text"
        case subtype
        case exitCode = "exit_code"
        case error
        case logRelPath = "log_rel_path"
        case gitHeadBefore = "git_head_before"
        case gitDirtyBefore = "git_dirty_before"
        case gitHeadAfter = "git_head_after"
        case gitBranch = "git_branch"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskId = Column(CodingKeys.taskId)
        static let state = Column(CodingKeys.state)
        static let startedAt = Column(CodingKeys.startedAt)
        static let finishedAt = Column(CodingKeys.finishedAt)
        static let error = Column(CodingKeys.error)
    }

    /// The two states a run can be in while its process is alive.
    static let activeStates = [RunState.starting.rawValue, RunState.running.rawValue]

    init(_ run: Run) {
        id = run.id.dbKey
        taskId = run.taskID.dbKey
        state = run.state.rawValue
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        numTurns = run.numTurns
        costUsd = run.costUSD
        resultText = run.resultText
        subtype = run.subtype
        exitCode = run.exitCode
        error = run.error
        logRelPath = run.logRelPath
        gitHeadBefore = run.gitHeadBefore
        gitDirtyBefore = run.gitDirtyBefore
        gitHeadAfter = run.gitHeadAfter
        gitBranch = run.gitBranch
    }

    var model: Run {
        Run(id: UUID(uuidString: id) ?? UUID(),
            taskID: UUID(uuidString: taskId) ?? UUID(),
            state: RunState(rawValue: state) ?? .starting,
            startedAt: startedAt,
            finishedAt: finishedAt,
            numTurns: numTurns,
            costUSD: costUsd,
            resultText: resultText,
            subtype: subtype,
            exitCode: exitCode,
            error: error,
            logRelPath: logRelPath,
            gitHeadBefore: gitHeadBefore,
            gitDirtyBefore: gitDirtyBefore,
            gitHeadAfter: gitHeadAfter,
            gitBranch: gitBranch)
    }
}
```

- [ ] **Step 8: Testleri çalıştır**

Run: `make test FILTER=RecordRoundTripTests 2>&1 | tail -3`
Expected: `Test run with 7 tests … passed`.

- [ ] **Step 9: Commit**

```bash
make format && git add Sources/ShotcuePersistence/Records Tests/ShotcuePersistenceTests/RecordRoundTripTests.swift
git commit -m "feat(persistence): add GRDB record types and model conversions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: GRDBProjectRepository ve observation köprüsü

**Files:**
- Create: `Sources/ShotcuePersistence/ObservationBridge.swift`
- Create: `Sources/ShotcuePersistence/GRDBProjectRepository.swift`
- Test: `Tests/ShotcuePersistenceTests/GRDBProjectRepositoryTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10, `Sources/ShotcueCore/Services/Repositories.swift`; imzalar birebir):
  ```swift
  public protocol ProjectRepository: Sendable {
      func allProjects() async throws -> [Project]
      func project(id: UUID) async throws -> Project?
      func save(_ project: Project) async throws
      func deleteProject(id: UUID) async throws
      /// Emits the full list now and after every change.
      func observeProjects() -> AsyncStream<[Project]>
  }
  ```
  Ayrıca `AppDatabase` (Task 1), `ProjectRecord` / `TaskRecord` / `UUID.dbKey` (Task 2), `Project`, `DailyTime` (Plan 00 Task 1).
- Produces:
  - `public final class GRDBProjectRepository: ProjectRepository, Sendable` — `public init(database: AppDatabase)`
  - `enum ObservationBridge { static func stream<Value: Sendable>(_ observation: ValueObservation<ValueReducers.Fetch<Value>>, in reader: any DatabaseReader) -> AsyncStream<Value> }` (internal; Task 4 ve Task 5 aynı fonksiyonu kullanır)

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcuePersistenceTests/GRDBProjectRepositoryTests.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore
import Testing
@testable import ShotcuePersistence

@Suite("GRDBProjectRepository")
struct GRDBProjectRepositoryTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    func project(_ name: String, sort: Double, created: TimeInterval = 0) -> Project {
        Project(name: name, path: "/tmp/\(name)", sortIndex: sort,
                createdAt: epoch.addingTimeInterval(created))
    }

    @Test func allProjectsOrdersBySortIndexThenCreatedAt() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        let late = project("late", sort: 2048)
        let tie2 = project("tie2", sort: 1024, created: 5)
        let tie1 = project("tie1", sort: 1024, created: 1)
        for candidate in [late, tie2, tie1] { try await repository.save(candidate) }
        #expect(try await repository.allProjects().map(\.name) == ["tie1", "tie2", "late"])
    }

    @Test func getReturnsNilForUnknownID() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        #expect(try await repository.project(id: UUID()) == nil)
    }

    @Test func saveUpsertsInsteadOfDuplicating() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        var value = project("crm", sort: 1024)
        try await repository.save(value)
        value.name = "crm-renamed"
        value.dailyTime = DailyTime(hour: 7, minute: 5)
        value.dailyEnabled = true
        try await repository.save(value)
        let all = try await repository.allProjects()
        #expect(all.count == 1)
        #expect(all.first?.name == "crm-renamed")
        #expect(all.first?.dailyTime == DailyTime(hour: 7, minute: 5))
        #expect(all.first?.dailyEnabled == true)
    }

    @Test func deleteRemovesTheRowAndNullsTaskProjectID() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBProjectRepository(database: database)
        let value = project("crm", sort: 1024)
        try await repository.save(value)
        let task = ShotTask(projectID: value.id, title: "t", status: .ready, sortIndex: 1024,
                            createdAt: epoch, updatedAt: epoch)
        try await database.writer.write { db in try TaskRecord(task).upsert(db) }
        try await repository.deleteProject(id: value.id)
        #expect(try await repository.allProjects().isEmpty)
        let orphaned = try await database.reader.read { db in
            try #require(try TaskRecord.fetchOne(db, key: task.id.dbKey)).model
        }
        #expect(orphaned.projectID == nil)
    }

    @Test func observeProjectsEmitsCurrentValueThenChanges() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        try await repository.save(project("first", sort: 1024))
        var iterator = repository.observeProjects().makeAsyncIterator()
        #expect(await iterator.next()?.map(\.name) == ["first"])
        try await repository.save(project("second", sort: 2048))
        #expect(await iterator.next()?.map(\.name) == ["first", "second"])
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=GRDBProjectRepositoryTests 2>&1 | grep -m3 "error:"`
Expected: `cannot find 'GRDBProjectRepository' in scope`.

- [ ] **Step 3: ObservationBridge.swift'i yaz**

`Sources/ShotcuePersistence/ObservationBridge.swift`:

```swift
import Foundation
import GRDB

/// Adapts GRDB's throwing `AsyncValueObservation` to the non-throwing `AsyncStream`
/// the Core repository protocols expose. The stream yields the current value first
/// (GRDB's initial fetch) and then one value per committed change.
enum ObservationBridge {
    static func stream<Value: Sendable>(
        _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
        in reader: any DatabaseReader
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: reader) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    // A failing observation (database closed, schema gone) ends the
                    // stream; UI stores treat a finished stream as "no more updates".
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: GRDBProjectRepository.swift'i yaz**

`Sources/ShotcuePersistence/GRDBProjectRepository.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

public final class GRDBProjectRepository: ProjectRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Single source of truth for the ordering, shared by the fetch and the observation.
    private static func fetchAll(_ db: Database) throws -> [Project] {
        try ProjectRecord.ordered().fetchAll(db).map(\.model)
    }

    public func allProjects() async throws -> [Project] {
        try await database.reader.read { db in try Self.fetchAll(db) }
    }

    public func project(id: UUID) async throws -> Project? {
        try await database.reader.read { db in
            try ProjectRecord.fetchOne(db, key: id.dbKey)?.model
        }
    }

    public func save(_ project: Project) async throws {
        let record = ProjectRecord(project)
        try await database.writer.write { db in try record.upsert(db) }
    }

    /// The `task.project_id` foreign key is ON DELETE SET NULL, so the project's tasks
    /// fall back to the inbox instead of disappearing.
    public func deleteProject(id: UUID) async throws {
        _ = try await database.writer.write { db in
            try ProjectRecord.deleteOne(db, key: id.dbKey)
        }
    }

    public func observeProjects() -> AsyncStream<[Project]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetchAll(db) },
            in: database.reader)
    }
}
```

- [ ] **Step 5: Testleri çalıştır**

Run: `make test FILTER=GRDBProjectRepositoryTests 2>&1 | tail -3`
Expected: `Test run with 5 tests … passed`.

- [ ] **Step 6: Commit**

```bash
make format && git add Sources/ShotcuePersistence/ObservationBridge.swift \
  Sources/ShotcuePersistence/GRDBProjectRepository.swift \
  Tests/ShotcuePersistenceTests/GRDBProjectRepositoryTests.swift
git commit -m "feat(persistence): add GRDB project repository and ValueObservation bridge

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: GRDBTaskRepository

**Files:**
- Create: `Sources/ShotcuePersistence/GRDBTaskRepository.swift`
- Test: `Tests/ShotcuePersistenceTests/GRDBTaskRepositoryTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10; imzalar birebir):
  ```swift
  public protocol TaskRepository: Sendable {
      func allTasks() async throws -> [ShotTask]
      func task(id: UUID) async throws -> ShotTask?
      /// `projectID == nil` → inbox (tasks without a project).
      func tasks(projectID: UUID?) async throws -> [ShotTask]
      func tasks(status: TaskStatus) async throws -> [ShotTask]
      func save(_ task: ShotTask) async throws
      /// Deletes the task and its captures/voice notes rows (files are the caller's job).
      func deleteTask(id: UUID) async throws
      func captures(taskID: UUID) async throws -> [Capture]
      func save(_ capture: Capture) async throws
      func moveCaptures(ids: [UUID], toTaskID: UUID) async throws
      func voiceNotes(taskID: UUID) async throws -> [VoiceNote]
      func save(_ voiceNote: VoiceNote) async throws
      /// Case-insensitive substring search over title, noteText and voice transcripts.
      func search(_ query: String) async throws -> [ShotTask]
      func observeAllTasks() -> AsyncStream<[ShotTask]>
      func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]>
  }
  ```
  Ayrıca `AppDatabase` (Task 1), `TaskRecord`/`CaptureRecord`/`VoiceNoteRecord`/`RunRecord`/`UUID.dbKey` (Task 2), `ObservationBridge.stream(_:in:)` ve `GRDBProjectRepository(database:)` (Task 3), `SearchText.normalized(_:)` (Task 1).
- Produces:
  - `public final class GRDBTaskRepository: TaskRepository, Sendable` — `public init(database: AppDatabase)`
  - `static func searchRequest(_ query: String) -> SQLRequest<TaskRecord>?` (internal; boş/yalnız-boşluk sorguda `nil`)

**Davranış notları (testlerin doğruladığı):**
- `tasks(projectID: nil)` → `WHERE project_id IS NULL` (GRDB `Column == nil` bunu üretir).
- Sıralama her yerde `sort_index, created_at`.
- `capture` ve `voice_note` listeleri `created_at` artan.
- `deleteTask` yalnızca `task` satırını siler; `capture`, `voice_note` ve `run` satırlarını SQLite CASCADE düşürür.
- `moveCaptures` tek `UPDATE … WHERE id IN (…)` ifadesiyle, dolayısıyla tek transaction'da çalışır.
- `save(_ task:)` bir `ShotTask`'ı projesine bağlıyorsa o proje satırı **önceden var olmalıdır** (`task.project_id` foreign key'i). Bu, `InMemoryTaskRepository`'de olmayan gerçek bir kısıttır; Plan 05/06 task'ı projeye atarken projeyi önce kaydeder.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcuePersistenceTests/GRDBTaskRepositoryTests.swift`:

```swift
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
        return Fixture(database: database,
                       projects: GRDBProjectRepository(database: database),
                       tasks: GRDBTaskRepository(database: database))
    }

    @Test func inboxIsTasksWithNullProject() async throws {
        let fixture = try makeFixture()
        let project = Project(name: "crm", path: "/tmp/crm", sortIndex: 1024, createdAt: epoch)
        try await fixture.projects.save(project)
        let inbox = ShotTask(title: "inbox", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        let assigned = ShotTask(projectID: project.id, title: "assigned", status: .ready,
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
        let readyLate = ShotTask(title: "ready-late", status: .ready, sortIndex: 3072,
                                 createdAt: epoch, updatedAt: epoch)
        let readyTie2 = ShotTask(title: "ready-tie2", status: .ready, sortIndex: 1024,
                                 createdAt: epoch.addingTimeInterval(9), updatedAt: epoch)
        let readyTie1 = ShotTask(title: "ready-tie1", status: .ready, sortIndex: 1024,
                                 createdAt: epoch.addingTimeInterval(1), updatedAt: epoch)
        let done = ShotTask(title: "done", status: .done, sortIndex: 512,
                            createdAt: epoch, updatedAt: epoch)
        for task in [readyLate, readyTie2, readyTie1, done] { try await fixture.tasks.save(task) }
        #expect(try await fixture.tasks.tasks(status: .ready).map(\.title)
                == ["ready-tie1", "ready-tie2", "ready-late"])
        #expect(try await fixture.tasks.tasks(status: .queued).isEmpty)
        #expect(try await fixture.tasks.allTasks().map(\.title)
                == ["done", "ready-tie1", "ready-tie2", "ready-late"])
    }

    @Test func deleteTaskCascadesCapturesVoiceNotesAndRuns() async throws {
        let fixture = try makeFixture()
        let task = ShotTask(title: "t", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try await fixture.tasks.save(task)
        try await fixture.tasks.save(Capture(taskID: task.id, relPath: "captures/a.png",
                                             width: 1, height: 1, createdAt: epoch))
        try await fixture.tasks.save(VoiceNote(taskID: task.id, relPath: "audio/a.m4a",
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
        let first = Capture(taskID: source.id, relPath: "captures/a.png", width: 1, height: 1,
                            createdAt: epoch)
        let second = Capture(taskID: source.id, relPath: "captures/b.png", width: 1, height: 1,
                             createdAt: epoch.addingTimeInterval(1))
        try await fixture.tasks.save(first)
        try await fixture.tasks.save(second)
        try await fixture.tasks.moveCaptures(ids: [first.id, second.id], toTaskID: target.id)
        #expect(try await fixture.tasks.captures(taskID: source.id).isEmpty)
        #expect(try await fixture.tasks.captures(taskID: target.id).map(\.id) == [first.id, second.id])
    }

    @Test func searchCoversTitleNoteAndTranscriptCaseInsensitively() async throws {
        let fixture = try makeFixture()
        let byTitle = ShotTask(title: "Login ekranı bozuk", sortIndex: 1024,
                               createdAt: epoch, updatedAt: epoch)
        let byNote = ShotTask(title: "ikinci", noteText: "Şu BUTON çalışmıyor", sortIndex: 2048,
                              createdAt: epoch, updatedAt: epoch)
        let byTranscript = ShotTask(title: "ucuncu", sortIndex: 3072, createdAt: epoch, updatedAt: epoch)
        let unrelated = ShotTask(title: "alakasiz", sortIndex: 4096, createdAt: epoch, updatedAt: epoch)
        for task in [byTitle, byNote, byTranscript, unrelated] { try await fixture.tasks.save(task) }
        try await fixture.tasks.save(VoiceNote(taskID: byTranscript.id, relPath: "audio/a.m4a",
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
        try await fixture.tasks.save(VoiceNote(taskID: task.id, relPath: "audio/a.m4a", durationSec: 1,
                                               transcript: "cache temizle", transcriptState: .done,
                                               createdAt: epoch))
        try await fixture.tasks.save(VoiceNote(taskID: task.id, relPath: "audio/b.m4a", durationSec: 1,
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
        try await fixture.tasks.save(ShotTask(projectID: project.id, title: "second", status: .ready,
                                              sortIndex: 2048, createdAt: epoch, updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["second"])
        try await fixture.tasks.save(ShotTask(projectID: project.id, title: "first", status: .ready,
                                              sortIndex: 1024, createdAt: epoch, updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["first", "second"])
        try await fixture.tasks.save(ShotTask(title: "inbox", sortIndex: 1, createdAt: epoch,
                                              updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["first", "second"])
    }

    @Test func observeAllTasksEmitsCurrentValueThenChanges() async throws {
        let fixture = try makeFixture()
        var iterator = fixture.tasks.observeAllTasks().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await fixture.tasks.save(ShotTask(title: "x", sortIndex: 1024, createdAt: epoch,
                                              updatedAt: epoch))
        #expect(await iterator.next()?.count == 1)
    }

    @Test func capturesAndVoiceNotesAreOrderedByCreatedAt() async throws {
        let fixture = try makeFixture()
        let task = ShotTask(title: "t", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try await fixture.tasks.save(task)
        let second = Capture(taskID: task.id, relPath: "captures/b.png", width: 1, height: 1,
                             createdAt: epoch.addingTimeInterval(10))
        let first = Capture(taskID: task.id, relPath: "captures/a.png", width: 1, height: 1,
                            createdAt: epoch)
        try await fixture.tasks.save(second)
        try await fixture.tasks.save(first)
        #expect(try await fixture.tasks.captures(taskID: task.id).map(\.relPath)
                == ["captures/a.png", "captures/b.png"])
        let noteLate = VoiceNote(taskID: task.id, relPath: "audio/b.m4a", durationSec: 1,
                                 createdAt: epoch.addingTimeInterval(10))
        let noteEarly = VoiceNote(taskID: task.id, relPath: "audio/a.m4a", durationSec: 1,
                                  createdAt: epoch)
        try await fixture.tasks.save(noteLate)
        try await fixture.tasks.save(noteEarly)
        #expect(try await fixture.tasks.voiceNotes(taskID: task.id).map(\.relPath)
                == ["audio/a.m4a", "audio/b.m4a"])
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=GRDBTaskRepositoryTests 2>&1 | grep -m3 "error:"`
Expected: `cannot find 'GRDBTaskRepository' in scope`.

- [ ] **Step 3: GRDBTaskRepository.swift'i yaz**

`Sources/ShotcuePersistence/GRDBTaskRepository.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

public final class GRDBTaskRepository: TaskRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Shared queries

    private static func fetchAll(_ db: Database) throws -> [ShotTask] {
        try TaskRecord.ordered().fetchAll(db).map(\.model)
    }

    /// `projectID == nil` is the inbox: GRDB turns `Column == nil` into `project_id IS NULL`.
    private static func fetch(_ db: Database, projectID: UUID?) throws -> [ShotTask] {
        let request: QueryInterfaceRequest<TaskRecord>
        if let projectID {
            request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == projectID.dbKey)
        } else {
            request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == nil)
        }
        return try request.fetchAll(db).map(\.model)
    }

    // MARK: - Tasks

    public func allTasks() async throws -> [ShotTask] {
        try await database.reader.read { db in try Self.fetchAll(db) }
    }

    public func task(id: UUID) async throws -> ShotTask? {
        try await database.reader.read { db in try TaskRecord.fetchOne(db, key: id.dbKey)?.model }
    }

    public func tasks(projectID: UUID?) async throws -> [ShotTask] {
        try await database.reader.read { db in try Self.fetch(db, projectID: projectID) }
    }

    public func tasks(status: TaskStatus) async throws -> [ShotTask] {
        try await database.reader.read { db in
            try TaskRecord.ordered()
                .filter(TaskRecord.Columns.status == status.rawValue)
                .fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ task: ShotTask) async throws {
        let record = TaskRecord(task)
        try await database.writer.write { db in try record.upsert(db) }
    }

    /// `capture`, `voice_note` and `run` rows go away through ON DELETE CASCADE.
    /// The files on disk are the caller's job (see `FileStore` in ShotcueCore).
    public func deleteTask(id: UUID) async throws {
        _ = try await database.writer.write { db in try TaskRecord.deleteOne(db, key: id.dbKey) }
    }

    // MARK: - Captures

    public func captures(taskID: UUID) async throws -> [Capture] {
        try await database.reader.read { db in
            try CaptureRecord
                .filter(CaptureRecord.Columns.taskId == taskID.dbKey)
                .order(CaptureRecord.Columns.createdAt)
                .fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ capture: Capture) async throws {
        let record = CaptureRecord(capture)
        try await database.writer.write { db in try record.upsert(db) }
    }

    /// One `UPDATE … WHERE id IN (…)` statement, so every capture moves atomically.
    public func moveCaptures(ids: [UUID], toTaskID: UUID) async throws {
        guard !ids.isEmpty else { return }
        let keys = ids.map(\.dbKey)
        let target = toTaskID.dbKey
        _ = try await database.writer.write { db in
            try CaptureRecord
                .filter(keys.contains(CaptureRecord.Columns.id))
                .updateAll(db, CaptureRecord.Columns.taskId.set(to: target))
        }
    }

    // MARK: - Voice notes

    public func voiceNotes(taskID: UUID) async throws -> [VoiceNote] {
        try await database.reader.read { db in
            try VoiceNoteRecord
                .filter(VoiceNoteRecord.Columns.taskId == taskID.dbKey)
                .order(VoiceNoteRecord.Columns.createdAt)
                .fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ voiceNote: VoiceNote) async throws {
        let record = VoiceNoteRecord(voiceNote)
        try await database.writer.write { db in try record.upsert(db) }
    }

    // MARK: - Search

    /// `nil` means "no filter" (empty or whitespace-only query). Both sides of every
    /// LIKE go through `shotcue_fold`, so Turkish case and diacritics match; `%`, `_`
    /// and `\` in the user's query are escaped so they are matched literally.
    static func searchRequest(_ query: String) -> SQLRequest<TaskRecord>? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = SearchText.normalized(trimmed)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let sql: SQL = """
            SELECT DISTINCT task.* FROM task
            LEFT JOIN voice_note ON voice_note.task_id = task.id
            WHERE shotcue_fold(task.title) LIKE \(pattern) ESCAPE '\\'
               OR shotcue_fold(task.note_text) LIKE \(pattern) ESCAPE '\\'
               OR shotcue_fold(COALESCE(voice_note.transcript, '')) LIKE \(pattern) ESCAPE '\\'
            ORDER BY task.sort_index, task.created_at
            """
        return SQLRequest<TaskRecord>(literal: sql)
    }

    public func search(_ query: String) async throws -> [ShotTask] {
        guard let request = Self.searchRequest(query) else { return try await allTasks() }
        return try await database.reader.read { db in
            try request.fetchAll(db).map(\.model)
        }
    }

    // MARK: - Observation

    public func observeAllTasks() -> AsyncStream<[ShotTask]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetchAll(db) },
            in: database.reader)
    }

    public func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetch(db, projectID: projectID) },
            in: database.reader)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=GRDBTaskRepositoryTests 2>&1 | tail -3`
Expected: `Test run with 9 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcuePersistence/GRDBTaskRepository.swift \
  Tests/ShotcuePersistenceTests/GRDBTaskRepositoryTests.swift
git commit -m "feat(persistence): add GRDB task repository with folded search and observation

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: GRDBRunRepository

**Files:**
- Create: `Sources/ShotcuePersistence/GRDBRunRepository.swift`
- Test: `Tests/ShotcuePersistenceTests/GRDBRunRepositoryTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10; imzalar birebir):
  ```swift
  public protocol RunRepository: Sendable {
      func runs(taskID: UUID) async throws -> [Run]
      func run(id: UUID) async throws -> Run?
      func save(_ run: Run) async throws
      /// Runs in `starting` or `running` state.
      func activeRuns() async throws -> [Run]
      /// On launch: marks leftover active runs as failed("interrupted"); returns how many.
      func markInterruptedRuns(at now: Date) async throws -> Int
      func observeRuns(taskID: UUID) -> AsyncStream<[Run]>
  }
  ```
  Ayrıca `AppDatabase` (Task 1), `RunRecord` / `RunRecord.activeStates` / `TaskRecord` / `UUID.dbKey` (Task 2), `ObservationBridge.stream(_:in:)` (Task 3), `Run`, `RunState` (Plan 00 Task 1).
- Produces:
  - `public final class GRDBRunRepository: RunRepository, Sendable` — `public init(database: AppDatabase)`

**Davranış notları:** `runs(taskID:)` ve `activeRuns()` `started_at` artan sıralı. `markInterruptedRuns(at:)` tek `UPDATE` ile `state = "failed"`, `error = "interrupted"`, `finished_at = now` yazar ve etkilenen satır sayısını döner; bitmiş run'lara dokunmaz, ikinci çağrı 0 döner.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcuePersistenceTests/GRDBRunRepositoryTests.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore
import Testing
@testable import ShotcuePersistence

@Suite("GRDBRunRepository")
struct GRDBRunRepositoryTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    struct Fixture {
        let database: AppDatabase
        let runs: GRDBRunRepository
        let task: ShotTask
    }

    /// The `run` table has a NOT NULL foreign key to `task`, so every fixture
    /// inserts its parent task row first.
    func makeFixture(extraTasks: [ShotTask] = []) throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let task = ShotTask(title: "t", sortIndex: 1024, createdAt: epoch, updatedAt: epoch)
        try database.writer.write { db in
            for row in [task] + extraTasks { try TaskRecord(row).upsert(db) }
        }
        return Fixture(database: database, runs: GRDBRunRepository(database: database), task: task)
    }

    @Test func runsAreOrderedByStartedAt() async throws {
        let other = ShotTask(title: "other", sortIndex: 2048, createdAt: epoch, updatedAt: epoch)
        let fixture = try makeFixture(extraTasks: [other])
        let late = Run(taskID: fixture.task.id, state: .succeeded,
                       startedAt: epoch.addingTimeInterval(60), logRelPath: "runs/late.jsonl")
        let early = Run(taskID: fixture.task.id, state: .failed, startedAt: epoch,
                        logRelPath: "runs/early.jsonl")
        let foreign = Run(taskID: other.id, state: .succeeded, startedAt: epoch,
                          logRelPath: "runs/foreign.jsonl")
        for run in [late, early, foreign] { try await fixture.runs.save(run) }
        #expect(try await fixture.runs.runs(taskID: fixture.task.id).map(\.id) == [early.id, late.id])
        #expect(try await fixture.runs.run(id: foreign.id)?.taskID == other.id)
        #expect(try await fixture.runs.run(id: UUID()) == nil)
    }

    @Test func activeRunsAreStartingOrRunning() async throws {
        let fixture = try makeFixture()
        let starting = Run(taskID: fixture.task.id, state: .starting, startedAt: epoch,
                           logRelPath: "runs/a.jsonl")
        let running = Run(taskID: fixture.task.id, state: .running,
                          startedAt: epoch.addingTimeInterval(1), logRelPath: "runs/b.jsonl")
        let done = Run(taskID: fixture.task.id, state: .succeeded,
                       startedAt: epoch.addingTimeInterval(2), logRelPath: "runs/c.jsonl")
        let cancelled = Run(taskID: fixture.task.id, state: .cancelled,
                            startedAt: epoch.addingTimeInterval(3), logRelPath: "runs/d.jsonl")
        for run in [starting, running, done, cancelled] { try await fixture.runs.save(run) }
        #expect(try await fixture.runs.activeRuns().map(\.id) == [starting.id, running.id])
    }

    @Test func markInterruptedRunsFailsActiveRowsAndCountsThem() async throws {
        let fixture = try makeFixture()
        let starting = Run(taskID: fixture.task.id, state: .starting, startedAt: epoch,
                           logRelPath: "runs/a.jsonl")
        let running = Run(taskID: fixture.task.id, state: .running,
                          startedAt: epoch.addingTimeInterval(1), logRelPath: "runs/b.jsonl")
        let done = Run(taskID: fixture.task.id, state: .succeeded,
                       startedAt: epoch.addingTimeInterval(2), resultText: "ok",
                       logRelPath: "runs/c.jsonl")
        for run in [starting, running, done] { try await fixture.runs.save(run) }
        let now = epoch.addingTimeInterval(120)
        #expect(try await fixture.runs.markInterruptedRuns(at: now) == 2)
        #expect(try await fixture.runs.activeRuns().isEmpty)
        let marked = try #require(try await fixture.runs.run(id: running.id))
        #expect(marked.state == .failed)
        #expect(marked.error == "interrupted")
        #expect(marked.finishedAt == now)
        let untouched = try #require(try await fixture.runs.run(id: done.id))
        #expect(untouched.state == .succeeded)
        #expect(untouched.error == nil)
        #expect(untouched.finishedAt == nil)
        #expect(try await fixture.runs.markInterruptedRuns(at: now) == 0)
    }

    @Test func observeRunsEmitsCurrentValueThenChanges() async throws {
        let fixture = try makeFixture()
        var iterator = fixture.runs.observeRuns(taskID: fixture.task.id).makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        let run = Run(taskID: fixture.task.id, state: .running, startedAt: epoch,
                      logRelPath: "runs/a.jsonl")
        try await fixture.runs.save(run)
        #expect(await iterator.next()?.map(\.state) == [.running])
        var finished = run
        finished.state = .succeeded
        finished.finishedAt = epoch.addingTimeInterval(5)
        try await fixture.runs.save(finished)
        #expect(await iterator.next()?.map(\.state) == [.succeeded])
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=GRDBRunRepositoryTests 2>&1 | grep -m3 "error:"`
Expected: `cannot find 'GRDBRunRepository' in scope`.

- [ ] **Step 3: GRDBRunRepository.swift'i yaz**

`Sources/ShotcuePersistence/GRDBRunRepository.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

public final class GRDBRunRepository: RunRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static func fetch(_ db: Database, taskID: UUID) throws -> [Run] {
        try RunRecord
            .filter(RunRecord.Columns.taskId == taskID.dbKey)
            .order(RunRecord.Columns.startedAt)
            .fetchAll(db)
            .map(\.model)
    }

    private static func activeRequest() -> QueryInterfaceRequest<RunRecord> {
        RunRecord
            .filter(RunRecord.activeStates.contains(RunRecord.Columns.state))
            .order(RunRecord.Columns.startedAt)
    }

    public func runs(taskID: UUID) async throws -> [Run] {
        try await database.reader.read { db in try Self.fetch(db, taskID: taskID) }
    }

    public func run(id: UUID) async throws -> Run? {
        try await database.reader.read { db in try RunRecord.fetchOne(db, key: id.dbKey)?.model }
    }

    public func save(_ run: Run) async throws {
        let record = RunRecord(run)
        try await database.writer.write { db in try record.upsert(db) }
    }

    public func activeRuns() async throws -> [Run] {
        try await database.reader.read { db in
            try Self.activeRequest().fetchAll(db).map(\.model)
        }
    }

    /// Called at launch: any run still `starting`/`running` belongs to a process that
    /// died with the previous app session (spec §8, "Uygulama run ortasında kapandı").
    public func markInterruptedRuns(at now: Date) async throws -> Int {
        try await database.writer.write { db in
            try Self.activeRequest()
                .updateAll(db,
                           RunRecord.Columns.state.set(to: RunState.failed.rawValue),
                           RunRecord.Columns.error.set(to: "interrupted"),
                           RunRecord.Columns.finishedAt.set(to: now.timeIntervalSince1970))
        }
    }

    public func observeRuns(taskID: UUID) -> AsyncStream<[Run]> {
        ObservationBridge.stream(
            ValueObservation.tracking { db in try Self.fetch(db, taskID: taskID) },
            in: database.reader)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=GRDBRunRepositoryTests 2>&1 | tail -3`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcuePersistence/GRDBRunRepository.swift \
  Tests/ShotcuePersistenceTests/GRDBRunRepositoryTests.swift
git commit -m "feat(persistence): add GRDB run repository with interrupted-run recovery

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: PersistenceMaintenance.renumberSortIndexes

**Files:**
- Create: `Sources/ShotcuePersistence/PersistenceMaintenance.swift`
- Test: `Tests/ShotcuePersistenceTests/PersistenceMaintenanceTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 3, `Sources/ShotcueCore/Logic/SortIndex.swift`):
  ```swift
  public enum SortIndex {
      public static let step: Double            // 1024
      public static func between(_ before: Double?, _ after: Double?) -> Double
      public static func needsRenumber(_ before: Double?, _ after: Double?) -> Bool
      public static func renumbered(count: Int) -> [Double]   // [1024, 2048, 3072, …]
  }
  ```
  Ayrıca `AppDatabase` (Task 1), `TaskRecord.ordered()` / `TaskRecord.Columns` / `UUID.dbKey` (Task 2), `GRDBProjectRepository` ve `GRDBTaskRepository` (Task 3, Task 4 — yalnızca testte).
- Produces:
  - `public enum PersistenceMaintenance { public static func renumberSortIndexes(in database: AppDatabase, projectID: UUID?) async throws }`

**Kim çağırır:** Plan 05 (UI) sürükle-bırak sonrası `SortIndex.needsRenumber(before, after)` doğru döndüğünde bu fonksiyonu çağırır; `projectID: nil` gelen kutusunu yeniden numaralandırır. Tek transaction içinde `sort_index, created_at` sırasına göre `1024, 2048, 3072, …` yazar ve başka hiçbir kolona dokunmaz.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcuePersistenceTests/PersistenceMaintenanceTests.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore
import Testing
@testable import ShotcuePersistence

@Suite("PersistenceMaintenance")
struct PersistenceMaintenanceTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    @Test func renumberSpreadsInboxTasksOverEvenSteps() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTaskRepository(database: database)
        let a = ShotTask(title: "a", sortIndex: 1.0, createdAt: epoch, updatedAt: epoch)
        let b = ShotTask(title: "b", sortIndex: 1.0 + 1e-9, createdAt: epoch.addingTimeInterval(1),
                         updatedAt: epoch)
        let c = ShotTask(title: "c", sortIndex: 2.0, createdAt: epoch.addingTimeInterval(2),
                         updatedAt: epoch)
        for task in [c, b, a] { try await repository.save(task) }
        #expect(SortIndex.needsRenumber(a.sortIndex, b.sortIndex))
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: nil)
        let renumbered = try await repository.tasks(projectID: nil)
        #expect(renumbered.map(\.title) == ["a", "b", "c"])
        #expect(renumbered.map(\.sortIndex) == SortIndex.renumbered(count: 3))
        #expect(SortIndex.needsRenumber(renumbered[0].sortIndex, renumbered[1].sortIndex) == false)
    }

    @Test func renumberTouchesOnlyTheGivenProject() async throws {
        let database = try AppDatabase.inMemory()
        let projects = GRDBProjectRepository(database: database)
        let tasks = GRDBTaskRepository(database: database)
        let project = Project(name: "crm", path: "/tmp/crm", sortIndex: 1024, createdAt: epoch)
        try await projects.save(project)
        let inside = ShotTask(projectID: project.id, title: "inside", status: .ready, sortIndex: 7,
                              createdAt: epoch, updatedAt: epoch)
        let outside = ShotTask(title: "outside", sortIndex: 9, createdAt: epoch, updatedAt: epoch)
        try await tasks.save(inside)
        try await tasks.save(outside)
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: project.id)
        #expect(try await tasks.task(id: inside.id)?.sortIndex == 1024)
        #expect(try await tasks.task(id: outside.id)?.sortIndex == 9)
    }

    @Test func renumberPreservesEveryOtherColumn() async throws {
        let database = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(database: database)
        let task = ShotTask(title: "keep me", noteText: "note", status: .scheduled, mode: .analyze,
                            modelOverride: "opus", sortIndex: 3, scheduledAt: epoch,
                            titleEditedByUser: true, createdAt: epoch, updatedAt: epoch)
        try await tasks.save(task)
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: nil)
        var expected = task
        expected.sortIndex = SortIndex.step
        #expect(try await tasks.task(id: task.id) == expected)
    }

    @Test func renumberOnAnEmptyListIsANoOp() async throws {
        let database = try AppDatabase.inMemory()
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: UUID())
        let repository = GRDBTaskRepository(database: database)
        #expect(try await repository.allTasks().isEmpty)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=PersistenceMaintenanceTests 2>&1 | grep -m3 "error:"`
Expected: `cannot find 'PersistenceMaintenance' in scope`.

- [ ] **Step 3: PersistenceMaintenance.swift'i yaz**

`Sources/ShotcuePersistence/PersistenceMaintenance.swift`:

```swift
import Foundation
import GRDB
import ShotcueCore

/// One-off repairs the UI triggers, kept out of the repositories because they are not
/// part of the Core protocols.
public enum PersistenceMaintenance {
    /// Rewrites `sort_index` of one list (a project, or the inbox when `projectID` is nil)
    /// to the even steps `SortIndex.renumbered(count:)` produces, keeping the current
    /// order. Call this when `SortIndex.needsRenumber(before, after)` is true after a
    /// drag and drop. Runs in a single transaction and touches no other column.
    public static func renumberSortIndexes(in database: AppDatabase, projectID: UUID?) async throws {
        try await database.writer.write { db in
            let request: QueryInterfaceRequest<TaskRecord>
            if let projectID {
                request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == projectID.dbKey)
            } else {
                request = TaskRecord.ordered().filter(TaskRecord.Columns.projectId == nil)
            }
            let records = try request.fetchAll(db)
            let indexes = SortIndex.renumbered(count: records.count)
            for (record, index) in zip(records, indexes) {
                try TaskRecord
                    .filter(TaskRecord.Columns.id == record.id)
                    .updateAll(db, TaskRecord.Columns.sortIndex.set(to: index))
            }
        }
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=PersistenceMaintenanceTests 2>&1 | tail -3`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcuePersistence/PersistenceMaintenance.swift \
  Tests/ShotcuePersistenceTests/PersistenceMaintenanceTests.swift
git commit -m "feat(persistence): add sort index renumbering maintenance helper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: InMemory ↔ GRDB eşitlik (contract) testi

**Files:**
- Test: `Tests/ShotcuePersistenceTests/TaskRepositoryContractTests.swift`

**Interfaces:**
- Consumes:
  - `ShotcueTestSupport`'tan `InMemoryTaskRepository(_ tasks: [ShotTask] = [])` (Plan 00 Task 10) — `TaskRepository`'nin referans implementasyonu.
  - `GRDBTaskRepository(database: AppDatabase)` (Task 4), `AppDatabase.inMemory()` (Task 1).
  - `TaskRepository` protokolünün tamamı (Plan 00 Task 10).
- Produces: yeni public tip yok. Tek parametrelendirilmiş suite: `@Suite("Task repository contract") struct TaskRepositoryContractTests` + `enum RepositoryFlavor: String, CaseIterable, Sendable { case inMemory, grdb }`.

**Neden bu test var:** Plan 05 (UI) yalnızca `TaskRepository` protokolünü görür; store testleri `InMemoryTaskRepository` kullanır, uygulama `GRDBTaskRepository` kullanır. İkisi aynı senaryoda aynı sonucu vermezse UI testleri yeşilken uygulama bozuk olur. Bu suite aynı gövdeyi `@Test(arguments:)` ile iki implementasyona karşı çalıştırır.

**Bilinçli iki fark (protokolün garanti etmediği şeyler; testin kaçındığı alanlar):**
1. **Arama katlaması.** `GRDBTaskRepository` Türkçe-duyarlı `SearchText.normalized(_:)` kullanır (aksan duyarsız); `InMemoryTaskRepository` sade `lowercased()` kullanır. Eşitlik testi bu yüzden ASCII sorgu terimleriyle (`"CACHE"`, `"once"`) çalışır. Protokol sözleşmesi yalnızca "case-insensitive" der; UI Türkçe/aksan duyarsızlığına **bağımlı olmamalıdır**.
2. **Foreign key.** GRDB'de `task.project_id` bir foreign key'dir, yani projesi kaydedilmemiş bir task saklanamaz; `InMemoryTaskRepository`'de böyle bir kısıt yok. Eşitlik senaryosu bu yüzden yalnızca projesiz (gelen kutusu) task'lar kullanır.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcuePersistenceTests/TaskRepositoryContractTests.swift`:

```swift
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing
@testable import ShotcuePersistence

/// The two implementations of `TaskRepository` that ship in v1.
enum RepositoryFlavor: String, CaseIterable, Sendable {
    case inMemory
    case grdb
}

@Suite("Task repository contract")
struct TaskRepositoryContractTests {
    static let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    /// The GRDB flavour keeps its `AppDatabase` alive through the repository's own
    /// reference, so returning the protocol existential is enough.
    static func makeRepository(_ flavor: RepositoryFlavor) throws -> any TaskRepository {
        switch flavor {
        case .inMemory:
            return InMemoryTaskRepository()
        case .grdb:
            return GRDBTaskRepository(database: try AppDatabase.inMemory())
        }
    }

    @Test(arguments: RepositoryFlavor.allCases)
    func inboxOrderingSearchAndCascade(flavor: RepositoryFlavor) async throws {
        let repository = try Self.makeRepository(flavor)
        let epoch = Self.epoch
        let inboxLate = ShotTask(title: "sonra", status: .inbox, sortIndex: 2048,
                                 createdAt: epoch, updatedAt: epoch)
        let inboxEarly = ShotTask(title: "once", status: .inbox, sortIndex: 1024,
                                  createdAt: epoch, updatedAt: epoch)
        try await repository.save(inboxLate)
        try await repository.save(inboxEarly)
        #expect(try await repository.tasks(projectID: nil).map(\.id) == [inboxEarly.id, inboxLate.id])
        #expect(try await repository.allTasks().map(\.id) == [inboxEarly.id, inboxLate.id])

        try await repository.save(Capture(taskID: inboxEarly.id, relPath: "captures/a.png",
                                          width: 10, height: 10, createdAt: epoch))
        try await repository.save(VoiceNote(taskID: inboxEarly.id, relPath: "audio/a.m4a",
                                            durationSec: 1, transcript: "cache temizle",
                                            transcriptState: .done, createdAt: epoch))
        #expect(try await repository.search("CACHE").map(\.id) == [inboxEarly.id])
        #expect(try await repository.search("once").map(\.id) == [inboxEarly.id])
        #expect(try await repository.search("").count == 2)

        try await repository.deleteTask(id: inboxEarly.id)
        #expect(try await repository.captures(taskID: inboxEarly.id).isEmpty)
        #expect(try await repository.voiceNotes(taskID: inboxEarly.id).isEmpty)
        #expect(try await repository.allTasks().map(\.id) == [inboxLate.id])
    }

    @Test(arguments: RepositoryFlavor.allCases)
    func statusFilterAndMoveCapturesBehaveIdentically(flavor: RepositoryFlavor) async throws {
        let repository = try Self.makeRepository(flavor)
        let epoch = Self.epoch
        let ready = ShotTask(title: "ready", status: .ready, sortIndex: 1024,
                             createdAt: epoch, updatedAt: epoch)
        let done = ShotTask(title: "done", status: .done, sortIndex: 2048,
                            createdAt: epoch, updatedAt: epoch)
        try await repository.save(ready)
        try await repository.save(done)
        #expect(try await repository.tasks(status: .ready).map(\.id) == [ready.id])
        #expect(try await repository.tasks(status: .queued).isEmpty)
        #expect(try await repository.task(id: UUID()) == nil)

        let capture = Capture(taskID: ready.id, relPath: "captures/a.png", width: 4, height: 4,
                              createdAt: epoch)
        try await repository.save(capture)
        try await repository.moveCaptures(ids: [capture.id], toTaskID: done.id)
        #expect(try await repository.captures(taskID: ready.id).isEmpty)
        #expect(try await repository.captures(taskID: done.id).map(\.id) == [capture.id])
    }

    @Test(arguments: RepositoryFlavor.allCases)
    func observationEmitsCurrentValueThenEveryChange(flavor: RepositoryFlavor) async throws {
        let repository = try Self.makeRepository(flavor)
        let epoch = Self.epoch
        var iterator = repository.observeAllTasks().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await repository.save(ShotTask(title: "b", sortIndex: 2048, createdAt: epoch,
                                           updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["b"])
        try await repository.save(ShotTask(title: "a", sortIndex: 1024, createdAt: epoch,
                                           updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["a", "b"])

        var inboxIterator = repository.observeTasks(projectID: nil).makeAsyncIterator()
        #expect(await inboxIterator.next()?.map(\.title) == ["a", "b"])
    }
}
```

- [ ] **Step 2: Eşitlik testinin gerçekten iki implementasyonu da çalıştırdığını doğrula**

Bu task'ta üretim kodu yazılmaz — test bir regresyon ağıdır, yeni davranış tanımlamaz. Task 1–6 sözleşmeyi karşılıyorsa ilk çalıştırmada yeşildir; kırmızıysa hata `ShotcuePersistence` tarafındadır ve ilgili task'a dönülür (`InMemoryTaskRepository` Plan 00'ın onaylanmış referansıdır ve **değiştirilmez**). O yüzden bu adımın işi "kırmızıyı görmek" değil, testin sessizce tek implementasyonu çalıştırmadığını kanıtlamaktır.

Run: `make test FILTER=TaskRepositoryContractTests 2>&1 | grep -c "argument flavor"`
Expected: `6` — üç testin her biri `.inMemory` ve `.grdb` için birer vaka üretiyor. `3` görürsen `@Test(arguments: RepositoryFlavor.allCases)` yerine argümansız `@Test` yazmışsındır; düzelt.

- [ ] **Step 3: Eşitlik testini çalıştır**

Run: `make test FILTER=TaskRepositoryContractTests 2>&1 | tail -4`
Expected: `Test run with 3 tests in 1 suite passed` ve her test satırında `with 2 test cases passed`.

- [ ] **Step 4: Modülün tüm testlerini çalıştır**

Run: `make test FILTER=ShotcuePersistenceTests 2>&1 | tail -4`
Expected: `Test run with 41 tests … passed` — Plan 00'dan gelen `PersistenceSmokeTests` (1) + Task 1 (8) + Task 2 (7) + Task 3 (5) + Task 4 (9) + Task 5 (4) + Task 6 (4) + Task 7 (3; parametrelendirilmiş testler toplam sayımda 1 sayılır, vaka sayısı ayrı satırda görünür). Sayı birebir tutmazsa suite listesini çıktıdan doğrula; **hiçbir** `✘` satırı olmamalı.

- [ ] **Step 5: Tüm paketi derle ve diğer modülleri kırmadığını doğrula**

Run: `swift build 2>&1 | grep -E "error:" ; make test 2>&1 | tail -3`
Expected: `swift build`'de hata satırı yok; `swift test` tüm target'larda yeşil (Plan 00'ın `ShotcueCoreTests` 56 testi dahil).

- [ ] **Step 6: Commit**

```bash
make format && git add Tests/ShotcuePersistenceTests/TaskRepositoryContractTests.swift
git commit -m "test(persistence): prove InMemory and GRDB task repositories match

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Plan 01 tamamlanma ölçütü

- `make test FILTER=ShotcuePersistenceTests` yeşil; `✘` satırı yok. Suite listesi: `Persistence smoke`, `AppDatabase`, `Record round trips`, `GRDBProjectRepository`, `GRDBTaskRepository`, `GRDBRunRepository`, `PersistenceMaintenance`, `Task repository contract`.
- `swift build` ve `swift test` (tüm paket) yeşil; `Package.swift` bu planda **değişmedi**.
- `Task repository contract` suite'i `InMemoryTaskRepository` ve `GRDBTaskRepository`'yi aynı üç senaryoda (gelen kutusu sıralaması + arama + cascade silme; durum filtresi + `moveCaptures`; observation'ın ilk değer + her değişim) karşılaştırıyor ve ikisi de geçiyor. Bu, Plan 05'in store testlerinin uygulamadaki davranışı temsil ettiğinin kanıtıdır.
- Şema spec §6.3 ile birebir: `project`, `task` (`title_edited_by_user` dahil), `capture`, `voice_note`, `run` tabloları; `task(project_id, status)`, `task(scheduled_at)`, `run(task_id, started_at)` indeksleri (+ `capture(task_id)`, `voice_note(task_id)`); foreign key'ler açık; task → capture/voice_note/run `ON DELETE CASCADE`, project → task `ON DELETE SET NULL`. Hepsi `AppDatabaseTests` tarafından `PRAGMA table_info` / `sqlite_master` ile doğrulanıyor.
- Diğer planların sözleşmesi hazır: `AppDatabase.open(at:)` / `.inMemory()` / `writer` / `reader`, `GRDBProjectRepository(database:)`, `GRDBTaskRepository(database:)`, `GRDBRunRepository(database:)`, `PersistenceMaintenance.renumberSortIndexes(in:projectID:)`. Plan 06 (App) composition root'ta `AppDatabase.open(at: FileStore(rootURL: FileStore.defaultRoot()).databaseURL)` çağırır ve açılışta `runRepository.markInterruptedRuns(at: clock.now)` ile spec §8'deki "uygulama run ortasında kapandı" durumunu temizler.
- Bu planın dokunmadığı ve dokunmaması gereken dosyalar: `Package.swift`, `Makefile`, `Sources/ShotcueCore/**`, `Sources/ShotcueTestSupport/**`, `Tests/ShotcuePersistenceTests/SmokeTests.swift`, `Sources/ShotcuePersistence/ShotcuePersistence.swift`.
- Plan 01 bittikten sonra Plan 05 (UI) store'ları `ValueObservation` beslemeli protokoller üzerinden yazılabilir; Plan 02/03/04 bu plandan bağımsızdır ve paralel yürüyebilir.
