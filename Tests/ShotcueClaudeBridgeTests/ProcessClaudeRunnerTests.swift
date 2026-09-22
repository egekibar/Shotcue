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
        RunSpec(
            runID: UUID(), prompt: "PROMPT", projectPath: projectPath, mode: mode,
            maxTurns: 50, maxBudgetUSD: 5, timeout: timeout,
            permissionMode: .bypassPermissions, addDirs: ["/tmp/captures"],
            systemPromptAppend: "SYS")
    }

    /// Writes an executable bash stand-in for `claude` into `directory`.
    func makeScript(_ body: String, in directory: URL, named name: String = "fake-claude") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(("#!/bin/bash\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func runner(scenario: String, argsFile: URL? = nil, killGrace: Duration = .seconds(1)) -> ProcessClaudeRunner {
        var overrides = ["FAKE_CLAUDE_SCENARIO": scenario]
        if let argsFile { overrides["FAKE_CLAUDE_ARGS_FILE"] = argsFile.path }
        return ProcessClaudeRunner(
            executableURL: fakeClaude, environmentOverrides: overrides,
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
        #expect(
            received[0]
                == .initialized(
                    sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73",
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

    /// Regression: the stdout and stderr sources fire independently, so reaching stdout EOF says nothing
    /// about stderr. Here the failure text deterministically lands after stdout is closed and the child
    /// has exited (a lingering helper writes it), which the drain window must still pick up.
    @Test func stderrArrivingAfterStdoutEOFIsStillReported() async throws {
        let project = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let script = project.appendingPathComponent("late-stderr.sh")
        try Data("#!/bin/bash\n( exec 1>&-; sleep 0.2; echo 'Error: not logged in.' >&2 ) &\nexit 1\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let subject = ProcessClaudeRunner(executableURL: script, environmentOverrides: [:], killGrace: .seconds(1))
        do {
            _ = try await subject.run(spec(projectPath: project.path)) { _ in }
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

    @Test func cancelBeforeRunNeverLaunches() async throws {
        let project = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let argsFile = project.appendingPathComponent("args.txt")
        let subject = runner(scenario: "success", argsFile: argsFile)
        let spec = spec(projectPath: project.path)

        await subject.cancel(runID: spec.runID)
        await #expect(throws: ClaudeRunError.cancelled) {
            _ = try await subject.run(spec) { _ in }
        }
        // The fake writes the args file first thing, so no file means no launch.
        #expect(!FileManager.default.fileExists(atPath: argsFile.path))

        // The pending cancel was consumed by that attempt: the registry keeps nothing behind.
        let result = try await subject.run(spec) { _ in }
        #expect(result.isSuccess)
    }

    /// claude 2.1.278 handles SIGINT by exiting 0 (SIGTERM → 143): a cancel we signalled must still
    /// come back as `.cancelled`, not as `.noResult`.
    @Test func cancelIsReportedWhenTheCLIExitsCleanlyOnSIGINT() async throws {
        let project = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let script = try makeScript(
            """
            trap 'exit 0' INT
            echo '{"type":"system","subtype":"init","session_id":"s","model":"m"}'
            while :; do sleep 0.1; done
            """, in: project)
        // A long grace period, so the child ends through its own trap (exit 0), never through SIGKILL.
        let subject = ProcessClaudeRunner(executableURL: script, environmentOverrides: [:], killGrace: .seconds(5))
        let spec = spec(projectPath: project.path, timeout: 60)
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

    /// `claude -p` exits non-zero when --max-turns is hit, yet its result line carries the subtype, cost
    /// and turns the coordinator needs.
    @Test func resultLineWinsOverANonZeroExit() async throws {
        let project = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let script = try makeScript(
            """
            echo '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":30,"total_cost_usd":0.25,"session_id":"s","permission_denials":[]}'
            exit 1
            """, in: project)
        let subject = ProcessClaudeRunner(executableURL: script, environmentOverrides: [:], killGrace: .seconds(1))
        let result = try await subject.run(spec(projectPath: project.path)) { _ in }
        #expect(result.hitLimit)
        #expect(result.subtype == ClaudeRunResult.maxTurnsSubtype)
        #expect(result.numTurns == 30)
        #expect(result.totalCostUSD == 0.25)
    }

    @Test func versionReadsTheCLIVersion() async throws {
        #expect(try await runner(scenario: "success").version() == "2.1.278 (Claude Code)")
    }

    /// An npm-global `claude` is a `#!/usr/bin/env node` script: `--version` needs the same PATH as `run`,
    /// not the app's launchd PATH.
    @Test func versionRunsWithClaudesOwnDirectoryFirstOnPATH() async throws {
        let directory = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            """
            if [ "${1:-}" = "--version" ]; then echo "$PATH"; exit 0; fi
            exit 1
            """, in: directory)
        let path = try await ProcessClaudeRunner(executableURL: script).version()
        #expect(path.hasPrefix(directory.path + ":"))
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
