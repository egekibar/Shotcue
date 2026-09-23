import Foundation

/// One screenshot file belonging to a task. Paths are relative to the FileStore root.
public struct Capture: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID
    public var relPath: String
    public var thumbRelPath: String?
    public var width: Int
    public var height: Int
    public var scale: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(), taskID: UUID, relPath: String, thumbRelPath: String? = nil,
        width: Int, height: Int, scale: Double = 2, createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.relPath = relPath
        self.thumbRelPath = thumbRelPath
        self.width = width
        self.height = height
        self.scale = scale
        self.createdAt = createdAt
    }
}
