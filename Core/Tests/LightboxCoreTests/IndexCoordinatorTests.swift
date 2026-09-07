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
    let reads: LockBox<Int>
    let release: DispatchSemaphore

    func read(_ url: URL) throws -> ImageMetadata {
        let count = reads.withLock { $0 += 1; return $0 }
        // `DispatchSemaphore.wait` is banned from async contexts; this is the
        // synchronous read the coordinator performs, so it is legal here — and
        // holding it is the whole point. Since #28 the coordinator's body runs
        // on its own `DispatchSerialQueue`, so parking here costs a dispatch
        // thread rather than a cooperative one. This exact frame is what the
        // `sample` of the stalled CI job caught; see `CooperativePoolTests`.
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

/// A coordinator that sees a different volume on each read, so a test can stage
/// a swap underneath a pass. The last entry repeats, so a caller only says what
/// changes. Mounting a second filesystem is the only other way to produce a
/// genuine mid-pass change of volume, and that is not something a unit test on
/// a CI runner should be doing.
private func makeCoordinatorSeeing(_ store: IndexStore,
                                   volumes: [VolumeIdentity?]) -> IndexCoordinator {
    let remaining = LockBox(volumes)
    return IndexCoordinator(store: store, walker: Walker(), metadata: StubMetadataReader(),
                            hasher: StubHasher(), grayscale: StubGrayscale(), concurrency: 4,
                            volumeReader: { _ in
        remaining.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? nil }
    })
}

/// A row for a file the coordinator never walked, so a test can plant an index
/// that predates the current mount. The volume identity is the point of it.
private func plantedRecord(path: String, device: Int64,
                           volumeUUID: String? = nil) -> FileRecord {
    FileRecord(id: nil, path: path,
               parentDir: (path as NSString).deletingLastPathComponent,
               name: (path as NSString).lastPathComponent,
               ext: (path as NSString).pathExtension.lowercased(),
               size: 8, mtime: 1_700_000_000, device: device, inode: 1,
               volumeUUID: volumeUUID, width: 640, height: 480,
               captureTime: nil, captureOffset: nil,
               cameraMake: nil, cameraModel: nil, orientation: 1,
               contentHash: nil, imageHash: nil, imageHashKind: nil,
               phash: nil, hashedAt: nil, indexedAt: 1_700_000_000)
}

/// No real volume gets this device id, so a row carrying it can only have come
/// from a filesystem that is not the one the test is walking.
private let foreignDevice: Int64 = 999_999_999

/// No real volume gets this UUID either. It is the shape of a real one so a
/// comparison is doing the same work it does in production.
private let foreignVolumeUUID = "00000000-0000-0000-0000-000000000000"

/// The temporary directory's volume UUID, or nil on a filesystem that
/// publishes none (SMB, some FAT). Read through the same resource key the code
/// under test reads, so a skip guard cannot disagree with the behaviour it is
/// guarding: the tests that prove UUID identity have nothing to prove on a
/// volume that has no UUID.
private let temporaryVolumeUUID: String? = (try? URL(fileURLWithPath: NSTemporaryDirectory())
    .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString

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

    // MARK: - Incomplete walks

    /// The invariant: a row may only be deleted on the evidence of a complete
    /// look at the place it lives. An unreadable subdirectory is not evidence
    /// that the files inside it were deleted — the walk never got in.
    @Test(.enabled(if: getuid() != 0, "requires a non-root user"))
    func anUnreadableSubdirectoryCostsNoRows() async throws {
        try tree.file("a.jpg")
        for i in 0..<8 { try tree.file("locked/img\(i).jpg") }
        try tree.file("locked/deep/nested/x.jpg")
        try tree.file("locked/deep/nested/y.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 11)

        try tree.chmod("locked", 0o000)
        let second = try await coordinator.indexTier0(root: tree.root, recursive: true,
                                                      onProgress: nil)
        #expect(second.phase == .finished)
        #expect(second.skipped == 1)          // and it says so, rather than silently
        #expect(try store.count() == 11)
        for i in 0..<8 {
            #expect(try store.record(atPath: path("locked/img\(i).jpg")) != nil)
        }
        // The protection is the whole subtree, not just the directory's own
        // children: the walk never learned anything about any depth below it.
        #expect(try store.record(atPath: path("locked/deep/nested/x.jpg")) != nil)
        #expect(try store.record(atPath: path("locked/deep/nested/y.jpg")) != nil)
    }

    /// The stamp is evidence, and evidence needs a look. Rows the walk could
    /// not see keep the volume identity they had — restating it would let the
    /// *next* pass reconcile rows on the strength of a subtree nobody entered.
    @Test(.enabled(if: getuid() != 0, "requires a non-root user"))
    func rowsInASubtreeTheWalkCouldNotEnterKeepTheirVolume() async throws {
        try tree.file("a.jpg")
        try tree.directory("locked")
        let store = try IndexStore.inMemory()
        try store.upsert(plantedRecord(path: path("locked/planted.jpg"),
                                       device: foreignDevice, volumeUUID: foreignVolumeUUID))

        try tree.chmod("locked", 0o000)
        _ = try await makeCoordinator(store).indexTier0(root: tree.root, recursive: true,
                                                        onProgress: nil)

        let row = try #require(try store.record(atPath: path("locked/planted.jpg")))
        #expect(row.volumeUUID == foreignVolumeUUID)
        #expect(row.device == foreignDevice)
    }

    /// An unreadable root must not read as "the folder is empty now".
    @Test(.enabled(if: getuid() != 0, "requires a non-root user"))
    func anUnreadableRootThrowsAndDeletesNothing() async throws {
        let scanRoot = try tree.directory("photos")
        for i in 0..<5 { try tree.file("photos/img\(i).jpg") }
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        #expect(try store.count() == 5)

        try tree.chmod("photos", 0o000)
        await #expect(throws: IndexCoordinatorError.rootUnreadable(scanRoot.path)) {
            try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        }
        #expect(try store.count() == 5)
    }

    /// The one that matters on this app's own hardware: an external drive is
    /// unplugged and the last folder is reopened. A missing root is a missing
    /// volume far more often than it is a deleted folder, and the two are
    /// indistinguishable from here — so neither may delete the drive's index.
    @Test func aMissingRootThrowsAndDeletesNothing() async throws {
        let scanRoot = try tree.directory("photos")
        for i in 0..<6 { try tree.file("photos/img\(i).jpg") }
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        #expect(try store.count() == 6)

        try FileManager.default.removeItem(at: scanRoot)
        await #expect(throws: IndexCoordinatorError.rootUnreadable(scanRoot.path)) {
            try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        }
        #expect(try store.count() == 6)
        for i in 0..<6 {
            #expect(try store.record(atPath: path("photos/img\(i).jpg")) != nil)
        }
    }

    @Test func aMissingRootIsRejectedByANonRecursiveScanToo() async throws {
        let scanRoot = try tree.directory("photos")
        try tree.file("photos/a.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: scanRoot, recursive: false, onProgress: nil)
        #expect(try store.count() == 1)

        try FileManager.default.removeItem(at: scanRoot)
        await #expect(throws: IndexCoordinatorError.rootUnreadable(scanRoot.path)) {
            try await coordinator.indexTier0(root: scanRoot, recursive: false, onProgress: nil)
        }
        #expect(try store.count() == 1)
    }

    // MARK: - Wrong volume

    /// The hole the completeness checks do not cover: a root that enumerates
    /// perfectly and yields nothing. A stale mount point, a share that mounts
    /// empty, a drive back with a fresh filesystem — each reads as "every file
    /// here was deleted" from a clean, complete, zero-entry pass. The rows say
    /// which volume they came from; this one is not it.
    @Test func anEmptyRootWhoseRowsAreOnAnotherVolumeDeletesNothing() async throws {
        let scanRoot = try tree.directory("photos")
        let store = try IndexStore.inMemory()
        for i in 0..<7 {
            try store.upsert(plantedRecord(path: scanRoot.appendingPathComponent("img\(i).jpg").path,
                                           device: foreignDevice))
        }
        #expect(try store.count() == 7)

        let progress = try await makeCoordinator(store)
            .indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        #expect(progress.total == 0)          // the walk really did see an empty folder
        #expect(progress.phase == .finished)
        #expect(try store.count() == 7)
    }

    /// The converse, or the fix above would just be "never reconcile an empty
    /// folder": when the rows are on the volume that answered, an emptied
    /// folder does reconcile to nothing.
    @Test func anEmptyRootOnTheSameVolumeStillReconciles() async throws {
        let scanRoot = try tree.directory("photos")
        for i in 0..<3 { try tree.file("photos/img\(i).jpg") }
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        #expect(try store.count() == 3)

        for i in 0..<3 {
            try FileManager.default.removeItem(at: scanRoot.appendingPathComponent("img\(i).jpg"))
        }
        _ = try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        #expect(try store.count() == 0)
    }

    /// The check is per row, not per pass: a scan that legitimately reconciles
    /// its own volume's rows must not be disabled by the presence of rows from
    /// another one, and must not judge them either.
    @Test func rowsFromAnotherVolumeSurviveAScanThatReconcilesItsOwn() async throws {
        let scanRoot = try tree.directory("photos")
        let doomed = try tree.file("photos/gone.jpg")
        try tree.file("photos/stays.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        for i in 0..<4 {
            try store.upsert(plantedRecord(path: scanRoot.appendingPathComponent("old\(i).jpg").path,
                                           device: foreignDevice))
        }
        #expect(try store.count() == 6)

        try FileManager.default.removeItem(at: doomed)
        _ = try await coordinator.indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        #expect(try store.record(atPath: doomed.path) == nil)       // its own volume, reconciled
        #expect(try store.record(atPath: path("photos/stays.jpg")) != nil)
        for i in 0..<4 {                                            // the other volume, untouched
            #expect(try store.record(atPath: path("photos/old\(i).jpg")) != nil)
        }
        #expect(try store.count() == 5)
    }

    /// The upgrade end to end: a populated v1 index, migrated by opening it,
    /// then a tier 0 pass over the tree it describes.
    ///
    /// The planted rows' size and mtime match the files on disk exactly, so
    /// tier 0 re-reads none of them — which is the point. Tier 0 only upserts a
    /// file whose bytes changed, so a backfill that rode along on the upsert
    /// would leave `volume_uuid` NULL on a real library until the user edited
    /// every photo in it.
    @Test(.enabled(if: temporaryVolumeUUID != nil,
                   "the temporary directory's volume publishes no UUID"))
    func aTier0PassFillsTheVolumeOfRowsMigratedFromV1() async throws {
        let photos = try tree.directory("photos")
        var planted: [(path: String, size: Int64, mtime: Double)] = []
        for i in 0..<4 {
            let url = try tree.file("photos/img\(i).jpg", bytes: 16 + i)
            var st = stat()
            #expect(stat(url.path, &st) == 0)
            // The same arithmetic `Walker` does, or the rows would read stale
            // and the pass would re-upsert them — proving nothing.
            let mtime = Double(st.st_mtimespec.tv_sec)
                + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
            planted.append((url.path, Int64(st.st_size), mtime))
        }

        let indexURL = tree.root.appendingPathComponent("v1/index.sqlite")
        try makeV1Index(at: indexURL) { db in
            for file in planted {
                try insertV1Row(db, path: file.path, size: file.size, mtime: file.mtime,
                                device: foreignDevice)
            }
        }

        let store = try IndexStore(url: indexURL)
        for file in planted {
            #expect(try store.record(atPath: file.path)?.volumeUUID == nil)
        }

        let progress = try await makeCoordinator(store)
            .indexTier0(root: photos, recursive: true, onProgress: nil)
        #expect(progress.total == 4)
        #expect(progress.completed == 0)      // nothing was stale, so nothing was re-read
        #expect(try store.count() == 4)
        for file in planted {
            let row = try #require(try store.record(atPath: file.path))
            #expect(row.volumeUUID == temporaryVolumeUUID)
            #expect(row.device != foreignDevice)   // the stale mount id is refreshed with it
        }
        try store.close()
    }

    /// A volume swapped out *while the walk runs*. The pass then holds results
    /// gathered from one filesystem and a root answered by another, and neither
    /// of its two writes may proceed.
    ///
    /// The delete is the obvious one. The stamp is the dangerous one: it would
    /// brand every row the walk produced — real files, off the real drive —
    /// with the impostor's identity. Nothing would be deleted that pass, and
    /// the damage would be silent and permanent, because a later pass on the
    /// real volume would then match those rows by neither UUID nor device and
    /// could never prune them again. Ghosts with no way back but a rebuild.
    @Test func aVolumeSwappedDuringTheWalkWritesNoVolumeStampAndDeletesNothing() async throws {
        let doomed = try tree.file("gone.jpg")
        try tree.file("stays.jpg")
        let store = try IndexStore.inMemory()
        let real = VolumeIdentity(device: 16, uuid: "REAL-VOLUME")
        let impostor = VolumeIdentity(device: 16, uuid: "IMPOSTOR")

        // A clean pass first, so the rows carry the real volume's identity.
        _ = try await makeCoordinatorSeeing(store, volumes: [real])
            .indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 2)
        #expect(try store.record(atPath: path("stays.jpg"))?.volumeUUID == "REAL-VOLUME")

        // Now the swap: the walk starts on the real volume and finishes with
        // the impostor answering. A file really did vanish, so a pass that
        // trusted itself would prune it.
        try FileManager.default.removeItem(at: doomed)
        let swapped = makeCoordinatorSeeing(store, volumes: [real, impostor])
        await #expect(throws: IndexCoordinatorError.rootUnreadable(tree.root.path)) {
            try await swapped.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        }

        #expect(try store.count() == 2)                                    // nothing deleted
        for name in ["gone.jpg", "stays.jpg"] {                            // nothing re-stamped
            #expect(try store.record(atPath: path(name))?.volumeUUID == "REAL-VOLUME")
        }
        // "WritesNoVolumeStamp", not "WritesNothing": the gate sits after the
        // per-entry upserts, so rows for files the walk collected can already
        // be in the index when it throws. Deliberate, and recoverable — see the
        // note on `indexTier0`.

        // And the proof that the guard, not a broken fixture, is what stopped
        // it: the same pass on a stable volume prunes the row.
        _ = try await makeCoordinatorSeeing(store, volumes: [real])
            .indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.record(atPath: doomed.path) == nil)
        #expect(try store.count() == 1)
    }

    /// The sharper form of the test above, and the one `st_dev` alone cannot
    /// pass: the rows claim a *different* volume while carrying the device id
    /// of the one that is actually mounted. A replug renumbers `st_dev`, so
    /// this collision is not hypothetical — a device-only check would read
    /// these rows as its own and delete every one of them.
    @Test func rowsFromAnotherVolumeSurviveEvenWhenTheDeviceIDCollides() async throws {
        let scanRoot = try tree.directory("photos")
        var st = stat()
        #expect(stat(scanRoot.path, &st) == 0)
        let store = try IndexStore.inMemory()
        for i in 0..<7 {
            try store.upsert(plantedRecord(path: scanRoot.appendingPathComponent("img\(i).jpg").path,
                                           device: Int64(st.st_dev),
                                           volumeUUID: foreignVolumeUUID))
        }
        #expect(try store.count() == 7)

        let progress = try await makeCoordinator(store)
            .indexTier0(root: scanRoot, recursive: true, onProgress: nil)
        #expect(progress.total == 0)          // the walk really did see an empty folder
        #expect(try store.count() == 7)
    }

    /// The case this app's own hardware produces every time the Seagate is
    /// replugged: `st_dev` is handed out at mount time, so the same volume
    /// comes back with a different one and every existing row starts to look
    /// like it came from another filesystem. Under a device-only check the
    /// reconcile then silently stops pruning — files deleted outside the app
    /// stay in the grid as ghosts until the index is rebuilt. The volume UUID
    /// is what survives the replug, so the prune must still happen.
    @Test(.enabled(if: temporaryVolumeUUID != nil,
                   "the temporary directory's volume publishes no UUID"))
    func aReplugThatRenumbersTheDeviceStillReconciles() async throws {
        let doomed = try tree.file("gone.jpg")
        try tree.file("stays.jpg")
        let store = try IndexStore.inMemory()
        let coordinator = makeCoordinator(store)
        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.count() == 2)

        // The replug, as the index sees it: same volume, same files, a
        // mount-time device id that now matches nothing.
        try store.testExecute(sql: "UPDATE files SET device = ?", arguments: [foreignDevice])
        try FileManager.default.removeItem(at: doomed)

        _ = try await coordinator.indexTier0(root: tree.root, recursive: true, onProgress: nil)
        #expect(try store.record(atPath: doomed.path) == nil)
        #expect(try store.record(atPath: path("stays.jpg")) != nil)
        #expect(try store.count() == 1)
    }

    @Test func theVolumeCheckAppliesToANonRecursiveScanToo() async throws {
        let scanRoot = try tree.directory("photos")
        let store = try IndexStore.inMemory()
        for i in 0..<7 {
            try store.upsert(plantedRecord(path: scanRoot.appendingPathComponent("img\(i).jpg").path,
                                           device: foreignDevice))
        }
        _ = try await makeCoordinator(store)
            .indexTier0(root: scanRoot, recursive: false, onProgress: nil)
        #expect(try store.count() == 7)
    }

    // MARK: - Progress

    @Test func tier0ReportsProgressMonotonically() async throws {
        // Enough files that the pass must report from inside the loop and not
        // only at the phase boundaries — the batched report is the branch the
        // monotonicity claim is actually about.
        for i in 0..<60 { try tree.file("img\(i).jpg") }
        let store = try IndexStore.inMemory()

        let box = LockBox<[IndexProgress]>([])
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
        // At least one sample from mid-pass, or the three phase-boundary
        // samples would satisfy every assertion above on their own.
        #expect(seen.contains { $0.phase == .reading && $0.completed > 0
                                && $0.completed < $0.total })
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
        let reads = LockBox(0)
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
