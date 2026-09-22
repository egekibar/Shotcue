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

/// Runs `claude -p` in the project directory and streams its stream-json output (spec §6.4).
/// Writes nothing to disk: log persistence belongs to `RunCoordinator`.
public final class ProcessClaudeRunner: ClaudeRunner, @unchecked Sendable {
    public let executableURL: URL
    public let environmentOverrides: [String: String]
    /// How long a SIGINT gets before SIGKILL. 10 s in production; tests shorten it.
    let killGrace: Duration

    private let active = LockBox<[UUID: Process]>([:])
    private let cancelRequested = LockBox<Set<UUID>>([])

    public convenience init(executableURL: URL, environmentOverrides: [String: String] = [:]) {
        self.init(
            executableURL: executableURL, environmentOverrides: environmentOverrides,
            killGrace: .seconds(10))
    }

    init(executableURL: URL, environmentOverrides: [String: String], killGrace: Duration) {
        self.executableURL = executableURL
        self.environmentOverrides = environmentOverrides
        self.killGrace = killGrace
    }

    public func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeRunError.notFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ClaudeArguments.build(spec: spec)
        process.currentDirectoryURL = URL(fileURLWithPath: spec.projectPath, isDirectory: true)
        var environment = ClaudeArguments.environment(
            base: ProcessInfo.processInfo.environment,
            claudeDirectory: executableURL.deletingLastPathComponent().path)
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Detach stdin: an unattended run must never inherit a terminal.
        process.standardInput = FileHandle.nullDevice

        let lastResult = LockBox<ClaudeRunResult?>(nil)
        let consume: @Sendable (String) -> Void = { line in
            guard let event = StreamJSONParser.parse(line: line) else { return }
            if case .result(let result) = event { lastResult.set(result) }
            onEvent(event)
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
        active.withLock { $0[spec.runID] = process }

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
        active.withLock { $0[spec.runID] = nil }
        let wasCancelled = cancelRequested.withLock { $0.remove(spec.runID) != nil }
        try? stdoutHandle.close()
        try? stderrHandle.close()

        guard let status = exitStatus else { throw ClaudeRunError.timedOut }
        // A signal-killed child reports the SIGNAL NUMBER in terminationStatus (2 for SIGINT),
        // not 128+signal; `claude` itself exits 130/143 when it handles the signal.
        if status == 130 || status == 143 { throw ClaudeRunError.cancelled }
        if wasCancelled, process.terminationReason == .uncaughtSignal { throw ClaudeRunError.cancelled }
        if status != 0 {
            throw ClaudeRunError.processFailed(
                exitCode: status,
                stderr: String(decoding: stderrBuffer.current, as: UTF8.self))
        }
        guard let result = lastResult.current else { throw ClaudeRunError.noResult }
        return result
    }

    public func cancel(runID: UUID) async {
        cancelRequested.withLock { _ = $0.insert(runID) }
        guard let process = active.current[runID] else { return }
        stop(process)
    }

    public func version() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeRunError.notFound
        }
        let output = try await ProcessCapture.run(executableURL: executableURL, arguments: ["--version"])
        guard output.exitCode == 0 else {
            throw ClaudeRunError.processFailed(exitCode: output.exitCode, stderr: output.stderr)
        }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SIGINT for a graceful stop (Claude saves the turn), SIGKILL after `killGrace`.
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        let pid = process.processIdentifier
        let grace = killGrace
        Task.detached {
            try? await Task.sleep(for: grace)
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
    }
}
