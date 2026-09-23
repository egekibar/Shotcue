import AVFoundation
import CoreAudio
import Foundation

/// Input devices for the Ses settings tab. `uid` is the Core Audio UID (`AVCaptureDevice.uniqueID`).
public enum AudioDeviceCatalog {
    public static func inputDevices() -> [(uid: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { (uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Translates a Core Audio UID to an `AudioDeviceID`; nil when the device is gone.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID)
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }
}
