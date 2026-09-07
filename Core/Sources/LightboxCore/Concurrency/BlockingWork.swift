import Dispatch
import Foundation

/// Where Core runs the work that blocks the thread it is on.
///
/// Swift's cooperative pool is exactly `activeProcessorCount` threads wide and
/// it does not grow. A thread parked in `read(2)`, in SQLite's busy wait, or in
/// a pipe read from exiftool is a thread the pool has *lost*, because the
/// kernel is not told the thread stopped being useful. Three of those on the
/// three-core CI runner and the whole process stops: that is issue #28. A
/// `sample` of the stalled run has the single cooperative thread parked here —
///
/// ```
/// Thread   DispatchQueue_15: com.apple.root.default-qos.cooperative
///   IndexCoordinator.indexTier0(root:recursive:onProgress:)  IndexCoordinator.swift:219
///     BlockingMetadataReader.read(_:)                        IndexCoordinatorTests.swift:28
///       _dispatch_semaphore_wait_slow
///         semaphore_wait_trap
/// ```
///
/// — waiting for a signal that only the test body could send, and the test body
/// needed a cooperative thread to run on. Nothing was busy; everything was
/// parked.
///
/// libdispatch's ordinary queues behave the opposite way: the pthread
/// workqueue stops counting a thread the moment it blocks and brings up
/// another, so blocking on one of these costs a thread rather than the
/// process's ability to make progress. Blocking work therefore belongs here and
/// not on the cooperative pool.
///
/// Two shapes are provided, because Core blocks in two shapes:
///
/// - `serialQueue(_:)` backs an actor's `unownedExecutor`. The actor's own body
///   then runs off the pool with no change to its code and no new suspension
///   point — so no new reentrancy, which matters for `IndexCoordinator`, whose
///   correctness argument is written in terms of what may interleave with what.
/// - `run(_:)` hops one closure off the pool and back. It is for blocking work
///   that is *not* actor-isolated: the hashing pass's task-group children.
enum BlockingWork {
    /// The label of the queue `IndexCoordinator` runs its body on.
    ///
    /// Named as a constant rather than left inline because tests assert on it.
    /// The assertion is deliberately against *our* label and not against
    /// Apple's `com.apple.root.default-qos.cooperative`: the property that must
    /// hold is "this ran where we put it", and that does not go stale when a
    /// future OS renames its root queues.
    static let indexCoordinatorLabel = "com.lightbox.index-coordinator"

    /// The label of the queue `MetadataWriter` runs its body on.
    static let metadataWriterLabel = "com.lightbox.metadata-writer"

    /// The label of the shared queue `run(_:)` hops onto.
    static let runLabel = "com.lightbox.blocking-work"

    /// A serial queue suitable for an actor's `unownedExecutor`.
    static func serialQueue(_ label: String) -> DispatchSerialQueue {
        DispatchSerialQueue(label: label, qos: .userInitiated)
    }

    /// Concurrent, because the callers are a bounded fan-out that is *meant* to
    /// overlap — the hashing pass reads `concurrency` files at once. Blocked
    /// threads here are replaced by the workqueue, which is the entire point.
    private static let queue = DispatchQueue(label: runLabel, qos: .userInitiated,
                                             attributes: .concurrent)

    /// Runs `body` off the cooperative pool and returns its result.
    ///
    /// Not cancellable, and that is not an oversight: the one caller —
    /// `IndexCoordinator.hash(_:hasher:grayscale:)` — documents why a cancelled
    /// hash must still finish and be recorded as an attempt. A
    /// `withTaskCancellationHandler` here would silently change that.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// The label of the dispatch queue the calling thread is running on.
    ///
    /// Tests use this to assert that blocking work landed off the pool. It is
    /// the same fact the `sample` above reports, asked from inside the process.
    static var currentQueueLabel: String {
        String(cString: __dispatch_queue_get_label(nil))
    }
}
