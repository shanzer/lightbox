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
/// The fix moves Core's blocking sections off that pool. These tests hold that
/// line in two different ways, because either alone is weak: the label tests
/// say *where* the work ran and fail instantly and legibly if it moves back,
/// and the starvation test reproduces the actual failure and fails within
/// seconds instead of hanging.
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
                                     metadata: QueueNamingMetadata(labels: LockBox(Set())),
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
