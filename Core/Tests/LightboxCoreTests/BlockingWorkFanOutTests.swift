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
/// The residual is other suites' use of the same budget, and `.serialized` does
/// nothing about that — which is why both measuring tests additionally need a
/// test process to themselves. See `measuresQueueGeometry` for what that costs
/// and why isolation, not a wider bound, is the answer.
///
/// **What contamination does was misread here, and the correction is the whole
/// of #49.** This used to say that `peak` counts only this suite's own closures
/// — true, the counter is a test-local `LockBox` — and concluded that a noisy
/// neighbour therefore changes the *arrival pattern* rather than the number. It
/// changes the number. The closures a neighbour parks hold part of a budget
/// that is process-wide, so this suite's own high-water falls by however many
/// they hold: 64 alone, **4** inside a full parallel suite, on a 10-core M4 and
/// on CI's 3 cores alike. Counting only your own arrivals does not isolate you
/// from someone else's.
///
/// Anything new in Core that blocks a lot of closures on `BlockingWork.run` at
/// once belongs in here too, not beside it.
@Suite(.serialized)
struct BlockingWorkFanOutTests {
    /// **Why two of these three tests need the process to themselves (#49).**
    ///
    /// Not because of hardware. That was the first diagnosis and it was wrong,
    /// in every particular; #49 has the measurements that retired it. What these
    /// two need is a test process with no other suite in it, and the reason is
    /// the resource they measure.
    ///
    /// **The 64 is a process-wide budget, not this queue's width.** libdispatch
    /// caps the *process* at 64 constrained (non-overcommit) worker threads, and
    /// every concurrent `DispatchQueue` in the process draws from that one pool
    /// — `BlockingWork.queue`, any queue a test makes for itself, and whatever
    /// GRDB, ImageIO and QuickLook use internally. Saturate it from one queue
    /// and a second concurrent queue admits **zero** closures, not merely fewer:
    ///
    /// ```
    /// queue A saturated: peak=64
    /// queue B while A holds 64: peak=0
    /// ```
    ///
    /// So a test that counts only *its own* arrivals is not measuring the
    /// ceiling; it is measuring the ceiling minus whatever the rest of the run
    /// is holding. Under a full parallel suite the ceiling test's own high-water
    /// comes in at **4** — on CI's 3 cores *and on a 10-core M4*, which is how
    /// the hardware explanation was falsified. A private queue does not help;
    /// that is what the `peak=0` above rules out.
    ///
    /// Three things follow, and all three are load-bearing:
    ///
    /// - **`.serialized` cannot fix this.** Swift Testing serialises within a
    ///   suite; the contaminators are other suites. It was the right fix for the
    ///   earlier 41-against-32 observation, which *was* this suite's two tests
    ///   colliding, and it is kept for that.
    /// - **Isolation is the gate, so the gate must not skip on CI.** These run
    ///   in their own step (`LIGHTBOX_POOL_LIMITS=1 … --filter … --no-parallel`),
    ///   where they pass on the 3-core runner — verified, not assumed. The
    ///   variable means "this process is dedicated to measuring the pool", not
    ///   "this machine is big enough".
    /// - **The number is portable after all.** Driven directly, the queue
    ///   reaches 64 in 137 ms on 3 cores and 30 ms on 10. The ceiling test used
    ///   to route through `ThumbnailCache.generate`, which made its arrival rate
    ///   a property of QuickLook; that is removed, and is why option 1 of #49
    ///   was the right one.
    ///
    /// `aHashBlockedOnEveryCoreDoesNotStopTheRestOfTheProcess` stays
    /// unconditional. It asserts the *property* #28 and #30 are about — that
    /// blocking work does not stall the process — scales itself to
    /// `activeProcessorCount`, and does not depend on having the budget to
    /// itself. Isolating the geometry must not take the property with it.
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
    /// closure blocks on a semaphore that **nothing signals until 64 closures
    /// have arrived**, so they accumulate rather than passing through: none can
    /// leave, so the 64th must arrive before anything is released. How fast they
    /// arrive and how many cores are free stop mattering — a slower machine
    /// takes longer to reach 64, it does not reach a smaller number.
    ///
    /// What can still make it reach a smaller number is another *process*
    /// participant holding part of the budget, which no amount of forcing inside
    /// this test can fix. That is the isolation requirement, and it is the only
    /// sensitivity left.
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
    /// 64 is libdispatch's cap on the process's constrained worker threads, not
    /// a Lightbox constant. If a future OS changes it, this fails loudly and on
    /// purpose: `BlockingWork.queue`, `ThumbnailCache.generate`, CLAUDE.md and
    /// HANDOFF all quote the number, and they must be corrected with it rather
    /// than the assertion being loosened.
    ///
    /// **It drives `BlockingWork.run` directly, and that is the fix for #49.**
    /// It used to go through `ThumbnailCache.generate`, so what it actually
    /// measured was how many closures *QuickLook delivered* into the encode
    /// concurrently — a property of the render stage and of the machine, not of
    /// the queue. Isolated on the 3-core runner the render stage delivers 3;
    /// driven directly the queue reaches 64 in 137 ms there, and in 30 ms on a
    /// 10-core M4. Same claim, a tenth of the moving parts, and now portable.
    ///
    /// The remaining sensitivity is the one the suite's note explains and the
    /// only one that survives measurement: the budget is process-wide, so this
    /// needs the process to itself.
    @Test(.enabled(if: BlockingWorkFanOutTests.measuresQueueGeometry,
                   "needs LIGHTBOX_POOL_LIMITS=1 — the 64 is a process-wide budget, so this needs a test process with no other suite in it (#49)"))
    func theBlockingWorkQueueAdmitsExactlySixtyFourBlockedClosures() async throws {
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
            for _ in 0..<requests {
                group.addTask {
                    await BlockingWork.run {
                        gate.enterAndBlock()
                        gate.leave()
                    }
                }
            }
            // A member of the group rather than a bare `Task`, so the group does
            // not finish before the release has happened. It needs a cooperative
            // thread, and it can only get one because the blocked closures are
            // parked on a dispatch queue instead — which is #28's whole point.
            group.addTask {
                await gate.waitForSaturation()
                gate.releaseAll(requests)
            }
        }

        let (reached, peak) = gate.tally
        #expect(reached == requests, "only \(reached) of \(requests) closures reached the queue")
        #expect(!rescued.withLock { $0 }, """
            \(requests) closures blocked on BlockingWork.run's queue and it never had \
            \(expectedCeiling) of them in flight at once — the high-water mark was \
            \(peak). Either libdispatch's constrained-thread cap has changed — the \
            number is quoted in BlockingWork.queue, ThumbnailCache.generate, CLAUDE.md \
            and HANDOFF — or this ran alongside something else holding part of the \
            budget, which is process-wide and is why this test wants the process to \
            itself (#49).
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
    /// Measured with 200 simultaneous requests, in a dedicated test process on
    /// both machine shapes this project runs on:
    ///
    /// | Run | High-water mark |
    /// |---|---|
    /// | M4, 10 cores, alone, either pool mode | 4–10 |
    /// | `macos-26` runner, 3 cores, alone | 3 |
    /// | M4, full parallel suite | 6–7 |
    /// | M4, full parallel suite, `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` | 10 |
    /// | CI, full parallel suite | **50** |
    ///
    /// The assertion is against half the ceiling rather than against 10,
    /// because the *property* under test is headroom, and because this is a
    /// timing observation rather than a fact — see its sibling above for the
    /// fact. A regression that removes the spread (an encode that grows an
    /// `fsync`, a render that starts answering from a cache) lands far past 32
    /// and is caught; ordinary scheduling noise does not get near it.
    ///
    /// **Fewer cores do not raise this; a shared budget does (#49).** The 50 in
    /// that last row was read as a hardware effect, and #49 wrote it up as one:
    /// slower renders leaving each encode's neighbours still in flight. The same
    /// runner produces **3** when it has the process to itself, so that was
    /// wrong. What the 50 measures is 200 encodes competing with every other
    /// suite for a budget that is process-wide — the ceiling test's own
    /// high-water drops to 4 under the identical conditions, on both machines.
    /// Both numbers are the one defect seen from its two sides, and it is
    /// contamination, not core count.
    ///
    /// So this keeps its bound and runs isolated, where it has 22 of headroom on
    /// the narrower machine rather than the negative margin the full-suite run
    /// suggested. What that headroom no longer has to absorb is other suites;
    /// what it still absorbs is this suite's sibling, which parks 64 closures on
    /// purpose and once drove this to 41 — and which is why `.serialized` stays.
    @Test(.enabled(if: BlockingWorkFanOutTests.measuresQueueGeometry,
                   "needs LIGHTBOX_POOL_LIMITS=1 — 200 encodes against a process-wide budget, so this needs a test process with no other suite in it (#49)"))
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
/// This is what makes `theBlockingWorkQueueAdmitsExactlySixtyFourBlockedClosures`
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
