import Testing
import Foundation
@testable import LightboxCore

// MARK: - Support

@discardableResult
private func index(_ url: URL, into store: IndexStore,
                   contentHash: String? = nil, phash: String? = nil) throws -> FileRecord {
    var st = stat()
    guard stat(url.path, &st) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let record = FileRecord(
        id: nil, path: url.path,
        parentDir: url.deletingLastPathComponent().path,
        name: url.lastPathComponent, ext: url.pathExtension.lowercased(),
        size: Int64(st.st_size),
        mtime: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000,
        device: Int64(st.st_dev), inode: Int64(bitPattern: UInt64(st.st_ino)),
        volumeUUID: nil, width: 4000, height: 3000,
        captureTime: 1_700_000_000, captureOffset: nil,
        cameraMake: "Canon", cameraModel: "EOS R5", orientation: 1,
        contentHash: contentHash, imageHash: nil, imageHashKind: nil, phash: phash,
        hashedAt: contentHash == nil ? nil : 1_700_000_100,
        indexedAt: 1_700_000_000)
    _ = try store.upsert(record)
    return try #require(try store.record(atPath: url.path))
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
private func bytes(_ url: URL) throws -> Int { try Data(contentsOf: url).count }

/// Removes anything these batches put in the developer's real Trash.
///
/// Driven off the journal rather than off the results, and registered before the
/// batch runs: every trashed file has a `trash_url` row whatever the batch then
/// does, whereas a result carries one only for an item that completed. Cleanup
/// that depends on the code under test succeeding leaks precisely when the code
/// is broken — which is when the suite is being run over and over.
///
/// **Plural, because an undo trashes too.** Reversing a copy puts the copy in
/// the Trash under the *undo* batch's rows, and emptying only the original
/// batch's would leave those behind.
private func emptyTrash(of store: IndexStore, batchIDs: [String?]) {
    for batchID in batchIDs.compactMap({ $0 }) {
        for row in (try? store.journalRows(batchID: batchID)) ?? [] {
            guard let path = row.trashURL else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

private func outcomes(_ batch: UndoBatch) -> [FileOperationOutcome] {
    batch.results.map(\.outcome)
}

/// Writes one `op_journal` row by hand, for the states no successful batch
/// produces.
private func journalRow(_ store: IndexStore, batch: String, kind: String, src: URL,
                        state: String) throws {
    try store.testExecute(sql: """
        INSERT INTO op_journal (batch_id, kind, src, dst, trash_url, timestamp, state)
        VALUES (?,?,?,NULL,NULL,?,?)
        """, arguments: [batch, kind, src.path, Date().timeIntervalSince1970, state])
}

// MARK: - Reversing each kind

struct FileOperatorUndoKindTests {
    let tree: TempTree
    /// A per-test tag on every fixture filename.
    ///
    /// **The Trash is one shared directory** and `swift test` runs test
    /// functions in parallel. Two tests that both trash an `IMG_0001.jpg`
    /// contend for one Trash path — harmless on its own, because the Trash
    /// renames on collision — but a test that *restores* from the Trash frees
    /// the name again, and the next test's journal-driven cleanup then deletes
    /// whatever took it. That failed about one run in three before the tag.
    let tag = String(UUID().uuidString.prefix(8))

    init() throws { tree = try TempTree() }

    /// A move is undone by moving it back — row, FTS entry and hashes with it.
    /// The assertion that matters is **where the photo is**, not what the
    /// journal says about it.
    @Test func undoingAMovePutsThePhotosAndTheirRowsBack() async throws {
        let sources = try (0..<3).map { try tree.file("from/IMG_000\($0)-\(tag).jpg", bytes: 32) }
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for (n, source) in sources.enumerated() {
            try index(source, into: store, contentHash: "content-\(n)")
        }

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: sources, destination: destination)
        _ = try await op.execute(plan)
        #expect(sources.allSatisfy { !exists($0) })

        let undone = try await op.undo(batch: plan.batchID)
        #expect(outcomes(undone) == [.completed, .completed, .completed])
        for (n, source) in sources.enumerated() {
            #expect(exists(source))
            #expect(!exists(destination.appendingPathComponent(source.lastPathComponent)))
            let row = try #require(try store.record(atPath: source.path))
            #expect(row.parentDir == source.deletingLastPathComponent().path)
            #expect(row.contentHash == "content-\(n)")
            #expect(try store.ftsMatchRowIDs("\"\(source.lastPathComponent)\"")
                    == [try #require(row.id)])
        }
        // The reversal is a batch of its own, journalled as moves in the other
        // direction, which is what makes redo nothing but undo of the undo.
        let rows = try store.journalRows(batchID: undone.batchID)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.kind == .move && $0.state == .complete })
        #expect(Set(rows.map(\.src)) == Set(sources.map {
            destination.appendingPathComponent($0.lastPathComponent).path
        }))
        #expect(Set(rows.compactMap(\.dst)) == Set(sources.map(\.path)))
    }

    /// A copy is undone by **trashing** the copy, never by unlinking it, and the
    /// original is not touched at all. `delete` is the only operation in this
    /// app that destroys a file, and undo is not it.
    @Test func undoingACopyTrashesTheCopyAndLeavesTheOriginal() async throws {
        let source = try tree.file("from/IMG_0001-\(tag).jpg", bytes: 64)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "content-abc")

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .copy, sources: [source], destination: destination)
        var undoBatchID: String?
        defer { emptyTrash(of: store, batchIDs: [plan.batchID, undoBatchID]) }
        _ = try await op.execute(plan)
        let copied = destination.appendingPathComponent("IMG_0001-\(tag).jpg")
        #expect(exists(copied))
        #expect(try store.count() == 2)

        let undone = try await op.undo(batch: plan.batchID)
        undoBatchID = undone.batchID
        #expect(outcomes(undone) == [.completed])
        // The copy is in the Trash, not gone.
        #expect(!exists(copied))
        let trashURL = try #require(undone.results[0].trashURL)
        #expect(exists(trashURL))
        // The original is exactly as it was.
        #expect(exists(source))
        #expect(try bytes(source) == 64)
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
        #expect(try store.record(atPath: copied.path) == nil)
        #expect(try store.count() == 1)
        // A trash, so undoing *this* restores the copy: redo.
        let rows = try store.journalRows(batchID: undone.batchID)
        #expect(rows.map(\.kind) == [.trash])
        #expect(rows[0].trashURL == trashURL.path)
    }

    @Test func undoingATrashRestoresTheFileFromTheRecordedURL() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 64)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: [source], destination: nil)
        var undoBatchID: String?
        defer { emptyTrash(of: store, batchIDs: [plan.batchID, undoBatchID]) }
        #expect(try await op.execute(plan)[0].outcome == .completed)
        #expect(!exists(source))
        let trashURL = try #require(
            try store.journalRows(batchID: plan.batchID)[0].trashURL)

        let undone = try await op.undo(batch: plan.batchID)
        undoBatchID = undone.batchID
        #expect(outcomes(undone) == [.completed])
        // The photo is back at its original path with its bytes, and out of the
        // Trash.
        #expect(exists(source))
        #expect(try bytes(source) == 64)
        #expect(!exists(URL(fileURLWithPath: trashURL)))
    }

    /// A `replace` displaced a photo the user never selected. Undoing the batch
    /// has to put **both** back, and in the right order: the item's own reversal
    /// vacates the destination before the displaced photo can return to it.
    @Test func undoingAReplaceRestoresBothThePhotoAndTheOneItDisplaced() async throws {
        let source = try tree.file("from/IMG_0001-\(tag).jpg", bytes: 10)
        let destination = try tree.directory("to")
        let occupant = try tree.file("to/IMG_0001-\(tag).jpg", bytes: 20)
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "the-mover")
        try index(occupant, into: store, contentHash: "the-displaced")

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source],
                                     destination: destination)
        var undoBatchID: String?
        defer { emptyTrash(of: store, batchIDs: [plan.batchID, undoBatchID]) }
        let results = try await op.execute(plan.resolvingAllCollisions(with: .replace))
        #expect(results[0].outcome == .completed)
        #expect(try bytes(occupant) == 10)  // the mover took the path

        let undone = try await op.undo(batch: plan.batchID)
        undoBatchID = undone.batchID
        #expect(outcomes(undone) == [.completed, .completed])
        // Both photos are back where they started, by their bytes.
        #expect(try bytes(source) == 10)
        #expect(try bytes(occupant) == 20)
        #expect(try store.record(atPath: source.path)?.contentHash == "the-mover")
        // The reversal ran the item first and the aside second: an aside
        // restored before the path was vacated would have failed.
        let rows = try store.journalRows(batchID: undone.batchID)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.state == .complete })
        #expect(rows[0].dst == source.path)
        #expect(rows[1].dst == occupant.path)
    }
}

// MARK: - The per-item failures

/// **Nothing is skipped silently.** Every one of these asserts where the photo
/// physically is as well as what the result says, because a summary sheet that
/// reports a failure over a file that quietly moved anyway is worse than no
/// sheet at all.
struct FileOperatorUndoFailureTests {
    let tree: TempTree
    /// A per-test tag on every fixture filename.
    ///
    /// **The Trash is one shared directory** and `swift test` runs test
    /// functions in parallel. Two tests that both trash an `IMG_0001.jpg`
    /// contend for one Trash path — harmless on its own, because the Trash
    /// renames on collision — but a test that *restores* from the Trash frees
    /// the name again, and the next test's journal-driven cleanup then deletes
    /// whatever took it. That failed about one run in three before the tag.
    let tag = String(UUID().uuidString.prefix(8))

    init() throws { tree = try TempTree() }

    /// The acceptance bullet: one item of the batch has been renamed since, so
    /// that item fails and the other two reverse.
    @Test func aFileRenamedSinceTheBatchFailsAndTheRestReverse() async throws {
        let sources = try (0..<3).map { try tree.file("from/IMG_000\($0)-\(tag).jpg", bytes: 32) }
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: sources, destination: destination)
        _ = try await op.execute(plan)

        // The user renamed one of them in Finder after the move.
        let moved = destination.appendingPathComponent("IMG_0001-\(tag).jpg")
        let renamed = destination.appendingPathComponent("holiday-\(tag).jpg")
        try FileManager.default.moveItem(at: moved, to: renamed)

        let undone = try await op.undo(batch: plan.batchID)
        // Steps run newest row first, so the results are in reverse plan order.
        let bySource = Dictionary(uniqueKeysWithValues:
            undone.results.map { ($0.source.lastPathComponent, $0.outcome) })
        #expect(bySource["IMG_0001-\(tag).jpg"] == .failed(.sourceVanished))
        #expect(bySource["IMG_0000-\(tag).jpg"] == .completed)
        #expect(bySource["IMG_0002-\(tag).jpg"] == .completed)
        // The two that could come back did; the renamed one is untouched where
        // the user left it.
        #expect(exists(sources[0]))
        #expect(exists(sources[2]))
        #expect(!exists(sources[1]))
        #expect(exists(renamed))
        #expect(try bytes(renamed) == 32)
        // A failure means nothing changed, and the row says so.
        let rows = try store.journalRows(batchID: undone.batchID)
        #expect(rows.count { $0.state == .failed } == 1)
        #expect(rows.count { $0.state == .complete } == 2)
    }

    /// A file edited between the batch and the undo is not the file the batch
    /// acted on. Moving it back would reverse an operation that is no longer the
    /// last thing to have happened to that photo.
    @Test func aFileModifiedSinceTheBatchFailsAndStaysWhereItIs() async throws {
        let source = try tree.file("from/IMG_0001-\(tag).jpg", bytes: 32)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "content-abc")

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        _ = try await op.execute(plan)
        let moved = destination.appendingPathComponent("IMG_0001-\(tag).jpg")
        // An external editor rewrote it in place.
        try Data(repeating: 0x42, count: 999).write(to: moved)

        let undone = try await op.undo(batch: plan.batchID)
        #expect(outcomes(undone) == [.failed(.modifiedSinceOperation)])
        #expect(exists(moved))
        #expect(try bytes(moved) == 999)
        #expect(!exists(source))
        #expect(try store.record(atPath: moved.path) != nil)
    }

    /// The live check: trash five, empty the Trash, undo. Five per-item failures
    /// naming the reason, and nothing else touched.
    @Test func anEmptiedTrashIsFivePerItemFailuresAndNothingElse() async throws {
        let sources = try (0..<5).map { try tree.file("lib/IMG_000\($0)-\(tag).jpg", bytes: 16) }
        let bystander = try tree.file("lib/keep-me-\(tag).jpg", bytes: 99)
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }
        try index(bystander, into: store, contentHash: "untouched")

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: sources, destination: nil)
        defer { emptyTrash(of: store, batchIDs: [plan.batchID]) }
        #expect(try await op.execute(plan).allSatisfy { $0.outcome == .completed })

        // "Empty Trash" in Finder, for exactly these five files.
        for row in try store.journalRows(batchID: plan.batchID) {
            try FileManager.default.removeItem(atPath: try #require(row.trashURL))
        }

        let undone = try await op.undo(batch: plan.batchID)
        #expect(undone.results.count == 5)
        #expect(outcomes(undone).allSatisfy { $0 == .failed(.trashEmptied) })
        // Nothing came back, and nothing else moved.
        #expect(sources.allSatisfy { !exists($0) })
        #expect(exists(bystander))
        #expect(try bytes(bystander) == 99)
        #expect(try store.record(atPath: bystander.path)?.contentHash == "untouched")
        #expect(try store.count() == 1)
        let rows = try store.journalRows(batchID: undone.batchID)
        #expect(rows.allSatisfy { $0.state == .failed })
    }

    /// **Undoing a trash must never clobber whatever took the original path.**
    /// After a trash, saving a new export over that path is an ordinary thing to
    /// do, and the undo arriving on top of it would destroy the newer file.
    @Test func undoingATrashNeverOverwritesWhatTookTheOriginalPath() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 64)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .trash, sources: [source], destination: nil)
        defer { emptyTrash(of: store, batchIDs: [plan.batchID]) }
        _ = try await op.execute(plan)
        let trashURL = try #require(
            try store.journalRows(batchID: plan.batchID)[0].trashURL)

        // A new export lands at the path the trashed photo used to hold.
        try Data(repeating: 0x42, count: 4096).write(to: source)

        let undone = try await op.undo(batch: plan.batchID)
        #expect(outcomes(undone) == [.failed(.destinationNotReplaceable)])
        // The newer file is exactly as it was, and the trashed one is still in
        // the Trash rather than half-way between.
        #expect(try bytes(source) == 4096)
        #expect(exists(URL(fileURLWithPath: trashURL)))
        #expect(try bytes(URL(fileURLWithPath: trashURL)) == 64)
    }

    /// The same rule for a move: the original path filled up while the photo was
    /// away, so the move back would overwrite it.
    @Test func undoingAMoveNeverOverwritesWhatTookTheSourcePath() async throws {
        let source = try tree.file("from/IMG_0001-\(tag).jpg", bytes: 32)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        _ = try await op.execute(plan)
        try Data(repeating: 0x42, count: 7).write(to: source)

        let undone = try await op.undo(batch: plan.batchID)
        #expect(outcomes(undone) == [.failed(.destinationNotReplaceable)])
        #expect(try bytes(source) == 7)
        #expect(try bytes(destination.appendingPathComponent("IMG_0001-\(tag).jpg")) == 32)
    }
}

// MARK: - What may be undone at all

struct FileOperatorUndoabilityTests {
    let tree: TempTree
    /// A per-test tag on every fixture filename.
    ///
    /// **The Trash is one shared directory** and `swift test` runs test
    /// functions in parallel. Two tests that both trash an `IMG_0001.jpg`
    /// contend for one Trash path — harmless on its own, because the Trash
    /// renames on collision — but a test that *restores* from the Trash frees
    /// the name again, and the next test's journal-driven cleanup then deletes
    /// whatever took it. That failed about one run in three before the tag.
    let tag = String(UUID().uuidString.prefix(8))

    init() throws { tree = try TempTree() }

    /// **Before, not after.** A permanent delete cannot be reversed, and the
    /// only useful moment to say so is while the user can still choose
    /// otherwise.
    @Test func aPermanentDeleteIsRefusedAndSaysSoBeforeItIsAttempted() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        try index(source, into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .delete, sources: [source], destination: nil)
        _ = try await op.execute(plan)

        let verdict = try await op.undoability(of: plan.batchID)
        #expect(verdict.kind == .delete)
        #expect(verdict.refusal == .permanentDelete)
        #expect(!verdict.isUndoable)
        await #expect(throws: UndoRefusal.permanentDelete) {
            _ = try await op.undo(batch: plan.batchID)
        }
    }

    @Test func aBatchWithNoRowsIsRefused() async throws {
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        let verdict = try await op.undoability(of: "never-existed")
        #expect(verdict.refusal == .noSuchBatch)
        #expect(verdict.kind == nil)
    }

    /// A row whose outcome nothing wrote down is a row the filesystem has to be
    /// asked about. Undo does not guess.
    @Test func aBatchWithUnsettledRowsIsRefused() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        try journalRow(store, batch: "half-done", kind: "trash", src: source,
                       state: "complete")
        try journalRow(store, batch: "half-done", kind: "trash", src: source,
                       state: "in_flight")

        let verdict = try await op.undoability(of: "half-done")
        #expect(verdict.refusal == .unsettled(rows: 1))
        await #expect(throws: UndoRefusal.unsettled(rows: 1)) {
            _ = try await op.undo(batch: "half-done")
        }
    }

    /// What a `reconciled` row did was reconstructed from two `stat`s after a
    /// crash, not recorded as it happened. Reversing an inference is how a
    /// half-finished cross-volume move becomes a lost photo.
    @Test func aBatchTheReconcileHadToResolveIsRefused() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        try journalRow(store, batch: "crashed", kind: "trash", src: source,
                       state: "complete")
        try journalRow(store, batch: "crashed", kind: "trash", src: source,
                       state: "reconciled")

        #expect(try await op.undoability(of: "crashed").refusal
                == .reconciledAfterACrash(rows: 1))
    }

    @Test func aBatchWithFailedRowsIsRefused() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        try journalRow(store, batch: "partly", kind: "trash", src: source,
                       state: "complete")
        try journalRow(store, batch: "partly", kind: "trash", src: source,
                       state: "failed")

        #expect(try await op.undoability(of: "partly").refusal == .someItemsFailed(rows: 1))
    }

    /// `skipped` is the one non-`complete` state that does not block: its
    /// contract is the strongest in the enumeration — journalled, deliberately
    /// not attempted, nothing changed — so a batch that lost its tail to an
    /// unplugged drive is still exactly as undoable as the part that ran.
    @Test func aSkippedRowDoesNotBlockUndoOfTheRest() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        try journalRow(store, batch: "interrupted", kind: "trash", src: source,
                       state: "skipped")
        try store.testExecute(sql: """
            INSERT INTO op_journal (batch_id, kind, src, dst, trash_url, timestamp, state)
            VALUES (?, 'move', ?, ?, NULL, ?, 'complete')
            """, arguments: ["interrupted", source.path + ".moved", source.path,
                             Date().timeIntervalSince1970])

        let verdict = try await op.undoability(of: "interrupted")
        #expect(verdict.refusal == nil)
        #expect(verdict.isUndoable)
        // Only the `complete` row produces a step.
        #expect(verdict.items == 1)
    }

    @Test func aBatchOfNothingButSkipsHasNothingToUndo() async throws {
        let source = try tree.file("lib/IMG_0001-\(tag).jpg", bytes: 16)
        let store = try IndexStore.inMemory()
        let op = FileOperator(store: store)
        try journalRow(store, batch: "all-skipped", kind: "trash", src: source,
                       state: "skipped")
        #expect(try await op.undoability(of: "all-skipped").refusal == .nothingToUndo)
    }

    /// A `replace` batch's kind is the kind of the rows the user's selection
    /// produced, not the `.trash` aside row that happens to be written first.
    @Test func aReplaceBatchReportsTheKindTheUserChose() async throws {
        let source = try tree.file("from/IMG_0001-\(tag).jpg", bytes: 10)
        let destination = try tree.directory("to")
        try tree.file("to/IMG_0001-\(tag).jpg", bytes: 20)
        let store = try IndexStore.inMemory()
        try index(source, into: store)
        try index(destination.appendingPathComponent("IMG_0001-\(tag).jpg"), into: store)

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        defer { emptyTrash(of: store, batchIDs: [plan.batchID]) }
        _ = try await op.execute(plan.resolvingAllCollisions(with: .replace))

        let verdict = try await op.undoability(of: plan.batchID)
        #expect(verdict.kind == .move)
        #expect(verdict.items == 2)
        #expect(verdict.isUndoable)
    }
}

// MARK: - Redo, and surviving a quit

struct FileOperatorRedoTests {
    let tree: TempTree
    /// A per-test tag on every fixture filename.
    ///
    /// **The Trash is one shared directory** and `swift test` runs test
    /// functions in parallel. Two tests that both trash an `IMG_0001.jpg`
    /// contend for one Trash path — harmless on its own, because the Trash
    /// renames on collision — but a test that *restores* from the Trash frees
    /// the name again, and the next test's journal-driven cleanup then deletes
    /// whatever took it. That failed about one run in three before the tag.
    let tag = String(UUID().uuidString.prefix(8))

    init() throws { tree = try TempTree() }

    /// Redo is undo of the undo, and needs no state of its own: the reversal is
    /// an ordinary batch, so it is what `lastBatchID()` returns next.
    @Test func redoIsUndoOfTheUndo() async throws {
        let source = try tree.file("from/IMG_0001-\(tag).jpg", bytes: 32)
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        try index(source, into: store, contentHash: "content-abc")

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: [source], destination: destination)
        _ = try await op.execute(plan)
        let moved = destination.appendingPathComponent("IMG_0001-\(tag).jpg")

        #expect(try await op.lastBatchID() == plan.batchID)
        let undone = try await op.undo(batch: plan.batchID)
        #expect(exists(source))
        #expect(!exists(moved))

        #expect(try await op.lastBatchID() == undone.batchID)
        let redone = try await op.undo(batch: undone.batchID)
        #expect(redone.results.map(\.outcome) == [.completed])
        #expect(!exists(source))
        #expect(exists(moved))
        let row = try #require(try store.record(atPath: moved.path))
        #expect(row.contentHash == "content-abc")
    }

    /// **The journal survives quitting.** The batch is run, the store is closed
    /// as the app would close it, and a *new* store at the same file undoes it —
    /// with the launch-time reconcile running in between and finding nothing to
    /// do, because every row of a finished batch is `complete`.
    @Test func aBatchSurvivesQuittingAndIsUndoneAfterRelaunch() async throws {
        let sources = try (0..<4).map { try tree.file("from/IMG_000\($0)-\(tag).jpg", bytes: 32) }
        let destination = try tree.directory("to")
        let indexURL = tree.root.appendingPathComponent("index/index.sqlite")
        var batchID = ""
        do {
            let store = try IndexStore(url: indexURL)
            for source in sources { try index(source, into: store, contentHash: "h") }
            let op = FileOperator(store: store)
            let plan = try await op.plan(kind: .move, sources: sources,
                                         destination: destination)
            batchID = plan.batchID
            _ = try await op.execute(plan)
            try store.close()
        }
        #expect(sources.allSatisfy { !exists($0) })

        let store = try IndexStore(url: indexURL)
        #expect(store.journalReconcileReport.examined == 0)
        let op = FileOperator(store: store)
        #expect(try await op.lastBatchID() == batchID)
        #expect(try await op.undoability(of: batchID).isUndoable)

        let undone = try await op.undo(batch: batchID)
        #expect(undone.results.allSatisfy { $0.outcome == .completed })
        for source in sources {
            #expect(exists(source))
            #expect(try store.record(atPath: source.path)?.contentHash == "h")
        }
    }

    /// Progress is what a sheet binds to: one callback per reversed row.
    @Test func undoReportsProgressPerStep() async throws {
        let sources = try (0..<3).map { try tree.file("from/f\($0)-\(tag).jpg", bytes: 16) }
        let destination = try tree.directory("to")
        let store = try IndexStore.inMemory()
        for source in sources { try index(source, into: store) }

        let op = FileOperator(store: store)
        let plan = try await op.plan(kind: .move, sources: sources, destination: destination)
        _ = try await op.execute(plan)

        let seen = LockBox<[(Int, Int)]>([])
        _ = try await op.undo(batch: plan.batchID) { completed, total, _ in
            seen.withLock { $0.append((completed, total)) }
        }
        let observed = seen.withLock { $0 }
        #expect(observed.map(\.0) == [1, 2, 3])
        #expect(observed.allSatisfy { $0.1 == 3 })
    }
}
