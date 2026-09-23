# Shotcue v1 — Plan 07: Uygulama içi diff görünümü ("Diff'i göster")

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Spec §6.4'teki "Diff'i göster" özelliğini eklemek: bir run'ın başlamadan önce kaydettiği HEAD'e (`Run.gitHeadBefore`) göre proje klasöründeki değişiklikleri (izlenen dosyaların diff'i + izlenmeyen dosyalar) Inspector'da salt metin olarak göstermek.

**Architecture:** Core'a yeni bir `DiffProvider` protokolü ve saf `DiffText` biçimlendiricisi; `ShellGitInspector` (ClaudeBridge) bu protokolü `git diff` + `git status --porcelain` ile uygular; UI, `AppServices.diff` (varsayılan `nil`) üzerinden `TaskDetailStore.showDiff(runID:)` ile metni alır ve `DiffSheet` içinde gösterir; App katmanı (Plan 06) `AppServices`'e `diff: gitInspector` geçirir.

**Tech Stack:** Swift 6.4, SwiftPM, Swift Testing, SwiftUI (macOS 26).

**Spec:** `docs/superpowers/specs/2026-09-22-shotcue-design.md` §6.4 ("'Diff'i göster': git diff <head_before> + çalışma ağacı, uygulama içinde salt metin.")

**Neden ayrı plan:** Plan 00–06 bu özelliği yalnızca Plan 06'nın manuel kontrol listesinde anıyordu; hiçbir modülde uygulaması yoktu (koordinatör kapsam denetimi, 2026-09-22). Birden çok modüle dokunduğu için Plan 04 ve Plan 05 `feat/shotcue-v1`'e birleştikten sonra, entegrasyon dalında çalışır.

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

## Dosya haritası (bu planın ürettikleri)

```
Package.swift                                  # tüm target'lar ve iki bağımlılık (Task 0)
Makefile, scripts/{bundle.sh,install.sh,shot.sh,make-cert.sh,make-fixture-png.swift}
Resources/{Info.plist,Shotcue.entitlements}
CLAUDE.md                                      # ajan kuralları
Sources/ShotcueCore/
  Models/Project.swift            Project, DailyTime
  Models/ShotTask.swift           ShotTask, TaskMode, TaskStatus (+ geçiş kuralları)
  Models/Capture.swift            Capture
  Models/VoiceNote.swift          VoiceNote, TranscriptState, Transcript
  Models/Run.swift                Run, RunState, ClaudeRunResult, RunEvent
  Models/KeyCombo.swift           KeyCombo (+ hazır kombinasyonlar)
  Models/GitSnapshot.swift        GitSnapshot
  Logic/SortIndex.swift           fractional sıralama
  Logic/PromptBuilder.swift       Claude prompt'u + sabit sistem talimatı
  Logic/StreamJSONParser.swift    stream-json satırı → RunEvent
  Logic/SchedulerRules.swift      dueActions(now:…)
  Logic/QueuePolicy.swift         nextRunnable(…)
  Logic/TitleMaker.swift          otomatik başlık
  Services/*.swift                protokoller (CaptureService, ThumbnailService, PermissionService,
                                  HotKeyService, AudioRecorder, Transcriber, ClaudeRunner, GitInspector,
                                  Clock, Repositories, Notifier, HandoffService, FileStore)
Sources/ShotcuePersistence/ShotcuePersistence.swift   # yer tutucu (Plan 01 doldurur)
Sources/ShotcueCapture/ShotcueCapture.swift           # yer tutucu (Plan 02)
Sources/ShotcueNotes/ShotcueNotes.swift               # yer tutucu (Plan 03)
Sources/ShotcueClaudeBridge/ShotcueClaudeBridge.swift # yer tutucu (Plan 04)
Sources/ShotcueUI/ShotcueUI.swift                     # yer tutucu (Plan 05)
Sources/ShotcueApp/ShotcueApp.swift                   # minimal @main (Plan 05 genişletir)
Tests/ShotcueCoreTests/*.swift
Tests/{Persistence,Capture,Notes,ClaudeBridge,UI}Tests/SmokeTests.swift   # yer tutucu testler
Tests/Fixtures/{fake-claude.sh,fake-screencapture.sh,sample-stream.jsonl,sample.png}
```

---

## Dosya haritası

```
Sources/ShotcueCore/Services/DiffProvider.swift          DiffProvider protokolü + DiffText (Task 1)
Sources/ShotcueTestSupport/FakeDiffProvider.swift         FakeDiffProvider (Task 1)
Tests/ShotcueCoreTests/DiffTextTests.swift                (Task 1)
Sources/ShotcueClaudeBridge/ShellGitInspector.swift       + DiffProvider uyumu (Task 2, aynı dosya: private capture/require kullanır)
Tests/ShotcueClaudeBridgeTests/ShellGitInspectorDiffTests.swift   (Task 2)
Sources/ShotcueUI/Support/AppServices.swift               + diff alanı (Task 3)
Sources/ShotcueUI/Stores/TaskDetailStore.swift            + diff durumu/aksiyonları (Task 3)
Sources/ShotcueUI/Views/DiffSheet.swift                   (Task 3)
Sources/ShotcueUI/Views/TaskInspectorView.swift           + "Diff'i göster" düğmesi ve sheet (Task 3)
Tests/ShotcueUITests/DiffTests.swift                      (Task 3)
```

---

### Task 1: `DiffProvider`, `DiffText` ve `FakeDiffProvider`

**Files:**
- Create: `Sources/ShotcueCore/Services/DiffProvider.swift`
- Create: `Sources/ShotcueTestSupport/FakeDiffProvider.swift`
- Test: `Tests/ShotcueCoreTests/DiffTextTests.swift`

**Interfaces:**
- Consumes: `Locked`, `FakeError` (ShotcueTestSupport).
- Produces: `public protocol DiffProvider: Sendable { func diff(at path: String, since: String?, maxBytes: Int) async throws -> String }`; `public enum DiffText` with `static let defaultMaxBytes = 1_000_000`, `static func compose(diff:untracked:since:maxBytes:) -> String`, `static func untrackedPaths(fromPorcelain:) -> [String]`, `static func truncated(_:maxBytes:) -> String`; `public final class FakeDiffProvider: DiffProvider` with `result`, `calls`, `init(result:)`.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueCoreTests/DiffTextTests.swift`:
```swift
import Testing
@testable import ShotcueCore
import ShotcueTestSupport

@Suite("DiffText")
struct DiffTextTests {
    @Test func composesTrackedDiffAndUntrackedFiles() {
        let text = DiffText.compose(diff: "diff --git a/a.swift b/a.swift\n+yeni satır\n",
                                    untracked: ["new.txt", "docs/x.md"],
                                    since: "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7", maxBytes: 10_000)
        #expect(text.hasPrefix("# git diff c42049d\n"))
        #expect(text.contains("+yeni satır"))
        #expect(text.contains("# İzlenmeyen dosyalar\n?? new.txt\n?? docs/x.md"))
    }

    @Test func emptyDiffSaysSoAndHeadIsTheDefaultBase() {
        let text = DiffText.compose(diff: "  \n", untracked: [], since: nil, maxBytes: 10_000)
        #expect(text.hasPrefix("# git diff HEAD\n"))
        #expect(text.contains("(izlenen dosyalarda değişiklik yok)"))
        #expect(!text.contains("İzlenmeyen"))
    }

    @Test func truncatesLongOutputWithANotice() {
        let long = String(repeating: "x", count: 500)
        let text = DiffText.compose(diff: long, untracked: [], since: nil, maxBytes: 100)
        #expect(text.utf8.count < 200)
        #expect(text.hasSuffix("… (çıktı 100 bayttan sonra kesildi)"))
        #expect(DiffText.truncated("kısa", maxBytes: 100) == "kısa")
    }

    @Test func parsesUntrackedPathsFromPorcelain() {
        let porcelain = " M a.swift\n?? new.txt\nA  b.swift\n?? dir/c.md\n"
        #expect(DiffText.untrackedPaths(fromPorcelain: porcelain) == ["new.txt", "dir/c.md"])
    }

    @Test func fakeProviderRecordsCallsAndReturnsItsResult() async throws {
        let fake = FakeDiffProvider(result: .success("patch"))
        #expect(try await fake.diff(at: "/tmp/p", since: "abc", maxBytes: 7) == "patch")
        #expect(fake.calls.current.count == 1)
        #expect(fake.calls.current.first?.path == "/tmp/p")
        #expect(fake.calls.current.first?.since == "abc")
        #expect(fake.calls.current.first?.maxBytes == 7)
        fake.result.set(.failure(FakeError("boom")))
        await #expect(throws: FakeError.self) { try await fake.diff(at: "/tmp/p", since: nil, maxBytes: 7) }
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `make test FILTER=DiffTextTests 2>&1 | grep -m2 "error:"`
Expected: `cannot find 'DiffText' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Services/DiffProvider.swift`:
```swift
import Foundation

/// Working-tree changes since a commit, for the Inspector's "Diff'i göster" (spec §6.4).
public protocol DiffProvider: Sendable {
    /// `git diff <since>` (against HEAD when `since` is nil) plus the untracked files in `path`,
    /// formatted by `DiffText.compose` and capped at `maxBytes`.
    func diff(at path: String, since: String?, maxBytes: Int) async throws -> String
}

public enum DiffText {
    public static let defaultMaxBytes = 1_000_000

    public static func compose(diff: String, untracked: [String], since: String?, maxBytes: Int) -> String {
        let base = since.map { String($0.prefix(7)) } ?? "HEAD"
        var lines = ["# git diff \(base)"]
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(trimmed.isEmpty ? "(izlenen dosyalarda değişiklik yok)" : diff.trimmingCharacters(in: .newlines))
        if !untracked.isEmpty {
            lines.append("")
            lines.append("# İzlenmeyen dosyalar")
            lines.append(contentsOf: untracked.map { "?? \($0)" })
        }
        return truncated(lines.joined(separator: "\n"), maxBytes: maxBytes)
    }

    public static func untrackedPaths(fromPorcelain porcelain: String) -> [String] {
        porcelain.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            line.hasPrefix("?? ") ? String(line.dropFirst(3)) : nil
        }
    }

    public static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let head = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        return head + "\n\n… (çıktı \(maxBytes) bayttan sonra kesildi)"
    }
}
```

`Sources/ShotcueTestSupport/FakeDiffProvider.swift`:
```swift
import Foundation
import ShotcueCore

public final class FakeDiffProvider: DiffProvider, @unchecked Sendable {
    public let result: Locked<Result<String, FakeError>>
    public let calls = Locked<[(path: String, since: String?, maxBytes: Int)]>([])

    public init(result: Result<String, FakeError> = .success("diff --git a/x b/x")) {
        self.result = Locked(result)
    }

    public func diff(at path: String, since: String?, maxBytes: Int) async throws -> String {
        calls.withLock { $0.append((path, since, maxBytes)) }
        return try result.current.get()
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=DiffTextTests 2>&1 | tail -3`
Expected: `5 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Services/DiffProvider.swift Sources/ShotcueTestSupport/FakeDiffProvider.swift Tests/ShotcueCoreTests/DiffTextTests.swift
git commit -m "feat(core): add DiffProvider and diff text formatting

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ShellGitInspector` → `DiffProvider`

**Files:**
- Modify: `Sources/ShotcueClaudeBridge/ShellGitInspector.swift` (uyum aynı dosyada bir extension olarak: struct'ın `private` `require(_:at:)` yardımcısını kullanır)
- Test: `Tests/ShotcueClaudeBridgeTests/ShellGitInspectorDiffTests.swift`

**Interfaces:**
- Consumes: `DiffProvider`, `DiffText` (Task 1); `ShellGitInspector`, `GitError`, private `require(_:at:)` (Plan 04 Task 3).
- Produces: `extension ShellGitInspector: DiffProvider`.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueClaudeBridgeTests/ShellGitInspectorDiffTests.swift`:
```swift
import Foundation
import Testing
@testable import ShotcueClaudeBridge
import ShotcueCore

@Suite("ShellGitInspector diff")
struct ShellGitInspectorDiffTests {
    /// Creates a throwaway repo with one commit; returns its path and HEAD.
    func makeRepo() throws -> (path: String, head: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func git(_ args: String...) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        _ = try git("init", "-q")
        _ = try git("config", "user.email", "test@example.com")
        _ = try git("config", "user.name", "Test")
        try "first line\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try git("add", "a.txt")
        _ = try git("commit", "-q", "-m", "init")
        let head = try git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        return (dir.path, head)
    }

    @Test func showsTrackedChangesAndUntrackedFilesSinceTheRecordedHead() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        try "first line\nsecond line\n".write(toFile: repo.path + "/a.txt", atomically: true, encoding: .utf8)
        try "hello\n".write(toFile: repo.path + "/new.txt", atomically: true, encoding: .utf8)
        let text = try await ShellGitInspector().diff(at: repo.path, since: repo.head, maxBytes: 100_000)
        #expect(text.hasPrefix("# git diff \(repo.head.prefix(7))"))
        #expect(text.contains("+second line"))
        #expect(text.contains("?? new.txt"))
    }

    @Test func defaultsToHeadAndHonoursTheByteCap() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        try String(repeating: "line\n", count: 200).write(toFile: repo.path + "/a.txt", atomically: true, encoding: .utf8)
        let text = try await ShellGitInspector().diff(at: repo.path, since: nil, maxBytes: 120)
        #expect(text.hasPrefix("# git diff HEAD"))
        #expect(text.hasSuffix("… (çıktı 120 bayttan sonra kesildi)"))
    }

    @Test func outsideARepositoryItThrows() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotcue-norepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: GitError.self) {
            _ = try await ShellGitInspector().diff(at: dir.path, since: nil, maxBytes: 1_000)
        }
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `make test FILTER=ShellGitInspectorDiffTests 2>&1 | grep -m2 "error:"`
Expected: `value of type 'ShellGitInspector' has no member 'diff'`.

- [ ] **Step 3: Uygulamayı yaz** — `Sources/ShotcueClaudeBridge/ShellGitInspector.swift` dosyasının **sonuna** ekle:

```swift
extension ShellGitInspector: DiffProvider {
    /// `git diff <since|HEAD>` of the working tree plus untracked files (spec §6.4 "Diff'i göster").
    public func diff(at path: String, since: String?, maxBytes: Int) async throws -> String {
        let tracked = try await require(["diff", "--no-color", "--no-ext-diff", since ?? "HEAD"], at: path)
        let status = try await require(["status", "--porcelain", "--untracked-files=all"], at: path)
        return DiffText.compose(diff: tracked.stdout,
                                untracked: DiffText.untrackedPaths(fromPorcelain: status.stdout),
                                since: since, maxBytes: maxBytes)
    }
}
```
(`require` Plan 04'te `private`; aynı dosyadaki extension erişebilir. Adı farklıysa mevcut yardımcıyı kullan ve raporda belirt.)

- [ ] **Step 4: Testleri çalıştır**

Run: `make test FILTER=ShellGitInspectorDiffTests 2>&1 | tail -3`
Expected: `3 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueClaudeBridge/ShellGitInspector.swift Tests/ShotcueClaudeBridgeTests/ShellGitInspectorDiffTests.swift
git commit -m "feat(bridge): provide run diffs from git

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: UI — `AppServices.diff`, `TaskDetailStore` diff akışı, `DiffSheet`, Inspector düğmesi

**Files:**
- Modify: `Sources/ShotcueUI/Support/AppServices.swift`
- Modify: `Sources/ShotcueUI/Stores/TaskDetailStore.swift`
- Create: `Sources/ShotcueUI/Views/DiffSheet.swift`
- Modify: `Sources/ShotcueUI/Views/TaskInspectorView.swift`
- Test: `Tests/ShotcueUITests/DiffTests.swift`

**Interfaces:**
- Consumes: `DiffProvider`, `DiffText.defaultMaxBytes`, `FakeDiffProvider` (Task 1); `AppServices` (Plan 05 Task 1), `TaskDetailStore` (Plan 05 Task 4: `services`, `runs`, `project`, `selectedRunID`, `latestRun`, `lastError`, `reload()`), `TaskInspectorView` (Plan 05 Task 10: `handoffSection`, `body`), `makeFakeServices`.
- Produces: `AppServices.diff: (any DiffProvider)?` + init parametresi `diff: (any DiffProvider)? = nil` (**son** parametre; mevcut çağrılar değişmeden derlenir); `TaskDetailStore.diffText: String?`, `isLoadingDiff: Bool`, `isDiffPresented: Bool`, `canShowDiff(for:) -> Bool`, `showDiff(runID:) async`, `closeDiff()`; `DiffSheet(text:onClose:)`.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueUITests/DiffTests.swift`:
```swift
import Foundation
import Testing
import ShotcueCore
import ShotcueTestSupport
@testable import ShotcueUI

extension AppServices {
    func withDiff(_ provider: (any DiffProvider)?) -> AppServices {
        AppServices(projects: projects, tasks: tasks, runs: runs, capture: capture, thumbnails: thumbnails,
                    permissions: permissions, recorder: recorder, transcriber: transcriber,
                    transcriptionQueue: transcriptionQueue, dispatcher: dispatcher, handoff: handoff,
                    fileStore: fileStore, clock: clock, diff: provider)
    }
}

@Suite("Task diff")
struct TaskDiffTests {
    let head = "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7"

    @MainActor
    func fixture(diff: FakeDiffProvider?, gitHeadBefore: String?) async -> (TaskDetailStore, Run, Project, FakeBundle) {
        let project = Project(name: "crm", path: "/tmp/crm")
        let task = ShotTask(projectID: project.id, title: "t", status: .done)
        let run = Run(taskID: task.id, state: .succeeded, logRelPath: "runs/x.jsonl", gitHeadBefore: gitHeadBefore)
        let f = makeFakeServices(projects: [project], tasks: [task], runs: [run])
        let store = TaskDetailStore(services: f.services.withDiff(diff), taskID: task.id)
        await store.reload()
        return (store, run, project, f)
    }

    @MainActor
    @Test func showDiffLoadsTheRunsDiffIntoTheSheet() async {
        let fake = FakeDiffProvider(result: .success("# git diff c42049d\n+x"))
        let (store, run, project, f) = await fixture(diff: fake, gitHeadBefore: head)
        defer { f.cleanUp() }
        #expect(store.canShowDiff(for: run))
        await store.showDiff(runID: run.id)
        #expect(store.diffText == "# git diff c42049d\n+x")
        #expect(store.isDiffPresented)
        #expect(fake.calls.current.first?.path == project.path)
        #expect(fake.calls.current.first?.since == head)
        #expect(fake.calls.current.first?.maxBytes == DiffText.defaultMaxBytes)
        store.closeDiff()
        #expect(store.isDiffPresented == false && store.diffText == nil)
    }

    @MainActor
    @Test func diffNeedsAProviderAndARecordedHead() async {
        let (withoutProvider, run1, _, f1) = await fixture(diff: nil, gitHeadBefore: head)
        defer { f1.cleanUp() }
        #expect(withoutProvider.canShowDiff(for: run1) == false)
        let (withoutHead, run2, _, f2) = await fixture(diff: FakeDiffProvider(), gitHeadBefore: nil)
        defer { f2.cleanUp() }
        #expect(withoutHead.canShowDiff(for: run2) == false)
    }

    @MainActor
    @Test func aFailingDiffReportsAnError() async {
        let fake = FakeDiffProvider(result: .failure(FakeError("not a repo")))
        let (store, run, _, f) = await fixture(diff: fake, gitHeadBefore: head)
        defer { f.cleanUp() }
        await store.showDiff(runID: run.id)
        #expect(store.isDiffPresented == false)
        #expect(store.lastError?.hasPrefix("Diff alınamadı") == true)
    }

    @MainActor
    @Test func diffSheetKeepsItsInputs() {
        let sheet = DiffSheet(text: "+x", onClose: {})
        #expect(sheet.text == "+x")
    }
}
```
(Plan 05'in `TaskDetailStoreTests`'i görevi/run'ları yüklemek için `reload()` yerine başka bir çağrı kullanıyorsa aynısını kullan.)

- [ ] **Step 2: Derlenmediğini gör**

Run: `make test FILTER=TaskDiffTests 2>&1 | grep -m2 "error:"`
Expected: `extra argument 'diff' in call` veya `cannot find 'DiffSheet' in scope`.

- [ ] **Step 3: `AppServices`'e `diff` ekle** — `Sources/ShotcueUI/Support/AppServices.swift`: `clock`'tan sonra `public let diff: (any DiffProvider)?` alanını; init'e **son** parametre olarak `diff: (any DiffProvider)? = nil`'i ve gövdeye `self.diff = diff`'i ekle.

- [ ] **Step 4: `TaskDetailStore`'a diff akışını ekle** — `Sources/ShotcueUI/Stores/TaskDetailStore.swift` sınıfının içine:
```swift
    // MARK: - Diff (Plan 07)

    public private(set) var diffText: String?
    public private(set) var isLoadingDiff = false
    public var isDiffPresented = false

    /// Needs a diff provider, a HEAD recorded before the run, and a task that still points at a project.
    public func canShowDiff(for run: Run) -> Bool {
        services.diff != nil && run.gitHeadBefore != nil && project != nil
    }

    public func showDiff(runID: UUID) async {
        guard let provider = services.diff,
              let run = runs.first(where: { $0.id == runID }),
              let project else { return }
        isLoadingDiff = true
        defer { isLoadingDiff = false }
        do {
            diffText = try await provider.diff(at: project.path, since: run.gitHeadBefore,
                                               maxBytes: DiffText.defaultMaxBytes)
            isDiffPresented = true
        } catch {
            lastError = "Diff alınamadı: \(error.localizedDescription)"
        }
    }

    public func closeDiff() {
        isDiffPresented = false
        diffText = nil
    }
```

- [ ] **Step 5: `DiffSheet`'i yaz** — `Sources/ShotcueUI/Views/DiffSheet.swift`:
```swift
import SwiftUI

/// Plain-text diff of a run (spec §6.4), selectable and scrollable in both directions.
public struct DiffSheet: View {
    public let text: String
    public let onClose: () -> Void

    public init(text: String, onClose: @escaping () -> Void) {
        self.text = text
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "Değişiklik yok." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack {
                Spacer()
                Button("Kapat") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
```

- [ ] **Step 6: Inspector'a düğmeyi ve sheet'i ekle** — `Sources/ShotcueUI/Views/TaskInspectorView.swift`:
1. `handoffSection` içindeki `HStack`'in (Terminal/Desktop düğmeleri) hemen ardına:
```swift
            if let run = store.runs.first(where: { $0.id == store.selectedRunID }) ?? store.latestRun {
                Button("Diff'i göster", systemImage: "plus.forwardslash.minus") {
                    Task { await store.showDiff(runID: run.id) }
                }
                .disabled(!store.canShowDiff(for: run) || store.isLoadingDiff)
            }
```
2. `TaskInspectorView.body`'nin döndürdüğü en dış görünüme:
```swift
        .sheet(isPresented: Binding(get: { store.isDiffPresented },
                                    set: { if !$0 { store.closeDiff() } })) {
            DiffSheet(text: store.diffText ?? "", onClose: { store.closeDiff() })
        }
```

- [ ] **Step 7: Testleri çalıştır**

Run: `make test FILTER='TaskDiffTests|TaskDetailStoreTests|TaskInspectorViewTests' 2>&1 | tail -4` ve ardından tam `make test`.
Expected: yeni 4 test ve mevcut testler geçer.

- [ ] **Step 8: Commit**

```bash
make format && git add Sources/ShotcueUI/Support/AppServices.swift Sources/ShotcueUI/Stores/TaskDetailStore.swift Sources/ShotcueUI/Views/DiffSheet.swift Sources/ShotcueUI/Views/TaskInspectorView.swift Tests/ShotcueUITests/DiffTests.swift
git commit -m "feat(ui): show a run's git diff in the inspector

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Plan 06 bağlantısı: `AppEnvironment` `AppServices(...)` kurarken `diff: gitInspector` (aynı `ShellGitInspector` örneği) geçirir. Manuel kontrol Plan 06 Task 9 madde 6.

## Plan 07 tamamlanma ölçütü
- `make test` yeşil; yeni testler: DiffText 5, ShellGitInspector diff 3, TaskDiff 4.
- `git diff --name-only <önce>..HEAD` yalnızca dosya haritasındaki dosyaları listeler.
