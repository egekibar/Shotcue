import Foundation
import Testing

/// Polls until `condition` holds. `RunCoordinator` starts runs in detached tasks, so tests
/// observe the repositories instead of awaiting the run itself.
func waitUntil(
    _ description: String, timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for: \(description)")
}
