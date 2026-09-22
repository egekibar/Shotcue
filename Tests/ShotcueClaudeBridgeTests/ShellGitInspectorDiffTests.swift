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

    @Test func showsTrackedChangesAndUntrackedFilesSinceTheRecordedHead() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        try "first line\nsecond line\n".write(toFile: repo.path + "/a.txt", atomically: true, encoding: .utf8)
        try "hello\n".write(toFile: repo.path + "/new.txt", atomically: true, encoding: .utf8)
        let text = try await ShellGitInspector().diff(at: repo.path, since: repo.head, maxBytes: 100_000)
        #expect(text.hasPrefix("# İzlenmeyen dosyalar\n?? new.txt\n\n# git diff \(repo.head.prefix(7))\n"))
        #expect(text.contains("+second line"))
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
        #expect(text.contains("?? özet.md"))
        #expect(text.contains("+++ b/çalışma.txt"))
    }

    @Test func defaultsToHeadAndHonoursTheByteCap() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo.path) }
        try String(repeating: "line\n", count: 200).write(
            toFile: repo.path + "/a.txt", atomically: true, encoding: .utf8)
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
