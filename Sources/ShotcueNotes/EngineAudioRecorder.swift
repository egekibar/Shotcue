import AVFoundation
import CoreAudio
import Foundation
import ShotcueCore
import os

/// Recording problems that used to be swallowed: an unusable input device, tap write errors, failed recoveries.
private let audioLog = Logger(subsystem: "com.shotcue.app", category: "audio")

/// `AVAudioEngine` microphone recorder with a single tap on bus 0 (research 03 §1:
/// "Tek bus'a yalnızca tek tap kurulabilir"). The tap both archives AAC and meters RMS.
public actor EngineAudioRecorder: AudioRecorder {
    public enum Failure: Error, Equatable {
        case unusableInputFormat(sampleRate: Double, channels: UInt32)
        case notRecording
        case alreadyRecording
    }

    private let engine = AVAudioEngine()
    private let inputDeviceUID: String?
    private var writer: AACWriter?
    private var destination: URL?
    private var configurationObserver: NSObjectProtocol?
    /// First tap-write or recovery error of the current recording; `stop()` logs it.
    private var issues = RecordingIssues()

    /// Fans the tap's levels out to every `levels` subscriber.
    nonisolated let levelBroadcaster = LevelBroadcaster()
    /// A fresh stream per access, so a consumer that goes away never ends the meter for the others.
    public nonisolated var levels: AsyncStream<Float> { levelBroadcaster.stream() }

    public init(inputDeviceUID: String? = nil) {
        self.inputDeviceUID = inputDeviceUID
    }

    /// A removed or switching device reports 0 Hz / 0 channels; installing a tap with that format crashes.
    public static func isUsable(format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    public func start(writingTo url: URL) async throws {
        guard writer == nil else { throw Failure.alreadyRecording }
        destination = url
        issues = RecordingIssues()
        let fileExisted = FileManager.default.fileExists(atPath: url.path)
        do {
            applyInputDevice()
            try installTapAndStart(creatingWriterAt: url)
        } catch {
            abandonFailedStart(at: url, removingFile: !fileExisted)
            throw error
        }
        observeConfigurationChanges()
    }

    public func stop() async throws -> RecordingInfo {
        guard let writer, let destination else { throw Failure.notRecording }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let finished = writer.finish()
        self.writer = nil
        self.destination = nil
        levelBroadcaster.yield(0)
        // A write or recovery error ended the audio early: the file keeps what was written before it.
        if let error = issues.firstError {
            audioLog.error(
                "Recording \(destination.lastPathComponent, privacy: .private) kept \(finished.duration, privacy: .public) s after an error: \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
        return RecordingInfo(fileURL: destination, duration: finished.duration)
    }

    // MARK: - Engine plumbing

    /// Must run before `engine.start()`; touching `inputNode` first makes the I/O unit exist.
    /// `AVAudioEngine` uses ONE HAL device for input and output, so changing the input also
    /// moves the output (research 03 §1) — acceptable for a note recorder.
    /// A device that is gone or refused is logged and the default input records instead; the returned
    /// error lets configuration-change recovery keep it for `stop()`.
    @discardableResult
    private func applyInputDevice() -> InputDeviceError? {
        guard let inputDeviceUID, let problem = selectInputDevice(uid: inputDeviceUID) else { return nil }
        audioLog.warning(
            "Input device not used (\(String(describing: problem), privacy: .private)); recording with the default input"
        )
        return problem
    }

    private func selectInputDevice(uid: String) -> InputDeviceError? {
        guard let deviceID = AudioDeviceCatalog.deviceID(forUID: uid) else { return .notFound(uid: uid) }
        guard let unit = engine.inputNode.audioUnit else { return .noAudioUnit(uid: uid) }
        var value = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &value,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr ? nil : .notApplied(uid: uid, status: status)
    }

    private func installTapAndStart(creatingWriterAt url: URL) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard Self.isUsable(format: format) else {
            throw Failure.unusableInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        let writer = try self.writer ?? AACWriter(url: url, inputFormat: format)
        let sink = TapSink(writer: writer, issues: issues, levels: levelBroadcaster)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Runs on a realtime audio thread, not the main actor: no allocation-heavy work here.
            // One tap, three jobs (archive + meter) — a bus accepts only one tap.
            sink.consume(buffer)
        }
        self.writer = writer
        engine.prepare()
        try engine.start()
    }

    /// Undoes a `start` whose engine did not come up: otherwise `writer` stays set and every later `start`
    /// throws `.alreadyRecording`. The file is removed only when this `start` created it.
    private func abandonFailedStart(at url: URL, removingFile: Bool) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = writer?.finish()
        writer = nil
        destination = nil
        if removingFile { try? FileManager.default.removeItem(at: url) }
    }

    /// Recovery sequence from research 03 §1: the engine has already stopped and uninitialised itself
    /// when this fires, the notification does not say what changed, and the callback arrives on an
    /// internal dispatch queue (never deallocate the engine there) — so we hop onto the actor, drop
    /// the tap, re-read `inputFormat(forBus: 0)`, reinstall the tap with the new format and
    /// call `engine.start()` again. Forgetting the restart kills the recording silently: no crash,
    /// no error, just no more audio.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.recoverFromConfigurationChange() }
        }
    }

    /// The existing `AACWriter` is reused so the already-written frames survive the switch;
    /// only the tap and the engine are rebuilt. A device that came back at 0 Hz leaves the
    /// recording stopped rather than crashing (the `isUsable` guard throws); the error is kept
    /// for `stop()`, which still returns what was written before it.
    private func recoverFromConfigurationChange() {
        guard let destination, writer != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        if let deviceProblem = applyInputDevice() {
            issues.recordRecoveryError(deviceProblem)
        }
        do {
            try installTapAndStart(creatingWriterAt: destination)
        } catch {
            issues.recordRecoveryError(error)
            audioLog.error(
                "Recording stopped after an audio configuration change: \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
    }
}

/// Why the selected input device was not used; the recording falls back to the default input.
enum InputDeviceError: Error, Equatable {
    case notFound(uid: String)
    case noAudioUnit(uid: String)
    case notApplied(uid: String, status: OSStatus)
}

/// Hands out one `AsyncStream` per `levels` access and yields every tap level to all of them.
/// A cancelled consumer unregisters only its own stream.
final class LevelBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Float>.Continuation] = [:]

    func stream() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        lock.withLock { continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }

    func yield(_ level: Float) {
        // Copied under the lock and yielded outside it: a consumer's `onTermination` takes the lock too.
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current { continuation.yield(level) }
    }

    var subscriberCount: Int { lock.withLock { continuations.count } }

    private func remove(_ id: UUID) {
        lock.withLock { continuations[id] = nil }
    }
}

/// First problem of one recording: a tap write error (after which no more buffers are written) or a
/// configuration-change recovery error. Lock-protected because the tap thread records into it.
final class RecordingIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var first: (any Error)?
    private var writeFailed = false

    var firstError: (any Error)? { lock.withLock { first } }
    var acceptsWrites: Bool { lock.withLock { !writeFailed } }

    func recordWriteError(_ error: any Error) {
        lock.withLock {
            writeFailed = true
            if first == nil { first = error }
        }
    }

    func recordRecoveryError(_ error: any Error) {
        lock.withLock {
            if first == nil { first = error }
        }
    }
}

/// What the tap does with each buffer: meter it for every `levels` subscriber and archive it until the
/// first write error, which is kept in `issues` and logged instead of being dropped by `try?`.
struct TapSink: Sendable {
    let write: @Sendable (AVAudioPCMBuffer) throws -> Void
    let issues: RecordingIssues
    let levels: LevelBroadcaster

    init(writer: AACWriter, issues: RecordingIssues, levels: LevelBroadcaster) {
        self.init(write: { try writer.write($0) }, issues: issues, levels: levels)
    }

    /// Tests inject a failing `write`.
    init(
        write: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void, issues: RecordingIssues,
        levels: LevelBroadcaster
    ) {
        self.write = write
        self.issues = issues
        self.levels = levels
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        levels.yield(LevelMeter.rms(buffer))
        guard issues.acceptsWrites else { return }
        do {
            try write(buffer)
        } catch {
            issues.recordWriteError(error)
            audioLog.error(
                "Recording write failed, later audio is not archived: \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
    }
}
