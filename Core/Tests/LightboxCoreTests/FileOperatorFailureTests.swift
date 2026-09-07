import Testing
import Foundation
@testable import LightboxCore

@discardableResult
private func index(_ url: URL, into store: IndexStore) throws -> Int64 {
    var st = stat()
    guard stat(url.path, &st) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return try store.upsert(FileRecord(
        id: nil, path: url.path,
        parentDir: url.deletingLastPathComponent().path,
        name: url.lastPathComponent, ext: url.pathExtension.lowercased(),
        size: Int64(st.st_size),
        mtime: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000,
        device: Int64(st.st_dev), inode: Int64(bitPattern: UInt64(st.st_ino)),
        volumeUUID: nil, width: 100, height: 100,
        captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
        orientation: nil, contentHash: "hash-\(url.lastPathComponent)",
        imageHash: nil, imageHashKind: nil, phash: nil,
        hashedAt: 1_700_000_100, indexedAt: 1_700_000_000))
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// A copier that hands every call to `body`, so a test can stage the errno the
/// real filesystem will not produce on demand.
private func stubCopier(_ body: @escaping @Sendable (URL, URL, Int) throws -> Void)
    -> FileOperator.Copying {
    let calls = LockBox(0)
    return { source, destination, _ in
        let n = calls.withLock { $0 += 1; return $0 }
        try body(source, destination, n)
    }
}

/// Copies for real. Used where a test wants some calls to succeed and one to
/// fail.
private func reallyCopy(_ source: URL, _ destination: URL) throws {
    try FileManager.default.copyItem(at: source, to: destination)
}

struct FileOperatorFailureTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The gap between planning and executing is real and cannot be closed by
    /// a longer pre-flight, so it is handled: the item fails with a reason, its
    /// journal row says `failed`, and its index row is left exactly as it was
    /// for the next tier 0 pass to reconcile.
    @Test func aSourceRemovedBetweenPlanAndExecuteFails() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 32)
        let survivor = try tree.file("from/IMG_0002.jpg", bytes: 32)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)
        try index(survivor, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source, survivor],
                                     destination: destination)
        try FileManager.default.removeItem(at: source)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.sourceVanished))
        // The batch never fails as a unit (spec §11): item two still runs.
        #expect(results[1].outcome == .completed)

        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.first { $0.src == source.path }?.state == .failed)
        #expect(rows.first { $0.src == survivor.path }?.state == .complete)
        #expect(try store.record(atPath: source.path) != nil)
    }

    /// A destination the user cannot write into. `chmod 0o500` is a real
    /// permission failure against a real directory, not an injected one.
    @Test func aDestinationThatCannotBeWrittenToFails() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 32)
        _ = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source],
                                     destination: tree.root.appendingPathComponent("to"))
        let destination = try tree.chmod("to", 0o500)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.permissionDenied))
        #expect(exists(source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
        #expect(try store.record(atPath: source.path) != nil)
    }

    /// A source the user cannot remove: readable, in a directory that is not
    /// writable, so `rename(2)` out of it is refused.
    @Test func aSourceThatCannotBeMovedOutOfItsFolderFails() async throws {
        let source = try tree.file("locked/IMG_0001.jpg", bytes: 32)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        try tree.chmod("locked", 0o500)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.permissionDenied))
        #expect(exists(source))
    }

    /// Disk full. A 2 MB disk image would exercise the same code path at the
    /// cost of `hdiutil` in CI and a mount that has to be cleaned up on every
    /// failure path; the errno is injected instead, and the thing under test —
    /// that `ENOSPC` maps to `diskFull`, leaves nothing behind, and journals
    /// `failed` — is the same either way.
    @Test func aFullDestinationFails() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 32)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store,
                              copier: stubCopier { _, _, _ in throw POSIXError(.ENOSPC) })
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        let results = try await op.execute(plan)

        #expect(results[0].outcome == .failed(.diskFull))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try store.count() == 1)
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.failed])
    }

    /// A read-only filesystem, which needs a real read-only mount to produce
    /// and is injected for the same reason as `ENOSPC`. It is a distinct reason
    /// from `permissionDenied` because no `chmod` fixes it, and the summary
    /// sheet should not offer one.
    @Test func aReadOnlyDestinationFails() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 32)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()

        let op = FileOperator(store: store,
                              copier: stubCopier { _, _, _ in throw POSIXError(.EROFS) })
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.destinationReadOnly))
    }

    /// The case external drives make routine. Once the volume stops answering,
    /// **the remaining items are marked skipped rather than attempted**: a
    /// batch that keeps trying produces a page of identical failures, and if
    /// something else mounts at that path the attempts would land on it.
    @Test func aVolumeThatGoesAwayMidBatchSkipsTheRestWithoutAttemptingThem() async throws {
        let sources = try (0..<4).map { try tree.file("from/IMG_000\($0).jpg", bytes: 16) }
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }

        let unplugged = LockBox(false)
        let op = FileOperator(store: store, volumeReader: { url in
            unplugged.withLock { $0 } ? nil : VolumeIdentity(ofDirectory: url)
        })
        let plan = try await op.plan(kind: .move, sources: sources, destination: destination)
        let results = try await op.execute(plan) { completed, _, _ in
            if completed == 1 { unplugged.withLock { $0 = true } }
        }

        #expect(results[0].outcome == .completed)
        #expect(results.dropFirst().allSatisfy { $0.outcome == .skipped(.volumeUnmounted) })
        // Not attempted: the three sources are still where they were.
        for source in sources.dropFirst() { #expect(exists(source)) }
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.filter { $0.state == .complete }.count == 1)
        #expect(rows.filter { $0.state == .skipped }.count == 3)
        #expect(rows.contains { $0.state == .inFlight } == false)
    }

    /// The journal acceptance bullet's second half: **a batch interrupted by a
    /// thrown error leaves the un-attempted rows `in_flight` and the attempted
    /// ones `complete`.** `in_flight` is not a bookkeeping leak, it is the
    /// signal — it means "nobody recorded what happened here, ask the
    /// filesystem", which is exactly what #6's launch-time reconcile does.
    @Test func cancellingMidBatchLeavesTheUnattemptedRowsInFlight() async throws {
        let sources = try (0..<4).map { try tree.file("from/IMG_000\($0).jpg", bytes: 16) }
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }

        let handle = LockBox<Task<[FileOperationResult], any Error>?>(nil)
        let installed = LockBox(false)
        // Cancellation is checked *between* items, so cancelling from inside
        // the third copy ends the batch after three completed items.
        let op = FileOperator(store: store, copier: stubCopier { source, destination, call in
            if call == 3 { handle.withLock { $0?.cancel() } }
            try reallyCopy(source, destination)
        })
        let plan = try await op.plan(kind: .copy, sources: sources, destination: destination)

        let task = Task { () -> [FileOperationResult] in
            while !installed.withLock({ $0 }) { await Task.yield() }
            return try await op.execute(plan)
        }
        handle.withLock { $0 = task }
        installed.withLock { $0 = true }

        // The results of everything already finished travel out with the
        // error: a cancelled batch has moved files and rewritten rows, and #7's
        // summary sheet has to be able to say what it managed.
        let completed = await #expect(throws: FileOperatorError.self) {
            _ = try await task.value
        }
        guard case .cancelled(let done)? = completed else {
            Issue.record("expected .cancelled, got \(String(describing: completed))")
            return
        }
        #expect(done.count == 3)
        #expect(done.allSatisfy { $0.outcome == .completed })

        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.count == 4)
        #expect(rows.prefix(3).allSatisfy { $0.state == .complete })
        #expect(rows[3].state == .inFlight)
        // Completed items stay done, on disk and in the index.
        #expect(try store.count() == 7)
        #expect(exists(destination.appendingPathComponent("IMG_0002.jpg")))
        #expect(!exists(destination.appendingPathComponent("IMG_0003.jpg")))
    }

    /// A cross-volume move is a copy and then a delete, journalled as one
    /// `move` row carrying both paths — which is what lets #6's reconcile see
    /// "src exists AND dst exists" and know the copy landed but the delete did
    /// not.
    @Test func aCrossVolumeMoveCopiesThenDeletesAndJournalsBothPaths() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 48)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store, volumeReader: { url in
            // Two volumes that are really one directory tree, so the
            // cross-volume branch runs against a real filesystem.
            VolumeIdentity(device: url.path.contains("/to") ? 2 : 1,
                           uuid: url.path.contains("/to") ? "VOL-B" : "VOL-A")
        }, copier: stubCopier { source, destination, _ in
            try reallyCopy(source, destination)
        })
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        let results = try await op.execute(plan)

        #expect(results[0].outcome == .completed)
        #expect(!exists(source))
        let moved = destination.appendingPathComponent("IMG_0001.jpg")
        #expect(exists(moved))
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows[0].kind == .move)
        #expect(rows[0].src == source.path)
        #expect(rows[0].dst == moved.path)
        #expect(rows[0].state == .complete)
        let row = try #require(try store.record(atPath: moved.path))
        #expect(row.contentHash == "hash-IMG_0001.jpg")
    }

    /// An item is all-or-nothing for a move: a failure on the sidecar puts the
    /// image back. Splitting a RAW from its `.xmp` is the failure mode
    /// companion handling exists to prevent, and a half-applied item would
    /// create it rather than avoid it.
    @Test func aCompanionFailureRollsTheWholeItemBack() async throws {
        let raw = try tree.file("from/IMG_0001.CR2", bytes: 48)
        let sidecar = try tree.file("from/IMG_0001.xmp", bytes: 6)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(raw, into: store)

        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.contains("/to") ? 2 : 1,
                           uuid: url.path.contains("/to") ? "VOL-B" : "VOL-A")
        }, copier: stubCopier { source, destination, _ in
            guard source.pathExtension != "xmp" else { throw POSIXError(.ENOSPC) }
            try reallyCopy(source, destination)
        })
        let plan = try await op.plan(kind: .move, sources: [raw], destination: destination)
        #expect(plan.items[0].companions == [sidecar])

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.diskFull))
        // Both halves still in the source folder, nothing left in the target.
        #expect(exists(raw))
        #expect(exists(sidecar))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try store.journalRows(batchID: plan.batchID)
                .allSatisfy { $0.state == .failed })
        #expect(try store.record(atPath: raw.path) != nil)
    }

    /// The one outcome the operator will not describe. A cross-volume move
    /// whose copy landed and whose source removal failed leaves both paths
    /// present; marking that `complete` or `failed` would both be lies, so the
    /// row stays `in_flight` for the reconcile to settle against the
    /// filesystem.
    @Test func aCrossVolumeMoveThatCannotRemoveItsSourceStaysInFlight() async throws {
        let source = try tree.file("locked/IMG_0001.jpg", bytes: 48)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store, volumeReader: { url in
            VolumeIdentity(device: url.path.contains("/to") ? 2 : 1,
                           uuid: url.path.contains("/to") ? "VOL-B" : "VOL-A")
        }, copier: stubCopier { source, destination, _ in
            try reallyCopy(source, destination)
        })
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        try tree.chmod("locked", 0o500)

        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.sourceRemovalFailed))
        #expect(exists(source))
        #expect(exists(destination.appendingPathComponent("IMG_0001.jpg")))
        #expect(try store.journalRows(batchID: plan.batchID).map(\.state) == [.inFlight])
        // The index still describes the source, which is the truth about the
        // path it names; the reconcile is what decides the rest.
        #expect(try store.record(atPath: source.path) != nil)
    }

    /// A stale plan must be a no-op, not a corruption. `files.id` is a reused
    /// rowid, so the guard is on id *and* path — the `setHashes(for:)` rule,
    /// applied to the writes that move and delete rows.
    @Test func aRowThatNoLongerMatchesThePlannedPathIsNotRewritten() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 32)
        let store = try IndexStore.inMemory()
        let id = try index(source, into: store)

        let destination = tree.root.appendingPathComponent("to/IMG_0001.jpg")
        // The row now describes a different file at a different path, exactly
        // as it would after a reconcile deleted this row and SQLite handed the
        // id to the next file indexed.
        try store.testExecute(sql: "UPDATE files SET path = ?, name = ? WHERE id = ?",
                              arguments: ["/elsewhere/other.jpg", "other.jpg", id])
        let applied = try store.applyAndMark(
            [.move(id: id, fromPath: source.path, to: destination)], marks: [])
        #expect(applied == 0)
        let row = try #require(try store.record(atPath: "/elsewhere/other.jpg"))
        #expect(row.name == "other.jpg")
    }
}
