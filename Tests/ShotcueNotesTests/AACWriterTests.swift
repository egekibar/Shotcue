import AVFoundation
import Foundation
import Testing

@testable import ShotcueNotes

@Suite("AACWriter")
struct AACWriterTests {
    @Test func settingsMatchTheArchiveFormat() {
        let settings = AACWriter.settings()
        #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(settings[AVSampleRateKey] as? Double == 48_000)
        #expect(settings[AVNumberOfChannelsKey] as? AVAudioChannelCount == 1)
        #expect(settings[AVEncoderBitRateKey] as? Int == 64_000)
    }

    @Test func convertsStereo44kToMono48kAAC() throws {
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let input = AudioFixtures.sine(sampleRate: 44_100, channels: 2, seconds: 1.0)
        let writer = try AACWriter(url: url, inputFormat: input.format)
        try writer.write(input)
        let finished = writer.finish()

        #expect(abs(finished.duration - 1.0) < 0.05)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.fileFormat.sampleRate == 48_000)
        #expect(readBack.fileFormat.channelCount == 1)
        #expect(abs(Double(readBack.length) / readBack.fileFormat.sampleRate - 1.0) < 0.05)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func passesThroughWhenInputIsAlready48kMono() throws {
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let input = AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.5)
        let writer = try AACWriter(url: url, inputFormat: input.format)
        try writer.write(input)
        let finished = writer.finish()
        #expect(finished.frames == 24_000)
        #expect(abs(finished.duration - 0.5) < 0.01)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func manyTapSizedBuffersAccumulate() throws {
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let chunk = AudioFixtures.sine(sampleRate: 44_100, channels: 1, seconds: 4096.0 / 44_100.0)
        let writer = try AACWriter(url: url, inputFormat: chunk.format)
        for _ in 0..<10 { try writer.write(chunk) }
        let finished = writer.finish()
        let expected = 10 * 4096.0 / 44_100.0
        #expect(abs(finished.duration - expected) < 0.05)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func keepsWritingAfterTheInputFormatChanges() throws {
        // EngineAudioRecorder keeps one writer across an AVAudioEngineConfigurationChange, so a device
        // switch mid-recording (e.g. AirPods: 16 kHz mono) feeds buffers in a new format. Covers both
        // a pass-through writer (48 kHz mono) and a converting one (44.1 kHz stereo).
        let initialFormats: [(sampleRate: Double, channels: AVAudioChannelCount)] = [(48_000, 1), (44_100, 2)]
        for initial in initialFormats {
            let url = AudioFixtures.temporaryURL(extension: "m4a")
            let before = AudioFixtures.sine(sampleRate: initial.sampleRate, channels: initial.channels, seconds: 0.5)
            let headsetChunk = AudioFixtures.sine(sampleRate: 16_000, channels: 1, seconds: 0.1)
            let writer = try AACWriter(url: url, inputFormat: before.format)
            try writer.write(before)
            for _ in 0..<5 { try writer.write(headsetChunk) }
            let finished = writer.finish()

            #expect(abs(finished.duration - 1.0) < 0.05)
            let readBack = try AVAudioFile(forReading: url)
            #expect(abs(Double(readBack.length) / readBack.fileFormat.sampleRate - 1.0) < 0.05)
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func drainsTheWholeResamplerTailOnFinish() throws {
        // Upsampling a large 16 kHz buffer leaves more than one output buffer (8192 frames) of audio
        // inside the converter; `finish()` must keep draining until the converter is empty.
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let input = AudioFixtures.sine(sampleRate: 16_000, channels: 1, seconds: 0.5)
        let writer = try AACWriter(url: url, inputFormat: input.format)
        try writer.write(input)
        let finished = writer.finish()
        #expect(abs(finished.duration - 0.5) < 0.01)
        try? FileManager.default.removeItem(at: url)
    }
}
