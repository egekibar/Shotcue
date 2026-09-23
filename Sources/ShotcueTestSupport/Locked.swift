import Foundation

/// Minimal lock box so fakes can be `Sendable` classes with mutable state.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value { withLock { $0 } }
    public func set(_ newValue: Value) { withLock { $0 = newValue } }
}

public struct FakeError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
