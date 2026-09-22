import AppKit
import ShotcueCore
import ShotcueUI

/// Hotkey → capture → task row → quick panel (spec §5.1). Filled in Task 3.
final class CaptureFlowController {
    private let services: AppServices
    private let settings: SettingsStore
    private let fileStore: FileStore
    private let notifier: any Notifier
    private let status: AppStatusModel
    private let quickPanel: QuickPanelController
    private let onboarding: OnboardingWindowController

    init(
        services: AppServices, settings: SettingsStore, fileStore: FileStore, notifier: any Notifier,
        status: AppStatusModel, quickPanel: QuickPanelController,
        onboarding: OnboardingWindowController
    ) {
        self.services = services
        self.settings = settings
        self.fileStore = fileStore
        self.notifier = notifier
        self.status = status
        self.quickPanel = quickPanel
        self.onboarding = onboarding
    }

    func begin() {}
}
