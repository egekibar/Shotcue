import Foundation
import ShotcueCore
import Testing

@testable import ShotcueCapture

@Suite("SystemPermissionService")
struct SystemPermissionServiceTests {
    @Test func settingsURLsMatchSpec() {
        #expect(
            SystemPermissionService.settingsURL(for: .screenRecording).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(
            SystemPermissionService.settingsURL(for: .microphone).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(
            SystemPermissionService.settingsURL(for: .notifications).absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    /// Reading state must never prompt and never trap. In `swift test` there is no bundle
    /// identifier, which is exactly the case UNUserNotificationCenter cannot survive.
    @Test func everyKindReportsAStateWithoutPrompting() async {
        let service = SystemPermissionService()
        for kind in PermissionKind.allCases {
            let state = await service.state(of: kind)
            #expect([PermissionState.notDetermined, .granted, .denied].contains(state))
        }
    }
}
