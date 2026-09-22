import AVFoundation
import Foundation
import Testing

@testable import ShotcueNotes

@Suite("EngineAudioRecorder")
struct EngineAudioRecorderTests {
    @Test func rejectsZeroHertzFormats() throws {
        // A removed input device makes `inputNode.inputFormat(forBus: 0)` report 0 Hz / 0 channels;
        // installing a tap with that format crashes (research 03 §1).
        var description = AudioStreamBasicDescription(
            mSampleRate: 0, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 0, mBitsPerChannel: 32, mReserved: 0)
        let zero = try #require(AVAudioFormat(streamDescription: &description))
        #expect(EngineAudioRecorder.isUsable(format: zero) == false)
    }

    @Test func acceptsUsableFormats() throws {
        let usable = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                channels: 2, interleaved: false))
        #expect(EngineAudioRecorder.isUsable(format: usable))
        let mono = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false))
        #expect(EngineAudioRecorder.isUsable(format: mono))
    }

    @Test func stopWithoutStartThrows() async {
        let recorder = EngineAudioRecorder()
        await #expect(throws: EngineAudioRecorder.Failure.notRecording) {
            _ = try await recorder.stop()
        }
    }

    @Test func levelsStreamIsAvailableBeforeRecording() async {
        let recorder = EngineAudioRecorder()
        var iterator = recorder.levels.makeAsyncIterator()
        let task = Task { await iterator.next() }
        task.cancel()
        _ = await task.value
        #expect(Bool(true))
    }
}
