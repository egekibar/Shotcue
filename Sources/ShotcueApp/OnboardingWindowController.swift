import AppKit
import ShotcueCore
import ShotcueUI

/// Permission onboarding window (spec §6.1, research 02 §4). Filled in Task 5.
final class OnboardingWindowController {
    private let permissionsStore: PermissionsStore
    private let permissions: any PermissionService
    private let activationPolicy: ActivationPolicyController
    init(
        permissionsStore: PermissionsStore, permissions: any PermissionService,
        activationPolicy: ActivationPolicyController
    ) {
        self.permissionsStore = permissionsStore
        self.permissions = permissions
        self.activationPolicy = activationPolicy
    }
    func show() {}
    func close() {}
}
