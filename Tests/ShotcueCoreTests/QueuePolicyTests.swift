import Foundation
import Testing

@testable import ShotcueCore

@Suite("QueuePolicy")
struct QueuePolicyTests {
    let p1 = UUID(), p2 = UUID()
    let t0 = Date(timeIntervalSince1970: 1_758_500_000)

    func task(_ p: UUID?, sort: Double, created: TimeInterval = 0, status: TaskStatus = .queued) -> ShotTask {
        ShotTask(projectID: p, title: "t", status: status, sortIndex: sort, createdAt: t0.addingTimeInterval(created))
    }

    @Test func ordersBySortIndexThenCreatedAt() {
        let a = task(p1, sort: 2048, created: 0)
        let b = task(p1, sort: 1024, created: 5)
        let c = task(p1, sort: 1024, created: 1)
        #expect(QueuePolicy.ordered([a, b, c]).map(\.id) == [c, b, a].map(\.id))
    }

    @Test func skipsProjectsThatAlreadyRun() {
        let a = task(p1, sort: 1)
        let b = task(p2, sort: 2)
        let next = QueuePolicy.nextRunnable(queued: [a, b], runningProjectIDs: [p1], runningCount: 1, maxConcurrent: 2)
        #expect(next?.id == b.id)
    }

    @Test func respectsGlobalLimit() {
        let a = task(p1, sort: 1)
        #expect(
            QueuePolicy.nextRunnable(queued: [a], runningProjectIDs: [p2], runningCount: 2, maxConcurrent: 2) == nil)
        #expect(
            QueuePolicy.nextRunnable(queued: [a], runningProjectIDs: [], runningCount: 0, maxConcurrent: 0)?.id == a.id)
    }

    @Test func ignoresNonQueuedAndProjectless() {
        let ready = task(p1, sort: 1, status: .ready)
        let orphan = task(nil, sort: 0)
        #expect(
            QueuePolicy.nextRunnable(queued: [ready, orphan], runningProjectIDs: [], runningCount: 0, maxConcurrent: 2)
                == nil)
    }
}
