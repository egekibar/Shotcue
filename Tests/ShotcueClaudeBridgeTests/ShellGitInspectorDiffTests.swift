import Foundation
import ShotcueCore
import Testing

@testable import ShotcueClaudeBridge

@Suite("ShellGitInspector diff")
struct ShellGitInspectorDiffTests {
    /// Runs `/usr/bin/git -C <path> <args>` to set up a throwaway repo; returns stdout.
    @discardableResult
    func git(_ args: String..., at path: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Creates a throwaway repo with one commit; returns its path and HEAD.
    func makeRepo() throws -> (path: String, head: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git("init", "-q", at: dir.path)
        try git("config", "user.email", "test@example.com", at: dir.path)
        try git("config", "user.name", "Test", at: dir.path)
        try "first line\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", "a.txt", at: dir.path)
        try git("commit", "-q", "-m", "init", at: dir.path)
        let head = try git("rev-parse", "HEAD", at: dir.path).trimmingCharacters(in: .whitespacesAndNewlines)
        return (dir.path, head)
    }

    @Test func showsTrackedChangesAndUntrackedFileContentsSinceTheRecordedHead() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        try "first line\nsecond line\n".write(toFile: repo.path + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: repo.path + "/docs", withIntermediateDirectories: true)
        try "hello\n".write(toFile: repo.path + "/docs/new file.txt", atomically: true, encoding: .utf8)
        let text = try await ShellGitInspector().diff(at: repo.path, since: repo.head, maxBytes: 100_000)
        let files = UnifiedDiffParser.parse(text).files
        #expect(files.map(\.path) == ["a.txt", "docs/new file.txt"])
        #expect(files.map(\.status) == [.modified, .added])
        #expect(files[0].hunks.first?.lines.last == DiffLine(kind: .added, text: "second line", oldNumber: nil, newNumber: 2))
        #expect(files[1].hunks.first?.lines == [DiffLine(kind: .added, text: "hello", oldNumber: nil, newNumber: 1)])
        // The repository is left as it was: untracked files stay untracked.
        #expect(try git("status", "--porcelain", at: repo.path).contains("?? docs/"))
    }

    @Test func showsNonASCIIFileNamesAsTheyAre() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        try "ilk\n".write(toFile: repo.path + "/çalışma.txt", atomically: true, encoding: .utf8)
        try git("add", "çalışma.txt", at: repo.path)
        try git("commit", "-q", "-m", "tr", at: repo.path)
        try "ilk\nikinci\n".write(toFile: repo.path + "/çalışma.txt", atomically: true, encoding: .utf8)
        try "özet\n".write(toFile: repo.path + "/özet.md", atomically: true, encoding: .utf8)
        let text = try await ShellGitInspector().diff(at: repo.path, since: nil, maxBytes: 100_000)
        #expect(UnifiedDiffParser.parse(text).files.map(\.path) == ["çalışma.txt", "özet.md"])
    }

    @Test func nothingChangedIsEmpty() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        #expect(try await ShellGitInspector().diff(at: repo.path, since: repo.head, maxBytes: 100_000) == "")
    }

    @Test func defaultsToHeadAndHonoursTheByteCap() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        try String(repeating: "line\n", count: 200).write(
            toFile: repo.path + "/a.txt", atomically: true, encoding: .utf8)
        try "late\n".write(toFile: repo.path + "/z.txt", atomically: true, encoding: .utf8)
        let text = try await ShellGitInspector().diff(at: repo.path, since: nil, maxBytes: 300)
        #expect(text.hasSuffix(DiffText.truncationNotice(maxBytes: 300)))
        let document = UnifiedDiffParser.parse(text)
        #expect(document.isTruncated)
        #expect(document.files.map(\.path) == ["a.txt"])
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
