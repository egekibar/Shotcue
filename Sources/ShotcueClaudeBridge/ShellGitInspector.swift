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

extension ShellGitInspector: DiffProvider {
    /// `git diff <since|HEAD>` of the working tree plus every untracked file diffed against /dev/null
    /// (spec §6.4 "Diff'i göster"). Nothing is staged: `--no-index` leaves the index alone.
    /// `core.quotePath=false` shows non-ASCII names (`özet.md`) as they are instead of octal escapes; explicit
    /// prefixes override a user's `diff.noprefix`/`diff.mnemonicPrefix`, which the parser would not recognise;
    /// `--` keeps a file named like the revision from making it ambiguous.
    public func diff(at path: String, since: String?, maxBytes: Int) async throws -> String {
        let options = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/"]
        let tracked = try await require(
            ["-c", "core.quotePath=false", "diff"] + options + [since ?? "HEAD", "--"], at: path)
        let listing = try await require(["ls-files", "--others", "--exclude-standard", "-z"], at: path)
        var untracked: [String] = []
        var bytes = tracked.stdout.utf8.count
        for file in DiffText.paths(fromNulSeparated: listing.stdout) {
            // Past the cap the rest would be cut anyway; skipping them avoids diffing a large tree for nothing.
            guard bytes <= maxBytes else { break }
            // `--no-index` exits 1 when the files differ, which is always the case here.
            let output = try await capture(
                ["-c", "core.quotePath=false", "diff", "--no-index"] + options + ["--", "/dev/null", file], at: path)
            guard output.exitCode <= 1 else {
                throw GitError.commandFailed(
                    arguments: ["diff", "--no-index", file], exitCode: output.exitCode, stderr: output.stderr)
            }
            untracked.append(output.stdout)
            bytes += output.stdout.utf8.count
        }
        return DiffText.compose(tracked: tracked.stdout, untracked: untracked, maxBytes: maxBytes)
    }
}
