import Foundation
import ShotcueCore

public enum ClaudeRunError: Error, Equatable, Sendable {
    case notFound
    case launchFailed(String)
    case processFailed(exitCode: Int32, stderr: String)
    case timedOut
    case cancelled
    case noResult
}

/// Runs an agent CLI (`claude -p`, `codex exec`, `agy -p`) in the project directory and streams its NDJSON output
/// as `RunEvent`s (spec §6.4). One instance per agent: `agent` picks the command line and the parser.
/// Writes nothing to disk: log persistence belongs to `RunCoordinator`.
public final class ProcessClaudeRunner: ClaudeRunner, @unchecked Sendable {
    public let executableURL: URL
    public let agent: AgentKind
    public let environmentOverrides: [String: String]
    /// How long a SIGINT gets before SIGKILL. 10 s in production; tests shorten it.
    let killGrace: Duration

    /// `run` and `cancel(runID:)` share ONE lock, so a cancel can never slip between
    /// "is the process registered yet?" and "remember the cancel".
    private struct Registry {
        var active: [UUID: Process] = [:]
        var cancelRequested: Set<UUID> = []
        /// Runs whose live process we signalled because of a cancel.
        var cancelSignalled: Set<UUID> = []

        mutating func forget(_ runID: UUID) {
            active[runID] = nil
            cancelRequested.remove(runID)
            cancelSignalled.remove(runID)
        }
    }

    private let registry = LockBox(Registry())

    public convenience init(
        executableURL: URL, agent: AgentKind = .claude, environmentOverrides: [String: String] = [:]
    ) {
        self.init(
            executableURL: executableURL, agent: agent, environmentOverrides: environmentOverrides,
            killGrace: .seconds(10))
    }

    init(
        executableURL: URL, agent: AgentKind = .claude, environmentOverrides: [String: String], killGrace: Duration
    ) {
        self.executableURL = executableURL
        self.agent = agent
        self.environmentOverrides = environmentOverrides
        self.killGrace = killGrace
    }

    public func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        let runID = spec.runID
        // Every exit path (notFound and launchFailed included) drops what the registry holds for this run.
        defer { registry.withLock { $0.forget(runID) } }
        // A cancel that arrived before the launch wins: nothing is started.
        if registry.withLock({ $0.cancelRequested.contains(runID) }) { throw ClaudeRunError.cancelled }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeRunError.notFound
        }

        let process = Process()
        process.executableURL = executableURL
        // The command line follows this runner's agent, whatever the spec says: the router picked the runner by it.
        var agentSpec = spec
        agentSpec.agent = agent
        process.arguments = AgentArguments.build(spec: agentSpec)
        process.currentDirectoryURL = URL(fileURLWithPath: spec.projectPath, isDirectory: true)
        process.environment = claudeEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Detach stdin: an unattended run must never inherit a terminal.
        process.standardInput = FileHandle.nullDevice

        let lastResult = LockBox<ClaudeRunResult?>(nil)
        let parser = LockBox(AgentStreamParsers.make(for: agent))
        let consume: @Sendable (String) -> Void = { line in
            for event in parser.withLock({ $0.consume(line: line) }) {
                if case .result(let result) = event { lastResult.set(result) }
                onEvent(event)
            }
        }

        let sawStdoutEOF = LockBox(false)
        let stdoutTail = LockBox(Data())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sawStdoutEOF.set(true)
                return
            }
            let lines = stdoutTail.withLock { LineSplitter.take(from: &$0, appending: chunk) }
            for line in lines { consume(line) }
        }

        // stderr is drained on its own dispatch source: a chatty stderr must never block stdout.
        let sawStderrEOF = LockBox(false)
        let stderrBuffer = LockBox(Data())
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sawStderrEOF.set(true)
                return
            }
            stderrBuffer.withLock { $0.append(chunk) }
        }

        let waiter = ProcessExitWaiter()
        waiter.attach(to: process)
        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw ClaudeRunError.launchFailed(String(describing: error))
        }
        // Register and re-check atomically: a cancel that raced with the launch still stops the child.
        let cancelPending = registry.withLock { registry -> Bool in
            registry.active[runID] = process
            return registry.cancelRequested.contains(runID)
        }
        if cancelPending { stop(process, cancelling: runID) }

        // Race the child against the timeout. Never wait for stdout EOF: a grandchild of the
        // child can keep the write end open long after the child itself is gone.
        let exitStatus = await withTaskGroup(of: Int32?.self, returning: Int32?.self) { group in
            group.addTask { await waiter.wait() }
            group.addTask {
                try? await Task.sleep(for: .seconds(spec.timeout))
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil {
                self.stop(process)  // escalates to SIGKILL so the other child can finish
                _ = await group.next()
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return first
        }

        // Give the handlers a moment to deliver buffered bytes, capped so a lingering
        // grandchild cannot stall us. Both pipes: the two sources fire independently, and stderr
        // carries the failure reason (`processFailed`).
        let drainDeadline = Date().addingTimeInterval(1)
        while !(sawStdoutEOF.current && sawStderrEOF.current), Date() < drainDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        if let leftover = stdoutTail.withLock({ LineSplitter.flush(&$0) }) { consume(leftover) }
        let cancelledByUs = registry.withLock { $0.cancelSignalled.contains(runID) }
        try? stdoutHandle.close()
        try? stderrHandle.close()

        // Outcome precedence, top to bottom.
        // 1. We signalled a cancel: whatever the exit looks like (claude exits 0 on SIGINT), it was cancelled.
        if cancelledByUs { throw ClaudeRunError.cancelled }
        // 2. The timeout stopped it.
        guard let status = exitStatus else { throw ClaudeRunError.timedOut }
        // 3. A result line is the run's answer even with a non-zero exit (a --max-turns stop exits with an error).
        if let result = lastResult.current { return result }
        // 4. Stopped from outside: `claude` exits 130/143 when it handles SIGINT/SIGTERM itself; a child killed
        //    by the signal reports the SIGNAL NUMBER in terminationStatus (2, 15), not 128+signal.
        if status == 130 || status == 143 { throw ClaudeRunError.cancelled }
        if process.terminationReason == .uncaughtSignal, status == SIGINT || status == SIGTERM {
            throw ClaudeRunError.cancelled
        }
        // 5. Anything else.
        if status != 0 {
            throw ClaudeRunError.processFailed(
                exitCode: status,
                stderr: String(decoding: stderrBuffer.current, as: UTF8.self))
        }
        throw ClaudeRunError.noResult
    }

    public func cancel(runID: UUID) async {
        let process = registry.withLock { registry -> Process? in
            registry.cancelRequested.insert(runID)
            return registry.active[runID]
        }
        if let process { stop(process, cancelling: runID) }
    }

    public func version() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeRunError.notFound
        }
        let output = try await ProcessCapture.run(
            executableURL: executableURL, arguments: ["--version"], environment: claudeEnvironment())
        guard output.exitCode == 0 else {
            throw ClaudeRunError.processFailed(exitCode: output.exitCode, stderr: output.stderr)
        }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The environment of every invocation (`run` and `version`): HOME, a PATH that starts with the CLI's own
    /// directory (an npm-global install is a `#!/usr/bin/env node` script), no API key, then the overrides.
    func claudeEnvironment() -> [String: String] {
        var environment = AgentArguments.environment(
            agent: agent, base: ProcessInfo.processInfo.environment,
            executableDirectory: executableURL.deletingLastPathComponent().path)
        environment.merge(environmentOverrides) { _, override in override }
        return environment
    }

    /// SIGINT for a graceful stop (Claude saves the turn), SIGKILL after `killGrace`.
    /// A cancel marks its run BEFORE the signal goes out, so any termination that follows reads as
    /// `.cancelled`; the timeout's stop passes no run id.
    private func stop(_ process: Process, cancelling runID: UUID? = nil) {
        guard process.isRunning else { return }
        if let runID { registry.withLock { _ = $0.cancelSignalled.insert(runID) } }
        process.interrupt()
        let pid = process.processIdentifier
        let grace = killGrace
        Task.detached {
            try? await Task.sleep(for: grace)
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
    }
}
