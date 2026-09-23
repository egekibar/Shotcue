import Foundation
import ShotcueCore

/// The Ajanlar tab of Settings (spec §6.6), passed to `RunCoordinator` and refreshed with
/// `updateSettings(_:)` whenever the user changes something.
public struct RunSettings: Sendable, Equatable {
    /// The agent of projects that did not pick one.
    public var defaultAgent: AgentKind
    public var maxConcurrent: Int
    public var maxTurns: Int
    public var maxBudgetUSD: Double
    public var timeout: TimeInterval
    public var permissionMode: ClaudePermissionMode
    /// Claude Code's default model and effort.
    public var model: String?
    public var effort: String?
    public var codexModel: String?
    public var codexEffort: String?
    public var antigravityModel: String?
    public var antigravityEffort: String?
    public var extraSystemPrompt: String
    public var keepAwake: Bool

    public init(
        defaultAgent: AgentKind = .claude, maxConcurrent: Int = 2, maxTurns: Int = 50, maxBudgetUSD: Double = 5,
        timeout: TimeInterval = 1800, permissionMode: ClaudePermissionMode = .bypassPermissions,
        model: String? = nil, effort: String? = nil, codexModel: String? = nil, codexEffort: String? = nil,
        antigravityModel: String? = nil, antigravityEffort: String? = nil, extraSystemPrompt: String = "",
        keepAwake: Bool = true
    ) {
        self.defaultAgent = defaultAgent
        self.maxConcurrent = maxConcurrent
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.timeout = timeout
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
        self.codexModel = codexModel
        self.codexEffort = codexEffort
        self.antigravityModel = antigravityModel
        self.antigravityEffort = antigravityEffort
        self.extraSystemPrompt = extraSystemPrompt
        self.keepAwake = keepAwake
    }

    /// The Settings defaults of one agent (the last link of the task → project → settings chain).
    public func defaults(for agent: AgentKind) -> (model: String?, effort: String?) {
        switch agent {
        case .claude: (model, effort)
        case .codex: (codexModel, codexEffort)
        case .antigravity: (antigravityModel, antigravityEffort)
        }
    }
}
