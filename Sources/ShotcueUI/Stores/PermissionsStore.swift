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
    /// the hotkey opens onboarding until it is granted (spec §8).
    public var isBlocking: Bool {
        state(of: .screenRecording) == .denied
    }

    public func label(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording: "Ekran Kaydı"
        case .microphone: "Mikrofon"
        case .notifications: "Bildirimler"
        }
    }

    public func explanation(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            "Ekranın bir bölgesini yakalamak için gerekir. macOS bu izni ayda bir yeniden onaylatabilir."
        case .microphone:
            "Sesli not almak için gerekir. İzin yoksa metin notu yine çalışır."
        case .notifications:
            "Bir çalışma bittiğinde sonucu ve maliyeti bildirmek için kullanılır."
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
        case .granted: "Verildi"
        case .denied: "Reddedildi"
        case .notDetermined: "Sorulmadı"
        }
    }
}
