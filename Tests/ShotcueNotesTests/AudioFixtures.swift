import AVFoundation
import Foundation
import Testing

/// Synthetic audio so the tests never need a microphone.
enum AudioFixtures {
    static func sine(
        sampleRate: Double, channels: AVAudioChannelCount, seconds: Double,
        frequency: Double = 440, amplitude: Float = 1.0
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            }
        }
        return buffer
    }

    static func silence(
        sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
        seconds: Double = 0.1
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { data[channel][frame] = 0 }
        }
        return buffer
    }

    static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-notes-\(UUID().uuidString).\(ext)")
    }
}
