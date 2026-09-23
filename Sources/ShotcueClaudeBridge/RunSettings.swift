import Foundation
import ShotcueCore

/// The Claude tab of Settings (spec §6.6), passed to `RunCoordinator` and refreshed with
/// `updateSettings(_:)` whenever the user changes something.
public struct RunSettings: Sendable, Equatable {
    public var maxConcurrent: Int
    public var maxTurns: Int
    public var maxBudgetUSD: Double
    public var timeout: TimeInterval
    public var permissionMode: ClaudePermissionMode
    public var model: String?
    public var effort: String?
    public var extraSystemPrompt: String
    public var keepAwake: Bool

    public init(
        maxConcurrent: Int = 2, maxTurns: Int = 50, maxBudgetUSD: Double = 5,
        timeout: TimeInterval = 1800, permissionMode: ClaudePermissionMode = .bypassPermissions,
        model: String? = nil, effort: String? = nil, extraSystemPrompt: String = "",
        keepAwake: Bool = true
    ) {
        self.maxConcurrent = maxConcurrent
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.timeout = timeout
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
        self.extraSystemPrompt = extraSystemPrompt
        self.keepAwake = keepAwake
    }
}
