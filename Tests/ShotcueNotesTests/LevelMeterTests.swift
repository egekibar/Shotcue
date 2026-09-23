import AVFoundation
import Foundation
import Testing

@testable import ShotcueNotes

@Suite("LevelMeter")
struct LevelMeterTests {
    @Test func silenceReadsZero() {
        #expect(LevelMeter.rms(AudioFixtures.silence()) == 0)
    }

    @Test func fullScaleSineReadsAboutSevenOhSeven() {
        let level = LevelMeter.rms(AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.1))
        #expect(abs(level - 0.7071) < 0.01)
    }

    @Test func levelIsClampedToUnitRange() {
        let loud = AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.05, amplitude: 8)
        let level = LevelMeter.rms(loud)
        #expect(level == 1)
    }

    @Test func emptyBufferReadsZero() {
        let buffer = AudioFixtures.silence()
        buffer.frameLength = 0
        #expect(LevelMeter.rms(buffer) == 0)
    }
}
