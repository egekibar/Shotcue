import Foundation
import GRDB

/// Adapts GRDB's throwing `AsyncValueObservation` to the non-throwing `AsyncStream`
/// the Core repository protocols expose. The stream yields the current value first
/// (GRDB's initial fetch) and then one value per committed change.
enum ObservationBridge {
    static func stream<Value: Sendable>(
        _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
        in reader: any DatabaseReader
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: reader) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    // A failing observation (database closed, schema gone) ends the
                    // stream; UI stores treat a finished stream as "no more updates".
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
