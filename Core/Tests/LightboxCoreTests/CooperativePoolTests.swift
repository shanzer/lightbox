import Testing
import Foundation
import Dispatch
@testable import LightboxCore

/// Issue #28: the Core job on the three-core `macos-26` runner stalled about
/// one run in two. Roughly 210 of ~470 tests had started and never finished,
/// including tests that do nothing but arithmetic — so the pool's threads were
/// not busy, they were parked. A `sample` of the stalled process, reproduced
/// locally with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, showed the whole
/// cooperative pool in one stack:
///
/// ```
/// Thread   DispatchQueue_15: com.apple.root.default-qos.cooperative
///   IndexCoordinator.indexTier0(root:recursive:onProgress:)  IndexCoordinator.swift:219
///     BlockingMetadataReader.read(_:)                        IndexCoordinatorTests.swift:28
///       _dispatch_semaphore_wait_slow → semaphore_wait_trap
/// ```
///
/// The cycle: the coordinator's synchronous body blocks on a cooperative
/// thread; the thing it waits for can only be produced by a task that needs a
/// cooperative thread of its own; the pool is `activeProcessorCount` wide and
/// never grows, so once the last thread parks there is nothing left to produce
/// it. Three concurrent blocking tests were enough on a three-core runner.
///
/// The fix moves Core's blocking sections off that pool. The line is held in
/// two different ways, because either alone is weak: the label tests below say
/// *where* the work ran and fail instantly and legibly if it moves back, and
/// `BlockingWorkFanOutTests.aHashBlockedOnEveryCoreDoesNotStopTheRestOfThe`
/// `Process` reproduces the actual failure and fails within seconds instead of
/// hanging. The starvation test lives over there rather than here because it
/// parks `activeProcessorCount + 1` closures on `BlockingWork.run`'s queue and
/// holds them, and everything with that shape has to be serialised against the
/// tests that measure the queue's occupancy.
struct CooperativePoolTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    // MARK: - Where the blocking work runs

    /// Records the dispatch queue its caller was running on.
    private struct QueueNamingMetadata: MetadataReading {
        let labels: LockBox<Set<String>>

        func read(_ url: URL) throws -> ImageMetadata {
            labels.withLock { _ = $0.insert(BlockingWork.currentQueueLabel) }
            return ImageMetadata(width: 10, height: 10)
        }
    }

    private struct QueueNamingHasher: FileHashing {
        let labels: LockBox<Set<String>>

        func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
            labels.withLock { _ = $0.insert(BlockingWork.currentQueueLabel) }
            return FileHashes(contentHash: "c", imageHash: "i", imageHashKind: "jpeg-scan-v1")
        }
    }

    private struct QuietGrayscale: GrayscaleRendering {
        func gray32(from url: URL) throws -> [UInt8] { [UInt8](repeating: 7, count: 1024) }
    }

    /// Tier 0 stats every file and reads ImageIO properties out of the changed
    /// ones, synchronously, inside the actor. That must not happen on a
    /// cooperative thread — it is the exact stack the `sample` above caught.
    @Test func tier0ReadsMetadataOffTheCooperativePool() async throws {
        let store = try IndexStore.inMemory()
        for i in 0..<4 { _ = try tree.file("m\(i).jpg") }
        let labels = LockBox(Set<String>())
        let c = IndexCoordinator(store: store, walker: Walker(),
                                 metadata: QueueNamingMetadata(labels: labels),
                                 hasher: QueueNamingHasher(labels: LockBox(Set())),
                                 grayscale: QuietGrayscale(), concurrency: 2)

        _ = try await c.indexTier0(root: tree.root, recursive: true, onProgress: nil)

        #expect(labels.withLock { $0 } == [BlockingWork.indexCoordinatorLabel],
                "tier 0's metadata reads ran somewhere other than the coordinator's own queue")
    }

    /// The hashing pass's children read whole files and decode images. They are
    /// not actor-isolated, so the actor's executor does not cover them; they
    /// get the hop in `BlockingWork.run` instead.
    @Test func theHashingPassHashesOffTheCooperativePool() async throws {
        let store = try IndexStore.inMemory()
        for i in 0..<4 { _ = try tree.file("h\(i).jpg") }
        let labels = LockBox(Set<String>())
        let c = IndexCoordinator(store: store, walker: Walker(),
                                 metadata: QueueNamingMetadata(labels: LockBox(Set())),
                                 hasher: QueueNamingHasher(labels: labels),
                                 grayscale: QuietGrayscale(), concurrency: 2)

        _ = try await c.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        let pass = try await c.runHashingPass(root: tree.root, onProgress: nil)

        #expect(pass.completed == 4)
        #expect(labels.withLock { $0 } == [BlockingWork.runLabel],
                "the hashing pass hashed on a thread that was not a blocking-work thread")
    }

    /// Every `MetadataWriter` call forks exiftool and blocks in `poll(2)` for up
    /// to `ExiftoolRunner.commandTimeout` — two minutes. Bounded, since #18 and
    /// #21, but a bounded two-minute park still empties a three-wide pool.
    ///
    /// No exiftool needed: what is asserted is the executor, which the actor has
    /// whether or not there is anything on `PATH` to run.
    @Test func theMetadataWriterRunsOffTheCooperativePool() async {
        let writer = MetadataWriter(availability: .notFound)
        let label = await writer.currentQueueLabel()
        #expect(label == BlockingWork.metadataWriterLabel)
    }

    /// A batch is the largest single lump of blocking work in Core: a
    /// `rename(2)` or a `copyfile(3)` per file, a `trashItem` that talks to
    /// another process, and a `stat` on each side of every one — 300 times over,
    /// against a drive that may have spun down. None of it may sit on the
    /// cooperative pool.
    ///
    /// The label is read from inside a real batch rather than from an idle
    /// actor, so what is asserted is where the filesystem work ran and not
    /// merely where a getter did.
    @Test func fileOperationsRunOffTheCooperativePool() async throws {
        let store = try IndexStore.inMemory()
        let source = try tree.file("from/IMG_0001.jpg", bytes: 16)
        let destination = try tree.directory("to")
        let labels = LockBox(Set<String>())

        let op = FileOperator(store: store, copier: { source, target, _ in
            labels.withLock { _ = $0.insert(BlockingWork.currentQueueLabel) }
            try FileManager.default.copyItem(at: source, to: target)
        })
        let plan = try await op.plan(kind: .copy, sources: [source],
                                     destination: destination)
        _ = try await op.execute(plan)

        #expect(await op.currentQueueLabel() == BlockingWork.fileOperatorLabel)
        #expect(labels.withLock { $0 } == [BlockingWork.fileOperatorLabel])
    }

    /// The QuickLook render is genuinely `async` and parks nothing, but what
    /// follows it is not: a PNG encode through ImageIO, a `mkdir`, and a
    /// `rename(2)` onto a cache directory that may be on the same external
    /// drive the library is. `@concurrent` puts that on the cooperative pool,
    /// which is the one place it must not be — and unlike the coordinator this
    /// site has real fan-out, one generation per visible grid cell.
    ///
    /// The installer is injected the way `FileOperator`'s `copier` is above, so
    /// what is asserted is the queue the encode *itself* ran on and not the
    /// queue some proxy for it ran on.
    @Test func theThumbnailEncodeRunsOffTheCooperativePool() async throws {
        let source = try Fixtures.writeImage(to: tree.root.appendingPathComponent("t.jpg"),
                                             width: 64, height: 64)
        let destination = tree.root.appendingPathComponent("cache/ab/abcdef.png")
        let labels = LockBox(Set<String>())

        _ = try await ThumbnailCache.generate(from: source, to: destination, size: 64) { _, target in
            labels.withLock { _ = $0.insert(BlockingWork.currentQueueLabel) }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("png".utf8).write(to: target)
        }

        #expect(labels.withLock { $0 } == [BlockingWork.runLabel],
                "the thumbnail encode ran on a thread that was not a blocking-work thread")
    }

    /// The actor's own body blocks too, and for longer than the encode does:
    /// `evictIfNeeded()` and `cachedCount()` enumerate a cache directory that
    /// holds one file per thumbnail the user has ever scrolled past — tens of
    /// thousands — and `stat` each one.
    @Test func theThumbnailCacheRunsItsOwnBodyOffTheCooperativePool() async throws {
        let cache = ThumbnailCache(directory: tree.root.appendingPathComponent("cache"))
        #expect(await cache.currentQueueLabel() == BlockingWork.thumbnailCacheLabel)
    }

    /// `recheckAvailability()` forks `exiftool -ver` and blocks in a pipe read
    /// until it answers or `ExiftoolLocator`'s probe timeout expires. It is the
    /// *Try Again* button behind an inspector that has just told the user
    /// exiftool is missing, so it is pressed exactly when the fork is slowest
    /// to fail.
    ///
    /// The probe is injected rather than run for real: what is under test is
    /// where the hop puts it, which does not depend on there being anything on
    /// `PATH` to fork. Injecting it also keeps this test off the two-minute
    /// path when there is not.
    ///
    /// The *cache* is injected for a blunter reason: `MetadataWriter`'s own is
    /// process-wide and has no restore, so recheck-ing a stub answer into it
    /// leaves `.notFound` cached for the rest of the run and every exiftool
    /// round-trip test that follows fails claiming exiftool is not installed.
    /// A private cache keeps this test's answer to itself.
    @Test func theExiftoolProbeRunsOffTheCooperativePool() async {
        let labels = LockBox(Set<String>())
        let answer = await MetadataWriter.recheckAvailability(
            in: MetadataWriter.AvailabilityCache()
        ) {
            labels.withLock { _ = $0.insert(BlockingWork.currentQueueLabel) }
            return .notFound
        }

        #expect(answer == .notFound)
        #expect(labels.withLock { $0 } == [BlockingWork.runLabel],
                "the exiftool probe forked on a thread that was not a blocking-work thread")
    }

    /// A recheck that does not *replace* the cached answer is not a recheck.
    ///
    /// The test above proves the probe ran off the pool and that its answer
    /// came back to the caller; neither fact needs the cache to have been
    /// written, so deleting the `store` call left the suite green. What the
    /// type exists for is the next read of `value`, and that is what this
    /// asserts. No probe fires on that read: the cache is warm, which is the
    /// whole point.
    ///
    /// The stub answer is `.tooOld` with a path that cannot exist rather than
    /// `.notFound`, because `.notFound` is exactly what a real
    /// `ExiftoolLocator.check` returns on a machine without exiftool — CI is
    /// one — so a `.notFound` assertion would pass there even with the store
    /// removed and the lazy probe running instead. This answer is one no real
    /// probe can produce.
    @Test func aRecheckReplacesWhatTheCacheAnswersWithNext() async {
        let stub = ExiftoolAvailability.tooOld(path: "/nowhere/exiftool",
                                               version: "0.1", minimum: "13.0")
        let cache = MetadataWriter.AvailabilityCache()

        let returned = await MetadataWriter.recheckAvailability(in: cache) { stub }

        #expect(returned == stub)
        #expect(cache.value == stub,
                "the recheck's answer never reached the cache, so the next reader re-probes")
    }
}
