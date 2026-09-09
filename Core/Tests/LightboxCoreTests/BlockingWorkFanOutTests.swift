import Testing
import Foundation
import Dispatch
import CoreGraphics
@testable import LightboxCore

/// The two tests that measure `BlockingWork.run`'s queue.
///
/// **`.serialized` is load-bearing, not tidiness.** Both of these measure
/// occupancy of one *process-global* queue, and one of them saturates it on
/// purpose: the ceiling test parks 64 closures there and holds them, which is
/// exactly the condition that makes the other's high-water mark meaningless.
/// Run in parallel they contaminate each other — the fan-out test's peak came
/// in at 41 against a bound of 32 in a full-suite run while both passed alone,
/// which is how this was found.
///
/// `aHashBlockedOnEveryCoreDoesNotStopTheRestOfTheProcess` is here for exactly
/// that reason and not because it is a fan-out test: it parks
/// `activeProcessorCount + 1` closures behind a semaphore until a watchdog
/// releases them, which is the same hold-and-saturate shape as the ceiling
/// test. It lived in `CooperativePoolTests` and therefore still ran in parallel
/// with this suite. Swift Testing serialises only *within* one suite, so a
/// second `.serialized` suite would not have helped — it has to be this one.
///
/// The residual is other suites' use of the same queue, and the largest of
/// those is now the hashing pass at `IndexCoordinator.concurrency` of 4 apiece.
/// That is what the fan-out bound's headroom absorbs. Note what contamination
/// does and does not do: `peak` counts only this suite's own closures, because
/// the counter lives in a test-local `LockBox` inside the injected installer,
/// so a noisy neighbour changes the *arrival pattern* rather than the number —
/// which is why the answer is serialisation and not a wider bound.
///
/// Anything new in Core that blocks a lot of closures on `BlockingWork.run` at
/// once belongs in here too, not beside it.
@Suite(.serialized)
struct BlockingWorkFanOutTests {
    /// **Why two of these three tests are opt-in (#49).**
    ///
    /// The ceiling and the fan-out bound are assertions about libdispatch's
    /// queue *geometry*, and both were written and verified on a 10-core M4.
    /// Neither holds on the 3-core `macos-26` runner, in opposite directions:
    ///
    /// | Test | Asserts | On CI |
    /// |---|---|---|
    /// | `theBlockingWorkQueueAdmitsExactlySixtyFourBlockedEncodes` | 64 blocked closures accumulate | high-water **3–4** |
    /// | `theEncodeFanOutStaysWellUnderTheBlockingWorkCeiling` | peak `< 32` | observed **50** |
    ///
    /// The first fails because a non-overcommit queue will not grow to 64
    /// threads on a 3-core box inside the watchdog's budget — the ceiling is
    /// libdispatch's cap, not a floor any machine reaches. The second fails
    /// because its own doc's prediction ("a three-core CI runner renders
    /// *slower*, not faster, so its peak is lower than this machine's; this
    /// cannot pass locally and fail there") is backwards: fewer cores means
    /// each render is slower, so *more* encodes are in flight at once, not
    /// fewer.
    ///
    /// So they are gated the way the benchmarks are, and for the same reason —
    /// a measurement is only meaningful on hardware that can produce it. They
    /// are not deleted, because the numbers they pin are quoted in
    /// `BlockingWork.queue`, `ThumbnailCache.generate`, `CLAUDE.md` and
    /// `HANDOFF`, and something has to be able to falsify them:
    ///
    /// ```bash
    /// cd Core && LIGHTBOX_POOL_LIMITS=1 swift test --filter BlockingWorkFanOut
    /// ```
    ///
    /// `aHashBlockedOnEveryCoreDoesNotStopTheRestOfTheProcess` stays
    /// unconditional. It asserts the *property* #28 and #30 are about — that
    /// blocking work does not stall the process — scales itself to
    /// `activeProcessorCount`, and passes on CI. Gating the geometry must not
    /// take the property with it.
    static let measuresQueueGeometry =
        ProcessInfo.processInfo.environment["LIGHTBOX_POOL_LIMITS"] == "1"

    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The ceiling itself, asserted rather than quoted — and asserted without
    /// asking anything of the scheduler.
    ///
    /// The first version of this test filled the queue with 50 ms sleeps and
    /// asserted the observed peak was exactly 64. That is a race dressed as a
    /// fact: it needs all 64 slots occupied at one instant, and a machine also
    /// running the App build hands out threads slowly enough that the peak
    /// comes in at 63. It did, once, and passed on re-run — the worst kind of
    /// test.
    ///
    /// The fix is to stop measuring a coincidence and start forcing it. Every
    /// encode blocks on a semaphore that **nothing signals until 64 encodes
    /// have arrived**, so the closures accumulate rather than passing through:
    /// none can leave, so the 64th must arrive before anything is released. How
    /// fast they arrive, how many cores are free, and how long QuickLook takes
    /// stop mattering entirely — a slower machine takes longer to reach 64, it
    /// does not reach a smaller number.
    ///
    /// That gives both bounds, neither of them timing-dependent:
    ///
    /// - **At least 64.** Saturation is what releases the semaphore, so if the
    ///   queue admitted only 63 the release would never happen. The watchdog
    ///   then fires and the test fails saying so, rather than hanging.
    /// - **At most 64.** The peak is asserted with `<=`, and that direction
    ///   cannot fail spuriously: contention makes *fewer* closures run at once,
    ///   never more. Only a genuinely wider queue can break it.
    ///
    /// The watchdog lives on a plain `Thread` for the same reason
    /// `CooperativePoolTests.aHashBlockedOnEveryCoreDoesNotStopTheRestOfThe`
    /// `Process`'s does: it has to be able to run when the thing it is watching
    /// has gone wrong, and it must not need the resource under test.
    ///
    /// 64 is libdispatch's limit for the non-overcommit root queue this
    /// targets, not a Lightbox constant. If a future OS changes it, this fails
    /// loudly and on purpose: `BlockingWork.queue`, `ThumbnailCache.generate`,
    /// CLAUDE.md and HANDOFF all quote the number, and they must be corrected
    /// with it rather than the assertion being loosened.
    @Test(.enabled(if: BlockingWorkFanOutTests.measuresQueueGeometry,
                   "needs LIGHTBOX_POOL_LIMITS=1 and a machine whose non-overcommit queue reaches 64 — see the suite's note (#49)"))
    func theBlockingWorkQueueAdmitsExactlySixtyFourBlockedEncodes() async throws {
        let source = try Fixtures.writeImage(to: tree.root.appendingPathComponent("ceiling.jpg"),
                                             width: 400, height: 300)
        let root = tree.root
        let requests = 200
        let expectedCeiling = 64
        let gate = SaturationGate(target: expectedCeiling)
        let rescued = LockBox(false)

        // Releases everything if saturation never comes, so a narrower queue is
        // a failed test in ten seconds rather than a hung suite.
        let watchdog = Thread {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if gate.isSaturated { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            rescued.withLock { $0 = true }
            gate.rescue(releasing: requests)
        }
        watchdog.start()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<requests {
                group.addTask {
                    _ = try? await ThumbnailCache.generate(
                        from: source,
                        to: root.appendingPathComponent("ceiling/\(i).png"),
                        size: 128
                    ) { image, target in
                        gate.enterAndBlock()
                        defer { gate.leave() }
                        try ThumbnailCache.install(image, at: target)
                    }
                }
            }
            // A member of the group rather than a bare `Task`, so the group does
            // not finish before the release has happened. It needs a cooperative
            // thread, and it can only get one because the blocked encodes are
            // parked on a dispatch queue instead — which is #28's whole point.
            group.addTask {
                await gate.waitForSaturation()
                gate.releaseAll(requests)
            }
        }

        let (reached, peak) = gate.tally
        #expect(reached == requests, "only \(reached) of \(requests) renders reached the encode")
        #expect(!rescued.withLock { $0 }, """
            \(requests) encodes blocked on BlockingWork.run's queue and it never had \
            \(expectedCeiling) of them in flight at once — the high-water mark was \
            \(peak). The queue is narrower than the ceiling quoted in \
            BlockingWork.queue, ThumbnailCache.generate, CLAUDE.md and HANDOFF.
            """)
        #expect(peak <= expectedCeiling, """
            BlockingWork.run admitted \(peak) concurrently-blocked closures, more than \
            the \(expectedCeiling) documented as its ceiling. This assertion cannot fail \
            from load — contention lowers concurrency — so libdispatch's non-overcommit \
            width has genuinely changed; correct the four places that quote it.
            """)
    }

    /// How far the grid's fan-out stays under the ceiling (#30).
    ///
    /// One of two callers that scale with the window — `FolderTreeView`'s
    /// sidebar rows are the other, and are neither measured nor tested — and
    /// the cheapest of the two per slot.
    ///
    /// `BlockingWork.run` admits 64 concurrently-blocked closures and queues
    /// the surplus, and the grid starts one generation per visible cell —
    /// 200-odd on a full-screen window of small tiles. If those all reached the
    /// encode together they would fill that queue and push the hashing pass and
    /// file operations behind them.
    ///
    /// They do not, and this measures why rather than asserting it: the encode
    /// is sub-millisecond and QuickLook's render is not, so requests arrive at
    /// the hop spread out.
    ///
    /// Measured on an M4 (10 cores), 200 simultaneous requests, during full
    /// parallel `swift test` runs rather than in isolation — the number in
    /// isolation is not the number that has to hold:
    ///
    /// | Run | High-water mark |
    /// |---|---|
    /// | alone, either pool mode | 5–10 |
    /// | full suite | 6–7 |
    /// | full suite, `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` | 10 |
    ///
    /// The assertion is against half the ceiling rather than against 10,
    /// because the *property* under test is headroom, and because this is a
    /// timing observation rather than a fact — see its sibling above for the
    /// fact. A regression that removes the spread (an encode that grows an
    /// `fsync`, a render that starts answering from a cache) lands far past 32
    /// and is caught; ordinary scheduling noise does not get near it.
    ///
    /// The margin between 10 and 32 is what absorbs other suites' use of the
    /// same global queue. It does *not* absorb this suite's own ceiling test
    /// running alongside — that one parks 64 closures deliberately and drove
    /// this to 41 — which is why the suite is `.serialized`.
    ///
    /// **That prediction was wrong, and CI falsified it (#49).** It used to
    /// read: "a three-core CI runner renders *slower*, not faster, so its peak
    /// is lower than this machine's; this cannot pass locally and fail there."
    /// It failed there at **50** against this bound of 32. Slower renders do
    /// not thin the queue — they leave each encode's neighbours still in
    /// flight when it arrives, so a *smaller* machine piles up *more*. The
    /// bound is calibrated to this one, which is why the test is now opt-in.
    @Test(.enabled(if: BlockingWorkFanOutTests.measuresQueueGeometry,
                   "needs LIGHTBOX_POOL_LIMITS=1 — the bound is calibrated to a 10-core machine; CI observed 50 against 32 (#49)"))
    func theEncodeFanOutStaysWellUnderTheBlockingWorkCeiling() async throws {
        let source = try Fixtures.writeImage(to: tree.root.appendingPathComponent("fan.jpg"),
                                             width: 400, height: 300)
        let root = tree.root
        // One lock over both counters, not one each. Incrementing `live` and
        // folding it into `peak` under separate acquisitions lets another
        // thread's increment land between them, so the maximum can be
        // under-reported by one — which is exactly how this test's sibling came
        // to observe 63 on a loaded machine.
        let counters = LockBox((live: 0, peak: 0, installs: 0))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    _ = try? await ThumbnailCache.generate(
                        from: source,
                        to: root.appendingPathComponent("fanout/\(i).png"),
                        size: 128
                    ) { image, target in
                        counters.withLock {
                            $0.installs += 1
                            $0.live += 1
                            $0.peak = max($0.peak, $0.live)
                        }
                        defer { counters.withLock { $0.live -= 1 } }
                        try ThumbnailCache.install(image, at: target)
                    }
                }
            }
        }

        // Not `observed > 0`: with `try?` swallowing every failure, 199 renders
        // could fail and a peak of 1 would still satisfy that. The peak only
        // means something if the load it was measured under actually happened.
        let (reached, observed) = counters.withLock { ($0.installs, $0.peak) }
        #expect(reached == 200, """
            only \(reached) of 200 renders reached the encode, so the peak was \
            measured under a load that was never actually applied.
            """)
        #expect(observed < 32, """
            \(observed) thumbnail encodes were blocked in BlockingWork.run at once, \
            against a queue that admits 64 and is shared with the hashing pass and \
            file operations. The grid's fan-out has stopped being spread out by \
            QuickLook's render time and now needs a limiter of its own.
            """)
    }

    // MARK: - The stall itself

    /// Blocks in every hash until released, so a test can park as many threads
    /// as the machine has cores and then ask whether anything else can still
    /// run.
    private struct StuckHasher: FileHashing {
        let entered: LockBox<Int>
        let release: DispatchSemaphore

        func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
            entered.withLock { $0 += 1 }
            release.wait()
            return FileHashes(contentHash: "c", imageHash: "i", imageHashKind: "jpeg-scan-v1")
        }
    }

    /// More blocked hashes than the cooperative pool has threads, released only
    /// by something that needs a cooperative thread itself.
    ///
    /// Before the fix this is the CI stall exactly: the blocked hashes take
    /// every pool thread, the releaser never gets one, and the process is done.
    /// After it, the hashes park dispatch-queue threads — which the workqueue
    /// replaces — and the releaser runs.
    ///
    /// **The deadline lives on a plain `Thread`, and it has to.** Under a
    /// genuinely starved pool nothing scheduled on the pool can report the
    /// starvation: a `Task.sleep` watchdog needs a thread to wake up on, and
    /// `completes(within:)` would hang alongside everything else. The watchdog
    /// therefore signals the semaphores itself, which unwedges the pool so the
    /// test can *fail* in ten seconds rather than hang until CI gives up.
    @Test func aHashBlockedOnEveryCoreDoesNotStopTheRestOfTheProcess() async throws {
        // One more blocker than the pool can possibly have threads. Other tests
        // running alongside this one only make the pool scarcer, never wider,
        // so this cannot pass by accident on a wide machine.
        let blockers = ProcessInfo.processInfo.activeProcessorCount + 1
        let entered = LockBox(0)
        let release = DispatchSemaphore(value: 0)
        let releasedByPool = LockBox(false)
        let rescuedByWatchdog = LockBox(false)

        var coordinators: [IndexCoordinator] = []
        for i in 0..<blockers {
            let store = try IndexStore.inMemory()
            let root = try tree.directory("blocker\(i)")
            _ = try tree.file("blocker\(i)/only.jpg")
            let c = IndexCoordinator(store: store, walker: Walker(),
                                     metadata: QuietMetadata(),
                                     hasher: StuckHasher(entered: entered, release: release),
                                     grayscale: QuietGrayscale(), concurrency: 1)
            _ = try await c.indexTier0(root: root, recursive: true, onProgress: nil)
            coordinators.append(c)
        }
        let roots = (0..<blockers).map { tree.root.appendingPathComponent("blocker\($0)") }

        let watchdog = Thread {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if releasedByPool.withLock({ $0 }) { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            rescuedByWatchdog.withLock { $0 = true }
            for _ in 0..<blockers { release.signal() }
        }
        watchdog.start()

        await withTaskGroup(of: Void.self) { group in
            for (c, root) in zip(coordinators, roots) {
                group.addTask { _ = try? await c.runHashingPass(root: root, onProgress: nil) }
            }
            // The proof obligation: this task needs a cooperative thread, and
            // it can only get one if the blocked hashes are not holding them.
            group.addTask {
                while entered.withLock({ $0 }) < blockers {
                    try? await Task.sleep(for: .milliseconds(5))
                    if rescuedByWatchdog.withLock({ $0 }) { return }
                }
                releasedByPool.withLock { $0 = true }
                for _ in 0..<blockers { release.signal() }
            }
        }

        #expect(!rescuedByWatchdog.withLock { $0 },
                """
                \(blockers) blocked hashes starved the cooperative pool: nothing on it \
                could run for ten seconds, and only an off-pool thread got the process \
                moving again. That is issue #28.
                """)
        #expect(releasedByPool.withLock { $0 })
    }
}

/// Holds every closure that enters until `target` of them have, then lets the
/// test decide when to release them.
///
/// This is what makes `theBlockingWorkQueueAdmitsExactlySixtyFourBlockedEncodes`
/// a fact rather than a race: because nothing leaves until the test says so,
/// reaching `target` is a consequence of the queue being that wide and not of
/// anything arriving quickly enough.
///
/// One lock over `live` and `peak` together — updating them under separate
/// acquisitions can under-report the maximum by one, which is the bug this
/// whole class was written to remove.
private final class SaturationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private let release = DispatchSemaphore(value: 0)
    private var live = 0
    private var peak = 0
    private var entries = 0
    private var saturated = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(target: Int) { self.target = target }

    var isSaturated: Bool { lock.withNSLock { saturated } }

    /// `(entries, peak)` — how many closures ever entered, and the most that
    /// were ever inside at once.
    var tally: (Int, Int) { lock.withNSLock { (entries, peak) } }

    /// Records an arrival and blocks the calling thread until released.
    ///
    /// Blocking here is the point: this runs on `BlockingWork.run`'s queue, so
    /// a parked thread occupies one of its slots. That is precisely what the
    /// ceiling counts, and it is safe because the queue's threads are replaced
    /// by the workqueue rather than lost, unlike a cooperative one.
    func enterAndBlock() {
        var toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        entries += 1
        live += 1
        peak = max(peak, live)
        if live >= target && !saturated {
            saturated = true
            toResume = waiter
            waiter = nil
        }
        lock.unlock()
        // Resumed outside the lock: a continuation may run its awaiting task
        // immediately, and that task takes this same lock.
        toResume?.resume()
        release.wait()
    }

    func leave() { lock.withNSLock { live -= 1 } }

    /// Suspends until `target` closures are inside. Returns at once if that has
    /// already happened, so the arrival cannot be missed by installing the
    /// continuation late.
    func waitForSaturation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if saturated {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func releaseAll(_ count: Int) {
        for _ in 0..<count { release.signal() }
    }

    /// Unblocks everything and wakes the waiter without saturation having
    /// happened, so a narrower-than-expected queue fails the test instead of
    /// hanging it.
    func rescue(releasing count: Int) {
        var toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        toResume = waiter
        waiter = nil
        lock.unlock()
        toResume?.resume()
        releaseAll(count)
    }
}

private extension NSLock {
    func withNSLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Quiet stand-ins so the starvation test's coordinators do no real work beyond
/// the hash it deliberately blocks in. Local copies rather than shared with
/// `CooperativePoolTests`: those exist to *record* the queue they ran on, and
/// nothing here asks that question.
private struct QuietMetadata: MetadataReading {
    func read(_ url: URL) throws -> ImageMetadata { ImageMetadata(width: 10, height: 10) }
}

private struct QuietGrayscale: GrayscaleRendering {
    func gray32(from url: URL) throws -> [UInt8] { [UInt8](repeating: 7, count: 1024) }
}
