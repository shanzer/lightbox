import Testing
import Foundation
@testable import LightboxCore

private struct StubMetadataReader: MetadataReading {
    var failingNames: Set<String> = []

    func read(_ url: URL) throws -> ImageMetadata {
        if failingNames.contains(url.lastPathComponent) { throw MetadataError.notAnImage }
        return ImageMetadata(width: 640, height: 480,
                             captureTime: Date(timeIntervalSince1970: 1_600_000_000),
                             captureOffset: "+00:00", cameraMake: "Stub", cameraModel: "S1",
                             orientation: 1)
    }
}

/// Blocks inside the first read and reports when it got there, so a test can
/// cancel at a known point in the pass rather than racing the scheduler.
private struct BlockingMetadataReader: MetadataReading {
    let reads: Mutex<Int>
    let release: DispatchSemaphore

    func read(_ url: URL) throws -> ImageMetadata {
        let count = reads.withLock { $0 += 1; return $0 }
        // `DispatchSemaphore.wait` is banned from async contexts; this is the
        // synchronous read the coordinator performs, so it is legal here — and
        // holding it is the whole point.
        if count == 1 { release.wait() }
        return ImageMetadata(width: 640, height: 480)
    }
}

private struct StubHasher: FileHashing {
    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        FileHashes(contentHash: "c-\(url.lastPathComponent)",
                   imageHash: "i-\(url.lastPathComponent)", imageHashKind: "jpeg-scan-v1")
    }
}

private struct StubGrayscale: GrayscaleRendering {
    func gray32(from url: URL) throws -> [UInt8] { [UInt8](repeating: 200, count: 1024) }
}

private func makeCoordinator(_ store: IndexStore,
                             metadata: any MetadataReading = StubMetadataReader()) -> IndexCoordinator {
    IndexCoordinator(store: store, walker: Walker(), metadata: metadata,
                     hasher: StubHasher(), grayscale: StubGrayscale(), concurrency: 4)
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct IndexCoordinatorTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    private func path(_ relative: String) -> String {
        tree.root.appendingPathComponent(relative).path
    }

    // MARK: - The pass itself

    @Test func tier0IndexesEveryImageInTheTree() async throws {
        try tree.file("a.jpg"); try tree.file("sub/b.png"); try tree.file("notes.txt")
        let store = try IndexStore.inMemory()

        let progress = try await makeCoordinator(store)
            .indexTier0(root: tree.root, recursive: true, onProgress: nil)

        #expect(progress.phase == .finished)
        #expect(progress.total == 2)
        #expect(progress.completed == 2)
        #expect(progress.failed == 0)
        #expect(try store.count() == 2)

        let record = try #require(try store.record(atPath: path("a.jpg")))
        #expect(record.width == 640)
        #expect(record.height == 480)
        #expect(record.cameraMake == "Stub")
        #expect(record.captureOffset == "+00:00")
        // Tier 1's job, not tier 0's: both hashes need a decode or a full read.
        #expect(record.contentHash == nil)
        #expect(record.imageHash == nil)
        #expect(record.phash == nil)
        #expect(record.hashedAt == nil)
    }

    @Test func tier0RespectsRecursionSetting() async throws {
        try tree.file("a.jpg"); try tree.file("sub/b.jpg")
        let store = try IndexStore.inMemory()

        _ = try await makeCoordinator(store)
            .indexTier0(root: tree.root, recursive: false, onProgress: nil)

        #expect(try store.count() == 1)
        #expect(try store.record(atPath: path("a.jpg")) != nil)
        #expect(try store.record(atPath: path("sub/b.jpg")) == nil)
    }

    @Test func tier0SkipsFilesThatHaveNotChanged() async throws {
        try tree.file("a.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)

        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        let first = try #require(try store.record(atPath: path("a.jpg")))

        let second = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(second.total == 1)
        #expect(second.completed == 0)          // nothing needed re-reading
        #expect(try store.count() == 1)
        let after = try #require(try store.record(atPath: path("a.jpg")))
        #expect(after.indexedAt == first.indexedAt)
    }

    @Test func tier0ReindexesAFileWhoseContentChanged() async throws {
        let url = try tree.file("a.jpg", bytes: 10)
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)

        try Data(repeating: 0x42, count: 999).write(to: url)
        let second = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(second.completed == 1)
        let record = try #require(try store.record(atPath: url.path))
        #expect(record.size == 999)
    }

    @Test func tier0StillIndexesAFileWhoseMetadataCannotBeRead() async throws {
        try tree.file("good.jpg"); try tree.file("bad.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store,
                                          metadata: StubMetadataReader(failingNames: ["bad.jpg"]))

        let progress = try await coordinator.indexTier0(root: tree.root, recursive: true,
                                                        onProgress: nil)
        #expect(progress.failed == 1)
        #expect(progress.completed == 2)
        #expect(try store.count() == 2)         // both rows exist; one has no dimensions

        let bad = try #require(try store.record(atPath: path("bad.jpg")))
        #expect(bad.width == nil)
        #expect(bad.height == nil)
        #expect(bad.size > 0)                   // the stat succeeded even though the read did not

        // One unreadable file must not abort the pass or poison its neighbours.
        let good = try #require(try store.record(atPath: path("good.jpg")))
        #expect(good.width == 640)
    }

    // MARK: - Reconciliation

    @Test func tier0RemovesRowsForVanishedFiles() async throws {
        let doomed = try tree.file("gone.jpg")
        try tree.file("stays.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 2)

        try FileManager.default.removeItem(at: doomed)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 1)
        #expect(try store.record(atPath: doomed.path) == nil)
        #expect(try store.record(atPath: path("stays.jpg")) != nil)
    }

    /// The live set must hold every walked path, including the files skipped as
    /// unchanged. Counting only the files this pass re-read would make the
    /// first rescan delete almost the whole index.
    @Test func reconciliationKeepsRowsForFilesSkippedAsUnchanged() async throws {
        for i in 0..<5 { try tree.file("img\(i).jpg") }
        try tree.file("sub/deep.jpg")
        let changed = try tree.file("changed.jpg", bytes: 10)
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 7)

        // Only one file is stale, so the other six are skipped — and must
        // survive the reconcile that follows.
        try Data(repeating: 0x42, count: 999).write(to: changed)
        let second = try await coordinator.indexTier0(root: tree.root, recursive: true,
                                                      onProgress: nil)
        #expect(second.completed == 1)
        #expect(second.total == 7)
        #expect(try store.count() == 7)
        for i in 0..<5 {
            #expect(try store.record(atPath: path("img\(i).jpg")) != nil)
        }
        #expect(try store.record(atPath: path("sub/deep.jpg")) != nil)
    }

    @Test func aNonRecursiveScanDoesNotDeleteRowsInSubdirectories() async throws {
        try tree.file("a.jpg"); try tree.file("sub/b.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 2)

        // Re-opening the same folder with the toggle off must not orphan the
        // subdirectory's rows, or every toggle would destroy half the index.
        _ = try await coordinator.indexTier0(root: tree.root, recursive: false, onProgress: nil)
        #expect(try store.count() == 2)
        #expect(try store.record(atPath: path("sub/b.jpg")) != nil)
    }

    /// The other half of the previous test: scoping the delete to the folder
    /// must not turn reconciliation into a no-op for the folder itself.
    @Test func aNonRecursiveScanStillRemovesVanishedRowsInItsOwnFolder() async throws {
        let doomed = try tree.file("gone.jpg")
        try tree.file("stays.jpg"); try tree.file("sub/b.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 3)

        try FileManager.default.removeItem(at: doomed)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: false, onProgress: nil)
        #expect(try store.record(atPath: doomed.path) == nil)
        #expect(try store.record(atPath: path("stays.jpg")) != nil)
        #expect(try store.record(atPath: path("sub/b.jpg")) != nil)
        #expect(try store.count() == 2)
    }

    // MARK: - Progress

    @Test func tier0ReportsProgressMonotonically() async throws {
        for i in 0..<20 { try tree.file("img\(i).jpg") }
        let store = try IndexStore.inMemory()

        let box = Mutex<[IndexProgress]>([])
        let final = try await makeCoordinator(store)
            .indexTier0(root: tree.root, recursive: true) { progress in
                box.withLock { $0.append(progress) }
            }
        let seen = box.withLock { $0 }
        #expect(!seen.isEmpty)
        #expect(seen.last?.phase == .finished)
        #expect(seen.last == final)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.completed <= $1.completed })
        #expect(seen.allSatisfy { $0.completed <= $0.total })
    }

    @Test func progressFractionIsZeroBeforeAnythingIsKnown() {
        #expect(IndexProgress().fraction == 0)
        #expect(IndexProgress(phase: .reading, completed: 5, total: 10).fraction == 0.5)
    }

    // MARK: - Cancellation

    @Test func tier0StopsWhenTheTaskIsCancelled() async throws {
        for i in 0..<500 { try tree.file("img\(i).jpg") }
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)

        // `root` is hoisted out because the task closure is `sending`: reading
        // `tree.root` inside it would capture the suite instance itself.
        let root = tree.root
        let task = Task { try await coordinator.indexTier0(root: root, recursive: true,
                                                           onProgress: nil) }
        task.cancel()
        _ = try? await task.value
        #expect(try store.count() < 500)
    }

    /// Cancellation must be observed between files, not after the whole pass:
    /// the reader is held inside the first file's read, and once released the
    /// coordinator must give up rather than index the remaining nine.
    @Test func cancellationStopsBetweenFilesRatherThanAfterThePass() async throws {
        for i in 0..<10 { try tree.file("img\(i).jpg") }
        let store = try IndexStore.inMemory()
        let release = DispatchSemaphore(value: 0)
        let reads = Mutex(0)
        let coordinator = makeCoordinator(store,
                                          metadata: BlockingMetadataReader(reads: reads,
                                                                           release: release))

        // `root` is hoisted out because the task closure is `sending`: reading
        // `tree.root` inside it would capture the suite instance itself.
        let root = tree.root
        let task = Task { try await coordinator.indexTier0(root: root, recursive: true,
                                                           onProgress: nil) }
        // Poll rather than block: a semaphore wait here would park a
        // cooperative-pool thread, which is what the compiler forbids.
        let deadline = ContinuousClock.now + .seconds(10)
        while reads.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(reads.withLock { $0 } == 1)      // the pass really did reach a read
        task.cancel()
        release.signal()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reads.withLock { $0 } == 1)
        #expect(try store.count() == 1)
    }

    /// A cancelled pass has a partial view of the tree, so it must not
    /// reconcile: deleting every row it did not manage to walk would empty the
    /// index the moment a user closed a folder mid-scan.
    @Test func aCancelledRescanDeletesNothing() async throws {
        for i in 0..<200 { try tree.file("dir\(i % 20)/img\(i).jpg") }
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 200)

        // `root` is hoisted out because the task closure is `sending`: reading
        // `tree.root` inside it would capture the suite instance itself.
        let root = tree.root
        let task = Task { try await coordinator.indexTier0(root: root, recursive: true,
                                                           onProgress: nil) }
        task.cancel()
        _ = try? await task.value
        // Whether cancellation lands during the walk, during the loop, or not
        // at all, no row may be lost: nothing on disk vanished.
        #expect(try store.count() == 200)
    }
}
