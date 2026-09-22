import Foundation
import Testing

@testable import ShotcueCore

@Suite("Task transitions")
struct TaskTransitionsTests {
    let now = Date(timeIntervalSince1970: 1_758_500_000)

    @Test func allowedMapMatchesSpec() {
        #expect(TaskStatus.allowedTransitions[.inbox] == [.ready])
        #expect(TaskStatus.allowedTransitions[.ready] == [.queued, .scheduled, .inbox])
        #expect(TaskStatus.allowedTransitions[.queued] == [.running, .ready, .scheduled])
        #expect(TaskStatus.allowedTransitions[.scheduled] == [.queued, .ready])
        #expect(TaskStatus.allowedTransitions[.running] == [.done, .failed, .cancelled])
        #expect(TaskStatus.allowedTransitions[.done] == [.queued, .scheduled])
        #expect(TaskStatus.allowedTransitions[.failed] == [.queued, .scheduled, .ready])
        #expect(TaskStatus.allowedTransitions[.cancelled] == [.queued, .scheduled, .ready])
        #expect(TaskStatus.allCases.allSatisfy { TaskStatus.allowedTransitions[$0] != nil })
    }

    @Test func inboxToReadyRequiresProject() {
        var t = ShotTask(title: "x", createdAt: now, updatedAt: now)
        #expect(throws: TaskStateError.missingProject) { try t.transition(to: .ready, at: now) }
        t.projectID = UUID()
        #expect(throws: Never.self) { try t.transition(to: .ready, at: now) }
        #expect(t.status == .ready)
    }

    @Test func invalidTransitionThrows() {
        var t = ShotTask(projectID: UUID(), title: "x", status: .inbox)
        #expect(throws: TaskStateError.invalidTransition(from: .inbox, to: .running)) {
            try t.transition(to: .running, at: now)
        }
        #expect(t.status == .inbox)
    }

    @Test func schedulingRequiresDateAndUnschedulingClearsIt() throws {
        var t = ShotTask(projectID: UUID(), title: "x", status: .ready)
        #expect(throws: TaskStateError.scheduledDateRequired) { try t.transition(to: .scheduled, at: now) }
        t.scheduledAt = now.addingTimeInterval(3600)
        try t.transition(to: .scheduled, at: now)
        #expect(t.status == .scheduled)
        try t.transition(to: .ready, at: now.addingTimeInterval(1))
        #expect(t.scheduledAt == nil)
        #expect(t.updatedAt == now.addingTimeInterval(1))
    }

    @Test func runningIsNotEditable() {
        #expect(TaskStatus.running.isEditable == false)
        #expect(TaskStatus.allCases.filter { $0 != .running }.allSatisfy { $0.isEditable })
    }

    @Test func fullHappyPath() throws {
        var t = ShotTask(projectID: UUID(), title: "x", status: .inbox)
        for next in [
            TaskStatus.ready, .queued, .running, .done, .queued, .running, .failed, .queued, .running, .cancelled,
        ] {
            try t.transition(to: next, at: now)
        }
        #expect(t.status == .cancelled)
    }
}
