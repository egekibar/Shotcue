import Foundation
import ShotcueCore

/// Fans one run's events out to every `liveEvents` subscriber.
///
/// `yield`/`finish` are called OUTSIDE the lock: `onTermination` runs synchronously on the
/// caller's thread and takes the same lock, which deadlocks NSLock (verified in the spike).
/// Once finished it stays finished: a stream opened afterwards ends at once.
final class RunEventBroadcaster: @unchecked Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<RunEvent>.Continuation] = [:]
        var finished = false
    }

    private let state = LockBox(State())

    func stream() -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [state] _ in
                state.withLock { $0.continuations[id] = nil }
            }
            // Checked under the same lock `finish()` takes, so a late subscriber is never left open.
            let alreadyFinished = state.withLock { state -> Bool in
                if state.finished { return true }
                state.continuations[id] = continuation
                return false
            }
            if alreadyFinished { continuation.finish() }
        }
    }

    func send(_ event: RunEvent) {
        let targets = state.withLock { Array($0.continuations.values) }
        for target in targets { target.yield(event) }
    }

    func finish() {
        let targets = state.withLock { state -> [AsyncStream<RunEvent>.Continuation] in
            state.finished = true
            let all = Array(state.continuations.values)
            state.continuations.removeAll()
            return all
        }
        for target in targets { target.finish() }
    }
}
