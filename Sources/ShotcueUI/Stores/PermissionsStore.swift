import Foundation
import Observation
import ShotcueCore
import SwiftUI

/// Permission states for the onboarding view and Ayarlar > İzinler (spec §6.1, §6.2, §8).
@MainActor
@Observable
public final class PermissionsStore {
    public private(set) var states: [PermissionKind: PermissionState] = [:]

    @ObservationIgnored private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    /// Reads every kind. Cheap enough to call on window activation.
    public func refresh() async {
        var next: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases {
            next[kind] = await services.permissions.state(of: kind)
        }
        states = next
    }

    public func request(_ kind: PermissionKind) async {
        let result = await services.permissions.request(kind)
        states[kind] = result
    }

    public func openSettings(_ kind: PermissionKind) {
        services.permissions.openSystemSettings(for: kind)
    }

    public func state(of kind: PermissionKind) -> PermissionState {
        states[kind] ?? .notDetermined
    }

    public var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { state(of: $0) == .granted }
    }

    /// Screen recording is the only permission without which the app cannot do its job at all;
    /// the hotkey opens onboarding until it is granted (spec §8). Anything but `.granted` blocks: the
    /// system reports `.notDetermined` both for a denied and for a never-asked screen recording grant.
    public var isBlocking: Bool {
        state(of: .screenRecording) != .granted
    }

    public func label(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording: L10n.t("Screen Recording")
        case .microphone: L10n.t("Microphone")
        case .notifications: L10n.t("Notifications")
        }
    }

    public func explanation(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            L10n.t("Needed to capture a region of the screen. macOS may ask to confirm it again about once a month.")
        case .microphone:
            L10n.t("Needed for voice notes. Typed notes work without it.")
        case .notifications:
            L10n.t("Used to report a run's result when it ends.")
        }
    }

    public func symbol(for kind: PermissionKind) -> String {
        switch state(of: kind) {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .notDetermined: "questionmark.circle.fill"
        }
    }

    public func tint(for kind: PermissionKind) -> Color {
        switch state(of: kind) {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        }
    }

    public func stateLabel(for kind: PermissionKind) -> String {
        switch state(of: kind) {
        case .granted: L10n.t("Granted")
        case .denied: L10n.t("Denied")
        case .notDetermined: L10n.t("Not asked")
        }
    }
}
