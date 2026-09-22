import AVFoundation
import CoreAudio
import Foundation
import ShotcueCore

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

    private let levelStream: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation
    public nonisolated var levels: AsyncStream<Float> { levelStream }

    public init(inputDeviceUID: String? = nil) {
        self.inputDeviceUID = inputDeviceUID
        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        levelStream = stream
        levelContinuation = continuation
    }

    /// A removed or switching device reports 0 Hz / 0 channels; installing a tap with that format crashes.
    public static func isUsable(format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    public func start(writingTo url: URL) async throws {
        guard writer == nil else { throw Failure.alreadyRecording }
        destination = url
        try applyInputDevice()
        try installTapAndStart(creatingWriterAt: url)
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
        levelContinuation.yield(0)
        return RecordingInfo(fileURL: destination, duration: finished.duration)
    }

    // MARK: - Engine plumbing

    /// Must run before `engine.start()`; touching `inputNode` first makes the I/O unit exist.
    /// `AVAudioEngine` uses ONE HAL device for input and output, so changing the input also
    /// moves the output (research 03 §1) — acceptable for a note recorder.
    private func applyInputDevice() throws {
        guard let inputDeviceUID, let deviceID = AudioDeviceCatalog.deviceID(forUID: inputDeviceUID) else { return }
        let input = engine.inputNode
        guard let unit = input.audioUnit else { return }
        var value = deviceID
        _ = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &value,
            UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func installTapAndStart(creatingWriterAt url: URL) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard Self.isUsable(format: format) else {
            throw Failure.unusableInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        let writer = try self.writer ?? AACWriter(url: url, inputFormat: format)
        let continuation = levelContinuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Runs on a realtime audio thread, not the main actor: no allocation-heavy work here.
            // One tap, three jobs (archive + meter) — a bus accepts only one tap.
            continuation.yield(LevelMeter.rms(buffer))
            try? writer.write(buffer)
        }
        self.writer = writer
        engine.prepare()
        try engine.start()
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
    /// recording stopped rather than crashing (the `isUsable` guard throws and we swallow it).
    private func recoverFromConfigurationChange() {
        guard let destination, writer != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        try? applyInputDevice()
        try? installTapAndStart(creatingWriterAt: destination)
    }
}
