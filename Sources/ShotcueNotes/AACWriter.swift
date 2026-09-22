import AVFoundation
import Foundation

/// Writes AAC-LC `.m4a` (48 kHz mono, 64 kbps) from arbitrary input buffers (spec §5.2).
/// `AVAudioConverter` absorbs the microphone's sample-rate/channel mismatch.
///
/// The methods are non-mutating on purpose: the recorder's tap block runs on a realtime audio
/// thread and shares one writer with the actor that calls `finish()`, so the state lives in a
/// locked reference box instead of in the struct.
public struct AACWriter: Sendable {
    /// Archive format from spec §5.2 / research 03 §1 ("Arşiv: AAC-LC .m4a, mono, 48 kHz, 64 kbps").
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 1
    public static let bitRate = 64_000

    public static func settings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// 48 kHz mono float32 — what the converter targets and `AVAudioFile.write(from:)` accepts.
    public static func targetFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channelCount, interleaved: false)
    }

    public enum Failure: Error, Equatable {
        case unsupportedTargetFormat
        case converterUnavailable
        case bufferAllocationFailed
        case conversionFailed
    }

    private let storage: Storage

    public init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let target = Self.targetFormat() else { throw Failure.unsupportedTargetFormat }
        let file = try AVAudioFile(forWriting: url, settings: Self.settings())
        let converter = try Self.converter(from: inputFormat, to: target)
        storage = Storage(file: file, target: target, inputFormat: inputFormat, converter: converter)
    }

    /// nil when `inputFormat` already is the target format (buffers go straight to the file).
    private static func converter(from inputFormat: AVAudioFormat, to target: AVAudioFormat) throws
        -> AVAudioConverter?
    {
        guard
            inputFormat.sampleRate != target.sampleRate || inputFormat.channelCount != target.channelCount
                || inputFormat.commonFormat != target.commonFormat
        else { return nil }
        guard let made = AVAudioConverter(from: inputFormat, to: target) else {
            throw Failure.converterUnavailable
        }
        return made
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        try storage.write(buffer)
    }

    /// Flushes the converter tail and closes the file — an `.m4a` stays unreadable
    /// (`kAudioFileInvalidFileError`, OSStatus 1685348671 = `'dta?'`) until the `AVAudioFile` is released.
    public func finish() -> (duration: TimeInterval, frames: AVAudioFramePosition) {
        storage.finish()
    }

    // MARK: - Locked state

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private let target: AVAudioFormat
        private var inputFormat: AVAudioFormat
        private var converter: AVAudioConverter?
        private var file: AVAudioFile?
        private var framesWritten: AVAudioFramePosition = 0

        init(file: AVAudioFile, target: AVAudioFormat, inputFormat: AVAudioFormat, converter: AVAudioConverter?) {
            self.file = file
            self.target = target
            self.inputFormat = inputFormat
            self.converter = converter
        }

        func write(_ buffer: AVAudioPCMBuffer) throws {
            lock.lock()
            defer { lock.unlock() }
            guard let file else { return }
            if buffer.format != inputFormat { try switchInput(to: buffer.format, file: file) }
            guard let converter else {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                return
            }
            try pump(converter: converter, file: file, source: buffer, endOfStream: false)
        }

        func finish() -> (duration: TimeInterval, frames: AVAudioFramePosition) {
            lock.lock()
            defer { lock.unlock() }
            if let converter, let file {
                try? pump(converter: converter, file: file, source: nil, endOfStream: true)
            }
            file = nil
            return (TimeInterval(framesWritten) / target.sampleRate, framesWritten)
        }

        /// A device switch mid-recording (e.g. AirPods at 16 kHz) makes `EngineAudioRecorder` reinstall its tap
        /// with a new format while keeping this writer. Without this, a pass-through writer stores the new
        /// buffers at the wrong rate and a converting one rejects them (OSStatus -1), silently losing audio.
        /// The old converter's tail is drained first, then the new format is converted into the same file.
        private func switchInput(to format: AVAudioFormat, file: AVAudioFile) throws {
            let next = try AACWriter.converter(from: format, to: target)
            if let converter {
                try pump(converter: converter, file: file, source: nil, endOfStream: true)
            }
            converter = next
            inputFormat = format
        }

        /// Block-based conversion: `.noDataNow` keeps the converter alive between tap buffers,
        /// `.endOfStream` drains the ~70 ms of input the resampler still holds. A drain repeats while the
        /// converter reports `.haveData`: upsampling a large low-rate buffer (e.g. 16 kHz) can leave more
        /// than one output buffer inside it, and a single pass would cut that tail off.
        private func pump(
            converter: AVAudioConverter, file: AVAudioFile,
            source: AVAudioPCMBuffer?, endOfStream: Bool
        ) throws {
            let sourceFrames = source?.frameLength ?? 4096
            let sourceRate = source?.format.sampleRate ?? target.sampleRate
            let capacity = AVAudioFrameCount(Double(sourceFrames) * target.sampleRate / sourceRate) + 4096
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw Failure.bufferAllocationFailed
            }
            var supplied = source == nil
            while true {
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return source
                }
                if let conversionError { throw conversionError }
                if status == .error { throw Failure.conversionFailed }
                guard output.frameLength > 0 else { return }
                try file.write(from: output)
                framesWritten += AVAudioFramePosition(output.frameLength)
                guard endOfStream, status == .haveData else { return }
            }
        }
    }
}
