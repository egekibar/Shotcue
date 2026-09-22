import Foundation
import ShotcueCore

/// Fans one run's events out to every `liveEvents` subscriber.
///
/// `yield`/`finish` are called OUTSIDE the lock: `onTermination` runs synchronously on the
/// caller's thread and takes the same lock, which deadlocks NSLock (verified in the spike).
final class RunEventBroadcaster: @unchecked Sendable {
    private let continuations = LockBox<[UUID: AsyncStream<RunEvent>.Continuation]>([:])

    func stream() -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [continuations] _ in
                continuations.withLock { $0[id] = nil }
            }
        }
    }

    func send(_ event: RunEvent) {
        let targets = continuations.withLock { Array($0.values) }
        for target in targets { target.yield(event) }
    }

    func finish() {
        let targets = continuations.withLock { registry -> [AsyncStream<RunEvent>.Continuation] in
            let all = Array(registry.values)
            registry.removeAll()
            return all
        }
        for target in targets { target.finish() }
    }
}
