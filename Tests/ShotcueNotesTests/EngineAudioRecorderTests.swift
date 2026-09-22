import AVFoundation
import Foundation
import ShotcueTestSupport
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

    @Test func levelsReachNewSubscribersAfterOneIsCancelled() async {
        // Each `levels` access is its own stream: a consumer that goes away (the panel closing) must not end
        // the meter for the next one, and it unregisters itself.
        let recorder = EngineAudioRecorder()
        let cancelled = Task { for await _ in recorder.levels {} }
        cancelled.cancel()
        await cancelled.value

        var iterator = recorder.levels.makeAsyncIterator()
        recorder.levelBroadcaster.yield(0.5)
        let received = await iterator.next()
        #expect(received == 0.5)
        #expect(recorder.levelBroadcaster.subscriberCount == 1)
    }

    @Test func aTapWriteErrorIsKeptAndStopsFurtherWrites() async {
        // The tap used to drop write errors with `try?` and keep writing. Now the first error is kept for
        // `stop()`, nothing more is written after it, and the level bar keeps moving.
        let issues = RecordingIssues()
        let levels = LevelBroadcaster()
        var meter = levels.stream().makeAsyncIterator()
        let writes = Locked(0)
        let sink = TapSink(
            write: { _ in
                let count = writes.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 2 { throw FakeError("disk full") }
            },
            issues: issues, levels: levels)
        let buffer = AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.01)
        for _ in 0..<4 { sink.consume(buffer) }
        issues.recordRecoveryError(FakeError("device gone"))

        #expect(writes.current == 2)
        #expect(issues.acceptsWrites == false)
        #expect(issues.firstError as? FakeError == FakeError("disk full"))
        var metered = 0
        for _ in 0..<4 {
            if await meter.next() != nil { metered += 1 }
        }
        #expect(metered == 4)
    }

    @Test func aRecoveryErrorIsKeptWithoutStoppingWrites() {
        // A device that could not be re-applied after a configuration change falls back to the default input:
        // the error is kept for `stop()`, but the recording goes on.
        let issues = RecordingIssues()
        issues.recordRecoveryError(FakeError("device gone"))
        issues.recordWriteError(FakeError("disk full"))
        #expect(issues.firstError as? FakeError == FakeError("device gone"))
        #expect(issues.acceptsWrites == false)

        let fresh = RecordingIssues()
        fresh.recordRecoveryError(FakeError("device gone"))
        #expect(fresh.acceptsWrites)
    }

    @Test func theTapArchivesThroughTheWriter() throws {
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let buffer = AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.5)
        let writer = try AACWriter(url: url, inputFormat: buffer.format)
        let issues = RecordingIssues()
        let sink = TapSink(writer: writer, issues: issues, levels: LevelBroadcaster())
        sink.consume(buffer)
        sink.consume(buffer)
        #expect(writer.finish().frames == 48_000)
        #expect(issues.firstError == nil)
        try? FileManager.default.removeItem(at: url)
    }
}
