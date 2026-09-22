import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ShotcueCore
import UserNotifications

/// TCC state plus the System Settings deep links (spec §6.1, §9; research §4).
///
/// `CGPreflightScreenCaptureAccess` never prompts. `CGRequestScreenCaptureAccess` prompts once and
/// a previously denied process is *not* re-prompted — the user has to flip the switch in
/// System Settings, which is why `openSystemSettings(for:)` exists. After a grant the app must be
/// relaunched (research §4.1); Plan 06 owns that relaunch.
///
/// The monthly re-consent dialog on macOS 26 is expected behaviour and cannot be turned off
/// (research §4.2); Settings > İzinler explains it to the user.
public struct SystemPermissionService: PermissionService {
    public init() {}

    /// Pure mapping so it is testable without opening anything.
    public static func settingsURL(for kind: PermissionKind) -> URL {
        switch kind {
        case .screenRecording:
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .microphone:
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        }
    }

    public func state(of kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            // TCC exposes no "denied" here: a denial and "never asked" both preflight as false.
            // The UI therefore always offers both "İzin ver" and the System Settings link.
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .notifications:
            // UNUserNotificationCenter.current() traps in a process without a bundle identifier,
            // and `swift test` has none (verified). Tests see .notDetermined instead of a crash.
            guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                return granted ? .granted : .denied
            } catch {
                return .denied
            }
        }
    }

    public func openSystemSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(Self.settingsURL(for: kind))
    }
}
