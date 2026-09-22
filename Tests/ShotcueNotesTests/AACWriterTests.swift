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
}
