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
///   that is *not* actor-isolated: the hashing pass's task-group children, the
///   thumbnail encode, the exiftool probe, and — across the module boundary —
///   the browser's search and the sidebar's directory reads.
///
/// `public`, but only just: `run(_:)` is, because the App target has the same
/// problem and must not grow a second answer to it — `BrowserModel`'s search
/// and `FolderTreeView`'s directory listings block on exactly the SQLite and
/// `read(2)` calls this exists for, and a `Task.detached` there parks a
/// cooperative thread just as surely as one in Core (#30). Everything else here
/// stays internal, including the queue labels and `currentQueueLabel`: the App
/// target's `CooperativePoolTests` reaches them through `@testable import
/// LightboxCore`, which works because the Core target is built with
/// `ENABLE_TESTABILITY`. Test-only needs do not justify public API.
///
/// That import is why the test suites are Debug-only: `ENABLE_TESTABILITY` is
/// set on the Debug configuration alone, so `xcodebuild test -configuration
/// Release` does not compile. Deliberate — see CLAUDE.md's note beside the
/// test-host gotcha — because testability in a Release build costs
/// cross-module optimization in the shipping app.
public enum BlockingWork {
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

    /// The label of the queue `FileOperator` runs its body on.
    static let fileOperatorLabel = "com.lightbox.file-operator"

    /// The label of the queue `ThumbnailCache` runs its body on.
    ///
    /// The actor's own body, not the encode: `evictIfNeeded()` and
    /// `cachedCount()` enumerate a directory holding tens of thousands of
    /// files, and `thumbnail(for:mtime:size:)` stats one on every request. The
    /// encode hops through `run(_:)` instead, because it is deliberately not
    /// actor-isolated — see `ThumbnailCache.generate`.
    static let thumbnailCacheLabel = "com.lightbox.thumbnail-cache"

    /// The label of the shared queue `run(_:)` hops onto.
    ///
    static let runLabel = "com.lightbox.blocking-work"

    /// A serial queue suitable for an actor's `unownedExecutor`.
    ///
    /// The explicit `.userInitiated` is a *floor*, and it costs something worth
    /// naming: a queue with a QoS of its own no longer propagates the calling
    /// task's priority, so work enqueued by a `.background` caller runs at
    /// user-initiated rather than in the background. That is acceptable for all
    /// four actors that take this queue, because each exists to serve a window
    /// the user is looking at — `IndexCoordinator` a folder open,
    /// `MetadataWriter` a metadata write, `FileOperator` a batch the user
    /// started, `ThumbnailCache` the grid in front of them — and none of the
    /// four is ever driven from a background-priority task.
    ///
    /// `ThumbnailCache` is the one worth pausing on, because it is the only
    /// adopter whose work is *scroll-driven* rather than started by an explicit
    /// command, and scroll-driven work is usually the first thing one would
    /// want to deprioritise. Not here: the cells asking are the cells on
    /// screen, and a thumbnail that arrives late is a grey tile the user is
    /// looking at. Its one fire-and-forget caller — `BrowserModel`'s cache trim
    /// — runs at this floor too, and that is a deliberate acceptance rather
    /// than an oversight: it is a single coalesced directory walk per folder
    /// open, not a background sweep.
    ///
    /// It is not a licence to reuse this for genuinely deprioritised work; such
    /// a caller wants its own queue at its own QoS.
    static func serialQueue(_ label: String) -> DispatchSerialQueue {
        DispatchSerialQueue(label: label, qos: .userInitiated)
    }

    /// Concurrent, because the callers are a bounded fan-out that is *meant* to
    /// overlap — the hashing pass reads `concurrency` files at once. Blocked
    /// threads here are replaced by the workqueue, which is the entire point.
    ///
    /// Replaced up to a limit, though, and the limit is real: this targets a
    /// non-overcommit root queue, and measuring it — 200 closures that block
    /// until released — showed exactly 64 running concurrently and the rest
    /// queued behind them. So this is not an escape from thread accounting, it
    /// is a much larger and non-fatal budget: exceed 64 concurrently-blocked
    /// closures and the surplus waits rather than deadlocking the process, but
    /// it still waits — and it waits *behind whoever else is here*, which is
    /// why every caller's fan-out is written down:
    ///
    /// A slot is held for as long as its closure blocks, so both columns
    /// matter: a caller with a small fan-out and a multi-second hold occupies
    /// the queue longer than a wide one that is done in a millisecond.
    ///
    /// | Caller | Concurrently blocked, at most | How long each holds its slot |
    /// |---|---|---|
    /// | `IndexCoordinator`'s hashing pass | `IndexCoordinator.concurrency`, 4 | a whole-file read and decode |
    /// | `ThumbnailCache.generate`'s encode | measured at most 10 for 200 simultaneous requests — `ThumbnailCache.generate` explains why, and `theEncodeFanOutStaysWellUnderTheBlockingWorkCeiling` guards it at half the ceiling (`< 32`), the margin absorbing other suites' use of the same queue | 0.6 ms |
    /// | `MetadataWriter.recheckAvailability` | 1 — a button | up to `ExiftoolLocator.loginShellProbeTimeout` + `versionProbeTimeout`, 15 s — two forks since #41, and only the second one is exiftool's |
    /// | `BrowserModel.reload`'s search | 1 — one query pass at a time | 93 ms for a 50k-row reload |
    /// | `FolderTreeView.loadWithLookahead` | one per sidebar row that appears, so it scales with sidebar height | a `contentsOfDirectory` plus an `lstat` per entry — **seconds** on a spun-down external volume |
    ///
    /// Two callers scale with the window rather than with a constant, not one:
    /// the grid's cells and the sidebar's rows. The thumbnail row is the only
    /// one that has been *measured* — 4, against a 64 ceiling — and it is also
    /// the cheapest per slot. In slot-seconds the sidebar is the heaviest
    /// caller here, and it is the one with no test behind it: its fan-out is
    /// bounded only by how tall the user's sidebar is, and each of its closures
    /// can hold a slot for seconds rather than for 0.6 ms. If this queue is
    /// ever found saturated, look there first.
    private static let queue = DispatchQueue(label: runLabel, qos: .userInitiated,
                                             attributes: .concurrent)

    /// Runs `body` off the cooperative pool and returns its result.
    ///
    /// Not cancellable, and that is not an oversight: the first caller —
    /// `IndexCoordinator.hash(_:hasher:grayscale:)` — documents why a cancelled
    /// hash must still finish and be recorded as an attempt. A
    /// `withTaskCancellationHandler` here would silently change that. The
    /// callers added since do not want cancellation either: the thumbnail
    /// encode has a temporary file to move or delete, the exiftool probe is a
    /// single `-ver` fork, and `BrowserModel`'s search was already
    /// non-cancellable — it superseded stale results with a generation token
    /// rather than by cancelling, and that is unchanged.
    public static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// The throwing shape of `run(_:)`, for blocking work that fails.
    ///
    /// A separate overload rather than `rethrows`: `rethrows` does not survive
    /// the `withCheckedContinuation` in the body, and typed throws would put
    /// the error type in the signature of every caller. Overload resolution
    /// picks this one only for a closure that actually throws, so a
    /// non-throwing caller still gets the non-`try` shape above.
    public static func run<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// The label of the dispatch queue the calling thread is running on.
    ///
    /// Tests use this to assert that blocking work landed off the pool. It is
    /// the same fact the `sample` above reports, asked from inside the process.
    /// Internal, not public: the App target's tests get at it with
    /// `@testable import LightboxCore`.
    static var currentQueueLabel: String {
        String(cString: __dispatch_queue_get_label(nil))
    }
}
