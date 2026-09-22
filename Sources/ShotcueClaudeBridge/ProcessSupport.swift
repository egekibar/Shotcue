import Foundation

/// Bridges `Process.terminationHandler` to async/await, resuming exactly once.
///
/// `attach(to:)` MUST run before `Process.run()`: a handler installed after the child has already
/// exited is never called, and the `await` below would hang forever (verified in the spike).
final class ProcessExitWaiter: @unchecked Sendable {
    private struct State {
        var status: Int32?
        var continuation: CheckedContinuation<Int32, Never>?
    }

    private let state = LockBox(State())

    func attach(to process: Process) {
        process.terminationHandler = { [state] finished in
            let status = finished.terminationStatus
            let waiting: CheckedContinuation<Int32, Never>? = state.withLock { current in
                guard current.status == nil else { return nil }
                current.status = status
                let pending = current.continuation
                current.continuation = nil
                return pending
            }
            waiting?.resume(returning: status)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let ready: Int32? = state.withLock { current in
                if let status = current.status { return status }
                current.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Splits raw pipe chunks into complete lines, keeping the unterminated tail in `buffer`.
enum LineSplitter {
    static func take(from buffer: inout Data, appending chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines
    }

    static func flush(_ buffer: inout Data) -> String? {
        guard !buffer.isEmpty else { return nil }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

struct ProcessOutput: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Runs a short-lived command and captures its output without blocking a cooperative thread.
enum ProcessCapture {
    static func run(
        executableURL: URL, arguments: [String], currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let out = LockBox(Data())
        let err = LockBox(Data())
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            out.withLock { $0.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            err.withLock { $0.append(chunk) }
        }

        let waiter = ProcessExitWaiter()
        waiter.attach(to: process)
        try process.run()
        let status = await waiter.wait()
        // Let the readability handlers deliver what is already in the pipes.
        try? await Task.sleep(for: .milliseconds(30))
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        out.withLock { $0.append((try? outPipe.fileHandleForReading.readToEnd()) ?? Data()) }
        err.withLock { $0.append((try? errPipe.fileHandleForReading.readToEnd()) ?? Data()) }
        return ProcessOutput(
            exitCode: status,
            stdout: String(decoding: out.current, as: UTF8.self),
            stderr: String(decoding: err.current, as: UTF8.self))
    }
}
