import Foundation

/// A minimal mutex, so tests can accumulate values from a `@Sendable` callback.
///
/// Deliberately not `Synchronization.Mutex`: that one is `~Copyable`, so it
/// cannot be captured by the escaping `@Sendable` progress closure this exists
/// to serve, nor stored in a `Sendable` stub struct that gets copied.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
