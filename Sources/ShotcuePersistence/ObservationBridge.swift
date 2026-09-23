import Foundation
import GRDB
import os

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
                    // A failing observation (database closed, schema gone, corrupt row) ends
                    // the stream; UI stores treat a finished stream as "no more updates".
                    // Log it so the failure is not silent; cancellation is the normal end. Only the error's type is
                    // public: a row-decoding error's description carries the row's values (titles, notes,
                    // transcripts), which must never reach the public unified log (final review I5).
                    if !(error is CancellationError) {
                        Logger(subsystem: "com.shotcue.app", category: "persistence")
                            .error(
                                "observation failed: \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
                            )
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
