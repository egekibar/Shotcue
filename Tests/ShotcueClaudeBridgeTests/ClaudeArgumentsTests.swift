import Foundation
import ShotcueCore
import Testing

@testable import ShotcueClaudeBridge

@Suite("ClaudeArguments")
struct ClaudeArgumentsTests {
    let runID = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!

    func spec(mode: TaskMode, model: String? = nil, effort: String? = nil) -> RunSpec {
        RunSpec(
            runID: runID, prompt: "PROMPT", projectPath: "/Users/me/crm", mode: mode,
            model: model, effort: effort, maxTurns: 50, maxBudgetUSD: 5, timeout: 1800,
            permissionMode: .bypassPermissions, addDirs: ["/tmp/captures"],
            systemPromptAppend: "SYS")
    }

    @Test func implementModeArgumentsAreExact() {
        #expect(
            ClaudeArguments.build(spec: spec(mode: .implement)) == [
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
        let found = ClaudeLocator.locate(
            preferredPath: preferred.path, candidates: [candidate.path],
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

        #expect(
            ClaudeLocator.locate(
                preferredPath: "/nope/claude", candidates: [candidate.path],
                fileManager: .default, loginShellWhich: { _ in nil })?.path
                == candidate.standardizedFileURL.path)

        let shellResult = URL(fileURLWithPath: "/from/shell/claude")
        #expect(
            ClaudeLocator.locate(
                preferredPath: nil, candidates: ["/nope/claude"],
                fileManager: .default, loginShellWhich: { _ in shellResult })
                == shellResult)
    }

    @Test func nilWhenNothingIsExecutable() {
        #expect(
            ClaudeLocator.locate(
                preferredPath: "/nope/claude", candidates: ["/also/nope"],
                fileManager: .default, loginShellWhich: { _ in nil }) == nil)
    }

    @Test func defaultCandidateOrderMatchesSpec() {
        #expect(
            ClaudeLocator.defaultCandidates == [
                "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            ])
    }
}
