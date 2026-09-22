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
        return GitOutputParser.snapshot(
            revParseHead: head.stdout,
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
