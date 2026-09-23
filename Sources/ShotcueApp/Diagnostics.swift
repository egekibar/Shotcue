import AppKit
import Foundation
import ShotcueCore
import ShotcueNotes
import ShotcueUI

struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

/// Read-only host diagnostics (spec §12; replaces Plan 00 Task 11's temporary `SpikeRunner`).
///
/// Nothing here mutates state: `claude --version` and `claude auth status` only read. The report is
/// written to the per-user temporary directory with mode 0600, and only `loggedIn` / `authMethod` /
/// `subscriptionType` are taken from the auth JSON, so the account e-mail and organisation never reach
/// a file.
struct Diagnostics {
    let claude: ClaudeExecutableLocator
    let permissions: any PermissionService
    let fileStore: FileStore
    let settings: SettingsStore

    /// `$TMPDIR` is per user (`/var/folders/…/T/`, mode 0700), unlike the world-readable `/tmp`.
    static let reportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("shotcue-diagnostics.txt")

    /// Shown in Settings > Claude (spec §6.4: the tested version is 2.1.278). Waits for the locator's
    /// background search when it is still running (Settings shows "aranıyor…" meanwhile).
    func claudeVersion() async -> (text: String, found: Bool) {
        guard let claudeExecutable = await claude.executable() else { return ("bulunamadı", false) }
        let result = await Self.run(claudeExecutable, ["--version"])
        guard result.status == 0, !result.timedOut else {
            return ("okunamadı (exit \(result.status))", false)
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? "okunamadı" : text, !text.isEmpty)
    }

    func writeReport(
        transcriberState: TranscriberModelState, loginItemStatus: String, hotKeyLabel: String
    ) async throws -> URL {
        let text = await report(
            transcriberState: transcriberState,
            loginItemStatus: loginItemStatus,
            hotKeyLabel: hotKeyLabel)
        try Self.writePrivately(text, to: Self.reportURL)
        return Self.reportURL
    }

    /// Replaces the file with one created owner-read/write only (0600).
    static func writePrivately(_ text: String, to url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        let created = manager.createFile(
            atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        guard created else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    private func report(
        transcriberState: TranscriberModelState, loginItemStatus: String, hotKeyLabel: String
    ) async -> String {
        let version = await claudeVersion()
        let auth = await authSummary()
        let signature = await signatureSummary()
        let screenRecording = await permissions.state(of: .screenRecording)
        let microphone = await permissions.state(of: .microphone)
        let notifications = await permissions.state(of: .notifications)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var lines: [String] = []
        lines.append("Shotcue tanılama — \(formatter.string(from: Date()))")
        lines.append("app: \(Bundle.main.bundleURL.path)")
        lines.append(
            "sürüm: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
                + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        lines.append("imza: \(signature)")
        lines.append("claude yolu: \(await claude.executable()?.path ?? "bulunamadı")")
        lines.append("claude ayarı: \(settings.claudePath ?? "(otomatik)")")
        lines.append("claude sürümü: \(version.text)")
        lines.append("claude auth: \(auth)")
        lines.append(
            "izinler: ekran kaydı=\(screenRecording.rawValue)"
                + " mikrofon=\(microphone.rawValue) bildirimler=\(notifications.rawValue)")
        lines.append("girişte başlat: \(loginItemStatus)")
        lines.append("kısayol: \(hotKeyLabel)")
        lines.append("depolama kökü: \(fileStore.rootURL.path)")
        lines.append("veritabanı: \(Self.fileSizeText(at: fileStore.databaseURL))")
        lines.append("boş disk alanı: \(Self.freeSpaceText(at: fileStore.rootURL))")
        lines.append("transkripsiyon modeli: \(Self.describe(transcriberState)) (\(settings.sttModel))")
        lines.append("Foundation Models: \(FoundationModelsStatus.current.localizedDescription)")
        return lines.joined(separator: "\n") + "\n"
    }

    private func authSummary() async -> String {
        guard let claudeExecutable = await claude.executable() else { return "claude yok" }
        let result = await Self.run(claudeExecutable, ["auth", "status"])
        guard result.status == 0, !result.timedOut, let summary = Self.authSummary(json: result.stdout) else {
            return "okunamadı (exit \(result.status))"
        }
        return summary
    }

    /// Whitelist, not blacklist: only these three keys are ever copied out of `claude auth status`, so a
    /// field added by a future CLI version cannot leak into the report either.
    static func authSummary(json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        let loggedIn = (object["loggedIn"] as? Bool).map { String($0) } ?? "?"
        let method = object["authMethod"] as? String ?? "?"
        let subscription = object["subscriptionType"] as? String ?? "?"
        return "loggedIn=\(loggedIn) authMethod=\(method) subscriptionType=\(subscription)"
    }

    /// `codesign -dv` writes to stderr; the two interesting lines are `Authority=` and `flags=`.
    /// Spec §10.2: `Authority=Shotcue Dev` is what keeps TCC grants across rebuilds.
    private func signatureSummary() async -> String {
        let result = await Self.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["-dv", Bundle.main.bundleURL.path])
        let lines = (result.stderr + result.stdout)
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("Authority=") || $0.contains("flags=") }
        return lines.isEmpty ? "imza okunamadı" : lines.joined(separator: "; ")
    }

    private static func describe(_ state: TranscriberModelState) -> String {
        switch state {
        case .notDownloaded: return "indirilmedi"
        case .downloading(let progress): return "indiriliyor (%\(Int(progress * 100)))"
        case .ready: return "hazır"
        case .failed(let message): return "hata: \(message)"
        }
    }

    private static func fileSizeText(at url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize
        else { return "yok" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private static func freeSpaceText(at url: URL) -> String {
        guard
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return "bilinmiyor" }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

    // MARK: - Child processes

    /// Runs a short-lived tool on a GCD thread (never blocking the main actor or the cooperative pool).
    /// `HOME`/`PATH` are set explicitly and `ANTHROPIC_API_KEY` is removed so `claude` reports the
    /// subscription session, not an API key (spec §6.4). After `timeout` the child gets SIGTERM, then
    /// SIGKILL two seconds later.
    nonisolated static func run(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval = 20
    ) async -> ProcessOutput {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutput, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    nonisolated private static func runBlocking(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval
    ) -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        // The tool's own directory first: an npm-global `claude` is a `#!/usr/bin/env node` script.
        environment["PATH"] =
            "\(executable.deletingLastPathComponent().path):\(NSHomeDirectory())/.local/bin"
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // R4: both pipes are drained while the child runs. Reading only after it exited deadlocks as
        // soon as one pipe's 64 KB buffer is full — the child blocks on `write` and never exits.
        let stdout = PipeDrain(outPipe)
        let stderr = PipeDrain(errPipe)
        do {
            try process.run()
        } catch {
            _ = stdout.finish(by: .now())
            _ = stderr.finish(by: .now())
            return ProcessOutput(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // End-of-file normally follows the exit at once; a grandchild that inherited a pipe could keep it
        // open, so the wait is bounded.
        let grace = DispatchTime.now() + 1
        return ProcessOutput(
            status: process.terminationStatus, stdout: stdout.finish(by: grace),
            stderr: stderr.finish(by: grace), timedOut: timedOut)
    }
}

/// Collects everything a child writes to one pipe while it runs, on the pipe's own dispatch source.
/// `nonisolated`: used from the GCD thread that runs the child, never from the main actor.
nonisolated private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let endOfFile = DispatchSemaphore(value: 0)
    private let handle: FileHandle

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                endOfFile.signal()
            } else {
                lock.withLock { buffer.append(chunk) }
            }
        }
    }

    /// Waits for end-of-file until `deadline`, stops reading, and returns what arrived as UTF-8 text.
    func finish(by deadline: DispatchTime) -> String {
        if endOfFile.wait(timeout: deadline) == .timedOut {
            handle.readabilityHandler = nil
        }
        return lock.withLock { String(decoding: buffer, as: UTF8.self) }
    }
}
