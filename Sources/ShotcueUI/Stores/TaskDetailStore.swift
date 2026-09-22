import Foundation
import Observation

/// Placeholder so `LibraryStore` (Task 3) compiles: it builds a detail store for a single selection.
/// Task 4 replaces this file with the real inspector store; the members below are the ones Task 4 keeps.
@MainActor
@Observable
public final class TaskDetailStore {
    public let taskID: UUID

    public init(services: AppServices, taskID: UUID) {
        self.taskID = taskID
    }

    public func start() async {}

    public func stop() {}
}
