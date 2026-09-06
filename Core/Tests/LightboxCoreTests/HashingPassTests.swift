import Testing
import Foundation
@testable import LightboxCore

/// Records every file it is asked about, so a test can assert not just the
/// stored result but how much work was done to get there — the whole point of
/// a queue that is supposed to drain exactly once.
private struct CountingHasher: FileHashing {
    let calls: LockBox<[String]>
    var failingNames: Set<String> = []

    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        calls.withLock { $0.append(url.lastPathComponent) }
        if failingNames.contains(url.lastPathComponent) { throw HashError.unreadable }
        return FileHashes(contentHash: "c-\(url.lastPathComponent)",
                          imageHash: "i-\(url.lastPathComponent)",
                          imageHashKind: "jpeg-scan-v1")
    }
}

/// Blocks inside the first file it is handed and does not return until the test
/// releases it, so pause, cancellation and overlap can be exercised at a known
/// point in the pass rather than by racing the scheduler.
private struct GatedHasher: FileHashing {
    let calls: LockBox<[String]>
    let release: DispatchSemaphore

    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        let ordinal = calls.withLock { $0.append(url.lastPathComponent); return $0.count }
        // `DispatchSemaphore.wait` is banned from async contexts; this is the
        // synchronous hash the coordinator performs inside a task-group child,
        // so it is legal here — and holding it is the whole point.
        if ordinal == 1 { release.wait() }
        return FileHashes(contentHash: "c-\(url.lastPathComponent)",
                          imageHash: "i-\(url.lastPathComponent)",
                          imageHashKind: "jpeg-scan-v1")
    }
}

/// A deterministic 32x32 grid that differs per filename, so the perceptual hash
/// is exercised for real without decoding an image.
private struct StubGray: GrayscaleRendering {
    func gray32(from url: URL) throws -> [UInt8] {
        var seed = UInt32(truncatingIfNeeded: url.lastPathComponent.hashValue)
        return (0..<1024).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
    }
}

private struct StubMetadata: MetadataReading {
    func read(_ url: URL) throws -> ImageMetadata { ImageMetadata(width: 10, height: 10) }
}

private func coordinator(_ store: IndexStore, hasher: any FileHashing,
                         grayscale: any GrayscaleRendering = StubGray()) -> IndexCoordinator {
    IndexCoordinator(store: store, walker: Walker(), metadata: StubMetadata(),
                     hasher: hasher, grayscale: grayscale, concurrency: 2)
}

/// Runs tier 0 over an existing tree. Kept separate from fixture creation: a
/// test that changes a file's bytes and then re-indexes must be able to re-run
/// the pass *without* rewriting the fixture underneath itself.
@discardableResult
private func runTier0(_ store: IndexStore, root: URL) async throws -> IndexProgress {
    let seeder = IndexCoordinator(store: store, walker: Walker(), metadata: StubMetadata(),
                                  hasher: CountingHasher(calls: LockBox([])),
                                  grayscale: StubGray())
    return try await seeder.indexTier0(root: root, recursive: true, onProgress: nil)
}

private func makeImages(_ tree: TempTree, count: Int) throws {
    for i in 0..<count { try tree.file("img\(i).jpg") }
}

private func seedTier0(_ tree: TempTree, _ store: IndexStore, count: Int) async throws {
    try makeImages(tree, count: count)
    try await runTier0(store, root: tree.root)
}

/// Waits until `condition` holds or the deadline passes, polling rather than
/// blocking: a semaphore wait here would park a cooperative-pool thread.
/// Returns whether the condition was observed.
@discardableResult
private func poll(until condition: @Sendable () -> Bool,
                  timeout: Duration = .seconds(10)) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's contract
/// rather than an ARC ordering inferred from where it was last used.
struct HashingPassTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    private func path(_ relative: String) -> String {
        tree.root.appendingPathComponent(relative).path
    }

    // MARK: - The pass itself

    @Test func hashingPassStoresAllThreeHashes() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 3)

        let hasher = CountingHasher(calls: LockBox([]))
        let progress = try await coordinator(store, hasher: hasher)
            .runHashingPass(root: tree.root, onProgress: nil)

        #expect(progress.phase == .finished)
        #expect(progress.total == 3)
        #expect(progress.completed == 3)
        #expect(progress.failed == 0)

        let record = try #require(try store.record(atPath: path("img0.jpg")))
        #expect(record.contentHash == "c-img0.jpg")
        #expect(record.imageHash == "i-img0.jpg")
        #expect(record.imageHashKind == "jpeg-scan-v1")
        #expect(record.phash?.count == 16)
        #expect(record.hashedAt != nil)
        #expect(try store.countMissingHashes(under: tree.root.path) == 0)
    }

    /// Different images must not collapse to the same perceptual hash, or the
    /// column would be present and useless.
    @Test func perceptualHashesDifferPerFile() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 3)
        _ = try await coordinator(store, hasher: CountingHasher(calls: LockBox([])))
            .runHashingPass(root: tree.root, onProgress: nil)

        var seen = Set<String>()
        for i in 0..<3 {
            let record = try #require(try store.record(atPath: path("img\(i).jpg")))
            seen.insert(try #require(record.phash))
        }
        #expect(seen.count == 3)
    }

    /// The queue is the database: once a row records that hashing was
    /// attempted, no later pass may pay for it again.
    @Test func aSecondPassDoesNoWork() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 3)
        let hasher = CountingHasher(calls: LockBox([]))
        let c = coordinator(store, hasher: hasher)

        _ = try await c.runHashingPass(root: tree.root, onProgress: nil)
        let afterFirst = hasher.calls.withLock { $0.count }
        #expect(afterFirst == 3)

        let second = try await c.runHashingPass(root: tree.root, onProgress: nil)
        #expect(second.phase == .finished)
        #expect(second.total == 0)
        #expect(second.completed == 0)
        #expect(hasher.calls.withLock { $0.count } == afterFirst)
    }

    /// A file that cannot be hashed still gets `hashed_at`, or it is retried on
    /// every pass for the life of the index.
    @Test func aFileThatFailsIsNotRetriedForever() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 2)
        let hasher = CountingHasher(calls: LockBox([]), failingNames: ["img1.jpg"])
        let c = coordinator(store, hasher: hasher)

        let first = try await c.runHashingPass(root: tree.root, onProgress: nil)
        #expect(first.phase == .finished)
        #expect(first.failed == 1)
        #expect(first.completed == 1)

        let failed = try #require(try store.record(atPath: path("img1.jpg")))
        #expect(failed.hashedAt != nil)         // attempted
        #expect(failed.contentHash == nil)      // but unhashed
        #expect(failed.imageHash == nil)
        #expect(failed.imageHashKind == nil)

        // One unreadable file must not poison its neighbour.
        let ok = try #require(try store.record(atPath: path("img0.jpg")))
        #expect(ok.contentHash == "c-img0.jpg")

        let callsAfterFirst = hasher.calls.withLock { $0.count }
        _ = try await c.runHashingPass(root: tree.root, onProgress: nil)
        #expect(hasher.calls.withLock { $0.count } == callsAfterFirst)
    }

    /// The other half of "never retried": a file whose bytes change must be
    /// re-enqueued. Tier 0 is re-run over the existing tree rather than
    /// recreating the fixture, so the changed bytes are the only variable and
    /// the observed size proves the pass really saw them.
    @Test func aReIndexedFileIsRehashed() async throws {
        let store = try IndexStore.inMemory()
        try makeImages(tree, count: 1)
        try await runTier0(store, root: tree.root)

        let hasher = CountingHasher(calls: LockBox([]))
        let c = coordinator(store, hasher: hasher)
        _ = try await c.runHashingPass(root: tree.root, onProgress: nil)
        let hashed = try #require(try store.record(atPath: path("img0.jpg")))
        #expect(hashed.hashedAt != nil)

        let url = tree.root.appendingPathComponent("img0.jpg")
        try Data(repeating: 0x7A, count: 4321).write(to: url)
        try await runTier0(store, root: tree.root)

        let after = try #require(try store.record(atPath: url.path))
        #expect(after.size == 4321, "tier 0 must have re-read the changed file")
        #expect(after.hashedAt == nil, "changing a file must invalidate its hashes")
        #expect(after.contentHash == nil)
        #expect(after.imageHash == nil)
        #expect(after.imageHashKind == nil)
        #expect(after.phash == nil)

        // And the tier 1 pass picks it up again rather than leaving it unhashed.
        let second = try await c.runHashingPass(root: tree.root, onProgress: nil)
        #expect(second.total == 1)
        #expect(second.completed == 1)
        #expect(hasher.calls.withLock { $0 } == ["img0.jpg", "img0.jpg"])
        #expect(try store.countMissingHashes(under: tree.root.path) == 0)
    }

    // MARK: - Scope

    @Test func onlyFilesUnderTheGivenRootAreHashed() async throws {
        let store = try IndexStore.inMemory()
        let outside = try TempTree()
        try await seedTier0(tree, store, count: 2)
        try await seedTier0(outside, store, count: 2)

        let hasher = CountingHasher(calls: LockBox([]))
        let progress = try await coordinator(store, hasher: hasher)
            .runHashingPass(root: tree.root, onProgress: nil)

        #expect(progress.total == 2)
        #expect(progress.completed == 2)
        #expect(hasher.calls.withLock { $0.count } == 2)
        #expect(try store.countMissingHashes(under: outside.root.path) == 2)
        let untouched = try #require(
            try store.record(atPath: outside.root.appendingPathComponent("img0.jpg").path))
        #expect(untouched.hashedAt == nil)
        try outside.cleanup()
    }

    /// SQLite's `LIKE` folds ASCII case, so a `LIKE`-based count would report a
    /// case-variant sibling's rows as this root's work.
    @Test func countMissingHashesDoesNotLeakAcrossCaseVariantSiblings() throws {
        let store = try IndexStore.inMemory()
        for path in ["/lib/a.jpg", "/lib/sub/b.jpg", "/LIB/c.jpg", "/library/d.jpg"] {
            _ = try store.upsert(FileRecord(id: nil, path: path,
                                            parentDir: (path as NSString).deletingLastPathComponent,
                                            name: (path as NSString).lastPathComponent,
                                            ext: "jpg", size: 8, mtime: 1, device: 1, inode: 1,
                                            width: nil, height: nil, captureTime: nil,
                                            captureOffset: nil, cameraMake: nil, cameraModel: nil,
                                            orientation: nil, contentHash: nil, imageHash: nil,
                                            imageHashKind: nil, phash: nil, hashedAt: nil,
                                            indexedAt: 1))
        }
        #expect(try store.countMissingHashes(under: "/lib") == 2)
    }

    @Test func countMissingHashesRejectsARelativeScope() throws {
        let store = try IndexStore.inMemory()
        #expect(throws: IndexStoreError.invalidScope("Pictures")) {
            _ = try store.countMissingHashes(under: "Pictures")
        }
    }

    // MARK: - Progress

    @Test func hashingProgressIsReportedMonotonically() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 120)

        let box = LockBox<[IndexProgress]>([])
        let final = try await coordinator(store, hasher: CountingHasher(calls: LockBox([])))
            .runHashingPass(root: tree.root) { progress in
                box.withLock { $0.append(progress) }
            }
        let seen = box.withLock { $0 }

        #expect(seen.last == final)
        #expect(seen.last?.phase == .finished)
        #expect(seen.first?.phase == .hashing)
        #expect(seen.allSatisfy { $0.total == 120 })
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.completed <= $1.completed })
        // At least one sample from mid-pass, or the phase-boundary samples
        // would satisfy every assertion above on their own.
        #expect(seen.contains { $0.phase == .hashing && $0.completed > 0
                                && $0.completed < $0.total })
    }

    // MARK: - Pause and resume

    @Test func pauseBeforeTheFirstBatchDoesNoWork() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 40)
        let hasher = CountingHasher(calls: LockBox([]))
        let c = coordinator(store, hasher: hasher)

        await c.pause()
        let isPaused = await c.isPaused
        #expect(isPaused)

        let box = LockBox<[IndexProgress]>([])
        let paused = try await c.runHashingPass(root: tree.root) { progress in
            box.withLock { $0.append(progress) }
        }
        #expect(paused.phase == .paused)
        #expect(paused.completed == 0)
        #expect(hasher.calls.withLock { $0.isEmpty })
        #expect(box.withLock { $0.last?.phase } == .paused)   // and it says so

        await c.resume()
        let isResumed = await c.isPaused
        #expect(!isResumed)

        let resumed = try await c.runHashingPass(root: tree.root, onProgress: nil)
        #expect(resumed.phase == .finished)
        #expect(resumed.completed == 40)
    }

    /// Pause must stop a pass that is already running, not only refuse to start
    /// one — and resume must pick up exactly the files the paused pass left,
    /// hashing none of them twice.
    @Test func pauseStopsAPassMidFlightAndResumeContinuesIt() async throws {
        let fileCount = 200
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: fileCount)

        let calls = LockBox<[String]>([])
        let release = DispatchSemaphore(value: 0)
        let c = coordinator(store, hasher: GatedHasher(calls: calls, release: release))

        // `root` is hoisted out because the task closure is `sending`: reading
        // `tree.root` inside it would capture the suite instance itself.
        let root = tree.root
        let box = LockBox<[IndexProgress]>([])
        let task = Task {
            try await c.runHashingPass(root: root) { progress in
                box.withLock { $0.append(progress) }
            }
        }

        #expect(try await poll { calls.withLock { !$0.isEmpty } })
        await c.pause()
        release.signal()
        let paused = try await task.value

        #expect(paused.phase == .paused)
        #expect(paused.completed > 0, "the pass had already started work")
        #expect(paused.completed < fileCount, "and pause really did stop it early")
        #expect(paused.total == fileCount)
        #expect(box.withLock { $0.last?.phase } == .paused)
        // The queue is the database, so the remaining work is visible in it.
        #expect(try store.countMissingHashes(under: root.path) == fileCount - paused.completed)

        await c.resume()
        let resumed = try await c.runHashingPass(root: root, onProgress: nil)
        #expect(resumed.phase == .finished)
        #expect(resumed.total == fileCount - paused.completed)
        #expect(paused.completed + resumed.completed == fileCount)

        let hashed = calls.withLock { $0 }
        #expect(hashed.count == fileCount)
        #expect(Set(hashed).count == fileCount, "no file may be hashed twice across a resume")
        #expect(try store.countMissingHashes(under: root.path) == 0)
    }

    // MARK: - Cancellation

    @Test func hashingPassStopsOnCancellation() async throws {
        let fileCount = 300
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: fileCount)

        let calls = LockBox<[String]>([])
        let release = DispatchSemaphore(value: 0)
        let c = coordinator(store, hasher: GatedHasher(calls: calls, release: release))

        let root = tree.root
        let task = Task { try await c.runHashingPass(root: root, onProgress: nil) }
        #expect(try await poll { calls.withLock { !$0.isEmpty } })
        task.cancel()
        release.signal()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.withLock { $0.count } < fileCount)
        // Whatever the cancelled pass did write stays written; the rest is
        // still queued, which is what makes the pass resumable.
        #expect(try store.countMissingHashes(under: root.path) > 0)
        #expect(try store.countMissingHashes(under: root.path)
                == fileCount - calls.withLock { $0.count })
    }

    /// Cancellation outranks pause. Both are true at the same loop boundary
    /// here, and the pass must report the one that is a failure to complete,
    /// not the one that is a state — otherwise a caller that cancels a paused
    /// pass gets a `.paused` result and no error.
    @Test func cancellingAPausedPassThrowsRatherThanReportingPaused() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 200)

        let calls = LockBox<[String]>([])
        let release = DispatchSemaphore(value: 0)
        let c = coordinator(store, hasher: GatedHasher(calls: calls, release: release))

        let root = tree.root
        let task = Task { try await c.runHashingPass(root: root, onProgress: nil) }
        #expect(try await poll { calls.withLock { !$0.isEmpty } })

        await c.pause()
        task.cancel()
        release.signal()

        await #expect(throws: CancellationError.self) { try await task.value }
        let isPaused = await c.isPaused
        #expect(isPaused)
    }

    // MARK: - Reentrancy

    /// `runHashingPass` suspends inside the actor, so without a guard a second
    /// pass could read the same `hashed_at IS NULL` rows the first is still
    /// hashing and pay for every one of them twice.
    ///
    /// The overlap is forced rather than hoped for. One pass is held inside its
    /// first file while the other is allowed to arrive, and a pass reports its
    /// opening `.hashing` progress with no suspension point between that
    /// callback and the gate — so once both have reported and one is blocked in
    /// the hasher, the other is provably queued behind it.
    @Test func overlappingHashingPassesDoNotDuplicateWork() async throws {
        let fileCount = 200
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: fileCount)

        let calls = LockBox<[String]>([])
        let release = DispatchSemaphore(value: 0)
        let c = coordinator(store, hasher: GatedHasher(calls: calls, release: release))

        let root = tree.root
        let started = LockBox(0)
        let bothStarted: @Sendable (IndexProgress) -> Void = { progress in
            if progress.completed == 0 { started.withLock { $0 += 1 } }
        }
        async let first = c.runHashingPass(root: root, onProgress: bothStarted)
        async let second = c.runHashingPass(root: root, onProgress: bothStarted)

        #expect(try await poll { started.withLock { $0 == 2 } && calls.withLock { !$0.isEmpty } })
        release.signal()
        let results = try await [first, second]

        #expect(results.allSatisfy { $0.phase == .finished })
        // Both really did work, or the test would pass vacuously on a scheduler
        // that ran them one after the other.
        #expect(results.allSatisfy { $0.completed > 0 })
        #expect(results.map(\.completed).reduce(0, +) == fileCount)
        let hashed = calls.withLock { $0 }
        #expect(hashed.count == fileCount)
        #expect(Set(hashed).count == fileCount)
        #expect(try store.countMissingHashes(under: root.path) == 0)
    }

    /// The dangerous interleaving: a tier 0 pass re-indexes a changed file
    /// while a hashing batch is suspended on that very file. Tier 0 clears the
    /// row's `hashed_at` because the bytes changed; if the hashing pass then
    /// landed its write, the index would permanently claim hashes computed
    /// from bytes the file no longer has, with `hashed_at` set so no later
    /// pass revisits it — and duplicate detection acts on those hashes.
    ///
    /// Deliberately driven from a *second* coordinator, because that is the
    /// case an in-actor guard cannot cover.
    @Test func aFileReIndexedDuringAHashingBatchIsNotStampedWithStaleHashes() async throws {
        let store = try IndexStore.inMemory()
        try makeImages(tree, count: 1)
        try await runTier0(store, root: tree.root)

        let calls = LockBox<[String]>([])
        let release = DispatchSemaphore(value: 0)
        let c = coordinator(store, hasher: GatedHasher(calls: calls, release: release))

        let root = tree.root
        let hashing = Task { try await c.runHashingPass(root: root, onProgress: nil) }
        #expect(try await poll { calls.withLock { !$0.isEmpty } })

        // The file changes while the batch is suspended on its hash, and tier 0
        // records the change before the hashing pass gets to write.
        let url = tree.root.appendingPathComponent("img0.jpg")
        try Data(repeating: 0x7A, count: 4321).write(to: url)
        try await runTier0(store, root: root)
        let reindexed = try #require(try store.record(atPath: url.path))
        #expect(reindexed.size == 4321)
        #expect(reindexed.hashedAt == nil)

        release.signal()
        let progress = try await hashing.value

        let after = try #require(try store.record(atPath: url.path))
        #expect(after.size == 4321)
        #expect(after.hashedAt == nil, "a re-indexed file must not keep hashes of its old bytes")
        #expect(after.contentHash == nil)
        #expect(after.phash == nil)
        // The refused write is not counted as done, and the file is still queued.
        #expect(progress.completed == 0)
        #expect(try store.countMissingHashes(under: root.path) == 1)

        // And a later pass really does hash it, rather than the refusal
        // quietly dropping the file out of the index forever.
        let recovery = try await coordinator(store, hasher: CountingHasher(calls: LockBox([])))
            .runHashingPass(root: root, onProgress: nil)
        #expect(recovery.completed == 1)
        #expect(try store.countMissingHashes(under: root.path) == 0)
    }

    // MARK: - An unreachable root

    /// The invariant tier 0 already holds, in the form that survives a
    /// remount: a whole-volume absence is not evidence about individual files.
    ///
    /// Marking an attempt is almost irreversible — only a change of size or
    /// mtime re-queues a row, and an unmounted drive changes neither — so a
    /// pass that ran against a vanished root would leave the entire library
    /// permanently unhashable, recoverable only by editing the database.
    @Test func anUnreachableRootThrowsRatherThanMarkingEveryFileAttempted() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 5)
        let before = try (0..<5).map { try #require(try store.record(atPath: path("img\($0).jpg"))) }
        #expect(try store.countMissingHashes(under: tree.root.path) == 5)

        // Stand in for the drive going away: the root stops resolving, and
        // crucially no file's size or mtime changes — which is exactly what a
        // disconnect looks like from the index's side.
        let parked = tree.root.deletingLastPathComponent()
            .appendingPathComponent("parked-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tree.root, to: parked)

        let hasher = CountingHasher(calls: LockBox([]))
        let c = coordinator(store, hasher: hasher)
        await #expect(throws: IndexCoordinatorError.rootUnreadable(tree.root.path)) {
            try await c.runHashingPass(root: tree.root, onProgress: nil)
        }
        #expect(hasher.calls.withLock { $0.isEmpty })

        // Remount.
        try FileManager.default.moveItem(at: parked, to: tree.root)

        // Nothing was recorded while the volume was away...
        #expect(try store.countMissingHashes(under: tree.root.path) == 5)
        for (i, was) in before.enumerated() {
            let now = try #require(try store.record(atPath: path("img\(i).jpg")))
            #expect(now.hashedAt == nil)
            #expect(now.size == was.size)
            #expect(now.mtime == was.mtime)
        }

        // ...which matters because tier 0 will not re-queue them: the files are
        // byte-for-byte what they were, so `needsReindex` is false for all five.
        let rescan = try await runTier0(store, root: tree.root)
        #expect(rescan.completed == 0)
        #expect(try store.countMissingHashes(under: tree.root.path) == 5)

        // And the work simply resumes.
        let resumed = try await c.runHashingPass(root: tree.root, onProgress: nil)
        #expect(resumed.completed == 5)
        #expect(resumed.failed == 0)
        #expect(try store.countMissingHashes(under: tree.root.path) == 0)
    }

    /// The same guard, at the point where it actually has to hold: the volume
    /// leaves while a batch is being hashed. The results are already computed
    /// when it is noticed, and they must still not be written.
    @Test func aRootThatLeavesMidBatchWritesNothing() async throws {
        let store = try IndexStore.inMemory()
        try await seedTier0(tree, store, count: 5)

        let calls = LockBox<[String]>([])
        let release = DispatchSemaphore(value: 0)
        let c = coordinator(store, hasher: GatedHasher(calls: calls, release: release))

        let root = tree.root
        let task = Task { try await c.runHashingPass(root: root, onProgress: nil) }
        #expect(try await poll { calls.withLock { !$0.isEmpty } })

        let parked = root.deletingLastPathComponent()
            .appendingPathComponent("parked-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: root, to: parked)
        release.signal()

        await #expect(throws: IndexCoordinatorError.rootUnreadable(root.path)) {
            try await task.value
        }
        try FileManager.default.moveItem(at: parked, to: root)

        // The hasher answered for these files — the guard, not a hashing
        // failure, is what kept them out of the database.
        #expect(calls.withLock { !$0.isEmpty })
        #expect(try store.countMissingHashes(under: root.path) == 5)
        for i in 0..<5 {
            let record = try #require(try store.record(atPath: path("img\(i).jpg")))
            #expect(record.hashedAt == nil)
        }
    }

    // MARK: - Real components

    /// Every other test here stubs the hasher and the renderer, and `TempTree`
    /// writes eight bytes of `0x41` rather than a decodable image — so nothing
    /// else proves the pass produces *correct* hashes, only that it drives the
    /// protocols correctly. This runs real files through the real components.
    @Test func theRealHasherAndRendererProduceTheStoredHashes() async throws {
        let store = try IndexStore.inMemory()
        let jpeg = try Fixtures.writeImage(to: tree.root.appendingPathComponent("photo.jpg"))
        // A checked-in WebP as well: a second image-hash rule, and a format
        // ImageIO cannot write, so it can only come from a real file.
        let webp = tree.root.appendingPathComponent("simple.webp")
        try FileManager.default.copyItem(at: try Fixtures.url("simple.webp"), to: webp)

        let c = IndexCoordinator(store: store, walker: Walker(), metadata: MetadataReader(),
                                 hasher: FileHasher(), grayscale: GrayscaleRenderer(),
                                 concurrency: 2)
        _ = try await c.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        let progress = try await c.runHashingPass(root: tree.root, onProgress: nil)
        #expect(progress.completed == 2)
        #expect(progress.failed == 0)

        for url in [jpeg, webp] {
            let mediaType = try #require(MediaType.forExtension(url.pathExtension))
            let expected = try FileHasher().hashes(for: url, mediaType: mediaType)
            let expectedPhash = try PerceptualHash(gray: GrayscaleRenderer().gray32(from: url)).hex

            let record = try #require(try store.record(atPath: url.path))
            #expect(record.contentHash == expected.contentHash)
            #expect(record.imageHash == expected.imageHash)
            #expect(record.imageHashKind == expected.imageHashKind)
            #expect(record.phash == expectedPhash)
            #expect(record.hashedAt != nil)
            // Shape, independent of the components: SHA-256 hex and 64 bits.
            #expect(record.contentHash?.count == 64)
            #expect(record.imageHash?.count == 64)
            #expect(record.phash?.count == 16)
            #expect(record.contentHash != record.imageHash)
        }
        // The two files are different pictures and must not collide.
        let a = try #require(try store.record(atPath: jpeg.path))
        let b = try #require(try store.record(atPath: webp.path))
        #expect(a.contentHash != b.contentHash)
        #expect(a.phash != b.phash)
    }
}
