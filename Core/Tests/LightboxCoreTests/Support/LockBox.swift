import Foundation

/// A minimal locked box, so tests can accumulate values from a `@Sendable`
/// callback and read them back afterwards.
///
/// Not `Synchronization.Mutex`, and not named `Mutex` either. That type is
/// non-`Copyable`, so a `Copyable` struct cannot store one — which rules it out
/// for the stub readers here, since they are structs conforming to a protocol
/// and get copied into the coordinator. Shadowing the stdlib name would also
/// leave any later test that imports `Synchronization` with an ambiguity, or
/// silently with the other type.
final class LockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
