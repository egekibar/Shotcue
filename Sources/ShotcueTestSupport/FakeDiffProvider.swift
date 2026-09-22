import Foundation
import ShotcueCore

public final class FakeDiffProvider: DiffProvider, @unchecked Sendable {
    public let result: Locked<Result<String, FakeError>>
    public let calls = Locked<[(path: String, since: String?, maxBytes: Int)]>([])

    public init(result: Result<String, FakeError> = .success("diff --git a/x b/x")) {
        self.result = Locked(result)
    }

    public func diff(at path: String, since: String?, maxBytes: Int) async throws -> String {
        calls.withLock { $0.append((path, since, maxBytes)) }
        return try result.current.get()
    }
}
