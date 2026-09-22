import Foundation

public protocol ProjectRepository: Sendable {
    func allProjects() async throws -> [Project]
    func project(id: UUID) async throws -> Project?
    func save(_ project: Project) async throws
    func deleteProject(id: UUID) async throws
    /// Emits the full list now and after every change.
    func observeProjects() -> AsyncStream<[Project]>
}

public protocol TaskRepository: Sendable {
    func allTasks() async throws -> [ShotTask]
    func task(id: UUID) async throws -> ShotTask?
    /// `projectID == nil` → inbox (tasks without a project).
    func tasks(projectID: UUID?) async throws -> [ShotTask]
    func tasks(status: TaskStatus) async throws -> [ShotTask]
    func save(_ task: ShotTask) async throws
    /// Deletes the task and its captures/voice notes rows (files are the caller's job).
    func deleteTask(id: UUID) async throws
    func captures(taskID: UUID) async throws -> [Capture]
    func save(_ capture: Capture) async throws
    func moveCaptures(ids: [UUID], toTaskID: UUID) async throws
    func voiceNotes(taskID: UUID) async throws -> [VoiceNote]
    func save(_ voiceNote: VoiceNote) async throws
    /// Case-insensitive substring search over title, noteText and voice transcripts.
    func search(_ query: String) async throws -> [ShotTask]
    func observeAllTasks() -> AsyncStream<[ShotTask]>
    func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]>
}

public protocol RunRepository: Sendable {
    func runs(taskID: UUID) async throws -> [Run]
    func run(id: UUID) async throws -> Run?
    func save(_ run: Run) async throws
    /// Runs in `starting` or `running` state.
    func activeRuns() async throws -> [Run]
    /// On launch: marks leftover active runs as failed("interrupted"); returns how many.
    func markInterruptedRuns(at now: Date) async throws -> Int
    func observeRuns(taskID: UUID) -> AsyncStream<[Run]>
}
