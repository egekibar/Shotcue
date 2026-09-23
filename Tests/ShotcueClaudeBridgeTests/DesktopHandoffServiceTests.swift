import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueClaudeBridge

/// `openInTerminal`, `openDesktopComposer` and `openInDesktop` end in the injected opener; the tests pass one that only
/// records, so nothing launches Terminal or Claude Desktop from a test process.
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
        #expect(
            DesktopHandoffService.resumeURL(sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
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
        let url = DesktopHandoffService.composerURL(
            route: "cowork/new", prompt: "x",
            projectPath: "/tmp/p", files: [])
        #expect(url.absoluteString == "claude://cowork/new?q=x&folder=/tmp/p")
    }

    @Test func composerURLTruncatesTheQueryAt14000Characters() throws {
        let long = String(repeating: "a", count: 20_000)
        let url = DesktopHandoffService.composerURL(
            route: "code/new", prompt: long,
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

        // `openDesktopComposer` spills through this helper before it calls NSWorkspace.open.
        let long = String(repeating: "ş", count: 20_000)
        let payload = try DesktopHandoffService.composerPayload(prompt: long, files: ["/tmp/a.png"], fileStore: store)
        let runsDirectory = store.absoluteURL(for: FileStore.runsDir)
        let spilled = try FileManager.default.contentsOfDirectory(atPath: runsDirectory.path)
            .filter { $0.hasSuffix("-prompt.md") }
        #expect(spilled.count == 1)
        let spillPath = runsDirectory.appendingPathComponent(spilled[0]).path
        let written = try String(contentsOfFile: spillPath, encoding: .utf8)
        #expect(written.count == 20_000)
        #expect(payload.text == DesktopHandoffService.longPromptNotice(path: spillPath))
        #expect(payload.files == ["/tmp/a.png", spillPath])

        // A prompt within the limit passes through untouched and writes nothing.
        let short = try DesktopHandoffService.composerPayload(prompt: "kısa", files: [], fileStore: store)
        #expect(short.text == "kısa")
        #expect(short.files.isEmpty)
    }

    /// Final review M6: the resumed session needs the project as its working directory (claude keeps sessions per
    /// folder, and its tools must run there), and nothing in the file may be read by the shell as code.
    @Test func commandFileContentsCdIntoTheProjectAndQuoteEverything() {
        let script = DesktopHandoffService.commandFileContents(
            claudeExecutable: URL(fileURLWithPath: "/Users/me/my tools/claude"),
            sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73",
            projectPath: "/Users/me/it's a project")
        #expect(
            script
                == "#!/bin/zsh\n"
                + "cd -- '/Users/me/it'\\''s a project' || exit 1\n"
                + "'/Users/me/my tools/claude' --resume 3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73\n")
        #expect(!script.contains("--bare"))
        #expect(DesktopHandoffService.shellQuoted("a'b") == "'a'\\''b'")
        #expect(DesktopHandoffService.shellQuoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test func openInTerminalWritesTheCommandFileAndOpensIt() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let opened = Locked<[URL]>([])
        let service = DesktopHandoffService(
            claudeExecutable: claude, fileStore: store,
            open: { url in
                opened.withLock { $0.append(url) }
                return true
            })
        // Any spelling of the id is accepted; the file carries the lowercase one the run started with.
        try service.openInTerminal(sessionID: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73", projectPath: "/tmp/proje")

        let sessionID = "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"
        let url = store.absoluteURL(for: "runs/\(sessionID)-resume.command")
        #expect(opened.current == [url])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(
            text
                == DesktopHandoffService.commandFileContents(
                    claudeExecutable: claude, sessionID: sessionID, projectPath: "/tmp/proje"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o755)
    }

    @Test func aSessionIDThatIsNotAUUIDIsRefusedBeforeAnythingIsWritten() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let opened = Locked(0)
        let service = DesktopHandoffService(
            claudeExecutable: claude, fileStore: store,
            open: { _ in
                opened.withLock { $0 += 1 }
                return true
            })
        #expect(throws: HandoffError.invalidSessionID("x; rm -rf ~")) {
            try service.openInTerminal(sessionID: "x; rm -rf ~", projectPath: "/tmp/proje")
        }
        #expect(opened.current == 0)
        let runs = store.absoluteURL(for: FileStore.runsDir).path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: runs)) ?? []).isEmpty)
    }

    @Test func aFailedOpenIsReported() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let service = DesktopHandoffService(claudeExecutable: claude, fileStore: store, open: { _ in false })
        #expect(throws: HandoffError.self) {
            try service.openInTerminal(sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73", projectPath: "/tmp/p")
        }
    }

    /// Final review M6: `+` would read as a space on the receiving side; it is percent-encoded.
    @Test func composerURLPercentEncodesPlus() throws {
        let url = DesktopHandoffService.composerURL(
            route: "code/new", prompt: "C++ ve a+b", projectPath: "/tmp/a+b", files: ["/tmp/x+y.png"])
        #expect(url.absoluteString.contains("q=C%2B%2B%20ve%20a%2Bb"))
        #expect(url.absoluteString.contains("folder=/tmp/a%2Bb"))
        #expect(url.absoluteString.contains("file=/tmp/x%2By.png"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.value == "C++ ve a+b")
    }
}
