import Foundation

/// Minimal lock box so `@unchecked Sendable` service types can hold mutable state, and so an
/// `actor`'s `nonisolated` members can reach shared registries.
///
/// Never call out to code that takes the same lock from inside `withLock` — `NSLock` is not
/// recursive and `AsyncStream.Continuation.onTermination` runs synchronously.
final class LockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
    func set(_ newValue: Value) { withLock { $0 = newValue } }
}
