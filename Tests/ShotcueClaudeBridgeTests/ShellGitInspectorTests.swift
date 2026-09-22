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
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Shotcue Test"],
        ] {
            _ = try await ProcessCapture.run(executableURL: exe, arguments: arguments, currentDirectory: url)
        }
        try Data("hello\n".utf8).write(to: url.appendingPathComponent("a.txt"))
        _ = try await ProcessCapture.run(executableURL: exe, arguments: ["add", "."], currentDirectory: url)
        _ = try await ProcessCapture.run(
            executableURL: exe, arguments: ["commit", "-q", "-m", "init"],
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
