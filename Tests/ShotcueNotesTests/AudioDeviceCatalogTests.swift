import Foundation
import Testing

@testable import ShotcueNotes

@Suite("AudioDeviceCatalog")
struct AudioDeviceCatalogTests {
    @Test func listingInputDevicesDoesNotCrash() {
        let devices = AudioDeviceCatalog.inputDevices()
        #expect(devices.count >= 0)
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
        }
    }

    @Test func unknownUIDTranslatesToNil() {
        #expect(AudioDeviceCatalog.deviceID(forUID: "shotcue-no-such-device") == nil)
    }

    @Test func listedDevicesTranslateToDeviceIDs() {
        for device in AudioDeviceCatalog.inputDevices() {
            #expect(AudioDeviceCatalog.deviceID(forUID: device.uid) != nil)
        }
    }
}
