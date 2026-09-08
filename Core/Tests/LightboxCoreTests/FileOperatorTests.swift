import Testing
import Foundation
@testable import LightboxCore

// MARK: - Support

/// Stats `url` and writes a row for it, so a test's index and its temp tree
/// describe the same files. Hashes are handed in rather than computed: what
/// these tests care about is whether a hash *survives* an operation, not what
/// it is.
@discardableResult
private func index(_ url: URL, into store: IndexStore,
                   contentHash: String? = nil, imageHash: String? = nil,
                   imageHashKind: String? = nil, phash: String? = nil,
                   volumeUUID: String? = nil) throws -> FileRecord {
    var st = stat()
    guard stat(url.path, &st) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let record = FileRecord(
        id: nil, path: url.path,
        parentDir: url.deletingLastPathComponent().path,
        name: url.lastPathComponent,
        ext: url.pathExtension.lowercased(),
        size: Int64(st.st_size),
        mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
        device: Int64(st.st_dev), inode: Int64(st.st_ino), volumeUUID: volumeUUID,
        width: 4000, height: 3000,
        captureTime: 1_700_000_000, captureOffset: nil,
        cameraMake: "Canon", cameraModel: "EOS R5", orientation: 1,
        contentHash: contentHash, imageHash: imageHash, imageHashKind: imageHashKind,
        phash: phash, hashedAt: contentHash == nil ? nil : 1_700_000_100,
        indexedAt: 1_700_000_000)
    let id = try store.upsert(record)
    return try #require(try store.record(atPath: url.path)).with(id: id)
}

private extension FileRecord {
    func with(id: Int64) -> FileRecord {
        var copy = self
        copy.id = id
        return copy
    }
}

private func journalStates(_ store: IndexStore, _ batchID: String) throws -> [OpJournalState] {
    try store.journalRows(batchID: batchID).map(\.state)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Removes whatever a batch put in the Trash, so a test run does not
/// accumulate files in the developer's Trash.
///
/// Driven off the journal rather than off the results, and registered before
/// the batch runs rather than after: every trashed file has a `trash_url` row
/// whatever the batch then does, whereas a result carries one only for an item
/// that completed. A test whose cleanup depends on the thing under test
/// succeeding leaks precisely when the code is broken — which is exactly when
/// the suite is being run over and over.
private func emptyTrash(of store: IndexStore, batchID: String) {
    for row in (try? store.journalRows(batchID: batchID)) ?? [] {
        guard let path = row.trashURL else { continue }
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - Move, journal, index

struct FileOperatorMoveTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The acceptance bullet for the index: after a move, `search` finds the
    /// record under the new `parent_dir`, with its hashes intact. Hashes are
    /// the expensive column and a move does not change a byte of the file, so
    /// losing them would silently re-queue the whole batch for tier 1.
    @Test func movingAFileRewritesItsRowAndKeepsItsHashes() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "content-abc", imageHash: "image-abc",
                  imageHashKind: "jpeg-v1", phash: "ffff0000ffff0000")

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        #expect(plan.items.count == 1)
        #expect(!plan.hasUnresolvedCollisions)

        let results = try await op.execute(plan)
        #expect(results.count == 1)
        #expect(results[0].outcome == .completed)

        let moved = destination.appendingPathComponent("IMG_0001.jpg")
        #expect(exists(moved))
        #expect(!exists(source))

        let hits = try store.search(SearchQuery(
            scope: .folder(path: destination.path, recursive: false)))
        #expect(hits.count == 1)
        let row = try #require(hits.first)
        #expect(row.path == moved.path)
        #expect(row.parentDir == destination.path)
        #expect(row.name == "IMG_0001.jpg")
        #expect(row.contentHash == "content-abc")
        #expect(row.imageHash == "image-abc")
        #expect(row.phash == "ffff0000ffff0000")
        #expect(try store.record(atPath: source.path) == nil)
    }

    /// `files_fts` is a standalone FTS5 table, so nothing maintains it but the
    /// code that writes `files`. A move that changes `name` and leaves the FTS
    /// row behind makes filename search answer with the old name forever.
    @Test func movingAFileUnderARenameUpdatesTheFTSRow() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        // An existing file with the same name forces the rename policy.
        try tree.file("to/IMG_0001.jpg", bytes: 8)
        let store = try IndexStore.inMemory()
        let record = try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        let results = try await op.execute(plan.resolvingAllCollisions(with: .rename))
        #expect(results[0].outcome == .completed)

        let moved = destination.appendingPathComponent("IMG_0001 2.jpg")
        #expect(exists(moved))
        #expect(!exists(source))
        // The file that forced the rename is untouched.
        #expect(try Data(contentsOf: destination.appendingPathComponent("IMG_0001.jpg"))
                .count == 8)
        let row = try #require(try store.record(atPath: moved.path))
        #expect(row.name == "IMG_0001 2.jpg")
        #expect(try store.ftsMatchRowIDs("\"IMG_0001 2.jpg\"") == [record.id!])
        #expect(try store.ftsMatchRowIDs("\"IMG_0001.jpg\"").isEmpty)
    }

    /// The journal acceptance bullet: after a successful batch every row is
    /// `complete`, and the rows carry the paths #6's undo will reverse.
    @Test func aSuccessfulBatchLeavesEveryJournalRowComplete() async throws {
        let sources = try (0..<3).map { try tree.file("from/IMG_000\($0).jpg", bytes: 32) }
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: sources, destination: destination)
        let results = try await op.execute(plan)
        #expect(results.allSatisfy { $0.outcome == .completed })

        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.state == .complete })
        #expect(rows.allSatisfy { $0.kind == .move })
        #expect(Set(rows.map(\.src)) == Set(sources.map(\.path)))
        #expect(Set(rows.compactMap(\.dst))
                == Set(sources.map { destination.appendingPathComponent($0.lastPathComponent).path }))
    }

    /// Progress is what the sheet in #7 binds to: one callback per finished
    /// item, counting up to the item total.
    @Test func executeReportsProgressPerItem() async throws {
        let sources = try (0..<4).map { try tree.file("from/f\($0).jpg", bytes: 16) }
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }

        let seen = LockBox<[(Int, Int)]>([])
        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: sources, destination: destination)
        _ = try await op.execute(plan) { completed, total, _ in
            seen.withLock { $0.append((completed, total)) }
        }
        let observed = seen.withLock { $0 }
        #expect(observed.map(\.0) == [1, 2, 3, 4])
        #expect(observed.allSatisfy { $0.1 == 4 })
    }
}

// MARK: - Copy

struct FileOperatorCopyTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    /// The copy carries the source's hashes: the bytes are identical, and
    /// re-hashing 50,000 copies is waste. It must be a *new* row — the source
    /// stays exactly where it was.
    @Test func copyingInsertsANewRowCarryingTheHashes() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "content-abc", imageHash: "image-abc",
                  imageHashKind: "jpeg-v1", phash: "0f0f0f0f0f0f0f0f")

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        let results = try await op.execute(plan)
        #expect(results[0].outcome == .completed)

        #expect(exists(source))
        let copied = destination.appendingPathComponent("IMG_0001.jpg")
        #expect(exists(copied))
        #expect(try store.count() == 2)

        let new = try #require(try store.record(atPath: copied.path))
        #expect(new.contentHash == "content-abc")
        #expect(new.imageHash == "image-abc")
        #expect(new.imageHashKind == "jpeg-v1")
        #expect(new.phash == "0f0f0f0f0f0f0f0f")
        #expect(new.hashedAt != nil)
        #expect(new.width == 4000)
        let original = try #require(try store.record(atPath: source.path))
        #expect(new.id != original.id)
    }

    /// Hash carry-over is only valid for a byte-identical copy. A copy that
    /// produced a short file is a failure, not a row: the destination is
    /// removed, the index is untouched, and tier 1 is never told a truncated
    /// file has the original's hashes.
    @Test func aTruncatedCopyFailsAndWritesNothingToTheIndex() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "content-abc", imageHash: "image-abc")

        // A copier that writes half the bytes and returns success, which is
        // what a filesystem that ran out of room under a buffered write does.
        let op = FileOperator(store: store, copier: { src, dst, _ in
            let bytes = try Data(contentsOf: src)
            try bytes.prefix(bytes.count / 2).write(to: dst)
        })
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        let results = try await op.execute(plan)
        #expect(results[0].outcome == .failed(.copyIncomplete))

        #expect(exists(source))
        #expect(!exists(destination.appendingPathComponent("IMG_0001.jpg")))
        #expect(try store.count() == 1)
        #expect(try journalStates(store, plan.batchID) == [.failed])
    }

    /// Hashes describe bytes. If the source changed between the pass that
    /// hashed it and this copy, carrying them over would stamp a stale digest
    /// onto a new row — the `setHashes(for:)` failure mode, with a copy in
    /// place of a rowid reuse. The copy still happens; the hashes do not.
    @Test func aSourceChangedSinceItWasHashedCopiesWithoutItsHashes() async throws {
        let source = try tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "content-abc", imageHash: "image-abc")
        // Rewrite the file: same path, different size, so the row's hashes no
        // longer describe it.
        try Data(repeating: 0x42, count: 128).write(to: source)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        let results = try await op.execute(plan)
        #expect(results[0].outcome == .completed)

        let new = try #require(
            try store.record(atPath: destination.appendingPathComponent("IMG_0001.jpg").path))
        #expect(new.contentHash == nil)
        #expect(new.imageHash == nil)
        #expect(new.hashedAt == nil)
        #expect(new.size == 128)
    }
}

// MARK: - Trash and delete

struct FileOperatorRemovalTests {
    let tree: TempTree

    init() throws { tree = try TempTree() }

    @Test func trashingRecordsTheResultingURLAndRemovesTheRow() async throws {
        let source = try tree.file("lib/\(tree.uniqueName("IMG_0001", ext: "jpg"))", bytes: 64)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: [source], destination: nil)
        defer { emptyTrash(of: store, batchID: plan.batchID) }
        let results = try await op.execute(plan)

        #expect(results[0].outcome == .completed)
        let trashURL = try #require(results[0].trashURL)
        #expect(exists(trashURL))
        #expect(!exists(source))
        #expect(try store.record(atPath: source.path) == nil)

        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .trash)
        #expect(rows[0].state == .complete)
        // The recorded Trash URL is the whole reason trashing is undoable.
        #expect(rows[0].trashURL == trashURL.path)
    }

    @Test func deletingIsADistinctKindThatRemovesTheFileOutright() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 64)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)
        let results = try await op.execute(plan)

        #expect(results[0].outcome == .completed)
        #expect(results[0].trashURL == nil)
        #expect(!exists(source))
        #expect(try store.record(atPath: source.path) == nil)
        let rows = try store.journalRows(batchID: plan.batchID)
        #expect(rows[0].kind == .delete)
        #expect(rows[0].state == .complete)
        #expect(rows[0].dst == nil)
    }

    /// A destination is meaningless for trash and delete, and a move with no
    /// destination has nowhere to go. Both are programmer errors caught before
    /// a single journal row is written.
    @Test func aPlanWithAMismatchedDestinationThrows() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 8)
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        await #expect(throws: FileOperatorError.destinationRequired) {
            _ = try await op.plan(kind: .move, sources: [source], destination: nil)
        }
        await #expect(throws: FileOperatorError.destinationNotAllowed) {
            _ = try await op.plan(kind: .trash, sources: [source],
                                  destination: tree.root)
        }
    }

    /// A destination that is not there is caught at plan time. The realistic
    /// cause is the one this app is built around: the drive was unplugged
    /// between the user picking a folder and the batch being run.
    @Test func aDestinationThatIsNotThereIsRefusedAtPlanTime() async throws {
        let source = try tree.file("lib/IMG_0001.jpg", bytes: 8)
        let missing = tree.root.appendingPathComponent("no-such-folder")
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        await #expect(throws: FileOperatorError.destinationUnreadable(missing.path)) {
            _ = try await op.plan(kind: .move, sources: [source], destination: missing)
        }
    }
}
