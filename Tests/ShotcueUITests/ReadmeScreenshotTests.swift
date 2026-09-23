import AppKit
import Foundation
import ImageIO
import Metal
import QuartzCore
import ShotcueCore
import ShotcueTestSupport
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import ShotcueUI

/// README screenshots of the real SwiftUI views, rendered offscreen from fictional sample data: no screen
/// recording, no visible window (they sit far outside every screen), nothing read from the user's database or
/// defaults, and the process is never activated.
///
/// Disabled unless `SHOTCUE_README_SHOTS` names an output directory, so a plain `make test` never runs it:
///
///     SHOTCUE_README_SHOTS=/tmp/shotcue-readme make test FILTER='ReadmeScreenshot'
///
/// Writes `library-{light,dark}.png`, `inspector-{light,dark}.png` and `quick-panel-{light,dark}.png`, each framed
/// as a window with rounded corners and a soft shadow on a transparent background.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["SHOTCUE_README_SHOTS"] != nil,
        "Set SHOTCUE_README_SHOTS=<output dir> to render the README screenshots."))
struct ReadmeScreenshotTests {
    @Test func libraryWindow() async throws {
        let studio = try await ReadmeStudio.make()
        defer { studio.cleanUp() }
        for appearance in ReadmeStudio.Look.allCases {
            try await studio.shootLibrary(appearance)
        }
    }

    @Test func taskInspector() async throws {
        let studio = try await ReadmeStudio.make()
        defer { studio.cleanUp() }
        for appearance in ReadmeStudio.Look.allCases {
            try await studio.shootInspector(appearance)
        }
    }

    @Test func quickPanel() async throws {
        let studio = try await ReadmeStudio.make()
        defer { studio.cleanUp() }
        for appearance in ReadmeStudio.Look.allCases {
            try await studio.shootQuickPanel(appearance)
        }
    }
}

// MARK: - Studio: sample data, hosting, capture

/// The shots' process reports itself active: it is never activated (it must not take focus from the user), and
/// AppKit draws the windows of an inactive app grey. Only takes effect when it is the first `NSApplication` made.
final class ReadmeShotApplication: NSApplication {
    override var isActive: Bool { true }
    @objc func _isActiveApp() -> Bool { true }
}

struct ReadmeShotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A throwaway FileStore root filled with fictional projects, tasks, captures, voice notes and a finished run, and
/// the helpers that host a view offscreen and write it out as a framed PNG.
final class ReadmeStudio {
    enum Look: String, CaseIterable {
        case light, dark

        var appearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }
    }

    let output: URL
    let root: URL
    let services: AppServices
    let tasks: InMemoryTaskRepository
    let now = Date()
    private let previousDirectory: String

    let pati: Project
    let kasa: Project
    let rota: Project
    /// The finished task the library selects and the inspector shows.
    private(set) var loginTaskID = UUID()
    private(set) var loginRunID = UUID()
    /// A fresh capture waiting in the quick panel.
    private(set) var panelTaskID = UUID()
    /// Relative path of every thumbnail, so the shared cache can be primed before the first render.
    private(set) var thumbnails: [String] = []

    private init(output: URL, root: URL) throws {
        self.output = output
        self.root = root
        let store = root.appendingPathComponent("store", isDirectory: true)
        let fileStore = FileStore(rootURL: store)
        try fileStore.ensureDirectories()

        // Project paths are shown in the inspector and the quick panel. They are written as "~/Projects/<name>"
        // and resolved against the working directory (a literal "~" folder in the scratch root), so the sidebar
        // finds the folders without any real path of this Mac appearing in the pictures.
        let fileManager = FileManager.default
        for name in ["pati-web", "kasa-pos", "rota-admin"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent("~/Projects/\(name)", isDirectory: true),
                withIntermediateDirectories: true)
        }
        previousDirectory = fileManager.currentDirectoryPath
        fileManager.changeCurrentDirectoryPath(root.path)

        let day: TimeInterval = 86_400
        pati = Project(
            name: "pati-web", path: "~/Projects/pati-web", defaultMode: .implement,
            dailyTime: DailyTime(hour: 2, minute: 0), dailyEnabled: true, runInBranch: true,
            sortIndex: 1024, createdAt: now - 40 * day)
        kasa = Project(name: "kasa-pos", path: "~/Projects/kasa-pos", sortIndex: 2048, createdAt: now - 30 * day)
        rota = Project(
            name: "rota-admin", path: "~/Projects/rota-admin", defaultMode: .analyze, sortIndex: 3072,
            createdAt: now - 20 * day)

        tasks = InMemoryTaskRepository()
        services = AppServices(
            projects: InMemoryProjectRepository([pati, kasa, rota]),
            tasks: tasks,
            runs: InMemoryRunRepository(),
            capture: FakeCaptureService(),
            thumbnails: FakeThumbnailService(),
            permissions: FakePermissionService(
                states: [.screenRecording: .granted, .microphone: .granted, .notifications: .granted]),
            recorder: FakeAudioRecorder(stopDuration: 18.4),
            transcriber: FakeTranscriber(state: .ready),
            transcriptionQueue: FakeTranscriptionQueue(),
            dispatcher: FakeTaskDispatcher(),
            handoff: FakeHandoffService(),
            fileStore: fileStore,
            clock: MutableClock(now),
            diff: FakeDiffProvider())
    }

    static func make() async throws -> ReadmeStudio {
        guard let path = ProcessInfo.processInfo.environment["SHOTCUE_README_SHOTS"], !path.isEmpty else {
            throw ReadmeShotError("SHOTCUE_README_SHOTS is not set")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-readme-\(UUID().uuidString)", isDirectory: true)
        let studio = try ReadmeStudio(output: output, root: root)
        // No Dock icon, never activated: the windows stay far outside every screen.
        ReadmeShotApplication.shared.setActivationPolicy(.accessory)
        try await studio.populate()
        return studio
    }

    func cleanUp() {
        FileManager.default.changeCurrentDirectoryPath(previousDirectory)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Sample data (fictional)

    private func populate() async throws {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400

        // pati-web: the project the library shows.
        let login = ShotTask(
            projectID: pati.id, title: "Giriş butonu mobilde kartın dışına taşıyor",
            noteText: "Giriş butonu mobilde kartın dışına taşıyor. Genişlik %100 olsun, iç boşluk korunsun.",
            status: .done, mode: .implement, sortIndex: 1024,
            createdAt: now - 2 * hour - 4 * minute, updatedAt: now - 97 * minute)
        loginTaskID = login.id
        try await add(
            login, mock: .login, voice: 18.4,
            transcript:
                "Mobilde giriş butonu kartın sağından taşıyor, yatayda kaydırma çıkıyor. Butonu kartın içine al, masaüstündeki görünüm bozulmasın."
        )

        try await add(
            ShotTask(
                projectID: pati.id, title: "Sahiplenme formunda telefon alanı doğrulanmıyor",
                noteText: "Sahiplenme formunda telefon alanı doğrulanmıyor. Harf kabul ediyor, 10 hane kontrolü yok.",
                status: .running, sortIndex: 2048, createdAt: now - 26 * minute, updatedAt: now - 3 * minute),
            mock: .phone)
        try await add(
            ShotTask(
                projectID: pati.id, title: "Kart gölgeleri karanlık modda kayboluyor",
                noteText: "Kart gölgeleri karanlık modda kayboluyor. Kenarlık ya da yükselti ekle.",
                status: .queued, sortIndex: 3072, createdAt: now - 3 * hour - 12 * minute,
                updatedAt: now - 3 * hour - 10 * minute),
            mock: .darkCards, voice: 9.2, transcript: "Karanlık modda kartlar arka plana karışıyor.")
        var gallery = ShotTask(
            projectID: pati.id, title: "Galeri sayfası neden yavaş açılıyor?",
            noteText: "Galeri sayfası neden yavaş açılıyor? Görseller tek tek geliyor.",
            status: .ready, mode: .analyze, sortIndex: 4096, createdAt: now - 1 * day - 2 * hour,
            updatedAt: now - 1 * day - hour)
        gallery.scheduledAt = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: now)
        try gallery.transition(to: .scheduled, at: gallery.updatedAt)
        try await add(gallery, mock: .gallery)
        try await add(
            ShotTask(
                projectID: pati.id, title: "Arama sonuç vermeyince boş durum göster",
                noteText: "Arama sonuç vermeyince boş durum göster; öneri olarak popüler aramaları listele.",
                status: .ready, sortIndex: 5120, createdAt: now - 1 * day - 5 * hour,
                updatedAt: now - 1 * day - 5 * hour),
            mock: .search)
        try await add(
            ShotTask(
                projectID: pati.id, title: "Footer'daki sosyal medya ikonları hizasız",
                noteText: "Footer'daki sosyal medya ikonları hizasız.",
                status: .ready, sortIndex: 6144, createdAt: now - 2 * day - 3 * hour,
                updatedAt: now - 2 * day - 3 * hour),
            mock: .footer, voice: 6.8, transcript: "İkonlar aynı çizgide değil.")
        try await add(
            ShotTask(
                projectID: pati.id, title: "Bağış formu eksi tutarı kabul ediyor",
                noteText: "Bağış formu eksi tutarı kabul ediyor. En az 10 ₺ olsun.",
                status: .failed, sortIndex: 7168, createdAt: now - 2 * day - 6 * hour,
                updatedAt: now - 2 * day - 5 * hour),
            mock: .donation)
        try await add(
            ShotTask(
                projectID: pati.id, title: "Harita pinleri mobilde tıklanmıyor",
                noteText: "Harita pinleri mobilde tıklanmıyor. Dokunma alanını büyüt.",
                status: .done, sortIndex: 8192, createdAt: now - 3 * day - 2 * hour,
                updatedAt: now - 3 * day - hour),
            mock: .map, voice: 12.1, transcript: "Mobilde pinlere dokununca hiçbir şey olmuyor.")
        try await add(
            ShotTask(
                projectID: pati.id, title: "Profil fotoğrafı yüklenince bulanık görünüyor",
                noteText: "Profil fotoğrafı yüklenince bulanık görünüyor.",
                status: .ready, mode: .analyze, sortIndex: 9216, createdAt: now - 4 * day,
                updatedAt: now - 4 * day),
            mock: .avatar)

        // The rest only feed the sidebar counts.
        for (index, item) in [
            (kasa.id, "Sepet toplamı kuruşları yanlış yuvarlıyor", TaskStatus.done),
            (kasa.id, "Fişte Türkçe karakterler bozuk basılıyor", .failed),
            (kasa.id, "İndirim kodu alanı mobilde klavyenin altında kalıyor", .ready),
            (rota.id, "Harita etiketleri üst üste biniyor", .ready),
            (rota.id, "Sürücü listesinde sayfalama sıfırlanıyor", .ready),
        ].enumerated() {
            try await tasks.save(
                ShotTask(
                    projectID: item.0, title: item.1, noteText: item.1 + ".", status: item.2,
                    sortIndex: Double(index + 1) * 1024, createdAt: now - Double(index + 2) * day,
                    updatedAt: now - Double(index + 2) * day))
        }
        try await tasks.save(
            ShotTask(
                title: "Onboarding metninde yazım hatası", noteText: "Onboarding metninde yazım hatası.",
                sortIndex: 1024, createdAt: now - 5 * hour, updatedAt: now - 5 * hour))
        try await tasks.save(
            ShotTask(
                title: TitleMaker.title(noteText: "", transcript: nil, createdAt: now - 50 * minute),
                sortIndex: 2048, createdAt: now - 50 * minute, updatedAt: now - 50 * minute))

        // The finished run of the login task, with the log the inspector replays.
        let started = now - 99 * minute
        let runID = UUID()
        let run = Run(
            id: runID, taskID: login.id, state: .succeeded, startedAt: started, finishedAt: started + 84,
            numTurns: 11, costUSD: 0.4137,
            resultText: """
                Giriş butonu artık kartın içinde; genişlik %100, iç boşluk korunuyor.
                Değişen dosyalar: src/components/LoginForm.tsx, LoginForm.test.tsx
                Yapılamayan: yok.
                """,
            subtype: "success", exitCode: 0, logRelPath: services.fileStore.runLogRelPath(id: runID),
            gitHeadBefore: "4f1c9a2e7b3d5c8f0a6e1d2b9c7f4a3e5d8b1c0f", gitDirtyBefore: false,
            gitHeadAfter: "4f1c9a2e7b3d5c8f0a6e1d2b9c7f4a3e5d8b1c0f", gitBranch: "main")
        loginRunID = run.id
        let log = ReadmeStudio.runLog(sessionID: run.id.uuidString.lowercased())
        try services.fileStore.ensureParentDirectory(for: run.logRelPath)
        try Data(log.utf8).write(to: services.fileStore.absoluteURL(for: run.logRelPath))
        try await services.runs.save(run)

        // A capture that just happened: an inbox task, nothing written in the panel yet.
        let fresh = ShotTask(
            title: TitleMaker.title(noteText: "", transcript: nil, createdAt: now),
            sortIndex: 3072, createdAt: now, updatedAt: now)
        panelTaskID = fresh.id
        try await add(fresh, mock: .login)
    }

    /// Saves the task with a capture drawn from `mock` (full PNG + 512 px JPEG thumbnail) and an optional voice note.
    private func add(_ task: ShotTask, mock: CaptureMock, voice: Double? = nil, transcript: String? = nil) async throws
    {
        try await tasks.save(task)
        let fileStore = services.fileStore
        let captureID = UUID()
        let relPath = fileStore.captureRelPath(id: captureID, date: task.createdAt)
        let thumbRelPath = fileStore.thumbRelPath(id: captureID)
        let full = try Self.render(mock, scale: 2)
        let thumb = try Self.render(mock, scale: 512.0 / CaptureMock.size.width)
        try fileStore.ensureParentDirectory(for: relPath)
        try Self.write(full, to: fileStore.absoluteURL(for: relPath), type: .png)
        try Self.write(thumb, to: fileStore.absoluteURL(for: thumbRelPath), type: .jpeg)
        thumbnails.append(thumbRelPath)
        try await tasks.save(
            Capture(
                taskID: task.id, relPath: relPath, thumbRelPath: thumbRelPath, width: full.width,
                height: full.height, scale: 2, createdAt: task.createdAt))
        if let voice {
            let noteID = UUID()
            let audio = fileStore.audioRelPath(id: noteID)
            try fileStore.ensureParentDirectory(for: audio)
            try Data("m4a".utf8).write(to: fileStore.absoluteURL(for: audio))
            try await tasks.save(
                VoiceNote(
                    id: noteID, taskID: task.id, relPath: audio, durationSec: voice, transcript: transcript,
                    transcriptState: transcript == nil ? .pending : .done, engine: "whisperkit/sample",
                    createdAt: task.createdAt + 5))
        }
    }

    /// A `claude -p --output-format stream-json --verbose` log, the lines `StreamJSONParser` turns into events.
    static func runLog(sessionID: String) -> String {
        let lines: [[String: Any]] = [
            ["type": "system", "subtype": "init", "session_id": sessionID, "model": "claude-sonnet-4-5"],
            assistant(text: "Önce ekran görüntüsünü okuyorum."),
            tool("Read", ["file_path": "~/Library/Application Support/Shotcue/captures/2026/09/c41f2a7e.png"]),
            toolResult(),
            tool("Grep", ["pattern": "LoginForm"]),
            toolResult(),
            tool("Edit", ["file_path": "src/components/LoginForm.tsx"]),
            toolResult(),
            tool("Edit", ["file_path": "src/components/LoginForm.test.tsx"]),
            toolResult(),
            tool("Bash", ["command": "npm test -- LoginForm"]),
            toolResult(),
            assistant(text: "Buton artık kartın içinde kalıyor; mobil ve masaüstü için test ekledim."),
            [
                "type": "result", "subtype": "success", "is_error": false, "duration_ms": 84_213, "num_turns": 11,
                "total_cost_usd": 0.4137, "session_id": sessionID,
                "result": "Giriş butonu artık kartın içinde; genişlik %100, iç boşluk korunuyor.",
                "permission_denials": [Any](),
            ],
        ]
        return
            lines
            .compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n") + "\n"
    }

    private static func assistant(text: String) -> [String: Any] {
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
    }

    private static func tool(_ name: String, _ input: [String: String]) -> [String: Any] {
        [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "id": "toolu_\(name.lowercased())", "name": name, "input": input]],
            ],
        ]
    }

    private static func toolResult() -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]]
    }

    // MARK: Shots

    func shootLibrary(_ look: Look) async throws {
        let cache = primedCache()
        let store = LibraryStore(services: services)
        store.start()
        defer { store.stop() }
        store.selection = .project(pati.id)
        try await waitFor("library rows") { store.tasks.count == 9 && store.projects.count == 3 }
        store.selectedTaskIDs = [loginTaskID]
        try await waitFor("inspector store") { store.detailStore?.runs.count == 1 }
        guard let detail = store.detailStore else { throw ReadmeShotError("no inspector store") }
        await detail.selectRun(loginRunID)
        try await waitFor("thumbnails") { store.thumbRelPaths.count >= 9 && !detail.selectedRunEvents.isEmpty }

        let host = NSHostingView(rootView: LibraryView(store: store, thumbnails: cache))
        // Title, toolbar and search field go to the window, as in the app's `Window` scene.
        host.sceneBridgingOptions = .all
        let image = try await capture(
            host, size: NSSize(width: 1280, height: 760), look: look, titled: true, backdrop: .window)
        // Shown about 880 pt wide in a README: twice that is plenty.
        let framed = try Self.framed(image, look: look, cornerRadius: 26)
        try Self.write(Self.resized(framed, maxWidth: 1840), to: file("library", look), type: .png)
    }

    func shootInspector(_ look: Look) async throws {
        let cache = primedCache()
        let store = TaskDetailStore(services: services, taskID: loginTaskID)
        await store.start()
        defer { store.stop() }
        await store.selectRun(loginRunID)
        try await waitFor("run log") { !store.selectedRunEvents.isEmpty && store.sessionID != nil }

        let host = NSHostingView(rootView: TaskInspectorView(store: store, thumbnails: cache))
        // The lower part: the run, its replayed log and the hand-off buttons (the library shot shows the top).
        let image = try await capture(
            host, size: NSSize(width: 400, height: 748), look: look, titled: false, backdrop: .window
        ) { Self.scrollToBottom(host) }
        try Self.write(Self.framed(image, look: look, cornerRadius: 18), to: file("inspector", look), type: .png)
    }

    func shootQuickPanel(_ look: Look) async throws {
        let cache = primedCache()
        let suite = "readme-shots-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ReadmeShotError("no defaults suite") }
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.lastUsedProjectID = pati.id.uuidString
        let model = TranscriberModelStore(
            transcriber: services.transcriber, transcriptionQueue: services.transcriptionQueue,
            modelName: SettingsStore.defaultSTTModel)
        let store = QuickPanelStore(services: services, settings: settings, modelStore: model)
        // Each appearance records its own note on the same capture: start from none.
        let panelTask = panelTaskID
        tasks.voiceStorage.withLock { notes in notes = notes.filter { $0.value.taskID != panelTask } }
        await store.capture(taskID: panelTaskID)
        // Right after a recording: the note is kept, the timer shows its length.
        await store.toggleRecording()
        await store.toggleRecording()
        store.noteText = "Giriş butonu mobilde kartın dışına taşıyor. Genişlik %100 olsun, iç boşluk korunsun."
        try await waitFor("panel") { store.voiceNotes.count == 1 && store.thumbnailURL != nil }

        let host = NSHostingView(rootView: QuickPanelView(store: store, thumbnails: cache))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        let size = NSSize(width: max(560, fitting.width), height: max(200, fitting.height))
        // The panel is glass: it is shown over a wallpaper-like backdrop, the way it floats over other apps.
        let image = try await capture(
            host, size: size, look: look, titled: false, backdrop: .wallpaper, margin: 44)
        try Self.write(Self.framed(image, look: look, cornerRadius: 22), to: file("quick-panel", look), type: .png)
    }

    private func file(_ name: String, _ look: Look) -> URL {
        output.appendingPathComponent("\(name)-\(look.rawValue).png")
    }

    /// The shared image cache with every thumbnail already decoded, so the first frame has its pictures.
    private func primedCache() -> ThumbnailCache {
        let cache = ThumbnailCache(fileStore: services.fileStore)
        for relPath in thumbnails {
            if let image = NSImage(contentsOf: services.fileStore.absoluteURL(for: relPath)) {
                cache.store(image, relPath: relPath)
            }
        }
        return cache
    }

    // MARK: Hosting and capture

    /// What would be behind the window on screen.
    enum Backdrop {
        /// The window background colour of the appearance.
        case window
        /// A soft gradient, for the glass quick panel that floats over other apps.
        case wallpaper
    }

    /// Stays far outside every screen and draws with the key-window look.
    ///
    /// The test process is never activated (it must not take focus from the user), and AppKit draws windows of an
    /// inactive app grey: plain window buttons, untinted prominent buttons. The overrides below report the active
    /// state instead; the underscored ones are the AppKit hooks behind that look, which is why they are selectors.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
        @objc(_hasActiveAppearanceForStandardWindowButton:)
        func hasActiveAppearance(forStandardWindowButton kind: Int) -> Bool { true }
        @objc func _hasKeyAppearance() -> Bool { true }
        @objc func hasKeyAppearance() -> Bool { true }
    }

    private func capture(
        _ host: NSView, size: NSSize, look: Look, titled: Bool, backdrop: Backdrop, margin: CGFloat = 0,
        prepare: (() -> Void)? = nil
    ) async throws -> CGImage {
        let style: NSWindow.StyleMask =
            titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -40_000, y: -40_000), size: size), styleMask: style,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look.appearance
        if titled {
            window.toolbarStyle = .unified
        } else {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await settle(host, in: window, rounds: 30)
        if let prepare {
            prepare()
            try await settle(host, in: window, rounds: 15)
        }
        guard let image = Self.render(window, look: look, backdrop: backdrop, margin: margin) else {
            throw ReadmeShotError("render failed")
        }
        return image
    }

    /// Lets SwiftUI settle: stores publish, the view graph updates, AppKit lays out and draws.
    private func settle(_ host: NSView, in window: NSWindow, rounds: Int) async throws {
        for _ in 0..<rounds {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// `CARenderer`s are kept: Core Animation asserts when one that rendered a window's layers is released, and the
    /// test process exits right after the shots.
    private static var renderers: [CARenderer] = []

    /// Renders `window` with Core Animation's own renderer into a Metal texture: the renderer the window server
    /// composites with, so Liquid Glass, materials and portals look as they do on screen (`cacheDisplay` draws on
    /// the CPU and leaves them blank or garbled). The window's top-level layers are moved under a root of our own,
    /// over `backdrop` and inside `margin`; the window is not used again afterwards.
    private static func render(_ window: NSWindow, look: Look, backdrop: Backdrop, margin: CGFloat) -> CGImage? {
        guard let frameLayer = window.contentView?.superview?.layer,
            let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { return nil }
        let scale: CGFloat = 2
        let size = CGSize(width: frameLayer.bounds.width + margin * 2, height: frameLayer.bounds.height + margin * 2)
        let root = CALayer()
        root.anchorPoint = .zero
        root.position = .zero
        root.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let stage = CALayer()
        stage.anchorPoint = .zero
        stage.position = .zero
        stage.bounds = CGRect(origin: .zero, size: size)
        stage.transform = CATransform3DMakeScale(scale, scale, 1)
        root.addSublayer(stage)
        let background = backdropLayer(backdrop, look: look)
        background.frame = stage.bounds
        stage.addSublayer(background)
        let windowLayer = CALayer()
        windowLayer.anchorPoint = .zero
        windowLayer.position = CGPoint(x: margin, y: margin)
        windowLayer.bounds = frameLayer.bounds
        for sublayer in frameLayer.sublayers ?? [] {
            windowLayer.addSublayer(sublayer)
        }
        stage.addSublayer(windowLayer)

        let width = Int(root.bounds.width)
        let height = Int(root.bounds.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let renderer = CARenderer(
            mtlTexture: texture,
            options: [
                kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                kCARendererMetalCommandQueue: queue,
            ])
        renderers.append(renderer)
        renderer.layer = root
        CATransaction.flush()
        renderer.bounds = root.bounds
        for _ in 0..<2 {
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
        }
        guard let fence = queue.makeCommandBuffer() else { return nil }
        fence.commit()
        fence.waitUntilCompleted()

        // Core Animation's origin is bottom-left: flip the rows.
        let rowBytes = width * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height {
            let source = (height - 1 - row) * rowBytes
            bytes.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: raw[source..<source + rowBytes])
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func backdropLayer(_ backdrop: Backdrop, look: Look) -> CALayer {
        switch backdrop {
        case .window:
            let layer = CALayer()
            var color = CGColor(gray: look == .dark ? 0.12 : 0.96, alpha: 1)
            look.appearance?.performAsCurrentDrawingAppearance { color = NSColor.windowBackgroundColor.cgColor }
            layer.backgroundColor = color
            return layer
        case .wallpaper:
            let layer = CAGradientLayer()
            layer.startPoint = CGPoint(x: 0, y: 1)
            layer.endPoint = CGPoint(x: 1, y: 0)
            let colors: [UInt32] = look == .dark ? [0x1A2150, 0x2B1B4F, 0x40243A] : [0xD9E4FF, 0xECDFFF, 0xFFE6D6]
            layer.colors = colors.map { hex in
                CGColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
            return layer
        }
    }

    /// Scrolls the first scroll view in `view` to its end.
    private static func scrollToBottom(_ view: NSView) {
        guard let scrollView = firstScrollView(in: view), let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let end = max(0, document.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? end : 0))
        scrollView.reflectScrolledClipView(clip)
        // A programmatic scroll flashes the overlay scroller; a still picture should not show it.
        scrollView.verticalScroller?.alphaValue = 0
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    /// Stores hand their work to `Task`s; this waits, bounded, until `condition` holds.
    private func waitFor(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ReadmeShotError("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Output

    /// The capture on a transparent canvas: rounded corners, a hairline edge and a soft shadow, like a window.
    static func framed(_ image: CGImage, look: Look, cornerRadius: CGFloat) throws -> CGImage {
        let scale: CGFloat = 2
        let margin = CGSize(width: 48 * scale, height: 56 * scale)
        let width = CGFloat(image.width) + margin.width * 2
        let height = CGFloat(image.height) + margin.height * 2
        guard
            let context = CGContext(
                data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ReadmeShotError("no context") }
        let rect = CGRect(
            x: margin.width, y: margin.height + 8 * scale, width: CGFloat(image.width), height: CGFloat(image.height))
        let path = CGPath(
            roundedRect: rect, cornerWidth: cornerRadius * scale, cornerHeight: cornerRadius * scale, transform: nil)
        let dark = look == .dark
        // Shadow, cast by the window's own shape.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -14 * scale), blur: 36 * scale,
            color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.22))
        context.addPath(path)
        context.setFillColor(CGColor(gray: dark ? 0.1 : 0.9, alpha: 1))
        context.fillPath()
        context.restoreGState()
        // Content, clipped to the rounded shape.
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        // Hairline edge.
        context.addPath(path)
        context.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.14))
        context.setLineWidth(1 * scale)
        context.strokePath()
        guard let result = context.makeImage() else { throw ReadmeShotError("no image") }
        return result
    }

    /// `image` scaled down to `maxWidth` pixels, or unchanged when it is not wider.
    static func resized(_ image: CGImage, maxWidth: Int) throws -> CGImage {
        guard image.width > maxWidth else { return image }
        let height = Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded())
        guard
            let context = CGContext(
                data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ReadmeShotError("no context") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        guard let result = context.makeImage() else { throw ReadmeShotError("no image") }
        return result
    }

    static func write(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw ReadmeShotError("cannot write \(url.lastPathComponent)") }
        let properties: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.86] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ReadmeShotError("cannot finalize \(url.lastPathComponent)")
        }
    }

    static func render(_ mock: CaptureMock, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(
            content: mock.view.frame(width: CaptureMock.size.width, height: CaptureMock.size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { throw ReadmeShotError("cannot render \(mock)") }
        return image
    }
}

// MARK: - Fictional captures (screenshots of made-up web apps)

enum CaptureMock {
    case login, phone, darkCards, gallery, search, footer, donation, map, avatar

    static let size = CGSize(width: 480, height: 340)

    @ViewBuilder var view: some View {
        switch self {
        case .login: LoginMock()
        case .phone: PhoneMock()
        case .darkCards: DarkCardsMock()
        case .gallery: GalleryMock()
        case .search: SearchMock()
        case .footer: FooterMock()
        case .donation: DonationMock()
        case .map: MapMock()
        case .avatar: AvatarMock()
        }
    }
}

extension Color {
    fileprivate init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

private struct Bar: View {
    var width: CGFloat
    var height: CGFloat = 8
    var color = Color(hex: 0xE2E5EC)
    var body: some View {
        RoundedRectangle(cornerRadius: height / 2).fill(color).frame(width: width, height: height)
    }
}

private struct SiteHeader: View {
    var dark = false
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color(hex: 0xFF8A4C))
                Image(systemName: "pawprint.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            Text("pati").font(.system(size: 16, weight: .bold)).foregroundStyle(dark ? .white : Color(hex: 0x1B1E2B))
            Spacer()
            ForEach([46.0, 38, 58], id: \.self) { width in
                Bar(width: width, height: 7, color: dark ? Color(hex: 0x2A2E36) : Color(hex: 0xE2E5EC))
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 44)
    }
}

private struct FieldMock: View {
    var label: String
    var value: String
    var valueColor = Color(hex: 0x6B7185)
    var trailing: AnyView?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color(hex: 0x6B7185))
            HStack {
                Text(value).font(.system(size: 13)).foregroundStyle(valueColor)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color(hex: 0xF2F4F8), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xDFE2EA)))
        }
    }
}

/// The login card whose button is wider than the card (the bug the sample task reports).
private struct LoginMock: View {
    var body: some View {
        ZStack {
            Color(hex: 0xF6F7FB)
            VStack(alignment: .leading, spacing: 11) {
                Text("Giriş yap").font(.system(size: 21, weight: .bold)).foregroundStyle(Color(hex: 0x1B1E2B))
                Bar(width: 150)
                FieldMock(label: "E-posta", value: "ada@ornek.com", valueColor: Color(hex: 0xA2A7B7))
                FieldMock(label: "Şifre", value: "••••••••")
                Text("Giriş yap")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 290, height: 40)
                    .background(Color(hex: 0xFF8A4C), in: .rect(cornerRadius: 10))
                    .frame(width: 236, alignment: .leading)
                    .padding(.top, 4)
                Text("Şifremi unuttum").font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xE0703A))
                    .frame(width: 236)
            }
            .padding(22)
            .frame(width: 280)
            .background(.white, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xE3E6EE)))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
        }
    }
}

/// An adoption form that accepts letters in the phone field.
private struct PhoneMock: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 0) {
                SiteHeader()
                Divider()
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sahiplenme\nbaşvurusu").font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color(hex: 0x1B1E2B))
                        Bar(width: 120)
                        Bar(width: 90)
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFFE7D8))
                            Image(systemName: "pawprint.fill").font(.system(size: 30)).foregroundStyle(
                                Color(hex: 0xFF9E6B))
                        }
                        .frame(width: 130, height: 92)
                        .padding(.top, 8)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        FieldMock(label: "Ad soyad", value: "Ada Yıldız", valueColor: Color(hex: 0x1B1E2B))
                        FieldMock(
                            label: "Telefon", value: "05xx abc 12", valueColor: Color(hex: 0x1B1E2B),
                            trailing: AnyView(
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x34C759))))
                        FieldMock(label: "Şehir", value: "İzmir", valueColor: Color(hex: 0x1B1E2B))
                        Text("Başvuruyu gönder")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .background(Color(hex: 0x7B61FF), in: .rect(cornerRadius: 9))
                    }
                    .frame(width: 250)
                }
                .padding(22)
            }
        }
    }
}

/// Dark mode cards that melt into the background.
private struct DarkCardsMock: View {
    struct Pet {
        let name: String
        let color: UInt32
    }
    static let pets = [
        Pet(name: "Karamel", color: 0xFF9E6B), Pet(name: "Duman", color: 0x7FA2FF), Pet(name: "Pamuk", color: 0x62C987),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0x0F1115)
            VStack(alignment: .leading, spacing: 14) {
                SiteHeader(dark: true)
                Text("Yuva bekleyenler").font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 22)
                HStack(spacing: 14) {
                    ForEach(Self.pets, id: \.name) { pet in
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(Color(hex: pet.color, opacity: 0.16))
                                Image(systemName: "pawprint.fill").font(.system(size: 26))
                                    .foregroundStyle(Color(hex: pet.color, opacity: 0.75))
                            }
                            .frame(height: 104)
                            Text(pet.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(
                                .white.opacity(0.8))
                            Text("2 yaş · İzmir").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(10)
                        .background(Color(hex: 0x14171C), in: .rect(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }
}

/// A gallery still loading its pictures one by one.
private struct GalleryMock: View {
    private func tile(_ index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(index < 2 ? Color(hex: index == 0 ? 0xFFE7D8 : 0xE0EAFF) : Color(hex: 0xEEF0F4))
            if index < 2 {
                Image(systemName: "pawprint.fill").font(.system(size: 26))
                    .foregroundStyle(Color(hex: index == 0 ? 0xFF9E6B : 0x7FA2FF))
            } else if index == 2 {
                Circle().trim(from: 0, to: 0.7)
                    .stroke(Color(hex: 0xB8BDC9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 136, height: 104)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 12) {
                SiteHeader()
                Text("Galeri").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(hex: 0x1B1E2B))
                    .padding(.horizontal, 22)
                VStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(0..<3, id: \.self) { column in
                                tile(row * 3 + column)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }
}

/// A search with no results and nothing on the page to say so.
private struct SearchMock: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 14) {
                SiteHeader()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x8A90A3))
                    Text("papağan").font(.system(size: 14)).foregroundStyle(Color(hex: 0x1B1E2B))
                    Spacer()
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xC4C8D2))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color(hex: 0xF3F4F8), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 22)
                Text("0 sonuç").font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A90A3)).padding(.horizontal, 24)
                Spacer()
            }
        }
    }
}

/// A footer whose social icons do not share a baseline.
private struct FooterMock: View {
    static let icons = ["camera.fill", "play.fill", "bubble.left.fill", "envelope.fill"]
    static let offsets: [CGFloat] = [0, 7, -3, 10]

    var body: some View {
        ZStack(alignment: .top) {
            Color.white
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Bar(width: 260, height: 10)
                    Bar(width: 200)
                    Bar(width: 230)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 40) {
                        ForEach(["Hakkımızda", "Destek", "Gönüllü ol"], id: \.self) { title in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                                    .white.opacity(0.9))
                                Bar(width: 60, height: 6, color: .white.opacity(0.15))
                                Bar(width: 44, height: 6, color: .white.opacity(0.15))
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(Self.icons.enumerated()), id: \.offset) { pair in
                            ZStack {
                                Circle().fill(.white.opacity(0.12))
                                Image(systemName: pair.element).font(.system(size: 12)).foregroundStyle(
                                    .white.opacity(0.85))
                            }
                            .frame(width: 30, height: 30)
                            .offset(y: Self.offsets[pair.offset])
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .frame(height: 170, alignment: .top)
                .background(Color(hex: 0x1E2330))
            }
        }
    }
}

/// A donation form that takes a negative amount.
private struct DonationMock: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0xF7FBF8)
            VStack(alignment: .leading, spacing: 12) {
                SiteHeader()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bağış yap").font(.system(size: 20, weight: .bold)).foregroundStyle(Color(hex: 0x1B1E2B))
                    HStack(spacing: 8) {
                        ForEach(["50 ₺", "100 ₺", "250 ₺"], id: \.self) { amount in
                            Text(amount).font(.system(size: 13, weight: .semibold)).foregroundStyle(
                                Color(hex: 0x2F8F5B)
                            )
                            .frame(width: 72, height: 32)
                            .background(Color(hex: 0xE3F5EA), in: .rect(cornerRadius: 8))
                        }
                    }
                    FieldMock(label: "Tutar", value: "-50 ₺", valueColor: Color(hex: 0x1B1E2B))
                        .frame(width: 236)
                    Text("Bağışı tamamla")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 236, height: 36)
                        .background(Color(hex: 0x34A56F), in: .rect(cornerRadius: 9))
                }
                .padding(.horizontal, 22)
            }
        }
    }
}

/// Shelters on a map whose pins are too small to tap.
private struct MapMock: View {
    static let pins: [CGPoint] = [CGPoint(x: 120, y: 150), CGPoint(x: 260, y: 110), CGPoint(x: 350, y: 220)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0xEAF2E3)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 190))
                path.addLine(to: CGPoint(x: 480, y: 130))
                path.move(to: CGPoint(x: 180, y: 0))
                path.addLine(to: CGPoint(x: 230, y: 340))
                path.move(to: CGPoint(x: 0, y: 290))
                path.addLine(to: CGPoint(x: 480, y: 260))
            }
            .stroke(.white, lineWidth: 10)
            RoundedRectangle(cornerRadius: 40).fill(Color(hex: 0xCFE5F7)).frame(width: 150, height: 90)
                .offset(x: 300, y: 250)
            ForEach(Array(Self.pins.enumerated()), id: \.offset) { pair in
                Image(systemName: "mappin.circle.fill").font(.system(size: 14)).foregroundStyle(Color(hex: 0xE5484D))
                    .offset(x: pair.element.x, y: pair.element.y)
            }
            HStack(spacing: 8) {
                Image(systemName: "pawprint.fill").foregroundStyle(Color(hex: 0xFF8A4C))
                Text("Yakındaki barınaklar").font(.system(size: 14, weight: .semibold)).foregroundStyle(
                    Color(hex: 0x1B1E2B))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.white, in: .capsule)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .padding(18)
        }
    }
}

/// A profile whose uploaded photo shows up blurred.
private struct AvatarMock: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 16) {
                SiteHeader()
                HStack(alignment: .center, spacing: 20) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFFB38A), Color(hex: 0x7FA2FF)], startPoint: .topLeading,
                                endPoint: .bottomTrailing)
                        )
                        .overlay(
                            Image(systemName: "person.fill").font(.system(size: 44)).foregroundStyle(
                                .white.opacity(0.8))
                        )
                        .frame(width: 110, height: 110)
                        .blur(radius: 5)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ada Yıldız").font(.system(size: 19, weight: .bold)).foregroundStyle(Color(hex: 0x1B1E2B))
                        Text("Gönüllü · 2 sahiplendirme").font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B7185))
                        Text("Fotoğrafı değiştir")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x4A70F5))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Color(hex: 0xE6ECFF), in: .capsule)
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }
}
