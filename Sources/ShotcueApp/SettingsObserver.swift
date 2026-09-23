import Foundation
import Observation
import ShotcueUI

/// Re-arming `withObservationTracking` watcher over `SettingsStore`.
///
/// `withObservationTracking`'s `onChange:` closure is `@Sendable`, so a non-Sendable handler cannot be
/// captured inside it (verified: "capture of 'onChange' with non-Sendable type '() -> Void' in a
/// '@Sendable' closure"). The handler is therefore stored and invoked after hopping back to the main
/// actor, and tracking is re-installed because each `withObservationTracking` fires exactly once.
/// Tracking is re-armed *before* the handler runs, so a setting the handler itself writes (the hotkey
/// picker reverted after a failed registration) is observed and applied on the next pass.
final class SettingsObserver {
    private var handler: (() -> Void)?
    private var settings: SettingsStore?
    private var running = false

    init() {}

    func start(_ settings: SettingsStore, onChange: @escaping () -> Void) {
        self.settings = settings
        self.handler = onChange
        running = true
        track()
    }

    func stop() {
        running = false
        handler = nil
        settings = nil
    }

    private func track() {
        guard running, let settings else { return }
        withObservationTracking {
            // Reading the whole snapshot registers every field the app pushes into a service.
            _ = AppSettingsBridge.snapshot(of: settings)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.track()
                self.handler?()
            }
        }
    }
}
