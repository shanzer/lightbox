import Testing
import Foundation
import Dispatch
@testable import LightboxCore

/// **Temporary instrumentation for #49. Delete with the fix.**
///
/// #49's preferred option — drive `BlockingWork.run` directly instead of
/// through `ThumbnailCache.generate`, so the claim is about the queue's width
/// rather than about one machine's render speed — is written down there as
/// *untested*: "it may or may not reach 64 on 3 cores". Nothing local can
/// answer that. `hw.activecpu` is not writable, and the cooperative pool's
/// `LIBDISPATCH_COOPERATIVE_POOL_STRICT` knob does not narrow the *workqueue*
/// these closures land on.
///
/// So this measures and prints rather than asserting, and it prints the growth
/// *curve* — when each new high-water mark was first seen — because the two
/// candidate root causes predict different curves and the same failure:
///
/// - **A cap.** A 3-core box's non-overcommit workqueue tops out near its core
///   count. The curve flattens early at 3–4 and stays there, and no budget
///   helps. `64` is then not a portable claim and #49's option 3 is the answer.
/// - **A rate.** The workqueue grows constrained threads on a throttle, so 64
///   is reachable but not inside the ceiling test's 10 s watchdog. The curve
///   keeps climbing for the whole budget. Option 1 works, with a budget stated
///   in terms of what was measured here.
///
/// A 10-core M4 reaches 64 in 0.245 s, which distinguishes neither: both
/// predict "fast when cores are plentiful".
///
/// Gated on its own variable, not on `LIGHTBOX_POOL_LIMITS`, and run from its
/// own CI step with `--filter`. That is not tidiness either: probe A parks 200
/// closures on the *process-global* queue and holds them for up to the whole
/// budget, which would starve every other suite sharing it — the contamination
/// the fan-out suite is `.serialized` to avoid, at a much larger scale.
@Suite(.serialized)
struct PoolGeometryProbe {
    static let enabled = ProcessInfo.processInfo.environment["LIGHTBOX_POOL_PROBE"] == "1"

    /// The budget. Deliberately far past the ceiling test's 10 s: the question
    /// is whether 64 is reachable *at all*, so a run that needs 25 s is a
    /// materially different answer from one that never arrives.
    static let budget = 30.0

    private static func report(_ title: String, _ lines: [String]) {
        print("::group::POOL PROBE — \(title)")
        print("cores=\(ProcessInfo.processInfo.activeProcessorCount) budget=\(budget)s")
        for line in lines { print(line) }
        print("::endgroup::")
    }

    /// Probe A — how wide the queue gets with nothing but blocked closures on it.
    ///
    /// No render stage, no QuickLook, no file IO: 200 closures that arrive as
    /// fast as the queue will take them and then park. This is #49's option 1
    /// with the assertion removed.
    @Test(.enabled(if: PoolGeometryProbe.enabled,
                   "diagnostic probe for #49 — set LIGHTBOX_POOL_PROBE=1"))
    func reportsHowWideTheBlockingWorkQueueActuallyGets() async {
        let requests = 200
        let release = DispatchSemaphore(value: 0)
        let counters = LockBox((live: 0, peak: 0, entries: 0))
        // (ms since start, peak at that moment). Collapsed to first-sighting of
        // each new peak when printed.
        let samples = LockBox([(ms: Int, peak: Int)]())
        let start = Date()

        // A plain `Thread` for the same reason the ceiling test's watchdog is
        // one: it must be able to run while the queue under test is saturated,
        // and it must not need the resource it is measuring.
        let sampler = Thread {
            while Date().timeIntervalSince(start) < Self.budget {
                let peak = counters.withLock { $0.peak }
                samples.withLock {
                    $0.append((ms: Int(Date().timeIntervalSince(start) * 1000), peak: peak))
                }
                if peak >= 64 { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            for _ in 0..<requests { release.signal() }
        }
        sampler.start()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<requests {
                group.addTask {
                    await BlockingWork.run {
                        counters.withLock {
                            $0.entries += 1
                            $0.live += 1
                            $0.peak = max($0.peak, $0.live)
                        }
                        release.wait()
                        counters.withLock { $0.live -= 1 }
                    }
                }
            }
        }

        let (_, peak, entries) = counters.withLock { ($0.live, $0.peak, $0.entries) }
        var curve: [String] = []
        var seen = 0
        for sample in samples.withLock({ $0 }) where sample.peak > seen {
            seen = sample.peak
            curve.append("  peak \(sample.peak) first seen at \(sample.ms) ms")
        }
        Self.report("A: direct BlockingWork.run, \(requests) closures blocked until released", curve + [
            "high-water=\(peak) entries=\(entries) of \(requests)",
            "reached64=\(peak >= 64)",
        ])
        // Reports; does not judge. #49 decides what the number means.
        #expect(entries == requests, "only \(entries) of \(requests) closures ever ran")
    }

    /// Probe B — the same measurement through `ThumbnailCache.generate`, which
    /// is the shape `theEncodeFanOutStaysWellUnderTheBlockingWorkCeiling`
    /// measures and the one that came in at 50 against a bound of 32 on CI.
    ///
    /// Run beside probe A so both numbers come from one machine in one run:
    /// "the queue only reaches 4" and "the grid put 50 in it at once" cannot
    /// both be true, and until now they were observed in different runs.
    @Test(.enabled(if: PoolGeometryProbe.enabled,
                   "diagnostic probe for #49 — set LIGHTBOX_POOL_PROBE=1"))
    func reportsTheEncodeFanOutPeak() async throws {
        let tree = try TempTree()
        let source = try Fixtures.writeImage(to: tree.root.appendingPathComponent("probe.jpg"),
                                             width: 400, height: 300)
        let root = tree.root
        let counters = LockBox((live: 0, peak: 0, installs: 0))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    _ = try? await ThumbnailCache.generate(
                        from: source,
                        to: root.appendingPathComponent("probe/\(i).png"),
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

        let (peak, installs) = counters.withLock { ($0.peak, $0.installs) }
        Self.report("B: 200 ThumbnailCache.generate requests", [
            "encode high-water=\(peak) installs=\(installs) of 200",
            "current bound is < 32; CI has observed 50",
        ])
        #expect(installs == 200, "only \(installs) of 200 renders reached the encode")
    }
}
