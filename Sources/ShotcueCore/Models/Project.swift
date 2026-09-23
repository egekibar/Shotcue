import Foundation

/// Wall-clock time of day for the per-project daily queue (local time zone).
public struct DailyTime: Hashable, Sendable, Codable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses "HH:MM"; nil when malformed or out of range.
    public init?(parsing text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
            (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        self.init(hour: h, minute: m)
    }

    public var formatted: String { String(format: "%02d:%02d", hour, minute) }
}

/// A project = a directory on disk where the coding agent runs. Groups in the library are projects.
public struct Project: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var path: String
    /// The agent the project's tasks go to; nil = the default from Settings.
    public var agent: AgentKind?
    public var defaultMode: TaskMode
    public var defaultModel: String?
    public var defaultEffort: String?
    public var dailyTime: DailyTime?
    public var dailyEnabled: Bool
    public var dailyLastFiredAt: Date?
    public var runInBranch: Bool
    public var stashBeforeRun: Bool
    public var sortIndex: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, path: String, agent: AgentKind? = nil, defaultMode: TaskMode = .implement,
        defaultModel: String? = nil, defaultEffort: String? = nil, dailyTime: DailyTime? = nil,
        dailyEnabled: Bool = false, dailyLastFiredAt: Date? = nil, runInBranch: Bool = false,
        stashBeforeRun: Bool = false, sortIndex: Double = 0, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.agent = agent
        self.defaultMode = defaultMode
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
        self.dailyTime = dailyTime
        self.dailyEnabled = dailyEnabled
        self.dailyLastFiredAt = dailyLastFiredAt
        self.runInBranch = runInBranch
        self.stashBeforeRun = stashBeforeRun
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
