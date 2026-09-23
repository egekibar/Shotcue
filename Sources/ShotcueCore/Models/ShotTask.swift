import Foundation

public enum TaskMode: String, Sendable, Codable, CaseIterable {
    case analyze, implement
}

public enum TaskStatus: String, Sendable, Codable, CaseIterable {
    case inbox, ready, queued, scheduled, running, done, failed, cancelled
}

/// A unit of work sent to Claude Code: one or more captures + note(s) targeting one project.
/// Named `ShotTask` to avoid clashing with Swift's `Task`.
public struct ShotTask: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var projectID: UUID?
    public var title: String
    public var noteText: String
    public var status: TaskStatus
    public var mode: TaskMode
    public var modelOverride: String?
    public var sortIndex: Double
    public var scheduledAt: Date?
    public var titleEditedByUser: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), projectID: UUID? = nil, title: String, noteText: String = "",
        status: TaskStatus = .inbox, mode: TaskMode = .implement, modelOverride: String? = nil,
        sortIndex: Double = 0, scheduledAt: Date? = nil, titleEditedByUser: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.noteText = noteText
        self.status = status
        self.mode = mode
        self.modelOverride = modelOverride
        self.sortIndex = sortIndex
        self.scheduledAt = scheduledAt
        self.titleEditedByUser = titleEditedByUser
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
