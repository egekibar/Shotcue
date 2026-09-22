import Foundation
import ShotcueCore

/// Region screenshot via `/usr/sbin/screencapture -i -s -x -t png <destination>` (spec §6.1).
///
/// The tool has `com.apple.private.tcc.check-allow-on-responsible-process`, so TCC is evaluated
/// against the *responsible* process: spawned from Shotcue.app the system prompt names Shotcue
/// and Shotcue's own Screen & System Audio Recording grant is what counts (research §2.2).
///
/// Result mapping (research §2.3): exit 0 → success; exit 1 with empty stderr → the user pressed
/// ESC, which is a cancel and not an error; anything else → a real failure worth showing.
public struct ScreencaptureService: CaptureService {
    public let executableURL: URL
    /// nil inherits the parent environment. Tests pass FAKE_SCREENCAPTURE_SCENARIO here.
    public let environment: [String: String]?

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.environment = environment
    }

    /// Kept pure and separate so the exact command line can be asserted without spawning anything
    /// (the fake script cannot record its argv).
    ///   -i interactive · -s mouse selection only (no window mode) · -x no shutter sound
    ///   -t png master format · last argument is the output path
    public static func arguments(for destination: URL) -> [String] {
        ["-i", "-s", "-x", "-t", "png", destination.path]
    }

    public func captureRegion(to destination: URL) async throws -> CaptureResult? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.arguments(for: destination)
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Drain stderr concurrently. Waiting for exit first would deadlock if the child ever
        // filled the 64 KB pipe buffer; reading first would block this task for the whole
        // (interactive, unbounded) selection.
        let readEnd = errorPipe.fileHandleForReading
        let stderrTask = Task.detached(priority: .utility) { () -> Data in
            ((try? readEnd.readToEnd()) ?? nil) ?? Data()
        }

        let exitCode: Int32
        do {
            exitCode = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(
                        throwing: CaptureError.launchFailed(String(describing: error)))
                }
            }
        } catch {
            stderrTask.cancel()
            throw error
        }

        let stderrText = String(decoding: await stderrTask.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if exitCode == 0 {
            guard let info = ImageInfo.read(url: destination) else {
                try? FileManager.default.removeItem(at: destination)
                throw CaptureError.unreadableImage(destination)
            }
            return CaptureResult(
                fileURL: destination, width: info.width, height: info.height, scale: info.scale)
        }

        // Cancel and failure both may have left a truncated PNG behind; never keep one.
        try? FileManager.default.removeItem(at: destination)
        if exitCode == 1, stderrText.isEmpty { return nil }
        throw CaptureError.screencaptureFailed(exitCode: exitCode, stderr: stderrText)
    }
}
