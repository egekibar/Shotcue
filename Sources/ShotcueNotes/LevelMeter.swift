import AVFoundation
import Accelerate
import Foundation

/// Root-mean-square level of a PCM buffer, normalised to 0…1 for the recording level bar.
/// A full-scale sine reads ~0.707; digital silence reads 0.
public enum LevelMeter {
    public static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = vDSP_Length(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channelCount {
            var value: Float = 0
            vDSP_rmsqv(channels[channel], 1, &value, frames)
            sum += value
        }
        let mean = sum / Float(max(1, channelCount))
        guard mean.isFinite else { return 0 }
        return min(1, max(0, mean))
    }
}
