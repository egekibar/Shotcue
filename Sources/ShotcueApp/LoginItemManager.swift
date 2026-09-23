import Foundation
import ServiceManagement

/// Launch at login (research 01 §8). The *only* source of truth is `SMAppService.mainApp.status`:
/// the toggle in Settings and the real registration can drift (the user can flip it in System
/// Settings), so the status is read on every Settings open and never cached.
///
/// Measured 2026-09-22: a bundle running from outside a normal apps directory reports `.notFound`.
/// Measured 2026-09-23: the ad-hoc signed fallback build reports `.notFound` from `~/Applications` too,
/// so launch-at-login needs the installed app *and* the "Shotcue Dev" signature (`make cert`).
enum LoginItemManager {
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return "kapalı"
        case .enabled:
            return "etkin"
        case .requiresApproval:
            return "Sistem Ayarları > Genel > Giriş Öğeleri'nde onay bekliyor"
        case .notFound:
            return "kullanılamıyor (~/Applications'a imzalı kurulum gerekir: make cert + make install)"
        @unknown default:
            return "bilinmiyor"
        }
    }

    /// Idempotent: registering an already-enabled service throws, so the current status is checked first.
    /// Launch applies the stored setting once, so "off" on a service that was never registered must be a no-op.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
