# Shotcue v1 — Plan 04: ClaudeBridge (runner, koordinatör, zamanlayıcı, aktarım)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ShotcueClaudeBridge` modülünü kurmak: `claude -p` komut satırını üreten saf fonksiyonlar, `Process` tabanlı canlı akışlı runner, kuyruğu ve proje başına tek-run kuralını yürüten `RunCoordinator` aktörü, `DispatchSourceTimer` tabanlı `SchedulerDriver`, git güvenlik ağı, NDJSON run logu, terminal/Claude Desktop aktarımı ve bildirimler — hepsi fake `claude` ile uçtan uca test edilmiş halde.

**Architecture:** Zaman ve sıralama kararları Plan 00'daki saf fonksiyonlarda (`SchedulerRules`, `QueuePolicy`, `PromptBuilder`, `StreamJSONParser`, `GitOutputParser`); bu modül yalnızca yan etkileri uygular. `ProcessClaudeRunner` stdout'u satır satır `readabilityHandler` ile okur ve `StreamJSONParser`'a verir; stderr ayrı bir dispatch kaynağından boşaltılır (büyük stderr stdout'u kilitlemesin). `RunCoordinator` bir `actor`'dür: kuyruk durumu izolasyon içinde, `liveEvents` ve runner'ın `@Sendable` olay callback'inin eriştiği yayıncı kaydı izolasyon dışında (`LockBox`). UI bu modülü **görmez**; yalnızca Core'daki `TaskDispatcher`/`HandoffService`/`Notifier` protokollerini kullanır, `ShotcueApp` (Plan 06) production örneklerini bağlar.

**Tech Stack:** Swift 6.4 (CLT 27.0, SDK 27.0), Swift Testing, macOS 26.0. İzinli import'lar: `Foundation`, `AppKit` (yalnızca `NSWorkspace` ve `NSWorkspace.didWakeNotification`), `UserNotifications`. Dış bağımlılık yok. Doğrulanmış CLI: Claude Code **2.1.278** (`/Users/egekibar/.local/bin/claude`).

**Spec:** `docs/superpowers/specs/2026-09-22-shotcue-design.md` (§5.5, §6.4, §6.5, §7, §8, §12) · araştırma: `docs/research/04-claude-integration-and-scheduling.md`

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
- Her task `swift test` yeşilken commit'lenir. Commit mesajı sonu: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## Plan 04 doğrulama notları (kod yazmadan önce oku)

Bu planın **tüm** kaynak ve test kodu 2026-09-22'de bu makinede `swift build` + `swift test` ile derlenip çalıştırıldı (scratchpad'de ayrı bir paket, Plan 00'ın Core ve TestSupport kaynakları birebir kopyalanarak): **57 test, 9 suite, ~2.1 sn, hepsi yeşil.** Aşağıdaki maddeler o doğrulamanın çıktısıdır; hiçbirini yeniden keşfetmek zorunda değilsin.

**Derlenerek doğrulanan API'ler:** `Process` + `Pipe` + `FileHandle.readabilityHandler` satır akışı · `Process.interrupt()` / `terminate()` / `kill(pid, SIGKILL)` / `kill(pid, 0)` · `Process.terminationReason` · `ProcessInfo.processInfo.beginActivity(options:reason:)` + `endActivity(_:)` (token `any NSObjectProtocol` olarak aktör alanında) · `DispatchSource.makeTimerSource(queue:)` + `schedule(deadline:repeating:leeway:)` + `setEventHandler` + `activate()` + `cancel()` bir `actor` içinde · `NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object:queue:using:)` + `removeObserver` · `UNNotificationAction` / `UNNotificationCategory` / `UNMutableNotificationContent` (+`interruptionLevel`) / `UNNotificationRequest` / `setNotificationCategories` / `requestAuthorization(options:)` / `add(_:)` · `URLComponents` ile `claude://` URL üretimi · async gereksinimleri olan bir protokole uyan `actor` + `nonisolated` senkron `liveEvents` → `AsyncStream`.

**CLI bayrakları (2.1.278 `claude --help` ile yeniden doğrulandı):** `-p`, `--session-id <uuid>`, `--output-format stream-json`, `--verbose`, `--permission-prompts none|host`, `--permission-mode acceptEdits|auto|bypassPermissions|manual|dontAsk|plan`, `--allowedTools`, `--add-dir`, `--append-system-prompt`, `--max-budget-usd`, `--model`, `--effort low|medium|high|xhigh|max`, `--resume`, `--version` — hepsi mevcut. **`--max-turns` `--help` çıktısında listelenmiyor** ama binary'de tanımlı (`--max-turns <turns>`, "Maximum number of agentic turns in non-interactive mode … (only works with --print)"); yani bayrak çalışır, sadece yardım metninden gizlenmiş. Manuel doğrulama listesine alındı. `--bare` **asla** kullanılmaz (OAuth/keychain okumaz, abonelik girişini atlar).

**Süreç davranışı (ölçülen, tasarımı belirleyen bulgular):**
1. **`Process.terminationHandler` `run()`'dan ÖNCE kurulmalı.** Çocuk zaten çıktıktan sonra kurulan handler hiç çağrılmıyor → `await` sonsuza kadar askıda kalıyor (spike'ta gözlendi). `ProcessExitWaiter` bu yüzden var.
2. **stdout EOF bitiş koşulu olarak kullanılamaz.** Çocuğun torunu (fake `claude`'un `sleep 300`'ü) pipe'ın yazma ucunu açık tutuyor; çocuk öldükten sonra bile EOF gelmiyor. Bitiş `terminationHandler` ile belirlenir, ardından en fazla 1 sn'lik bir boşaltma penceresi uygulanır.
3. **Sinyalle ölen çocukta `terminationStatus` = SİNYAL NUMARASI** (SIGINT → 2, SIGTERM → 15, SIGKILL → 9) ve `terminationReason == .uncaughtSignal`; 128+sinyal **değil**. Gerçek `claude` sinyali kendisi yakalayıp 130/143 ile çıkar, bu yüzden her iki yol da ele alınır.
4. **SIGINT tek başına yetmeyebilir:** shell sarmalayıcı (`bash` + `sleep`) SIGINT'i yutup beklemeye devam ediyor; SIGKILL yükseltmesi zorunlu. Ölçüm: SIGINT → hayatta, 1 sn sonra SIGKILL → öldü; SIGTERM → anında öldü.
5. **`AsyncStream.Continuation.onTermination` senkron çalışır ve aynı kilidi ister.** `yield`/`finish` çağrıları kilidin **dışında** yapılmalı, yoksa `NSLock` (özyinelemeli değil) kilitleniyor — spike'ta gerçek bir deadlock olarak görüldü.
6. Paylaşılan `FileHandle.nullDevice` kapatılmamalı; yalnızca kendi `Pipe` okuma uçlarımızı kapatıyoruz.
7. `String(format: "%.2f", 5.0)` → `"5.00"` (sistem Türkçe locale'de bile ondalık nokta; doğrulandı).

**`FileHandle.bytes.lines`** de derleniyor, ama (2) yüzünden kullanılmıyor: EOF'a bağımlı olduğu için `hang` senaryosunda geri dönmüyor.

**Test koşucusu notu:** Bu makinede SwiftPM'in varsayılan `swiftbuild` sistemi Swift Testing makro eklentisini `usr/lib/swift/host/plugins/testing/` alt dizininde bulamıyor ve `plugin for module 'TestingMacros' not found` hatası veriyor. `swift test` bu hatayı verirse eklentiyi açıkça yükle:

```bash
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  --filter <Suite>
```

Bu doğruysa Plan 00'ın `Makefile`'ındaki `test` hedefine aynı bayraklar eklenir (Plan 00 sahibinin işi; bu planda `Makefile` değiştirilmez). Adımlardaki `Run:` satırları sade `make test FILTER=<Suite>` biçiminde yazıldı.

---

## Dosya haritası (bu planın ürettikleri)

```
Sources/ShotcueClaudeBridge/
  LockBox.swift                 internal LockBox<Value> (NSLock kutusu)                      Task 2
  ProcessSupport.swift          ProcessExitWaiter, LineSplitter, ProcessOutput, ProcessCapture Task 2
  ClaudeLocator.swift           ClaudeLocator                                                Task 1
  ClaudeArguments.swift         ClaudeArguments                                              Task 1
  ProcessClaudeRunner.swift     ClaudeRunError, ProcessClaudeRunner                          Task 2
  ShellGitInspector.swift       GitError, ShellGitInspector                                  Task 3
  RunLogWriter.swift            RunLogWriter                                                 Task 4
  RunEventBroadcaster.swift     internal RunEventBroadcaster                                 Task 5
  RunSettings.swift             RunSettings                                                  Task 5
  RunCoordinator.swift          RunCoordinator (TaskDispatcher)                              Task 5
  SchedulerDriver.swift         SchedulerDriver                                              Task 6
  DesktopHandoffService.swift   HandoffError, DesktopHandoffService                          Task 7
  UserNotificationNotifier.swift UserNotificationNotifier                                    Task 8
Tests/ShotcueClaudeBridgeTests/
  TestPaths.swift               Plan 00'dan birebir kopya (fixture yolu)                     Task 1
  Waiting.swift                 waitUntil(_:timeout:_:) yardımcısı                           Task 5
  ClaudeArgumentsTests.swift    ClaudeArguments + ClaudeLocator suite'leri (10 test)          Task 1
  ProcessClaudeRunnerTests.swift 9 test (fake-claude.sh senaryoları)                         Task 2
  ShellGitInspectorTests.swift  5 test (geçici gerçek git deposu)                            Task 3
  RunLogWriterTests.swift       3 test                                                       Task 4
  RunCoordinatorTests.swift     ErrorClaudeRunner, Harness, 15 test                          Task 5
  SchedulerDriverTests.swift    4 test                                                       Task 6
  DesktopHandoffServiceTests.swift 7 test                                                    Task 7
  UserNotificationNotifierTests.swift 4 test                                                 Task 8
```

`Sources/ShotcueClaudeBridge/ShotcueClaudeBridge.swift` (Plan 00'ın yer tutucusu) Task 1'de silinir. Bu planda **başka hiçbir dosya değiştirilmez**: `Package.swift`, `Makefile`, `CLAUDE.md`, `Sources/ShotcueCore/**`, `Sources/ShotcueTestSupport/**`, `Tests/Fixtures/**` Plan 00'a aittir.

---

### Task 1: ClaudeArguments ve ClaudeLocator (saf komut satırı üretimi)

`claude` sürümüyle değişebilecek her şey tek dosyada toplanır: argüman dizisi ve ortam değişkenleri. İkisi de saf fonksiyon, yani `Process` çalıştırmadan birebir test edilir. `ClaudeLocator` GUI'den başlatılan uygulamanın minimal `PATH`'ini telafi eder: ayar → üç kurulum konumu → login shell `which claude`.

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/TestPaths.swift` (Plan 00'daki dosyanın birebir kopyası)
- Create: `Tests/ShotcueClaudeBridgeTests/ClaudeArgumentsTests.swift`
- Create: `Sources/ShotcueClaudeBridge/ClaudeArguments.swift`
- Create: `Sources/ShotcueClaudeBridge/ClaudeLocator.swift`
- Delete: `Sources/ShotcueClaudeBridge/ShotcueClaudeBridge.swift` (Plan 00 yer tutucusu)

**Interfaces:**
- Consumes (Plan 00, birebir): `RunSpec(runID:prompt:projectPath:mode:model:effort:maxTurns:maxBudgetUSD:timeout:permissionMode:addDirs:systemPromptAppend:)` — alanlar `runID: UUID`, `prompt: String`, `projectPath: String`, `mode: TaskMode`, `model: String?`, `effort: String?`, `maxTurns: Int`, `maxBudgetUSD: Double`, `timeout: TimeInterval`, `permissionMode: ClaudePermissionMode`, `addDirs: [String]`, `systemPromptAppend: String`; `enum ClaudePermissionMode: String` (`bypassPermissions`, `acceptEdits`, `dontAsk`); `enum TaskMode: String` (`analyze`, `implement`).
- Produces: `public enum ClaudeArguments` → `public static func build(spec: RunSpec) -> [String]`, `public static func environment(base: [String: String], claudeDirectory: String) -> [String: String]`, `public static let analyzeAllowedTools: String`, `public static let systemPath: String`. `public enum ClaudeLocator` → `public static func locate(preferredPath: String? = nil) -> URL?`, `public static let defaultCandidates: [String]`, internal `locate(preferredPath:candidates:fileManager:loginShellWhich:)` (testler için enjeksiyon noktası). Task 2 `build`/`environment`'ı `ProcessClaudeRunner` içinde, Plan 06 `ClaudeLocator.locate`'i Ayarlar'da kullanır.

- [ ] **Step 1: TestPaths.swift'i kopyala**

`Tests/ShotcueClaudeBridgeTests/TestPaths.swift` (Plan 00 Task 0'daki dosyanın aynısı; her test target'ı kendi kopyasını taşır):

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

`Tests/ShotcueClaudeBridgeTests/ClaudeArgumentsTests.swift`:

```swift
import Foundation
import ShotcueCore
import Testing
@testable import ShotcueClaudeBridge

@Suite("ClaudeArguments")
struct ClaudeArgumentsTests {
    let runID = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!

    func spec(mode: TaskMode, model: String? = nil, effort: String? = nil) -> RunSpec {
        RunSpec(runID: runID, prompt: "PROMPT", projectPath: "/Users/me/crm", mode: mode,
                model: model, effort: effort, maxTurns: 50, maxBudgetUSD: 5, timeout: 1800,
                permissionMode: .bypassPermissions, addDirs: ["/tmp/captures"],
                systemPromptAppend: "SYS")
    }

    @Test func implementModeArgumentsAreExact() {
        #expect(ClaudeArguments.build(spec: spec(mode: .implement)) == [
            "-p", "PROMPT",
            "--session-id", "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompts", "none",
            "--max-turns", "50",
            "--max-budget-usd", "5.00",
            "--append-system-prompt", "SYS",
            "--add-dir", "/tmp/captures",
            "--permission-mode", "bypassPermissions",
        ])
    }

    @Test func analyzeModeForcesDontAskAndReadOnlyTools() throws {
        let args = ClaudeArguments.build(spec: spec(mode: .analyze, model: "opus", effort: "high"))
        let modeIndex = try #require(args.firstIndex(of: "--permission-mode"))
        #expect(args[modeIndex + 1] == "dontAsk")
        let toolsIndex = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(args[toolsIndex + 1] == ClaudeArguments.analyzeAllowedTools)
        #expect(args[toolsIndex + 1].contains("Bash(git diff *)"))
        #expect(!args[toolsIndex + 1].contains("Edit"))
        #expect(args.suffix(4) == ["--model", "opus", "--effort", "high"])
        #expect(!args.contains("--bare"))
    }

    @Test func optionalFlagsAreOmittedWhenEmpty() {
        let args = ClaudeArguments.build(spec: spec(mode: .implement, model: "", effort: nil))
        #expect(!args.contains("--model"))
        #expect(!args.contains("--effort"))
        #expect(!args.contains("--allowedTools"))
    }

    @Test func budgetIsFormattedWithTwoDecimals() throws {
        var s = spec(mode: .implement)
        s.maxBudgetUSD = 12.5
        let args = ClaudeArguments.build(spec: s)
        let index = try #require(args.firstIndex(of: "--max-budget-usd"))
        #expect(args[index + 1] == "12.50")
    }

    @Test func addDirsAreRepeated() {
        var s = spec(mode: .implement)
        s.addDirs = ["/a", "/b"]
        let args = ClaudeArguments.build(spec: s)
        #expect(args.filter { $0 == "--add-dir" }.count == 2)
    }

    @Test func environmentSetsHomeAndPathAndDropsAPIKey() {
        let env = ClaudeArguments.environment(
            base: ["ANTHROPIC_API_KEY": "sk-test", "KEEP": "1", "PATH": "/nope"],
            claudeDirectory: "/Users/me/.local/bin")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["KEEP"] == "1")
        #expect(env["HOME"] == NSHomeDirectory())
        #expect(env["PATH"] == "/Users/me/.local/bin:" + ClaudeArguments.systemPath)
    }
}

@Suite("ClaudeLocator")
struct ClaudeLocatorTests {
    @Test func preferredPathWins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferred = directory.appendingPathComponent("claude")
        let candidate = directory.appendingPathComponent("other-claude")
        for url in [preferred, candidate] {
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let found = ClaudeLocator.locate(preferredPath: preferred.path, candidates: [candidate.path],
                                         fileManager: .default, loginShellWhich: { _ in nil })
        #expect(found?.path == preferred.standardizedFileURL.path)
    }

    @Test func fallsBackToCandidatesThenShell() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = directory.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)

        #expect(ClaudeLocator.locate(preferredPath: "/nope/claude", candidates: [candidate.path],
                                     fileManager: .default, loginShellWhich: { _ in nil })?.path
                == candidate.standardizedFileURL.path)

        let shellResult = URL(fileURLWithPath: "/from/shell/claude")
        #expect(ClaudeLocator.locate(preferredPath: nil, candidates: ["/nope/claude"],
                                     fileManager: .default, loginShellWhich: { _ in shellResult })
                == shellResult)
    }

    @Test func nilWhenNothingIsExecutable() {
        #expect(ClaudeLocator.locate(preferredPath: "/nope/claude", candidates: ["/also/nope"],
                                     fileManager: .default, loginShellWhich: { _ in nil }) == nil)
    }

    @Test func defaultCandidateOrderMatchesSpec() {
        #expect(ClaudeLocator.defaultCandidates == [
            "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
    }
}
```

- [ ] **Step 3: Testin derlenmediğini gör**

Run: `make test FILTER="ClaudeArgumentsTests|ClaudeLocatorTests" 2>&1 | grep -m2 "error:"`
Expected: `cannot find 'ClaudeArguments' in scope` ve `cannot find 'ClaudeLocator' in scope`.

- [ ] **Step 4: ClaudeArguments'ı yaz**

`Sources/ShotcueClaudeBridge/ClaudeArguments.swift`:

```swift
import Foundation
import ShotcueCore

/// Pure construction of the `claude -p` command line and its environment (spec §6.4).
/// Everything version-sensitive lives here so a CLI upgrade touches one file.
public enum ClaudeArguments {
    /// Analyze mode is locked down to read-only tools.
    public static let analyzeAllowedTools =
        "Read,Glob,Grep,WebFetch,WebSearch,Bash(git log *),Bash(git diff *),Bash(git status *),Bash(git show *)"

    /// System paths appended after the `claude` binary's own directory.
    public static let systemPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func build(spec: RunSpec) -> [String] {
        let analyze = spec.mode == .analyze
        var arguments: [String] = [
            "-p", spec.prompt,
            "--session-id", spec.runID.uuidString.lowercased(),
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompts", "none",
            "--max-turns", "\(spec.maxTurns)",
            "--max-budget-usd", String(format: "%.2f", spec.maxBudgetUSD),
            "--append-system-prompt", spec.systemPromptAppend,
        ]
        for directory in spec.addDirs {
            arguments += ["--add-dir", directory]
        }
        arguments += ["--permission-mode", analyze ? ClaudePermissionMode.dontAsk.rawValue : spec.permissionMode.rawValue]
        if analyze {
            arguments += ["--allowedTools", analyzeAllowedTools]
        }
        if let model = spec.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort = spec.effort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        return arguments
    }

    /// `claude` must see HOME (keychain + ~/.claude) and a PATH that contains its own directory.
    /// `ANTHROPIC_API_KEY` is removed so the run bills the user's subscription login, not an API key.
    public static func environment(base: [String: String], claudeDirectory: String) -> [String: String] {
        var environment = base
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "\(claudeDirectory):\(systemPath)"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        return environment
    }
}
```

- [ ] **Step 5: ClaudeLocator'ı yaz**

`Sources/ShotcueClaudeBridge/ClaudeLocator.swift`:

```swift
import Foundation

/// Finds the `claude` executable (spec §6.4): the user's setting first, then the three install
/// locations, then `which claude` through a login shell (GUI apps inherit a minimal PATH).
public enum ClaudeLocator {
    /// Checked in order, after `preferredPath`.
    public static let defaultCandidates = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    public static func locate(preferredPath: String? = nil) -> URL? {
        locate(preferredPath: preferredPath, candidates: defaultCandidates,
               fileManager: .default, loginShellWhich: whichThroughLoginShell)
    }

    /// Injection points exist so tests can prove the ordering without depending on the machine.
    static func locate(preferredPath: String?, candidates: [String], fileManager: FileManager,
                       loginShellWhich: (FileManager) -> URL?) -> URL? {
        var paths: [String] = []
        if let preferredPath, !preferredPath.trimmingCharacters(in: .whitespaces).isEmpty {
            paths.append(preferredPath)
        }
        paths.append(contentsOf: candidates)
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        return loginShellWhich(fileManager)
    }

    static func whichThroughLoginShell(_ fileManager: FileManager) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("/") } ?? ""
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
```

- [ ] **Step 6: Yer tutucuyu sil ve testleri çalıştır**

Run: `rm Sources/ShotcueClaudeBridge/ShotcueClaudeBridge.swift && make test FILTER="ClaudeArgumentsTests|ClaudeLocatorTests" 2>&1 | tail -3`
Expected: `Test run with 10 tests in 2 suites passed`. (Yer tutucu silindiği için Plan 00'ın `Tests/ShotcueClaudeBridgeTests/SmokeTests.swift` dosyası da silinmelidir; `ShotcueClaudeBridgeInfo` artık yok.)

- [ ] **Step 7: Commit**

```bash
rm -f Tests/ShotcueClaudeBridgeTests/SmokeTests.swift
make format && git add -A Sources/ShotcueClaudeBridge Tests/ShotcueClaudeBridgeTests
git commit -m "feat(bridge): build claude CLI arguments and locate the executable

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: ProcessClaudeRunner (canlı akış, iptal, zaman aşımı)

Modülün kalbi. `claude -p`'yi proje dizininde çalıştırır, stdout'un her satırını `StreamJSONParser.parse(line:)`'a verir, `RunEvent`'leri `onEvent`'e iletir, son `result` satırını hatırlar ve süreç bitişini `terminationHandler` üzerinden bekler. **Diske hiçbir şey yazmaz** — log tutmak `RunCoordinator`'ın işi.

Doğrulama notlarındaki 1–4 numaralı bulgular bu dosyanın şeklini belirledi: exit handler `run()`'dan önce kurulur, bitiş stdout EOF'una bağlanmaz, sinyalle ölüm `terminationReason` ile ayırt edilir, SIGINT'ten sonra SIGKILL yükseltmesi yapılır. `killGrace` production'da 10 sn; internal initializer testlerin bunu 1 sn'ye düşürmesini sağlar (public API değişmez).

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/ProcessClaudeRunnerTests.swift`
- Create: `Sources/ShotcueClaudeBridge/LockBox.swift`
- Create: `Sources/ShotcueClaudeBridge/ProcessSupport.swift`
- Create: `Sources/ShotcueClaudeBridge/ProcessClaudeRunner.swift`
- Uses (değiştirmez): `Tests/Fixtures/fake-claude.sh`, `Tests/Fixtures/sample-stream.jsonl` (Plan 00 Task 0)

**Interfaces:**
- Consumes (Plan 00, birebir): `protocol ClaudeRunner: Sendable { func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult; func cancel(runID: UUID) async; func version() async throws -> String }`; `StreamJSONParser.parse(line: String) -> RunEvent?`; `enum RunEvent` (`initialized(sessionID:model:)`, `assistantText(_:)`, `toolUse(name:summary:)`, `apiRetry(attempt:)`, `result(_:)`, `other(type:)`); `ClaudeRunResult(subtype:isError:sessionID:result:totalCostUSD:numTurns:durationMs:permissionDenials:)` + `isSuccess`, `hitLimit`, `maxTurnsSubtype`, `maxBudgetSubtype`; `Locked<Value>` (`ShotcueTestSupport`, sadece testlerde).
- Produces: `public enum ClaudeRunError: Error, Equatable, Sendable` (`notFound`, `launchFailed(String)`, `processFailed(exitCode: Int32, stderr: String)`, `timedOut`, `cancelled`, `noResult`); `public final class ProcessClaudeRunner: ClaudeRunner, @unchecked Sendable` → `public convenience init(executableURL: URL, environmentOverrides: [String: String] = [:])`, internal `init(executableURL:environmentOverrides:killGrace:)`, `public let executableURL: URL`, `public let environmentOverrides: [String: String]`. Ayrıca modül içi yardımcılar: `LockBox<Value>`, `ProcessExitWaiter`, `LineSplitter.take(from:appending:)` / `.flush(_:)`, `ProcessOutput(exitCode:stdout:stderr:)`, `ProcessCapture.run(executableURL:arguments:currentDirectory:environment:)` (Task 3 ve `version()` kullanır).

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/ProcessClaudeRunnerTests.swift`:

```swift
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing
@testable import ShotcueClaudeBridge

@Suite("ProcessClaudeRunner")
struct ProcessClaudeRunnerTests {
    let fakeClaude = TestPaths.fixture("fake-claude.sh")

    /// A real directory so `cwd` can be compared; symlinks resolved because bash reports getcwd().
    func makeProjectDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func spec(projectPath: String, mode: TaskMode = .implement, timeout: TimeInterval = 30) -> RunSpec {
        RunSpec(runID: UUID(), prompt: "PROMPT", projectPath: projectPath, mode: mode,
                maxTurns: 50, maxBudgetUSD: 5, timeout: timeout,
                permissionMode: .bypassPermissions, addDirs: ["/tmp/captures"],
                systemPromptAppend: "SYS")
    }

    func runner(scenario: String, argsFile: URL? = nil, killGrace: Duration = .seconds(1)) -> ProcessClaudeRunner {
        var overrides = ["FAKE_CLAUDE_SCENARIO": scenario]
        if let argsFile { overrides["FAKE_CLAUDE_ARGS_FILE"] = argsFile.path }
        return ProcessClaudeRunner(executableURL: fakeClaude, environmentOverrides: overrides,
                                   killGrace: killGrace)
    }

    @Test func successStreamsEveryEventAndReturnsTheResult() async throws {
        let project = try makeProjectDirectory()
        let argsFile = project.appendingPathComponent("args.txt")
        let events = Locked<[RunEvent]>([])
        let spec = spec(projectPath: project.path)

        let result = try await runner(scenario: "success", argsFile: argsFile)
            .run(spec) { event in events.withLock { $0.append(event) } }

        #expect(result.isSuccess)
        #expect(result.numTurns == 11)
        #expect(result.totalCostUSD == 0.4137)
        #expect(result.sessionID == "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
        #expect(result.result?.hasPrefix("Fixed the button color.") == true)

        let received = events.current
        #expect(received.count == 7)
        #expect(received[0] == .initialized(sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73",
                                           model: "claude-sonnet-5"))
        #expect(received[1] == .assistantText("Reading the screenshot first."))
        #expect(received[2] == .toolUse(name: "Read", summary: "Read /tmp/shots/a.png"))
        #expect(received[3] == .other(type: "user"))
        #expect(received[4] == .apiRetry(attempt: 1))
        #expect(received[5] == .toolUse(name: "Edit", summary: "Edit /tmp/proj/src/Button.tsx"))
        if case .result = received[6] {} else { Issue.record("last event must be .result") }

        let dump = try String(contentsOf: argsFile, encoding: .utf8)
        let lines = dump.components(separatedBy: "\n")
        #expect(lines.contains("--session-id"))
        #expect(lines.contains(spec.runID.uuidString.lowercased()))
        #expect(lines.contains("--output-format"))
        #expect(lines.contains("stream-json"))
        #expect(lines.contains("--verbose"))
        #expect(lines.contains("none"))
        #expect(!lines.contains("--bare"))
        // bash prints getcwd(), i.e. the physical path: /var/folders/… is reached as
        // /private/var/folders/…. The directory name is a fresh UUID, so the leaf is proof enough.
        let cwdLine = try #require(lines.first { $0.hasPrefix("CWD=") })
        #expect(cwdLine.hasSuffix("/" + project.lastPathComponent))
        #expect(lines.contains { $0.hasPrefix("HOME=") })
        #expect(!lines.contains { $0.hasPrefix("ANTHROPIC_API_KEY=") })
    }

    @Test func maxTurnsComesBackAsALimitResult() async throws {
        let project = try makeProjectDirectory()
        let result = try await runner(scenario: "max_turns").run(spec(projectPath: project.path)) { _ in }
        #expect(result.subtype == ClaudeRunResult.maxTurnsSubtype)
        #expect(result.hitLimit)
        #expect(!result.isSuccess)
        #expect(result.numTurns == 30)
    }

    @Test func nonZeroExitThrowsProcessFailedWithStderr() async throws {
        let project = try makeProjectDirectory()
        do {
            _ = try await runner(scenario: "error").run(spec(projectPath: project.path)) { _ in }
            Issue.record("expected a throw")
        } catch let error as ClaudeRunError {
            guard case .processFailed(let exitCode, let stderr) = error else {
                Issue.record("expected processFailed, got \(error)")
                return
            }
            #expect(exitCode == 1)
            #expect(stderr.contains("not logged in"))
        }
    }

    @Test func slowOutputStillSucceeds() async throws {
        let project = try makeProjectDirectory()
        let events = Locked<[RunEvent]>([])
        let result = try await runner(scenario: "slow")
            .run(spec(projectPath: project.path)) { event in events.withLock { $0.append(event) } }
        #expect(result.isSuccess)
        #expect(events.current.count == 7)
    }

    @Test func timeoutInterruptsAndThrowsTimedOut() async throws {
        let project = try makeProjectDirectory()
        let started = Date()
        do {
            _ = try await runner(scenario: "hang")
                .run(spec(projectPath: project.path, timeout: 2)) { _ in }
            Issue.record("expected a throw")
        } catch let error as ClaudeRunError {
            #expect(error == .timedOut)
        }
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func cancelDuringRunThrowsCancelled() async throws {
        let project = try makeProjectDirectory()
        let subject = runner(scenario: "hang")
        let spec = spec(projectPath: project.path, timeout: 120)
        let seen = Locked(0)
        let run = Task {
            try await subject.run(spec) { _ in seen.withLock { $0 += 1 } }
        }
        while seen.current == 0 { try await Task.sleep(for: .milliseconds(20)) }
        await subject.cancel(runID: spec.runID)
        do {
            _ = try await run.value
            Issue.record("expected a throw")
        } catch let error as ClaudeRunError {
            #expect(error == .cancelled)
        }
    }

    @Test func versionReadsTheCLIVersion() async throws {
        #expect(try await runner(scenario: "success").version() == "2.1.278 (Claude Code)")
    }

    @Test func missingExecutableThrowsNotFound() async throws {
        let missing = ProcessClaudeRunner(executableURL: URL(fileURLWithPath: "/nope/claude"))
        await #expect(throws: ClaudeRunError.notFound) {
            _ = try await missing.run(self.spec(projectPath: "/tmp")) { _ in }
        }
        await #expect(throws: ClaudeRunError.notFound) { _ = try await missing.version() }
    }

    @Test func lineSplitterKeepsPartialTail() {
        var buffer = Data()
        #expect(LineSplitter.take(from: &buffer, appending: Data("a\nb".utf8)) == ["a"])
        #expect(LineSplitter.take(from: &buffer, appending: Data("c\n".utf8)) == ["bc"])
        #expect(LineSplitter.flush(&buffer) == nil)
        _ = LineSplitter.take(from: &buffer, appending: Data("tail".utf8))
        #expect(LineSplitter.flush(&buffer) == "tail")
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=ProcessClaudeRunnerTests 2>&1 | grep -m2 "error:"`
Expected: `cannot find 'ProcessClaudeRunner' in scope` (ve `LineSplitter` için aynısı).

- [ ] **Step 3: LockBox'ı yaz**

`Sources/ShotcueClaudeBridge/LockBox.swift` (Plan 00'ın `Locked`'ı `ShotcueTestSupport`'ta yaşar ve uygulamaya link edilmez; bu yüzden modülün kendi internal kutusu olur):

```swift
import Foundation

/// Minimal lock box so `@unchecked Sendable` service types can hold mutable state, and so an
/// `actor`'s `nonisolated` members can reach shared registries.
///
/// Never call out to code that takes the same lock from inside `withLock` — `NSLock` is not
/// recursive and `AsyncStream.Continuation.onTermination` runs synchronously.
final class LockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
    func set(_ newValue: Value) { withLock { $0 = newValue } }
}
```

- [ ] **Step 4: ProcessSupport'u yaz**

`Sources/ShotcueClaudeBridge/ProcessSupport.swift`:

```swift
import Foundation

/// Bridges `Process.terminationHandler` to async/await, resuming exactly once.
///
/// `attach(to:)` MUST run before `Process.run()`: a handler installed after the child has already
/// exited is never called, and the `await` below would hang forever (verified in the spike).
final class ProcessExitWaiter: @unchecked Sendable {
    private struct State {
        var status: Int32?
        var continuation: CheckedContinuation<Int32, Never>?
    }

    private let state = LockBox(State())

    func attach(to process: Process) {
        process.terminationHandler = { [state] finished in
            let status = finished.terminationStatus
            let waiting: CheckedContinuation<Int32, Never>? = state.withLock { current in
                guard current.status == nil else { return nil }
                current.status = status
                let pending = current.continuation
                current.continuation = nil
                return pending
            }
            waiting?.resume(returning: status)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let ready: Int32? = state.withLock { current in
                if let status = current.status { return status }
                current.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Splits raw pipe chunks into complete lines, keeping the unterminated tail in `buffer`.
enum LineSplitter {
    static func take(from buffer: inout Data, appending chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines
    }

    static func flush(_ buffer: inout Data) -> String? {
        guard !buffer.isEmpty else { return nil }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

struct ProcessOutput: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Runs a short-lived command and captures its output without blocking a cooperative thread.
enum ProcessCapture {
    static func run(executableURL: URL, arguments: [String], currentDirectory: URL? = nil,
                    environment: [String: String]? = nil) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let out = LockBox(Data())
        let err = LockBox(Data())
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            out.withLock { $0.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            err.withLock { $0.append(chunk) }
        }

        let waiter = ProcessExitWaiter()
        waiter.attach(to: process)
        try process.run()
        let status = await waiter.wait()
        // Let the readability handlers deliver what is already in the pipes.
        try? await Task.sleep(for: .milliseconds(30))
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        out.withLock { $0.append((try? outPipe.fileHandleForReading.readToEnd()) ?? Data()) }
        err.withLock { $0.append((try? errPipe.fileHandleForReading.readToEnd()) ?? Data()) }
        return ProcessOutput(exitCode: status,
                             stdout: String(decoding: out.current, as: UTF8.self),
                             stderr: String(decoding: err.current, as: UTF8.self))
    }
}
```

- [ ] **Step 5: ProcessClaudeRunner'ı yaz**

`Sources/ShotcueClaudeBridge/ProcessClaudeRunner.swift`:

```swift
import Foundation
import ShotcueCore

public enum ClaudeRunError: Error, Equatable, Sendable {
    case notFound
    case launchFailed(String)
    case processFailed(exitCode: Int32, stderr: String)
    case timedOut
    case cancelled
    case noResult
}

/// Runs `claude -p` in the project directory and streams its stream-json output (spec §6.4).
/// Writes nothing to disk: log persistence belongs to `RunCoordinator`.
public final class ProcessClaudeRunner: ClaudeRunner, @unchecked Sendable {
    public let executableURL: URL
    public let environmentOverrides: [String: String]
    /// How long a SIGINT gets before SIGKILL. 10 s in production; tests shorten it.
    let killGrace: Duration

    private let active = LockBox<[UUID: Process]>([:])
    private let cancelRequested = LockBox<Set<UUID>>([])

    public convenience init(executableURL: URL, environmentOverrides: [String: String] = [:]) {
        self.init(executableURL: executableURL, environmentOverrides: environmentOverrides,
                  killGrace: .seconds(10))
    }

    init(executableURL: URL, environmentOverrides: [String: String], killGrace: Duration) {
        self.executableURL = executableURL
        self.environmentOverrides = environmentOverrides
        self.killGrace = killGrace
    }

    public func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeRunError.notFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ClaudeArguments.build(spec: spec)
        process.currentDirectoryURL = URL(fileURLWithPath: spec.projectPath, isDirectory: true)
        var environment = ClaudeArguments.environment(
            base: ProcessInfo.processInfo.environment,
            claudeDirectory: executableURL.deletingLastPathComponent().path)
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Detach stdin: an unattended run must never inherit a terminal.
        process.standardInput = FileHandle.nullDevice

        let lastResult = LockBox<ClaudeRunResult?>(nil)
        let consume: @Sendable (String) -> Void = { line in
            guard let event = StreamJSONParser.parse(line: line) else { return }
            if case .result(let result) = event { lastResult.set(result) }
            onEvent(event)
        }

        let sawStdoutEOF = LockBox(false)
        let stdoutTail = LockBox(Data())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sawStdoutEOF.set(true)
                return
            }
            let lines = stdoutTail.withLock { LineSplitter.take(from: &$0, appending: chunk) }
            for line in lines { consume(line) }
        }

        // stderr is drained on its own dispatch source: a chatty stderr must never block stdout.
        let stderrBuffer = LockBox(Data())
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            stderrBuffer.withLock { $0.append(chunk) }
        }

        let waiter = ProcessExitWaiter()
        waiter.attach(to: process)
        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw ClaudeRunError.launchFailed(String(describing: error))
        }
        active.withLock { $0[spec.runID] = process }

        // Race the child against the timeout. Never wait for stdout EOF: a grandchild of the
        // child can keep the write end open long after the child itself is gone.
        let exitStatus = await withTaskGroup(of: Int32?.self, returning: Int32?.self) { group in
            group.addTask { await waiter.wait() }
            group.addTask {
                try? await Task.sleep(for: .seconds(spec.timeout))
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil {
                self.stop(process)          // escalates to SIGKILL so the other child can finish
                _ = await group.next()
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return first
        }

        // Give the handlers a moment to deliver buffered bytes, capped so a lingering
        // grandchild cannot stall us.
        let drainDeadline = Date().addingTimeInterval(1)
        while !sawStdoutEOF.current, Date() < drainDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        if let leftover = stdoutTail.withLock({ LineSplitter.flush(&$0) }) { consume(leftover) }
        active.withLock { $0[spec.runID] = nil }
        let wasCancelled = cancelRequested.withLock { $0.remove(spec.runID) != nil }
        try? stdoutHandle.close()
        try? stderrHandle.close()

        guard let status = exitStatus else { throw ClaudeRunError.timedOut }
        // A signal-killed child reports the SIGNAL NUMBER in terminationStatus (2 for SIGINT),
        // not 128+signal; `claude` itself exits 130/143 when it handles the signal.
        if status == 130 || status == 143 { throw ClaudeRunError.cancelled }
        if wasCancelled, process.terminationReason == .uncaughtSignal { throw ClaudeRunError.cancelled }
        if status != 0 {
            throw ClaudeRunError.processFailed(exitCode: status,
                                               stderr: String(decoding: stderrBuffer.current, as: UTF8.self))
        }
        guard let result = lastResult.current else { throw ClaudeRunError.noResult }
        return result
    }

    public func cancel(runID: UUID) async {
        cancelRequested.withLock { _ = $0.insert(runID) }
        guard let process = active.current[runID] else { return }
        stop(process)
    }

    public func version() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeRunError.notFound
        }
        let output = try await ProcessCapture.run(executableURL: executableURL, arguments: ["--version"])
        guard output.exitCode == 0 else {
            throw ClaudeRunError.processFailed(exitCode: output.exitCode, stderr: output.stderr)
        }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SIGINT for a graceful stop (Claude saves the turn), SIGKILL after `killGrace`.
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        let pid = process.processIdentifier
        let grace = killGrace
        Task.detached {
            try? await Task.sleep(for: grace)
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
    }
}
```

- [ ] **Step 6: Testleri çalıştır**

Run: `make test FILTER=ProcessClaudeRunnerTests 2>&1 | tail -3`
Expected: `Test run with 9 tests in 1 suite passed`. Süre ~2 sn (`slow` 1 sn, `hang` 2 sn zaman aşımı). `timeoutInterruptsAndThrowsTimedOut` 15 sn'yi aşarsa SIGKILL yükseltmesi çalışmıyor demektir — `stop(_:)`'daki `Task.detached` bloğunu kontrol et.

- [ ] **Step 7: Commit**

```bash
make format && git add Sources/ShotcueClaudeBridge Tests/ShotcueClaudeBridgeTests
git commit -m "feat(bridge): run claude -p with live stream-json events

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: ShellGitInspector (run öncesi/sonrası güvenlik ağı)

Her run'ın öncesinde ve sonrasında `git rev-parse HEAD`, `git status --porcelain`, `git branch --show-current` okunur; ham çıktı Plan 00'daki `GitOutputParser.snapshot`'a verilir. Proje ayarı açıksa `git switch -c shotcue/<taskId-kısa>` ve `git stash push -u -m shotcue` çalıştırılır. Depo olmayan bir dizinde `snapshot` **nil** döner (exit 128), böylece git'siz projeler de çalışır.

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/ShellGitInspectorTests.swift`
- Create: `Sources/ShotcueClaudeBridge/ShellGitInspector.swift`

**Interfaces:**
- Consumes (Plan 00, birebir): `protocol GitInspector: Sendable { func snapshot(at path: String) async -> GitSnapshot?; func createBranch(_ name: String, at path: String) async throws; func stashAll(at path: String) async throws }`; `GitSnapshot(head:isDirty:branch:)`; `GitOutputParser.snapshot(revParseHead:statusPorcelain:branchShowCurrent:) -> GitSnapshot?`; `GitOutputParser.branchName(for taskID: UUID) -> String`. Task 2'den: `ProcessCapture.run(executableURL:arguments:currentDirectory:environment:)`, `ProcessOutput`.
- Produces: `public enum GitError: Error, Equatable, Sendable { case commandFailed(arguments: [String], exitCode: Int32, stderr: String) }`; `public struct ShellGitInspector: GitInspector` → `public init(gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"))`, `public let gitExecutable: URL`.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/ShellGitInspectorTests.swift`:

```swift
import Foundation
import ShotcueCore
import Testing
@testable import ShotcueClaudeBridge

@Suite("ShellGitInspector")
struct ShellGitInspectorTests {
    let git = ShellGitInspector()

    /// Creates a throwaway repository with one commit.
    func makeRepository() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let exe = URL(fileURLWithPath: "/usr/bin/git")
        for arguments in [["init", "-q", "-b", "main"],
                          ["config", "user.email", "test@example.com"],
                          ["config", "user.name", "Shotcue Test"]] {
            _ = try await ProcessCapture.run(executableURL: exe, arguments: arguments, currentDirectory: url)
        }
        try Data("hello\n".utf8).write(to: url.appendingPathComponent("a.txt"))
        _ = try await ProcessCapture.run(executableURL: exe, arguments: ["add", "."], currentDirectory: url)
        _ = try await ProcessCapture.run(executableURL: exe, arguments: ["commit", "-q", "-m", "init"],
                                         currentDirectory: url)
        return url
    }

    @Test func cleanRepositoryOnMain() async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let snapshot = try #require(await git.snapshot(at: repo.path))
        #expect(snapshot.head.count == 40)
        // Bind first: #expect would decompose `allSatisfy(_:)` into a rethrowing call.
        let isHex = snapshot.head.allSatisfy(\.isHexDigit)
        #expect(isHex)
        #expect(snapshot.isDirty == false)
        #expect(snapshot.branch == "main")
    }

    @Test func untrackedFileMakesItDirty() async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("draft\n".utf8).write(to: repo.appendingPathComponent("b.txt"))
        let snapshot = try #require(await git.snapshot(at: repo.path))
        #expect(snapshot.isDirty)
    }

    @Test func createBranchSwitchesAndStashCleansTheTree() async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await git.createBranch("shotcue/3f2a9c40", at: repo.path)
        #expect(await git.snapshot(at: repo.path)?.branch == "shotcue/3f2a9c40")

        try Data("draft\n".utf8).write(to: repo.appendingPathComponent("b.txt"))
        #expect(await git.snapshot(at: repo.path)?.isDirty == true)
        try await git.stashAll(at: repo.path)
        #expect(await git.snapshot(at: repo.path)?.isDirty == false)
    }

    @Test func duplicateBranchThrows() async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await git.createBranch("shotcue/dup", at: repo.path)
        await #expect(throws: GitError.self) {
            try await self.git.createBranch("shotcue/dup", at: repo.path)
        }
    }

    @Test func snapshotIsNilOutsideARepository() async throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(await git.snapshot(at: plain.path) == nil)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=ShellGitInspectorTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'ShellGitInspector' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueClaudeBridge/ShellGitInspector.swift`:

```swift
import Foundation
import ShotcueCore

public enum GitError: Error, Equatable, Sendable {
    case commandFailed(arguments: [String], exitCode: Int32, stderr: String)
}

/// `git` safety net around every run (spec §6.4). Reads are best-effort (nil outside a repo);
/// writes (`createBranch`, `stashAll`) throw so the coordinator can record the failure.
public struct ShellGitInspector: GitInspector {
    public let gitExecutable: URL

    public init(gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.gitExecutable = gitExecutable
    }

    public func snapshot(at path: String) async -> GitSnapshot? {
        guard let head = try? await capture(["rev-parse", "HEAD"], at: path), head.exitCode == 0 else {
            return nil
        }
        let status = (try? await capture(["status", "--porcelain"], at: path))?.stdout ?? ""
        let branch = (try? await capture(["branch", "--show-current"], at: path))?.stdout ?? ""
        return GitOutputParser.snapshot(revParseHead: head.stdout,
                                        statusPorcelain: status,
                                        branchShowCurrent: branch)
    }

    public func createBranch(_ name: String, at path: String) async throws {
        try await require(["switch", "-c", name], at: path)
    }

    public func stashAll(at path: String) async throws {
        try await require(["stash", "push", "-u", "-m", "shotcue"], at: path)
    }

    @discardableResult
    private func require(_ arguments: [String], at path: String) async throws -> ProcessOutput {
        let output = try await capture(arguments, at: path)
        guard output.exitCode == 0 else {
            throw GitError.commandFailed(arguments: arguments, exitCode: output.exitCode, stderr: output.stderr)
        }
        return output
    }

    private func capture(_ arguments: [String], at path: String) async throws -> ProcessOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return try await ProcessCapture.run(
            executableURL: gitExecutable,
            arguments: arguments,
            currentDirectory: URL(fileURLWithPath: path, isDirectory: true),
            environment: environment)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=ShellGitInspectorTests 2>&1 | tail -3`
Expected: `Test run with 5 tests in 1 suite passed`. Testler gerçek `git`'i geçici dizinlerde çalıştırır; `user.email`/`user.name` depo bazında ayarlandığı için makinenin global git yapılandırmasına dokunulmaz.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueClaudeBridge/ShellGitInspector.swift Tests/ShotcueClaudeBridgeTests/ShellGitInspectorTests.swift
git commit -m "feat(bridge): snapshot git state around runs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: RunLogWriter (NDJSON run logu)

Her `RunEvent`, `runs/<runID>.jsonl` dosyasına tek satırlık bir JSON nesnesi olarak eklenir (`{"t":"toolUse","name":…}`). Anahtarlar sıralı yazılır, bölü işaretleri kaçırılmaz — log `jq` ile okunabilir kalır. `RunLogWriter` bir **değer tipi** olmak zorundadır: runner'ın `@Sendable` olay callback'i onu yakalar.

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/RunLogWriterTests.swift`
- Create: `Sources/ShotcueClaudeBridge/RunLogWriter.swift`

**Interfaces:**
- Consumes (Plan 00, birebir): `FileStore(rootURL:)` → `runLogRelPath(id: UUID) -> String`, `absoluteURL(for relPath: String) -> URL`, `ensureParentDirectory(for relPath: String, fileManager: FileManager = .default) throws`, `public static let runsDir = "runs"`; `RunEvent`; `ClaudeRunResult` (`Codable`).
- Produces: `public struct RunLogWriter: Sendable` → `public init(fileStore: FileStore)`, `public let fileStore: FileStore`, `public static func line(for event: RunEvent) -> String`, `public func append(_ event: RunEvent, runID: UUID) throws`. Task 5 bunu `RunCoordinator` içinde kullanır; Plan 06 aynı formatı okuyarak geçmiş logu gösterir.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/RunLogWriterTests.swift`:

```swift
import Foundation
import ShotcueCore
import Testing
@testable import ShotcueClaudeBridge

@Suite("RunLogWriter")
struct RunLogWriterTests {
    let runID = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!

    func object(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func everyEventKindBecomesOneJSONObject() throws {
        #expect(try object(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")))["t"] as? String == "toolUse")
        #expect(try object(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")))["name"] as? String == "Read")
        #expect(try object(RunLogWriter.line(for: .assistantText("merhaba")))["text"] as? String == "merhaba")
        #expect(try object(RunLogWriter.line(for: .apiRetry(attempt: 2)))["attempt"] as? Int == 2)
        #expect(try object(RunLogWriter.line(for: .other(type: "user")))["type"] as? String == "user")
        let initLine = try object(RunLogWriter.line(for: .initialized(sessionID: "s1", model: "sonnet")))
        #expect(initLine["t"] as? String == "init")
        #expect(initLine["session"] as? String == "s1")
        #expect(initLine["model"] as? String == "sonnet")
        // Slashes are not escaped, so paths stay readable in the log.
        #expect(RunLogWriter.line(for: .toolUse(name: "Read", summary: "Read /tmp/a.png")).contains("/tmp/a.png"))
    }

    @Test func resultIsNested() throws {
        let result = ClaudeRunResult(subtype: "success", isError: false, sessionID: "s",
                                     result: "ok", totalCostUSD: 0.42, numTurns: 7, durationMs: 1234)
        let line = try object(RunLogWriter.line(for: .result(result)))
        #expect(line["t"] as? String == "result")
        let nested = try #require(line["result"] as? [String: Any])
        #expect(nested["subtype"] as? String == "success")
        #expect(nested["numTurns"] as? Int == 7)
        #expect(nested["totalCostUSD"] as? Double == 0.42)
    }

    @Test func appendWritesOneLinePerEventAndCreatesTheDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileStore(rootURL: root)
        let writer = RunLogWriter(fileStore: store)

        try writer.append(.initialized(sessionID: "s", model: "m"), runID: runID)
        try writer.append(.assistantText("bir"), runID: runID)
        try writer.append(.assistantText("iki\nsatır"), runID: runID)

        let url = store.absoluteURL(for: store.runLogRelPath(id: runID))
        #expect(url.path.hasSuffix("runs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        // An embedded newline must not become a second line.
        #expect(try object(String(lines[2]))["text"] as? String == "iki\nsatır")
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=RunLogWriterTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'RunLogWriter' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueClaudeBridge/RunLogWriter.swift`:

```swift
import Foundation
import ShotcueCore

/// Appends one JSON object per `RunEvent` to `runs/<runID>.jsonl` (spec §6.4).
/// A value type so the runner's `@Sendable` event callback can capture it.
public struct RunLogWriter: Sendable {
    public let fileStore: FileStore

    public init(fileStore: FileStore) { self.fileStore = fileStore }

    /// Flat shape so the UI (and a human with `jq`) can read the log without the Core enum.
    struct Record: Encodable {
        var t: String
        var attempt: Int?
        var model: String?
        var name: String?
        var result: ClaudeRunResult?
        var session: String?
        var summary: String?
        var text: String?
        var type: String?
    }

    static func record(for event: RunEvent) -> Record {
        switch event {
        case .initialized(let sessionID, let model):
            return Record(t: "init", model: model, session: sessionID)
        case .assistantText(let text):
            return Record(t: "assistantText", text: text)
        case .toolUse(let name, let summary):
            return Record(t: "toolUse", name: name, summary: summary)
        case .apiRetry(let attempt):
            return Record(t: "apiRetry", attempt: attempt)
        case .result(let result):
            return Record(t: "result", result: result)
        case .other(let type):
            return Record(t: "other", type: type)
        }
    }

    /// One line of NDJSON, keys sorted so the output is byte-stable.
    public static func line(for event: RunEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record(for: event)) else { return #"{"t":"unencodable"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    public func append(_ event: RunEvent, runID: UUID) throws {
        let relPath = fileStore.runLogRelPath(id: runID)
        let url = fileStore.absoluteURL(for: relPath)
        let payload = Data((Self.line(for: event) + "\n").utf8)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            try fileStore.ensureParentDirectory(for: relPath)
            try payload.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=RunLogWriterTests 2>&1 | tail -3`
Expected: `Test run with 3 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueClaudeBridge/RunLogWriter.swift Tests/ShotcueClaudeBridgeTests/RunLogWriterTests.swift
git commit -m "feat(bridge): append run events to an ndjson log

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: RunCoordinator (kuyruk, run yaşam döngüsü, canlı olaylar)

Planın en büyük parçası. `RunCoordinator` Core'daki `TaskDispatcher` protokolünü uygular ve UI'ın gördüğü tek yüzdür. Sorumlulukları:

- `enqueue(taskID:)` → task'ı `transition(to: .queued)` ile kuyruğa alır, kaydeder, kuyruğu pompalar.
- `pumpQueue()` → `QueuePolicy.nextRunnable(queued:runningProjectIDs:runningCount:maxConcurrent:)` ile aday kalmayana kadar run başlatır. **Aday seçimiyle kaydetme arasında hiç `await` yok**; aktör yeniden girişli olduğu için aynı task iki kez başlatılmasın diye kayıt senkron yapılır.
- Bir run: `Run(id: UUID(), taskID:, state: .starting, logRelPath: fileStore.runLogRelPath(id:))` satırı → (proje ayarı açıksa `createBranch(GitOutputParser.branchName(for:))` ve `stashAll`) → run öncesi git snapshot'ı → `PromptInput` (ekran görüntülerinin **mutlak** yolları, ilkinin etiketi task başlığı; not metni; yalnızca `transcriptState == .done` olan sesli notların transkriptleri) → `RunSpec` → task `.running` → `keepAwake` açıksa `beginActivity(options: [.idleSystemSleepDisabled, .userInitiated])` → `runner.run(spec) { event in … }`; her olay `runs/<id>.jsonl`'a bir satır olarak yazılır ve `liveEvents` abonelerine dağıtılır.
- Sonuç eşlemesi: `isSuccess` → run `.succeeded` / task `.done`; `hitLimit` veya diğer `is_error` → run `.failed` (`error = subtype`) / task `.failed`; `ClaudeRunError.cancelled` → run `.cancelled` / task `.cancelled` (bildirim yok); diğer hatalar → `.failed`. Her durumda `finishedAt`, `numTurns`, `costUSD`, `resultText`, `subtype`, `exitCode` ve run sonrası git snapshot'ı yazılır, ardından `Notifier` çağrılır ve kuyruk yeniden pompalanır.
- Proje klasörü taşınmış/silinmişse (spec §8) run **hiç başlatılmaz**: Run satırı `.failed` + açıklayıcı mesajla kaydedilir, task `.ready`'ye döner (yol düzeltilip yeniden gönderilebilsin), bildirim gönderilir ve `runner` hiç çağrılmaz.
- `cancel(taskID:)`: çalışıyorsa `runner.cancel(runID:)`, kuyrukta/zamanlanmışsa `.ready`'ye döner. `runQueueNow()`: her projenin her `ready` task'ı `QueuePolicy.ordered` sırasıyla kuyruğa girer. `setPaused/isPaused`: duraklatma yalnızca pompalamayı durdurur, çalışan run'lar devam eder. `liveEvents(runID:)` **nonisolated**'dır (protokoldeki senkron gereksinim bunu zorunlu kılar) ve izolasyon dışındaki yayıncı kaydına bakar; bitmiş bir run için hemen kapanmış boş akış döner.
- `updateSettings(_:)` ve `recoverInterruptedRuns()` (açılışta `running` kalan run'ları `failed`, task'larını `.failed` yapar).

Durum değişiklikleri **yalnızca** `ShotTask.transition(to:at:)` ile yapılır (Plan 00 Task 2); doğrudan `status =` ataması yasak.

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/Waiting.swift`
- Create: `Tests/ShotcueClaudeBridgeTests/RunCoordinatorTests.swift`
- Create: `Sources/ShotcueClaudeBridge/RunEventBroadcaster.swift`
- Create: `Sources/ShotcueClaudeBridge/RunSettings.swift`
- Create: `Sources/ShotcueClaudeBridge/RunCoordinator.swift`

**Interfaces:**
- Consumes (Plan 00, birebir): `protocol TaskDispatcher: Sendable { func enqueue(taskID: UUID) async throws; func cancel(taskID: UUID) async; func runQueueNow() async; func setPaused(_ paused: Bool) async; func isPaused() async -> Bool; func liveEvents(runID: UUID) -> AsyncStream<RunEvent> }`; `TaskRepository` (`task(id:)`, `tasks(status:)`, `save(_ task:)`, `captures(taskID:)`, `voiceNotes(taskID:)`); `ProjectRepository` (`project(id:)`); `RunRepository` (`save(_ run:)`, `activeRuns()`, `markInterruptedRuns(at:) -> Int`); `GitInspector`; `FileStore`; `protocol Notifier { func notify(_ notification: AppNotification) async }`; `AppNotification(kind:title:body:taskID:runID:)` + `Kind.runDone/.runFailed`; `protocol Clock { var now: Date { get } }`; `ShotTask.transition(to:at:) throws(TaskStateError)`; `QueuePolicy.ordered(_:)` / `.nextRunnable(queued:runningProjectIDs:runningCount:maxConcurrent:)`; `PromptBuilder.build(_:) -> String` + `PromptBuilder.systemPromptAppend`; `PromptInput(mode:title:projectPath:screenshots:noteText:transcripts:)`; `ScreenshotRef(absolutePath:label:)`; `Run(id:taskID:state:startedAt:finishedAt:numTurns:costUSD:resultText:subtype:exitCode:error:logRelPath:gitHeadBefore:gitDirtyBefore:gitHeadAfter:gitBranch:)`; `GitOutputParser.branchName(for:)`; `Capture.relPath`, `VoiceNote.transcript`/`.transcriptState`; `Project.path`/`.defaultModel`/`.defaultEffort`/`.runInBranch`/`.stashBeforeRun`. Testlerde `ShotcueTestSupport`: `FakeClaudeRunner(events:outcome:eventDelay:version:)` (+`specs`, `cancelled`), `InMemoryTaskRepository`, `InMemoryProjectRepository`, `InMemoryRunRepository`, `FakeGitInspector(snapshots:)` (+`branches`, `stashes`), `FakeNotifier` (+`sent`), `MutableClock`, `Locked`.
- Produces: `public struct RunSettings: Sendable, Equatable` → `public init(maxConcurrent: Int = 2, maxTurns: Int = 50, maxBudgetUSD: Double = 5, timeout: TimeInterval = 1800, permissionMode: ClaudePermissionMode = .bypassPermissions, model: String? = nil, effort: String? = nil, extraSystemPrompt: String = "", keepAwake: Bool = true)`; `public actor RunCoordinator: TaskDispatcher` → `public init(runner: any ClaudeRunner, taskRepository: any TaskRepository, projectRepository: any ProjectRepository, runRepository: any RunRepository, gitInspector: any GitInspector, fileStore: FileStore, notifier: any Notifier, clock: any Clock, settings: RunSettings)`, `public func updateSettings(_ settings: RunSettings)`, `public func recoverInterruptedRuns() async throws -> Int`, `public nonisolated func liveEvents(runID: UUID) -> AsyncStream<RunEvent>` + protokolün diğer üyeleri. Task 6 `SchedulerDriver`'a `any TaskDispatcher` olarak, Plan 06 `AppEnvironment`'a bu initializer ile girer.

- [ ] **Step 1: Test yardımcısını yaz**

`Tests/ShotcueClaudeBridgeTests/Waiting.swift`:

```swift
import Foundation
import Testing

/// Polls until `condition` holds. `RunCoordinator` starts runs in detached tasks, so tests
/// observe the repositories instead of awaiting the run itself.
func waitUntil(_ description: String, timeout: Duration = .seconds(10),
               _ condition: @Sendable () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for: \(description)")
}
```

- [ ] **Step 2: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/RunCoordinatorTests.swift`:

```swift
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing
@testable import ShotcueClaudeBridge

/// `FakeClaudeRunner` can only fail with `FakeError`; the cancelled/timeout mapping needs a
/// runner that throws `ClaudeRunError`.
final class ErrorClaudeRunner: ClaudeRunner, @unchecked Sendable {
    let error: ClaudeRunError
    let cancelled = Locked<[UUID]>([])
    init(_ error: ClaudeRunError) { self.error = error }
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        onEvent(.assistantText("başladı"))
        throw error
    }
    func cancel(runID: UUID) async { cancelled.withLock { $0.append(runID) } }
    func version() async throws -> String { "2.1.278 (Claude Code)" }
}

struct Harness {
    static let head = "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7"

    /// The coordinator refuses to run when the project directory is missing (spec §8),
    /// so every fixture project points at a directory that really exists.
    static func makeProjectDirectory(_ name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-project-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    let clock: MutableClock
    let projectRepository: InMemoryProjectRepository
    let taskRepository: InMemoryTaskRepository
    let runRepository: InMemoryRunRepository
    let gitInspector: FakeGitInspector
    let notifier: FakeNotifier
    let fileStore: FileStore
    let coordinator: RunCoordinator
    let root: URL

    init(projects: [Project], tasks: [ShotTask], runs: [Run] = [], runner: any ClaudeRunner,
         settings: RunSettings = RunSettings(keepAwake: false)) {
        clock = MutableClock()
        projectRepository = InMemoryProjectRepository(projects)
        taskRepository = InMemoryTaskRepository(tasks)
        runRepository = InMemoryRunRepository(runs)
        gitInspector = FakeGitInspector(snapshots: Dictionary(
            uniqueKeysWithValues: projects.map {
                ($0.path, GitSnapshot(head: Harness.head, isDirty: false, branch: "main"))
            }))
        notifier = FakeNotifier()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-coord-\(UUID().uuidString)", isDirectory: true)
        fileStore = FileStore(rootURL: root)
        coordinator = RunCoordinator(runner: runner, taskRepository: taskRepository,
                                     projectRepository: projectRepository, runRepository: runRepository,
                                     gitInspector: gitInspector, fileStore: fileStore,
                                     notifier: notifier, clock: clock, settings: settings)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func runs(of taskID: UUID) async -> [Run] { (try? await runRepository.runs(taskID: taskID)) ?? [] }
    func status(of taskID: UUID) async -> TaskStatus? { try? await taskRepository.task(id: taskID)?.status }
}

@Suite("RunCoordinator")
struct RunCoordinatorTests {
    func successRunner(delay: Duration = .zero) -> FakeClaudeRunner {
        FakeClaudeRunner(
            events: [.assistantText("bakıyorum"), .toolUse(name: "Read", summary: "Read a.png")],
            outcome: .success(ClaudeRunResult(subtype: "success", isError: false,
                                              result: "Özet satırı\nikinci satır",
                                              totalCostUSD: 0.42, numTurns: 7, durationMs: 1234)),
            eventDelay: delay)
    }

    @Test func enqueueRunsTheTaskAndFillsTheRunRow() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Buton rengi", noteText: "Kırmızı olmalı.", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run succeeded") { await h.runs(of: task.id).first?.state == .succeeded }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.numTurns == 7)
        #expect(run.costUSD == 0.42)
        #expect(run.resultText == "Özet satırı\nikinci satır")
        #expect(run.subtype == "success")
        #expect(run.exitCode == 0)
        #expect(run.finishedAt != nil)
        #expect(run.gitHeadBefore == Harness.head)
        #expect(run.gitHeadAfter == Harness.head)
        #expect(run.gitDirtyBefore == false)
        #expect(run.gitBranch == "main")
        #expect(run.logRelPath == h.fileStore.runLogRelPath(id: run.id))
        // The Run id IS the Claude session id: it is what the runner receives as --session-id.
        #expect(runner.specs.current.first?.runID == run.id)
        #expect(await h.status(of: task.id) == .done)

        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.kind == .runDone)
        #expect(notification.title == "Buton rengi")
        #expect(notification.body == "Özet satırı")
        #expect(notification.taskID == task.id)
        #expect(notification.runID == run.id)

        // One log line per forwarded event (the final result is the return value, not an event).
        let log = try String(contentsOf: h.fileStore.absoluteURL(for: run.logRelPath), encoding: .utf8)
        #expect(log.split(separator: "\n", omittingEmptySubsequences: true).count == 2)
        #expect(log.contains("\"t\":\"toolUse\""))
    }

    @Test func limitResultFailsTheTaskAndNotifies() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Uzun iş", status: .ready)
        let runner = FakeClaudeRunner(events: [],
                                      outcome: .success(ClaudeRunResult(subtype: ClaudeRunResult.maxTurnsSubtype,
                                                                        isError: true, numTurns: 30)))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.subtype == ClaudeRunResult.maxTurnsSubtype)
        #expect(run.error == ClaudeRunResult.maxTurnsSubtype)
        #expect(await h.status(of: task.id) == .failed)
        let notification = try #require(h.notifier.sent.current.first)
        #expect(notification.kind == .runFailed)
        #expect(notification.body == "Tur limiti aşıldı (30 tur).")
    }

    @Test func cancelledRunnerErrorMapsToCancelledWithoutANotification() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "İptal", status: .ready)
        let h = Harness(projects: [project], tasks: [task], runner: ErrorClaudeRunner(.cancelled))
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run cancelled") { await h.runs(of: task.id).first?.state == .cancelled }

        #expect(await h.status(of: task.id) == .cancelled)
        #expect(h.notifier.sent.current.isEmpty)
    }

    @Test func processFailureRecordsExitCodeAndAuthHint() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Auth", status: .ready)
        let runner = ErrorClaudeRunner(.processFailed(exitCode: 1, stderr: "Error: not logged in. Run 'claude login'."))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.exitCode == 1)
        #expect(run.error == "claude ile tekrar giriş yapın.")
        #expect(h.notifier.sent.current.first?.kind == .runFailed)
    }

    @Test func cancelForwardsToTheRunnerWhileRunningAndUnqueuesOtherwise() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let running = ShotTask(projectID: project.id, title: "Çalışan", status: .ready, sortIndex: 1)
        let runner = successRunner(delay: .milliseconds(120))
        let h = Harness(projects: [project], tasks: [running], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: running.id)
        await waitUntil("task running") { await h.status(of: running.id) == .running }
        let runID = try #require(await h.runs(of: running.id).first?.id)
        await h.coordinator.cancel(taskID: running.id)
        #expect(runner.cancelled.current == [runID])

        // A queued (not yet started) task goes back to `ready` instead.
        await h.coordinator.setPaused(true)
        let queued = ShotTask(projectID: project.id, title: "Kuyrukta", status: .ready, sortIndex: 2)
        try await h.taskRepository.save(queued)
        try await h.coordinator.enqueue(taskID: queued.id)
        #expect(await h.status(of: queued.id) == .queued)
        await h.coordinator.cancel(taskID: queued.id)
        #expect(await h.status(of: queued.id) == .ready)
    }

    @Test func oneRunPerProjectAndTheGlobalLimitAreRespected() async throws {
        let first = Project(name: "a", path: Harness.makeProjectDirectory("a"))
        let second = Project(name: "b", path: Harness.makeProjectDirectory("b"))
        let tasks = [
            ShotTask(projectID: first.id, title: "a1", status: .ready, sortIndex: 1),
            ShotTask(projectID: first.id, title: "a2", status: .ready, sortIndex: 2),
            ShotTask(projectID: second.id, title: "b1", status: .ready, sortIndex: 3),
            ShotTask(projectID: second.id, title: "b2", status: .ready, sortIndex: 4),
        ]
        let h = Harness(projects: [first, second], tasks: tasks,
                        runner: successRunner(delay: .milliseconds(40)),
                        settings: RunSettings(maxConcurrent: 2, keepAwake: false))
        defer { h.cleanUp() }

        for task in tasks { try await h.coordinator.enqueue(taskID: task.id) }

        var peak = 0
        var everDoubledUpOnOneProject = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let running = (try? await h.taskRepository.tasks(status: .running)) ?? []
            peak = max(peak, running.count)
            if Set(running.compactMap(\.projectID)).count != running.count { everDoubledUpOnOneProject = true }
            if ((try? await h.taskRepository.tasks(status: .done)) ?? []).count == tasks.count { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let done = (try? await h.taskRepository.tasks(status: .done)) ?? []
        #expect(done.count == 4)
        #expect(peak >= 1)
        #expect(peak <= 2)
        #expect(everDoubledUpOnOneProject == false)
    }

    @Test func pausedQueueDoesNotStartRuns() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Beklet", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        await h.coordinator.setPaused(true)
        #expect(await h.coordinator.isPaused())
        try await h.coordinator.enqueue(taskID: task.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.status(of: task.id) == .queued)
        #expect(runner.specs.current.isEmpty)

        await h.coordinator.setPaused(false)
        await waitUntil("run succeeded after resume") { await h.status(of: task.id) == .done }
    }

    @Test func runQueueNowEnqueuesEveryReadyTaskInManualOrder() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let tasks = [
            ShotTask(projectID: project.id, title: "üçüncü", status: .ready, sortIndex: 3),
            ShotTask(projectID: project.id, title: "birinci", status: .ready, sortIndex: 1),
            ShotTask(projectID: project.id, title: "ikinci", status: .ready, sortIndex: 2),
            ShotTask(title: "projesiz", status: .inbox, sortIndex: 0),
        ]
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: tasks, runner: runner,
                        settings: RunSettings(maxConcurrent: 1, keepAwake: false))
        defer { h.cleanUp() }

        await h.coordinator.runQueueNow()
        await waitUntil("all three finished") { runner.specs.current.count == 3 }

        let titles = runner.specs.current.compactMap { spec in
            spec.prompt.components(separatedBy: "\n").first { $0.hasPrefix("TITLE: ") }
        }
        #expect(titles == ["TITLE: birinci", "TITLE: ikinci", "TITLE: üçüncü"])
        #expect(await h.status(of: tasks[3].id) == .inbox)
    }

    @Test func analyzeModeLocksTheRunDown() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "İncele", status: .ready, mode: .analyze)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let spec = try #require(runner.specs.current.first)
        #expect(spec.mode == .analyze)
        #expect(spec.permissionMode == .dontAsk)
        #expect(spec.prompt.hasPrefix("TASK TYPE: ANALYZE ONLY"))
        let arguments = ClaudeArguments.build(spec: spec)
        #expect(arguments.contains("--allowedTools"))
        let modeIndex = try #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(arguments[modeIndex + 1] == "dontAsk")
    }

    @Test func specCarriesSettingsProjectDefaultsAndCaptureDirectory() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"), defaultModel: "sonnet", defaultEffort: "medium")
        let task = ShotTask(projectID: project.id, title: "Model", status: .ready, modelOverride: "opus")
        let runner = successRunner()
        let settings = RunSettings(maxTurns: 12, maxBudgetUSD: 3.5, timeout: 600,
                                   permissionMode: .acceptEdits, model: "haiku", effort: "low",
                                   extraSystemPrompt: "Türkçe cevap ver.", keepAwake: false)
        let h = Harness(projects: [project], tasks: [task], runner: runner, settings: settings)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let spec = try #require(runner.specs.current.first)
        #expect(spec.model == "opus")             // task override wins over project and settings
        #expect(spec.effort == "medium")          // project default wins over settings
        #expect(spec.maxTurns == 12)
        #expect(spec.maxBudgetUSD == 3.5)
        #expect(spec.timeout == 600)
        #expect(spec.permissionMode == .acceptEdits)
        #expect(spec.projectPath == project.path)
        #expect(spec.addDirs == [h.fileStore.rootURL.appendingPathComponent("captures", isDirectory: true).path])
        #expect(spec.systemPromptAppend.hasPrefix(PromptBuilder.systemPromptAppend))
        #expect(spec.systemPromptAppend.hasSuffix("\n\nTürkçe cevap ver."))
    }

    @Test func promptCarriesCaptureAbsolutePathsAndTranscripts() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Filtre bozuk", noteText: "Son 7 gün yanlış.", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }
        try await h.taskRepository.save(Capture(taskID: task.id, relPath: "captures/2026/09/first.png",
                                                width: 100, height: 50,
                                                createdAt: Date(timeIntervalSince1970: 1)))
        try await h.taskRepository.save(Capture(taskID: task.id, relPath: "captures/2026/09/second.png",
                                                width: 100, height: 50,
                                                createdAt: Date(timeIntervalSince1970: 2)))
        try await h.taskRepository.save(VoiceNote(taskID: task.id, relPath: "audio/a.m4a", durationSec: 3,
                                                  transcript: "tarih filtresi çalışmıyor",
                                                  transcriptState: .done))
        try await h.taskRepository.save(VoiceNote(taskID: task.id, relPath: "audio/b.m4a", durationSec: 3,
                                                  transcript: "bu henüz yazıya dökülmedi",
                                                  transcriptState: .pending))

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let prompt = try #require(runner.specs.current.first?.prompt)
        let firstPath = h.fileStore.absoluteURL(for: "captures/2026/09/first.png").path
        let secondPath = h.fileStore.absoluteURL(for: "captures/2026/09/second.png").path
        #expect(prompt.contains("- \(firstPath)  (Filtre bozuk)"))
        #expect(prompt.contains("- \(secondPath)"))
        #expect(prompt.contains("tarih filtresi çalışmıyor"))
        #expect(!prompt.contains("bu henüz yazıya dökülmedi"))
        #expect(prompt.contains("Son 7 gün yanlış."))
    }

    @Test func branchAndStashSettingsCallTheInspector() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"), runInBranch: true, stashBeforeRun: true)
        let task = ShotTask(projectID: project.id, title: "Dalda çalış", status: .ready)
        let h = Harness(projects: [project], tasks: [task], runner: successRunner())
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run succeeded") { await h.runs(of: task.id).first?.state == .succeeded }

        #expect(h.gitInspector.branches.current.map(\.name) == [GitOutputParser.branchName(for: task.id)])
        #expect(h.gitInspector.branches.current.map(\.path) == [project.path])
        #expect(h.gitInspector.stashes.current == [project.path])
        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.gitBranch == GitOutputParser.branchName(for: task.id))
    }

    @Test func liveEventsStreamsAndFinishes() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Canlı", status: .ready)
        let runner = FakeClaudeRunner(
            events: [.assistantText("bir"), .assistantText("iki"), .assistantText("üç")],
            outcome: .success(ClaudeRunResult(subtype: "success", isError: false)),
            eventDelay: .milliseconds(80))
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run row created") { await h.runs(of: task.id).first != nil }
        let runID = try #require(await h.runs(of: task.id).first?.id)

        let stream = h.coordinator.liveEvents(runID: runID)
        var received: [RunEvent] = []
        for await event in stream { received.append(event) }   // finishes when the run ends

        #expect(!received.isEmpty)
        #expect(received.allSatisfy { if case .assistantText = $0 { return true } else { return false } })
        #expect(await h.status(of: task.id) == .done)

        // Subscribing to a finished run yields an empty, already-finished stream.
        var afterwards: [RunEvent] = []
        for await event in h.coordinator.liveEvents(runID: runID) { afterwards.append(event) }
        #expect(afterwards.isEmpty)
    }

    @Test func recoverInterruptedRunsFailsLeftoverRuns() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let interrupted = ShotTask(projectID: project.id, title: "Yarım kalan", status: .running)
        let finished = ShotTask(projectID: project.id, title: "Biten", status: .done)
        let staleRun = Run(taskID: interrupted.id, state: .running, logRelPath: "runs/a.jsonl")
        let oldRun = Run(taskID: finished.id, state: .succeeded, logRelPath: "runs/b.jsonl")
        let h = Harness(projects: [project], tasks: [interrupted, finished], runs: [staleRun, oldRun],
                        runner: successRunner())
        defer { h.cleanUp() }

        #expect(try await h.coordinator.recoverInterruptedRuns() == 1)
        #expect(await h.status(of: interrupted.id) == .failed)
        #expect(await h.status(of: finished.id) == .done)
        let recovered = try #require(await h.runs(of: interrupted.id).first)
        #expect(recovered.state == .failed)
        #expect(recovered.error == "interrupted")
        #expect(try await h.runRepository.activeRuns().isEmpty)
    }

    @Test func missingProjectDirectoryFailsBeforeTheRunnerIsCalled() async throws {
        let project = Project(name: "taşınmış", path: "/tmp/shotcue-does-not-exist-\(UUID().uuidString)")
        let task = ShotTask(projectID: project.id, title: "Kayıp proje", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("run failed") { await h.runs(of: task.id).first?.state == .failed }

        #expect(runner.specs.current.isEmpty)
        // The task never ran, so it returns to `ready` instead of `failed`.
        #expect(await h.status(of: task.id) == .ready)
        let run = try #require(await h.runs(of: task.id).first)
        #expect(run.error == RunCoordinator.missingProjectMessage(path: project.path))
        #expect(h.notifier.sent.current.first?.kind == .runFailed)
    }

    @Test func updateSettingsAppliesToTheNextRun() async throws {
        let project = Project(name: "crm", path: Harness.makeProjectDirectory("crm"))
        let task = ShotTask(projectID: project.id, title: "Ayar", status: .ready)
        let runner = successRunner()
        let h = Harness(projects: [project], tasks: [task], runner: runner)
        defer { h.cleanUp() }

        await h.coordinator.updateSettings(RunSettings(maxTurns: 99, maxBudgetUSD: 1.25, keepAwake: false))
        try await h.coordinator.enqueue(taskID: task.id)
        await waitUntil("spec captured") { !runner.specs.current.isEmpty }

        let spec = try #require(runner.specs.current.first)
        #expect(spec.maxTurns == 99)
        #expect(spec.maxBudgetUSD == 1.25)
    }
}
```

- [ ] **Step 3: Testin derlenmediğini gör**

Run: `make test FILTER=RunCoordinatorTests 2>&1 | grep -m2 "error:"`
Expected: `cannot find 'RunSettings' in scope` ve `cannot find 'RunCoordinator' in scope`.

- [ ] **Step 4: RunEventBroadcaster'ı yaz**

`Sources/ShotcueClaudeBridge/RunEventBroadcaster.swift`:

```swift
import Foundation
import ShotcueCore

/// Fans one run's events out to every `liveEvents` subscriber.
///
/// `yield`/`finish` are called OUTSIDE the lock: `onTermination` runs synchronously on the
/// caller's thread and takes the same lock, which deadlocks NSLock (verified in the spike).
final class RunEventBroadcaster: @unchecked Sendable {
    private let continuations = LockBox<[UUID: AsyncStream<RunEvent>.Continuation]>([:])

    func stream() -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [continuations] _ in
                continuations.withLock { $0[id] = nil }
            }
        }
    }

    func send(_ event: RunEvent) {
        let targets = continuations.withLock { Array($0.values) }
        for target in targets { target.yield(event) }
    }

    func finish() {
        let targets = continuations.withLock { registry -> [AsyncStream<RunEvent>.Continuation] in
            let all = Array(registry.values)
            registry.removeAll()
            return all
        }
        for target in targets { target.finish() }
    }
}
```

- [ ] **Step 5: RunSettings'i yaz**

`Sources/ShotcueClaudeBridge/RunSettings.swift`:

```swift
import Foundation
import ShotcueCore

/// The Claude tab of Settings (spec §6.6), passed to `RunCoordinator` and refreshed with
/// `updateSettings(_:)` whenever the user changes something.
public struct RunSettings: Sendable, Equatable {
    public var maxConcurrent: Int
    public var maxTurns: Int
    public var maxBudgetUSD: Double
    public var timeout: TimeInterval
    public var permissionMode: ClaudePermissionMode
    public var model: String?
    public var effort: String?
    public var extraSystemPrompt: String
    public var keepAwake: Bool

    public init(maxConcurrent: Int = 2, maxTurns: Int = 50, maxBudgetUSD: Double = 5,
                timeout: TimeInterval = 1800, permissionMode: ClaudePermissionMode = .bypassPermissions,
                model: String? = nil, effort: String? = nil, extraSystemPrompt: String = "",
                keepAwake: Bool = true) {
        self.maxConcurrent = maxConcurrent
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.timeout = timeout
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
        self.extraSystemPrompt = extraSystemPrompt
        self.keepAwake = keepAwake
    }
}
```

- [ ] **Step 6: RunCoordinator'ı yaz**

`Sources/ShotcueClaudeBridge/RunCoordinator.swift`:

```swift
import Foundation
import ShotcueCore

/// Owns the run queue (spec §5.5, §6.4): at most one run per project, a global concurrency limit,
/// git snapshots around every run, the NDJSON log, notifications and the live event stream.
/// All time decisions live in `SchedulerRules`/`QueuePolicy`; this actor only applies them.
public actor RunCoordinator: TaskDispatcher {
    private struct InFlight: Sendable {
        var runID: UUID
        var projectID: UUID
    }

    private let runner: any ClaudeRunner
    private let taskRepository: any TaskRepository
    private let projectRepository: any ProjectRepository
    private let runRepository: any RunRepository
    private let gitInspector: any GitInspector
    private let fileStore: FileStore
    private let notifier: any Notifier
    private let clock: any Clock
    private let logWriter: RunLogWriter

    /// Outside actor isolation so the nonisolated `liveEvents` and the runner's @Sendable
    /// event callback can reach them.
    private let broadcasters = LockBox<[UUID: RunEventBroadcaster]>([:])
    private let finishedRunIDs = LockBox<Set<UUID>>([])

    private var settings: RunSettings
    private var paused = false
    private var inFlight: [UUID: InFlight] = [:]
    private var activities: [UUID: any NSObjectProtocol] = [:]

    public init(runner: any ClaudeRunner, taskRepository: any TaskRepository,
                projectRepository: any ProjectRepository, runRepository: any RunRepository,
                gitInspector: any GitInspector, fileStore: FileStore, notifier: any Notifier,
                clock: any Clock, settings: RunSettings) {
        self.runner = runner
        self.taskRepository = taskRepository
        self.projectRepository = projectRepository
        self.runRepository = runRepository
        self.gitInspector = gitInspector
        self.fileStore = fileStore
        self.notifier = notifier
        self.clock = clock
        self.settings = settings
        self.logWriter = RunLogWriter(fileStore: fileStore)
    }

    // MARK: - TaskDispatcher

    public func enqueue(taskID: UUID) async throws {
        guard var task = try await taskRepository.task(id: taskID) else { return }
        try task.transition(to: .queued, at: clock.now)
        try await taskRepository.save(task)
        await pumpQueue()
    }

    public func cancel(taskID: UUID) async {
        if let flight = inFlight[taskID] {
            await runner.cancel(runID: flight.runID)
            return
        }
        guard var task = try? await taskRepository.task(id: taskID),
              task.status == .queued || task.status == .scheduled
        else { return }
        await apply(.ready, to: &task)
    }

    public func runQueueNow() async {
        let ready = (try? await taskRepository.tasks(status: .ready)) ?? []
        for task in QueuePolicy.ordered(ready) where task.projectID != nil {
            try? await enqueue(taskID: task.id)
        }
        await pumpQueue()
    }

    public func setPaused(_ paused: Bool) async {
        self.paused = paused
        if !paused { await pumpQueue() }
    }

    public func isPaused() async -> Bool { paused }

    public nonisolated func liveEvents(runID: UUID) -> AsyncStream<RunEvent> {
        if finishedRunIDs.current.contains(runID) {
            return AsyncStream { $0.finish() }
        }
        return broadcaster(for: runID).stream()
    }

    // MARK: - App-facing extras

    public func updateSettings(_ settings: RunSettings) { self.settings = settings }

    /// Launch recovery (spec §8): runs left `starting`/`running` by a crash become `failed`.
    public func recoverInterruptedRuns() async throws -> Int {
        let stale = try await runRepository.activeRuns()
        let count = try await runRepository.markInterruptedRuns(at: clock.now)
        for run in stale {
            guard var task = try await taskRepository.task(id: run.taskID), task.status == .running else { continue }
            await apply(.failed, to: &task)
        }
        return count
    }

    // MARK: - Queue

    private func pumpQueue() async {
        guard !paused else { return }
        while true {
            let queued = ((try? await taskRepository.tasks(status: .queued)) ?? [])
                .filter { inFlight[$0.id] == nil }
            guard let next = QueuePolicy.nextRunnable(
                queued: queued,
                runningProjectIDs: Set(inFlight.values.map(\.projectID)),
                runningCount: inFlight.count,
                maxConcurrent: settings.maxConcurrent)
            else { return }
            guard start(next) else { return }
        }
    }

    /// Registers the run without suspending, so a reentrant `pumpQueue` cannot double-start it.
    private func start(_ task: ShotTask) -> Bool {
        guard let projectID = task.projectID else { return false }
        let runID = UUID()
        inFlight[task.id] = InFlight(runID: runID, projectID: projectID)
        Task { await self.execute(taskID: task.id, runID: runID) }
        return true
    }

    private func finishInFlight(_ taskID: UUID) async {
        inFlight[taskID] = nil
        await pumpQueue()
    }

    // MARK: - One run

    private func execute(taskID: UUID, runID: UUID) async {
        guard let loaded = try? await taskRepository.task(id: taskID),
              let projectID = loaded.projectID,
              let project = try? await projectRepository.project(id: projectID)
        else {
            await finishInFlight(taskID)
            return
        }
        var task = loaded
        var run = Run(id: runID, taskID: taskID, state: .starting, startedAt: clock.now,
                      logRelPath: fileStore.runLogRelPath(id: runID))
        try? await runRepository.save(run)

        // Spec §8: a moved or deleted project directory must not start a run at all.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            run.state = .failed
            run.finishedAt = clock.now
            run.error = Self.missingProjectMessage(path: project.path)
            // The task never entered `running`, so it goes back to `ready`: fix the path and resend.
            await apply(.ready, to: &task)
            try? await runRepository.save(run)
            await notifier.notify(AppNotification(kind: .runFailed, title: task.title,
                                                  body: run.error ?? "", taskID: task.id, runID: runID))
            await finishInFlight(taskID)
            return
        }

        if project.runInBranch {
            do {
                try await gitInspector.createBranch(GitOutputParser.branchName(for: taskID), at: project.path)
            } catch {
                run.error = "branch: \(error)"
            }
        }
        if project.stashBeforeRun {
            do {
                try await gitInspector.stashAll(at: project.path)
            } catch {
                run.error = [run.error, "stash: \(error)"].compactMap { $0 }.joined(separator: " | ")
            }
        }
        let before = await gitInspector.snapshot(at: project.path)
        run.gitHeadBefore = before?.head
        run.gitDirtyBefore = before?.isDirty
        run.gitBranch = before?.branch

        let spec = await makeSpec(task: task, project: project, runID: runID)
        run.state = .running
        try? await runRepository.save(run)
        await apply(.running, to: &task)

        let writer = logWriter
        let broadcaster = broadcaster(for: runID)
        let onEvent: @Sendable (RunEvent) -> Void = { event in
            try? writer.append(event, runID: runID)
            broadcaster.send(event)
        }
        if settings.keepAwake {
            activities[runID] = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Shotcue run \(runID.uuidString)")
        }

        let outcome: Result<ClaudeRunResult, any Error>
        do {
            outcome = .success(try await runner.run(spec, onEvent: onEvent))
        } catch {
            outcome = .failure(error)
        }

        if let activity = activities.removeValue(forKey: runID) {
            ProcessInfo.processInfo.endActivity(activity)
        }
        broadcasters.withLock { $0[runID] = nil }
        finishedRunIDs.withLock { _ = $0.insert(runID) }
        broadcaster.finish()

        run.finishedAt = clock.now
        run.gitHeadAfter = await gitInspector.snapshot(at: project.path)?.head
        let notification = await record(outcome: outcome, into: &run, task: &task)
        try? await runRepository.save(run)
        if let notification { await notifier.notify(notification) }
        await finishInFlight(taskID)
    }

    /// Maps the runner outcome onto the Run row, the task status and the notification (spec §6.4).
    private func record(outcome: Result<ClaudeRunResult, any Error>, into run: inout Run,
                        task: inout ShotTask) async -> AppNotification? {
        switch outcome {
        case .success(let result):
            run.numTurns = result.numTurns
            run.costUSD = result.totalCostUSD
            run.resultText = result.result
            run.subtype = result.subtype
            run.exitCode = 0
            if result.isSuccess {
                run.state = .succeeded
                await apply(.done, to: &task)
                return AppNotification(kind: .runDone, title: task.title,
                                       body: Self.firstLine(result.result) ?? "Tamamlandı",
                                       taskID: task.id, runID: run.id)
            }
            run.state = .failed
            run.error = result.subtype
            await apply(.failed, to: &task)
            return AppNotification(kind: .runFailed, title: task.title,
                                   body: Self.message(for: result), taskID: task.id, runID: run.id)

        case .failure(let error):
            let claudeError = error as? ClaudeRunError
            if claudeError == .cancelled {
                run.state = .cancelled
                run.error = "cancelled"
                await apply(.cancelled, to: &task)
                return nil
            }
            run.state = .failed
            run.error = Self.message(for: error)
            if case .processFailed(let exitCode, _) = claudeError { run.exitCode = exitCode }
            await apply(.failed, to: &task)
            return AppNotification(kind: .runFailed, title: task.title,
                                   body: Self.message(for: error), taskID: task.id, runID: run.id)
        }
    }

    private func makeSpec(task: ShotTask, project: Project, runID: UUID) async -> RunSpec {
        let captures = (try? await taskRepository.captures(taskID: task.id)) ?? []
        let voiceNotes = (try? await taskRepository.voiceNotes(taskID: task.id)) ?? []
        let screenshots = captures.enumerated().map { index, capture in
            ScreenshotRef(absolutePath: fileStore.absoluteURL(for: capture.relPath).path,
                          label: index == 0 ? task.title : nil)
        }
        let transcripts = voiceNotes
            .filter { $0.transcriptState == .done }
            .compactMap(\.transcript)
        let prompt = PromptBuilder.build(PromptInput(
            mode: task.mode, title: task.title, projectPath: project.path,
            screenshots: screenshots, noteText: task.noteText, transcripts: transcripts))
        let extra = settings.extraSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunSpec(
            runID: runID,
            prompt: prompt,
            projectPath: project.path,
            mode: task.mode,
            model: task.modelOverride ?? project.defaultModel ?? settings.model,
            effort: project.defaultEffort ?? settings.effort,
            maxTurns: settings.maxTurns,
            maxBudgetUSD: settings.maxBudgetUSD,
            timeout: settings.timeout,
            permissionMode: task.mode == .analyze ? .dontAsk : settings.permissionMode,
            addDirs: [fileStore.rootURL.appendingPathComponent(FileStore.capturesDir, isDirectory: true).path],
            systemPromptAppend: PromptBuilder.systemPromptAppend + (extra.isEmpty ? "" : "\n\n" + extra))
    }

    /// Every status change goes through `ShotTask.transition` (Plan 00 Task 2); direct assignment
    /// is forbidden. A rejected transition means the row changed underneath us — the Run row still
    /// carries the outcome, so we keep going.
    private func apply(_ status: TaskStatus, to task: inout ShotTask) async {
        do {
            try task.transition(to: status, at: clock.now)
            try await taskRepository.save(task)
        } catch {
            return
        }
    }

    private nonisolated func broadcaster(for runID: UUID) -> RunEventBroadcaster {
        broadcasters.withLock { registry in
            if let existing = registry[runID] { return existing }
            let created = RunEventBroadcaster()
            registry[runID] = created
            return created
        }
    }

    // MARK: - Messages (user-visible, Turkish)

    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        return String(line.prefix(200))
    }

    static func message(for result: ClaudeRunResult) -> String {
        switch result.subtype {
        case ClaudeRunResult.maxTurnsSubtype:
            return "Tur limiti aşıldı (\(result.numTurns.map(String.init) ?? "?") tur)."
        case ClaudeRunResult.maxBudgetSubtype:
            return "Bütçe limiti aşıldı."
        default:
            return firstLine(result.result) ?? "Çalışma hata ile bitti (\(result.subtype))."
        }
    }

    static func missingProjectMessage(path: String) -> String {
        "Proje klasörü bulunamadı: \(path). Ayarlar > Projeler'den yolu düzeltin."
    }

    static func message(for error: any Error) -> String {
        guard let error = error as? ClaudeRunError else { return String(describing: error) }
        switch error {
        case .notFound:
            return "claude bulunamadı. Ayarlar > Claude'dan yolu kontrol edin."
        case .launchFailed(let detail):
            return "claude başlatılamadı: \(detail)"
        case .processFailed(let exitCode, let stderr):
            if stderr.lowercased().contains("not logged in") || stderr.lowercased().contains("login") {
                return "claude ile tekrar giriş yapın."
            }
            return firstLine(stderr) ?? "claude \(exitCode) koduyla çıktı."
        case .timedOut:
            return "Zaman aşımı. Çalışma durduruldu."
        case .cancelled:
            return "İptal edildi."
        case .noResult:
            return "claude sonuç satırı üretmeden çıktı."
        }
    }
}
```

- [ ] **Step 7: Testleri çalıştır**

Run: `make test FILTER=RunCoordinatorTests 2>&1 | tail -3`
Expected: `Test run with 16 tests in 1 suite passed`, ~0.3 sn. `oneRunPerProjectAndTheGlobalLimitAreRespected` testinde `peak > 2` görülürse `pumpQueue`'daki `inFlight` kaydı bir `await`'ten sonra yapılıyor demektir; `start(_:)` senkron kalmalı.

- [ ] **Step 8: Commit**

```bash
make format && git add Sources/ShotcueClaudeBridge Tests/ShotcueClaudeBridgeTests
git commit -m "feat(bridge): coordinate the run queue with live events

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: SchedulerDriver (30 sn tick + uyanma)

Zaman kararları Plan 00'daki `SchedulerRules`'da; bu aktör sadece sonuçları uygular. `tick()` tek bir uzlaştırma turudur: süresi gelmiş tek seferlik task'lar kuyruğa alınır, günlük kuyruğu tetiklenen projelerin `ready` task'ları manuel sırayla kuyruğa girer ve `dailyLastFiredAt = clock.now` yazılır (aynı gün ikinci kez tetiklenmez). `start()` bir `DispatchSourceTimer` kurar — Foundation `Timer` run-loop moduna bağlı olduğu için menü çubuğu etkileşimlerinde kayar, `NSBackgroundActivityScheduler` ise çalışma zamanını kendisi seçer; ikisi de yasak. Uyanmada (`NSWorkspace.didWakeNotification`) anında bir tick atılır, böylece uykuda kaçan slot **bir kez** çalışır.

**Duraklatma burada ele alınmaz:** zamanlayıcı her zaman kuyruğa alır, duraklatılmış `RunCoordinator` sadece pompalamaz. Böylece duraklatma kaldırıldığında kaçan işler kaybolmaz (spec §6.5'teki "flood yok" kuralı `SchedulerRules`'un kendi `dailyLastFiredAt` kontrolüyle sağlanır).

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/SchedulerDriverTests.swift`
- Create: `Sources/ShotcueClaudeBridge/SchedulerDriver.swift`

**Interfaces:**
- Consumes (Plan 00, birebir): `SchedulerRules.dueActions(now: Date, calendar: Calendar, tasks: [ShotTask], projects: [Project]) -> [ScheduledAction]`; `SchedulerRules.dailyCandidates(projectID: UUID, tasks: [ShotTask]) -> [ShotTask]`; `enum ScheduledAction { case enqueueTask(UUID); case fireDailyQueue(projectID: UUID) }`; `TaskRepository.allTasks()`; `ProjectRepository.allProjects()` / `.project(id:)` / `.save(_:)`; `Project.dailyLastFiredAt`; `Clock.now`; `TaskDispatcher.enqueue(taskID:)`. Testlerde `FakeTaskDispatcher` (+`enqueued`), `InMemory*`, `MutableClock`, `DailyTime(hour:minute:)`.
- Produces: `public actor SchedulerDriver` → `public init(dispatcher: any TaskDispatcher, taskRepository: any TaskRepository, projectRepository: any ProjectRepository, clock: any Clock, calendar: Calendar = .current, interval: TimeInterval = 30)`, `public func tick() async`, `public func start()`, `public func stop()`. Plan 06 açılışta `start()`, çıkışta `stop()` çağırır ve uygulama ön plana geldiğinde `tick()` ister.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/SchedulerDriverTests.swift`:

```swift
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing
@testable import ShotcueClaudeBridge

@Suite("SchedulerDriver")
struct SchedulerDriverTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// 2025-09-22 10:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_758_535_200)

    func driver(tasks: [ShotTask], projects: [Project], clock: MutableClock,
                dispatcher: FakeTaskDispatcher) -> (SchedulerDriver, InMemoryProjectRepository) {
        let projectRepository = InMemoryProjectRepository(projects)
        let driver = SchedulerDriver(dispatcher: dispatcher,
                                     taskRepository: InMemoryTaskRepository(tasks),
                                     projectRepository: projectRepository,
                                     clock: clock, calendar: utc, interval: 30)
        return (driver, projectRepository)
    }

    @Test func dueOneShotTaskIsEnqueuedOnce() async throws {
        let project = Project(name: "crm", path: "/tmp/crm")
        let due = ShotTask(projectID: project.id, title: "şimdi", status: .scheduled,
                           scheduledAt: now.addingTimeInterval(-60))
        let later = ShotTask(projectID: project.id, title: "sonra", status: .scheduled,
                             scheduledAt: now.addingTimeInterval(3600))
        let dispatcher = FakeTaskDispatcher()
        let (subject, _) = driver(tasks: [due, later], projects: [project],
                                  clock: MutableClock(now), dispatcher: dispatcher)

        await subject.tick()
        #expect(dispatcher.enqueued.current == [due.id])
    }

    @Test func dailyQueueFiresOncePerDayAndStampsTheProject() async throws {
        let project = Project(name: "crm", path: "/tmp/crm", dailyTime: DailyTime(hour: 9, minute: 30),
                              dailyEnabled: true)
        let first = ShotTask(projectID: project.id, title: "bir", status: .ready, sortIndex: 1)
        let second = ShotTask(projectID: project.id, title: "iki", status: .ready, sortIndex: 2)
        let queued = ShotTask(projectID: project.id, title: "zaten kuyrukta", status: .queued, sortIndex: 0)
        let dispatcher = FakeTaskDispatcher()
        let clock = MutableClock(now)
        let (subject, projects) = driver(tasks: [second, queued, first], projects: [project],
                                         clock: clock, dispatcher: dispatcher)

        await subject.tick()
        #expect(dispatcher.enqueued.current == [first.id, second.id])
        #expect(try await projects.project(id: project.id)?.dailyLastFiredAt == now)

        // A second tick on the same day must not fire again.
        clock.advance(by: 60)
        await subject.tick()
        #expect(dispatcher.enqueued.current == [first.id, second.id])
    }

    @Test func disabledDailyQueueNeverFires() async throws {
        let project = Project(name: "crm", path: "/tmp/crm", dailyTime: DailyTime(hour: 9, minute: 0),
                              dailyEnabled: false)
        let task = ShotTask(projectID: project.id, title: "bir", status: .ready)
        let dispatcher = FakeTaskDispatcher()
        let (subject, projects) = driver(tasks: [task], projects: [project],
                                         clock: MutableClock(now), dispatcher: dispatcher)

        await subject.tick()
        #expect(dispatcher.enqueued.current.isEmpty)
        #expect(try await projects.project(id: project.id)?.dailyLastFiredAt == nil)
    }

    @Test func startAndStopAreIdempotent() async throws {
        let dispatcher = FakeTaskDispatcher()
        let (subject, _) = driver(tasks: [], projects: [], clock: MutableClock(now), dispatcher: dispatcher)
        await subject.start()
        await subject.start()
        await subject.stop()
        await subject.stop()
        // The timer fires no earlier than `interval`, so nothing should have been dispatched.
        #expect(dispatcher.enqueued.current.isEmpty)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=SchedulerDriverTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'SchedulerDriver' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueClaudeBridge/SchedulerDriver.swift`:

```swift
import AppKit
import Foundation
import ShotcueCore

/// Applies `SchedulerRules` (spec §6.5). A `DispatchSourceTimer` ticks every `interval` seconds —
/// Foundation's `Timer` is run-loop bound and drifts while the menu bar is interacted with, and
/// `NSBackgroundActivityScheduler` chooses its own time. Waking from sleep ticks immediately so a
/// missed slot runs once (no flood).
public actor SchedulerDriver {
    private let dispatcher: any TaskDispatcher
    private let taskRepository: any TaskRepository
    private let projectRepository: any ProjectRepository
    private let clock: any Clock
    private let calendar: Calendar
    private let interval: TimeInterval

    private let queue = DispatchQueue(label: "com.shotcue.scheduler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wakeObserver: (any NSObjectProtocol)?

    public init(dispatcher: any TaskDispatcher, taskRepository: any TaskRepository,
                projectRepository: any ProjectRepository, clock: any Clock,
                calendar: Calendar = .current, interval: TimeInterval = 30) {
        self.dispatcher = dispatcher
        self.taskRepository = taskRepository
        self.projectRepository = projectRepository
        self.clock = clock
        self.calendar = calendar
        self.interval = interval
    }

    /// One reconcile pass. Pausing is the coordinator's concern: the scheduler always enqueues,
    /// and a paused `RunCoordinator` simply does not pump the queue.
    public func tick() async {
        let tasks = (try? await taskRepository.allTasks()) ?? []
        let projects = (try? await projectRepository.allProjects()) ?? []
        let now = clock.now
        let actions = SchedulerRules.dueActions(now: now, calendar: calendar, tasks: tasks, projects: projects)
        for action in actions {
            switch action {
            case .enqueueTask(let taskID):
                try? await dispatcher.enqueue(taskID: taskID)
            case .fireDailyQueue(let projectID):
                for candidate in SchedulerRules.dailyCandidates(projectID: projectID, tasks: tasks) {
                    try? await dispatcher.enqueue(taskID: candidate.id)
                }
                if var project = try? await projectRepository.project(id: projectID) {
                    project.dailyLastFiredAt = now
                    try? await projectRepository.save(project)
                }
            }
        }
    }

    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        source.activate()
        timer = source
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.tick() }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=SchedulerDriverTests 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueClaudeBridge/SchedulerDriver.swift Tests/ShotcueClaudeBridgeTests/SchedulerDriverTests.swift
git commit -m "feat(bridge): drive scheduled runs with a dispatch timer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: DesktopHandoffService (terminal ve Claude Desktop aktarımı)

Üç aktarım yolu (spec §6.4, araştırma 04 §3):

1. **Terminal:** `runs/<sessionID>-resume.command` dosyası yazılır (`#!/bin/zsh` + `"<claude>" --resume <id>`), 755 yapılır ve `NSWorkspace.shared.open` ile kullanıcının varsayılan terminalinde açılır.
2. **Desktop:** `claude://code/resume?session=<id>` — CLI oturumunu Code sekmesine import eder.
3. **Composer:** `claude://code/new?q=…&folder=…&file=…`. Deep link prompt'u **otomatik göndermez**, composer'a doldurur; `q` Desktop tarafında ~14 336 karakterde sessizce kırpıldığı için 14 000'de kesiyoruz. Prompt bu sınırı aşarsa tamamı `runs/<uuid>-prompt.md`'ye yazılır ve `q` yalnızca "bu dosyayı Read ile oku" talimatını taşır; dosya ayrıca `file=` ile eklenir. `composerRoute` varsayılan `code/new`; 2.2553.1 bundle'ında dosya eklerini gerçekten iliştiren yol `cowork/new` olduğu için (araştırma 04 §3.3-5) Plan 06 Ayarlar'dan bu rotayı değiştirebilir.

URL üretimi `URLComponents` ile yapılır (yüzde kodlamayı kendisi halleder) ve saf `static` fonksiyonlar olarak testlerden çağrılır; `NSWorkspace` test sürecinde çalışmaz.

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/DesktopHandoffServiceTests.swift`
- Create: `Sources/ShotcueClaudeBridge/DesktopHandoffService.swift`

**Interfaces:**
- Consumes (Plan 00, birebir): `protocol HandoffService: Sendable { func openInTerminal(sessionID: String) throws; func openInDesktop(sessionID: String) throws; func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws }`; `FileStore` → `absoluteURL(for:)`, `ensureParentDirectory(for:)`, `promptRelPath(id: UUID) -> String`, `public static let runsDir`.
- Produces: `public enum HandoffError: Error, Equatable, Sendable { case openFailed(String) }`; `public struct DesktopHandoffService: HandoffService` → `public init(claudeExecutable: URL, fileStore: FileStore, composerRoute: String = "code/new")`, `public static let composerPromptLimit = 14_000`, `public static func composerURL(route: String, prompt: String, projectPath: String, files: [String]) -> URL`, `public static func resumeURL(sessionID: String) -> URL`, `public static func commandFileContents(claudeExecutable: URL, sessionID: String) -> String`, `public static func longPromptNotice(path: String) -> String`. Plan 06 bunu Inspector'daki "Terminalde devam et / Desktop'ta aç / Composer'da aç" düğmelerine bağlar.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/DesktopHandoffServiceTests.swift`:

```swift
import Foundation
import ShotcueCore
import Testing
@testable import ShotcueClaudeBridge

@Suite("DesktopHandoffService")
struct DesktopHandoffServiceTests {
    let claude = URL(fileURLWithPath: "/Users/me/.local/bin/claude")

    func makeStore() throws -> FileStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FileStore(rootURL: root)
    }

    @Test func resumeURLMatchesTheDesktopRoute() {
        #expect(DesktopHandoffService.resumeURL(sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
                .absoluteString == "claude://code/resume?session=3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
    }

    @Test func composerURLEncodesEveryParameter() throws {
        let url = DesktopHandoffService.composerURL(
            route: "code/new",
            prompt: "Buton rengi yanlış & \"kırmızı\" olmalı",
            projectPath: "/Users/me/my project",
            files: ["/tmp/a b.png", "/tmp/c.png"])
        #expect(url.scheme == "claude")
        #expect(url.host == "code")
        #expect(url.path == "/new")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.map(\.name) == ["q", "folder", "file", "file"])
        #expect(items[0].value == "Buton rengi yanlış & \"kırmızı\" olmalı")
        #expect(items[1].value == "/Users/me/my project")
        #expect(items[2].value == "/tmp/a b.png")
        // Percent-encoding happens in the raw string, decoded again by URLComponents.
        #expect(url.absoluteString.contains("%20"))
        #expect(url.absoluteString.contains("&folder=/Users/me/my%20project"))
    }

    @Test func composerURLSupportsTheCoworkFallbackRoute() {
        let url = DesktopHandoffService.composerURL(route: "cowork/new", prompt: "x",
                                                    projectPath: "/tmp/p", files: [])
        #expect(url.absoluteString == "claude://cowork/new?q=x&folder=/tmp/p")
    }

    @Test func composerURLTruncatesTheQueryAt14000Characters() throws {
        let long = String(repeating: "a", count: 20_000)
        let url = DesktopHandoffService.composerURL(route: "code/new", prompt: long,
                                                    projectPath: "/tmp/p", files: [])
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try #require(components.queryItems?.first { $0.name == "q" }?.value)
        #expect(query.count == DesktopHandoffService.composerPromptLimit)
        #expect(DesktopHandoffService.composerPromptLimit == 14_000)
    }

    @Test func longPromptsAreSpilledToAFileWithAReadInstruction() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let notice = DesktopHandoffService.longPromptNotice(path: "/tmp/x-prompt.md")
        #expect(notice.contains("/tmp/x-prompt.md"))
        #expect(notice.contains("Read tool"))
        #expect(notice.count < DesktopHandoffService.composerPromptLimit)

        // The spill file is written before NSWorkspace.open (which fails in a test process).
        let service = DesktopHandoffService(claudeExecutable: claude, fileStore: store)
        let long = String(repeating: "ş", count: 20_000)
        try? service.openDesktopComposer(prompt: long, projectPath: "/tmp/p", files: [])
        let runsDirectory = store.absoluteURL(for: FileStore.runsDir)
        let spilled = try FileManager.default.contentsOfDirectory(atPath: runsDirectory.path)
            .filter { $0.hasSuffix("-prompt.md") }
        #expect(spilled.count == 1)
        let written = try String(contentsOf: runsDirectory.appendingPathComponent(spilled[0]), encoding: .utf8)
        #expect(written.count == 20_000)
    }

    @Test func commandFileContentsResumeTheSession() {
        let script = DesktopHandoffService.commandFileContents(
            claudeExecutable: claude, sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
        #expect(script == "#!/bin/zsh\n\"/Users/me/.local/bin/claude\" --resume 3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73\n")
        #expect(!script.contains("--bare"))
    }

    @Test func openInTerminalWritesAnExecutableCommandFile() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let service = DesktopHandoffService(claudeExecutable: claude, fileStore: store)
        let sessionID = "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"
        // NSWorkspace.open fails in a test process; the file must still be written correctly.
        try? service.openInTerminal(sessionID: sessionID)

        let url = store.absoluteURL(for: "runs/\(sessionID)-resume.command")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == DesktopHandoffService.commandFileContents(claudeExecutable: claude, sessionID: sessionID))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o755)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=DesktopHandoffServiceTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'DesktopHandoffService' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueClaudeBridge/DesktopHandoffService.swift`:

```swift
import AppKit
import Foundation
import ShotcueCore

public enum HandoffError: Error, Equatable, Sendable {
    case openFailed(String)
}

/// Hands a session to the terminal or to Claude Desktop (spec §6.4, research 04 §3).
/// Deep links never auto-send: they fill the composer, the user presses Enter.
public struct DesktopHandoffService: HandoffService {
    /// Claude Desktop silently truncates `q` at 14 336 characters; we stay below it.
    public static let composerPromptLimit = 14_000

    public let claudeExecutable: URL
    public let fileStore: FileStore
    /// `code/new` keeps the project context; `cowork/new` is the fallback when file
    /// attachments matter (research 04 §3.3-5).
    public let composerRoute: String

    public init(claudeExecutable: URL, fileStore: FileStore, composerRoute: String = "code/new") {
        self.claudeExecutable = claudeExecutable
        self.fileStore = fileStore
        self.composerRoute = composerRoute
    }

    public func openInTerminal(sessionID: String) throws {
        let relPath = "\(FileStore.runsDir)/\(sessionID)-resume.command"
        try fileStore.ensureParentDirectory(for: relPath)
        let url = fileStore.absoluteURL(for: relPath)
        try Self.commandFileContents(claudeExecutable: claudeExecutable, sessionID: sessionID)
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else { throw HandoffError.openFailed(url.path) }
    }

    public func openInDesktop(sessionID: String) throws {
        let url = Self.resumeURL(sessionID: sessionID)
        guard NSWorkspace.shared.open(url) else { throw HandoffError.openFailed(url.absoluteString) }
    }

    public func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws {
        var text = prompt
        var attachments = files
        if prompt.count > Self.composerPromptLimit {
            let relPath = fileStore.promptRelPath(id: UUID())
            try fileStore.ensureParentDirectory(for: relPath)
            let url = fileStore.absoluteURL(for: relPath)
            try prompt.write(to: url, atomically: true, encoding: .utf8)
            text = Self.longPromptNotice(path: url.path)
            attachments.append(url.path)
        }
        let url = Self.composerURL(route: composerRoute, prompt: text,
                                   projectPath: projectPath, files: attachments)
        guard NSWorkspace.shared.open(url) else { throw HandoffError.openFailed(url.absoluteString) }
    }

    // MARK: - Pure parts (unit tested without touching NSWorkspace)

    public static func commandFileContents(claudeExecutable: URL, sessionID: String) -> String {
        "#!/bin/zsh\n\"\(claudeExecutable.path)\" --resume \(sessionID)\n"
    }

    public static func longPromptNotice(path: String) -> String {
        "The full task description did not fit here. Read it first with the Read tool: \(path)"
    }

    public static func resumeURL(sessionID: String) -> URL {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/resume"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url ?? URL(string: "claude://code/resume")!
    }

    public static func composerURL(route: String, prompt: String, projectPath: String, files: [String]) -> URL {
        var components = URLComponents()
        components.scheme = "claude"
        let parts = route.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        components.host = parts.first.map(String.init) ?? "code"
        components.path = "/" + (parts.count > 1 ? String(parts[1]) : "new")
        var items = [URLQueryItem(name: "q", value: String(prompt.prefix(composerPromptLimit)))]
        items.append(URLQueryItem(name: "folder", value: projectPath))
        items += files.map { URLQueryItem(name: "file", value: $0) }
        components.queryItems = items
        return components.url ?? URL(string: "claude://code/new")!
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=DesktopHandoffServiceTests 2>&1 | tail -3`
Expected: `Test run with 7 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueClaudeBridge/DesktopHandoffService.swift Tests/ShotcueClaudeBridgeTests/DesktopHandoffServiceTests.swift
git commit -m "feat(bridge): hand sessions to the terminal and Claude Desktop

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: UserNotificationNotifier (bitiş bildirimleri)

Spec §6.7'deki iki kategori: `RUN_DONE` (aksiyonlar `OPEN` "Aç", `TERMINAL` "Terminalde devam et") ve `RUN_FAILED` (`OPEN`, `RETRY` "Yeniden çalıştır"). Kategori ve aksiyon kimlikleri `public static let` sabitleri olarak dışa verilir; Plan 06'nın `UNUserNotificationCenterDelegate`'i string literal kopyalamak zorunda kalmaz. `userInfo` içinde `taskID` ve `runID` taşınır, request kimliği run id'sidir (aynı run için iki bildirim birikmez). Hata bildirimleri `.timeSensitive` seviyesinde gelir.

Not: spec §5.5 bildirimde maliyeti de anıyor, ama Core'daki `AppNotification` yalnızca `title`/`body` taşır ve `body` sözleşme gereği sonucun ilk satırıdır. Maliyet, tur sayısı ve süre Inspector'daki run kartında gösterilir (Plan 06); bildirime maliyet eklenmesi istenirse `AppNotification`'a alan eklemek Plan 00'ın işidir.

`UNUserNotificationCenter.current()` bundle kimliği olmayan bir süreçte (yani test koşucusunda) kullanılamaz; bu yüzden test yalnızca saf `request(for:)` ve `categories()` fonksiyonlarını çağırır, gerçek center'a hiç dokunmaz. Yetki isteği ve kategori kaydı Plan 06'da uygulama açılışında yapılır.

**Files:**
- Create: `Tests/ShotcueClaudeBridgeTests/UserNotificationNotifierTests.swift`
- Create: `Sources/ShotcueClaudeBridge/UserNotificationNotifier.swift`

**Interfaces:**
- Consumes (Plan 00, birebir): `protocol Notifier: Sendable { func notify(_ notification: AppNotification) async }`; `AppNotification(kind:title:body:taskID:runID:)` ile `enum Kind: String { case runDone, runFailed }`.
- Produces: `public final class UserNotificationNotifier: Notifier, @unchecked Sendable` → `public init(center: UNUserNotificationCenter = .current())`, `public func registerCategories()`, `@discardableResult public func requestAuthorization() async -> Bool`, `public func notify(_:) async`, `public static func categories() -> Set<UNNotificationCategory>`, `public static func request(for notification: AppNotification) -> UNNotificationRequest`, sabitler `runDoneCategory` ("RUN_DONE"), `runFailedCategory` ("RUN_FAILED"), `openAction` ("OPEN"), `terminalAction` ("TERMINAL"), `retryAction` ("RETRY"), `taskIDKey` ("taskID"), `runIDKey` ("runID").

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/UserNotificationNotifierTests.swift`:

```swift
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
        let request = UserNotificationNotifier.request(for: AppNotification(
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
        let request = UserNotificationNotifier.request(for: AppNotification(
            kind: .runFailed, title: "Uzun iş", body: "Tur limiti aşıldı (30 tur).",
            taskID: taskID, runID: runID))
        #expect(request.content.categoryIdentifier == UserNotificationNotifier.runFailedCategory)
        #expect(request.content.interruptionLevel == .timeSensitive)
    }

    @Test func categoriesCarryTheActionsPlan06Matches() throws {
        let categories = UserNotificationNotifier.categories()
        #expect(categories.count == 2)
        let done = try #require(categories.first { $0.identifier == UserNotificationNotifier.runDoneCategory })
        #expect(done.actions.map(\.identifier) == [UserNotificationNotifier.openAction,
                                                   UserNotificationNotifier.terminalAction])
        #expect(done.actions.map(\.title) == ["Aç", "Terminalde devam et"])
        let failed = try #require(categories.first { $0.identifier == UserNotificationNotifier.runFailedCategory })
        #expect(failed.actions.map(\.identifier) == [UserNotificationNotifier.openAction,
                                                     UserNotificationNotifier.retryAction])
        #expect(failed.actions.map(\.title) == ["Aç", "Yeniden çalıştır"])
        #expect(UserNotificationNotifier.runDoneCategory == "RUN_DONE")
        #expect(UserNotificationNotifier.runFailedCategory == "RUN_FAILED")
    }

    @Test func identifierFallsBackWhenThereIsNoRun() {
        let request = UserNotificationNotifier.request(for: AppNotification(
            kind: .runDone, title: "t", body: "b"))
        #expect(!request.identifier.isEmpty)
        #expect(request.content.userInfo.isEmpty)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=UserNotificationNotifierTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'UserNotificationNotifier' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueClaudeBridge/UserNotificationNotifier.swift`:

```swift
import Foundation
import ShotcueCore
import UserNotifications

/// Run notifications with actions (spec §6.7). The identifiers are public so Plan 06's
/// `UNUserNotificationCenterDelegate` can match them without duplicating string literals.
public final class UserNotificationNotifier: Notifier, @unchecked Sendable {
    public static let runDoneCategory = "RUN_DONE"
    public static let runFailedCategory = "RUN_FAILED"
    public static let openAction = "OPEN"
    public static let terminalAction = "TERMINAL"
    public static let retryAction = "RETRY"
    public static let taskIDKey = "taskID"
    public static let runIDKey = "runID"

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Called once at launch, before the first `notify`.
    public func registerCategories() {
        center.setNotificationCategories(Self.categories())
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notify(_ notification: AppNotification) async {
        try? await center.add(Self.request(for: notification))
    }

    // MARK: - Pure parts (unit tested without the real center)

    public static func categories() -> Set<UNNotificationCategory> {
        let open = UNNotificationAction(identifier: openAction, title: "Aç", options: [.foreground])
        let terminal = UNNotificationAction(identifier: terminalAction, title: "Terminalde devam et", options: [])
        let retry = UNNotificationAction(identifier: retryAction, title: "Yeniden çalıştır", options: [])
        return [
            UNNotificationCategory(identifier: runDoneCategory, actions: [open, terminal],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: runFailedCategory, actions: [open, retry],
                                   intentIdentifiers: [], options: []),
        ]
    }

    public static func request(for notification: AppNotification) -> UNNotificationRequest {
        let failed = notification.kind == .runFailed
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = failed ? runFailedCategory : runDoneCategory
        content.interruptionLevel = failed ? .timeSensitive : .active
        var info: [String: String] = [:]
        if let taskID = notification.taskID { info[taskIDKey] = taskID.uuidString }
        if let runID = notification.runID { info[runIDKey] = runID.uuidString }
        content.userInfo = info
        let identifier = notification.runID?.uuidString ?? UUID().uuidString
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=UserNotificationNotifierTests 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Tüm modülü çalıştır ve commit'le**

Run: `make test FILTER=ShotcueClaudeBridgeTests 2>&1 | tail -3`
Expected: `Test run with 58 tests in 9 suites passed` (~2 sn).

```bash
make format && git add Sources/ShotcueClaudeBridge/UserNotificationNotifier.swift Tests/ShotcueClaudeBridgeTests/UserNotificationNotifierTests.swift
git commit -m "feat(bridge): post run notifications with actions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Plan 04 tamamlanma ölçütü

**Otomatik (hepsi yeşil olmalı):**

- [ ] `swift build` hatasız ve uyarısız derlenir (`ld: warning: search path … not found` uyarıları zararsızdır).
- [ ] `make test FILTER=ShotcueClaudeBridgeTests` → **58 test, 9 suite, geçer**; süre ~2 sn.
  - `ClaudeArguments` 6 · `ClaudeLocator` 4 · `ProcessClaudeRunner` 9 · `ShellGitInspector` 5 · `RunLogWriter` 3 · `RunCoordinator` 16 · `SchedulerDriver` 4 · `DesktopHandoffService` 7 · `UserNotificationNotifier` 4
- [ ] `swift test` (tüm paket) → Plan 00'ın Core testleri ve diğer modüllerin testleri de geçmeye devam eder.
- [ ] `git diff --stat` yalnızca `Sources/ShotcueClaudeBridge/**` ve `Tests/ShotcueClaudeBridgeTests/**` gösterir. `Package.swift`, `Makefile`, `CLAUDE.md`, `Sources/ShotcueCore/**`, `Sources/ShotcueTestSupport/**`, `Tests/Fixtures/**` **değişmemiş** olmalı.
- [ ] `grep -rn "#Preview\|--bare\|Foundation.Timer\|NSBackgroundActivityScheduler" Sources/ShotcueClaudeBridge` → boş.
- [ ] `grep -rn "^import" Sources/ShotcueClaudeBridge | sort -u` → yalnızca `Foundation`, `AppKit`, `UserNotifications`, `ShotcueCore`.
- [ ] `grep -rn "\.status = " Sources/ShotcueClaudeBridge` → boş (durum değişiklikleri yalnızca `transition(to:at:)` ile).

**Manuel (Plan 06 bittikten sonra, `make run` ile kurulu uygulamada):**

- [ ] Ayarlar > Claude: `claude` yolu bulunur ve `version()` **2.1.278 (Claude Code)** gösterir.
- [ ] Gerçek bir **Analiz** run'ı: küçük bir projede bir ekran görüntüsü + not ile gönder. Beklenen: `--permission-mode dontAsk` + `--allowedTools` ile çalışır, hiçbir dosya değişmez, `result` metni üç satırlık özetle biter, `runs/<id>.jsonl` olay satırlarını içerir, maliyet ve tur sayısı Inspector'da görünür.
- [ ] Gerçek bir **Uygula** run'ı: aynı projede küçük bir düzeltme. Beklenen: dosya değişir, `git status` değişikliği gösterir, commit **yapılmaz**, bildirim "Aç / Terminalde devam et" aksiyonlarıyla gelir.
- [ ] Çalışan run'ı **İptal** et: run `cancelled`, task `cancelled`, süreç 10 sn içinde ölür (`pgrep -f "claude -p"` boşalır).
- [ ] **Zaman aşımı**: ayarlardan 1 dakika yap ve uzun bir iş gönder; run `failed` + "Zaman aşımı" mesajı.
- [ ] **Taşınmış proje**: bir projenin klasörünü yeniden adlandır ve gönder → run başlamaz, Run satırı "Proje klasörü bulunamadı" der, task `ready` kalır.
- [ ] **Aktarım**: "Terminalde devam et" terminalde `claude --resume <id>` açar ve oturum gerçekten devam eder; "Desktop'ta aç" oturumu Claude Desktop'ın Code sekmesine alır; "Composer'da aç" prompt'u doldurur (göndermez). Composer'a görsel iliştirilmiyorsa `composerRoute`'u `cowork/new` yap ve tekrar dene (araştırma 04 §3.3-5, spike S5).
- [ ] **Günlük kuyruk**: bir projeye `daily_time` = birkaç dakika sonrası ver; zamanı gelince `ready` task'lar kuyruğa girer ve `dailyLastFiredAt` bugüne yazılır; ikinci bir tick tekrar tetiklemez.
- [ ] **Uyanma**: Mac'i uyut, günlük saati uykuda geçsin, uyandır → tek bir catch-up turu çalışır (kuyruk selleri yok).
- [ ] **Kesinti kurtarma**: bir run çalışırken uygulamayı zorla kapat, yeniden başlat → `recoverInterruptedRuns()` o run'ı `failed(interrupted)` yapar ve task `failed` olur; "Terminalde devam et" session id ile hâlâ çalışır.
