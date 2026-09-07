import Testing
import Foundation
@testable import LightboxCore

// MARK: - Support

/// A crash is simulated rather than caused: the journal row is written by hand
/// in the state a crash would have left it, the filesystem is arranged to match
/// the moment being tested, and the store is then **opened** — which is where
/// the reconcile runs. Nothing here calls the reconcile directly except the
/// retention tests, which need a fixed clock.
private struct ReconcileFixture {
    let tree: TempTree
    let indexURL: URL

    init() throws {
        tree = try TempTree()
        indexURL = tree.root.appendingPathComponent("index/index.sqlite")
    }

    /// Opens the store at the fixture's path, running the launch-time reconcile.
    func open() throws -> IndexStore { try IndexStore(url: indexURL) }
}

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

/// Writes one `op_journal` row by hand and returns its `op_id`.
@discardableResult
private func journalRow(_ store: IndexStore, batch: String = "crashed-batch",
                        kind: String, src: URL, dst: URL? = nil, trashURL: URL? = nil,
                        timestamp: Double = Date().timeIntervalSince1970,
                        state: String = "in_flight") throws -> Int64 {
    try store.testExecute(sql: """
        INSERT INTO op_journal (batch_id, kind, src, dst, trash_url, timestamp, state)
        VALUES (?,?,?,?,?,?,?)
        """, arguments: [batch, kind, src.path, dst?.path, trashURL?.path,
                         timestamp, state])
    return try #require(try store.testFetchOne(sql: "SELECT max(op_id) FROM op_journal")
                        as Int64?)
}

private func rowState(_ store: IndexStore, _ opID: Int64) throws -> String? {
    try store.testFetchOne(sql: "SELECT state FROM op_journal WHERE op_id = ?",
                           arguments: [opID])
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
private func bytes(_ url: URL) throws -> Int { try Data(contentsOf: url).count }

// MARK: - move

/// The `move` half of the decision table. Every case asserts **where the photo
/// physically is** as well as what the index and the row say: the whole point of
/// the reconcile is that it believes the filesystem, and a test that only reads
/// the journal cannot tell whether it did.
struct JournalReconcileMoveTests {
    /// src exists, dst does not: the move never happened. The row must be left
    /// exactly where it is.
    @Test func aMoveThatNeverHappenedLeavesTheIndexAlone() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = fixture.tree.root
            .appendingPathComponent("to/IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(source))
        #expect(!exists(destination))
        let row = try #require(try store.record(atPath: source.path))
        #expect(row.contentHash == "content-abc")
        #expect(try store.record(atPath: destination.path) == nil)
        #expect(try rowState(store, opID) == "reconciled")
        #expect(store.journalReconcileReport.conclusions[opID] == .neverHappened)
    }

    /// src is gone, dst is there: it happened, and the row follows the file —
    /// hashes and all, because a move does not change a byte.
    @Test func aMoveThatHappenedRewritesTheRowToTheDestination() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        var opID: Int64 = 0
        var rowID: Int64 = 0
        do {
            let store = try fixture.open()
            // The row as it stood before the move: at `src`, with hashes.
            rowID = try #require(try index(source, into: store,
                                           contentHash: "content-abc",
                                           phash: "ffff0000ffff0000").id)
            // A real `rename(2)`, so the file at `dst` really is the file the
            // row describes — `size`, `mtime` and inode all carried across.
            try FileManager.default.moveItem(at: source, to: destination)
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(!exists(source))
        #expect(exists(destination))
        #expect(try store.record(atPath: source.path) == nil)
        let row = try #require(try store.record(atPath: destination.path))
        #expect(row.id == rowID)
        #expect(row.parentDir == destination.deletingLastPathComponent().path)
        #expect(row.name == "IMG_0001.jpg")
        #expect(row.contentHash == "content-abc")
        #expect(row.phash == "ffff0000ffff0000")
        // `files_fts` is standalone; a rewrite that forgets it answers filename
        // search with a path that is gone.
        #expect(try store.ftsMatchRowIDs("\"IMG_0001.jpg\"") == [rowID])
        #expect(try rowState(store, opID) == "reconciled")
        #expect(store.journalReconcileReport.conclusions[opID] == .happened)
    }

    /// A tier 0 pass between the crash and this open has already indexed the
    /// destination. Moving the old row onto that path would collide with
    /// `UNIQUE(path)`; the correct correction is to retire the stale source row
    /// and leave the fresher one alone.
    @Test func aMoveWhoseDestinationIsAlreadyIndexedRetiresTheSourceRow() throws {
        let fixture = try ReconcileFixture()
        let source = fixture.tree.root.appendingPathComponent("from/IMG_0001.jpg")
        let destination = try fixture.tree.file("to/IMG_0001.jpg", bytes: 64)
        var opID: Int64 = 0
        var destinationID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: source)
            try index(source, into: store, contentHash: "content-abc")
            try FileManager.default.removeItem(at: source)
            destinationID = try #require(try index(destination, into: store).id)
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(destination))
        #expect(try store.record(atPath: source.path) == nil)
        let row = try #require(try store.record(atPath: destination.path))
        #expect(row.id == destinationID)
        #expect(try store.count() == 1)
        #expect(try rowState(store, opID) == "reconciled")
    }

    /// **The row that matters.** A crash between the copy leg and the delete leg
    /// of a cross-volume move leaves both paths holding the photo. A journal row
    /// saying `move` plus a destination that exists must never be read as
    /// permission to unlink the source.
    @Test func aCrossVolumeMoveWithBothPathsPresentKeepsBothAndAddsACopyRow() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        var opID: Int64 = 0
        var sourceID: Int64 = 0
        do {
            let store = try fixture.open()
            sourceID = try #require(try index(source, into: store,
                                              contentHash: "content-abc",
                                              phash: "ffff0000ffff0000").id)
            // `copyItem` carries the modification date, as `copyfile(3)` with
            // `COPYFILE_ALL` and `clonefile` both do — so the destination really
            // is the copy leg's output rather than a lookalike.
            try FileManager.default.copyItem(at: source, to: destination)
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        // Neither file may be removed. This is the assertion the issue is about.
        #expect(exists(source))
        #expect(exists(destination))
        let original = try #require(try store.record(atPath: source.path))
        #expect(original.id == sourceID)
        #expect(original.contentHash == "content-abc")
        #expect(original.phash == "ffff0000ffff0000")
        let copy = try #require(try store.record(atPath: destination.path))
        #expect(copy.id != sourceID)
        // Never carry hashes across a crash: nothing verified these bytes.
        #expect(copy.contentHash == nil)
        #expect(copy.phash == nil)
        #expect(copy.hashedAt == nil)
        // Metadata that cannot change when bytes are copied does come across, so
        // the new row is not a blank the grid cannot draw.
        #expect(copy.width == 4000)
        #expect(copy.volumeUUID == nil)
        #expect(try rowState(store, opID) == "reconciled")
        #expect(store.journalReconcileReport.conclusions[opID] == .copyDoneDeleteNot)
    }

    /// Neither path holds anything. The index must not go on claiming a photo at
    /// either of them.
    @Test func aMoveWithNeitherPathPresentRetiresBothStaleRows() throws {
        let fixture = try ReconcileFixture()
        let source = fixture.tree.root.appendingPathComponent("from/IMG_0001.jpg")
        let destination = fixture.tree.root.appendingPathComponent("to/IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            for url in [source, destination] {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 64).write(to: url)
                try index(url, into: store)
                try FileManager.default.removeItem(at: url)
            }
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try store.count() == 0)
        #expect(try rowState(store, opID) == "reconciled")
        #expect(store.journalReconcileReport.conclusions[opID] == .goneFromBoth)
    }

    /// A `move` row with no `dst` names one of the two paths the decision needs.
    /// There is nothing to believe the filesystem about, so the row stays
    /// `in_flight` and retention never takes it.
    @Test func aMoveRowWithNoDestinationIsLeftInFlight() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            opID = try journalRow(store, kind: "move", src: source, dst: nil)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try rowState(store, opID) == "in_flight")
        #expect(store.journalReconcileReport.conclusions[opID] == .malformed)
        #expect(store.journalReconcileReport.unresolved == 1)
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
    }
}

// MARK: - copy

struct JournalReconcileCopyTests {
    @Test func aCopyWhoseDestinationLandedGetsARowWithoutHashes() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            try FileManager.default.copyItem(at: source, to: destination)
            opID = try journalRow(store, kind: "copy", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(source))
        #expect(exists(destination))
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
        let copy = try #require(try store.record(atPath: destination.path))
        #expect(copy.contentHash == nil)
        #expect(copy.hashedAt == nil)
        #expect(copy.size == 64)
        #expect(try rowState(store, opID) == "reconciled")
        #expect(store.journalReconcileReport.conclusions[opID] == .happened)
    }

    @Test func aCopyWhoseDestinationIsNotThereChangesNothing() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = fixture.tree.root.appendingPathComponent("to/IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            opID = try journalRow(store, kind: "copy", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try store.count() == 1)
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
        #expect(store.journalReconcileReport.conclusions[opID] == .neverHappened)
    }
}

// MARK: - trash: the plain rows

struct JournalReconcilePlainTrashTests {
    @Test func aTrashWhoseSourceIsStillThereChangedNothing() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 64)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            opID = try journalRow(store, kind: "trash", src: source)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(source))
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
        #expect(store.journalReconcileReport.conclusions[opID] == .neverHappened)
        #expect(try rowState(store, opID) == "reconciled")
    }

    /// The file is gone from `src` and the row named where it went. The index
    /// row goes; the recorded URL is what makes it recoverable.
    @Test func aTrashThatHappenedRetiresTheRowAndNamesTheTrashURL() throws {
        let fixture = try ReconcileFixture()
        let source = fixture.tree.root.appendingPathComponent("lib/IMG_0001.jpg")
        // A stand-in for the Trash, so the suite never touches the real one.
        let trashed = try fixture.tree.file("trash/IMG_0001.jpg", bytes: 64)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: source)
            try index(source, into: store)
            try FileManager.default.removeItem(at: source)
            opID = try journalRow(store, kind: "trash", src: source, trashURL: trashed)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(trashed))
        #expect(try store.record(atPath: source.path) == nil)
        #expect(store.journalReconcileReport.conclusions[opID]
                == .inTrash(url: trashed.path, present: true))
        #expect(try rowState(store, opID) == "reconciled")
    }

    /// `trash_url` records where the photo went, not a promise that it is still
    /// there. A Trash emptied since the crash is reported as such rather than
    /// asserted to hold the file.
    @Test func aTrashWhoseURLNoLongerExistsIsReportedAsGone() throws {
        let fixture = try ReconcileFixture()
        let source = fixture.tree.root.appendingPathComponent("lib/IMG_0001.jpg")
        let trashed = fixture.tree.root.appendingPathComponent("trash/IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: source)
            try index(source, into: store)
            try FileManager.default.removeItem(at: source)
            opID = try journalRow(store, kind: "trash", src: source, trashURL: trashed)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try store.record(atPath: source.path) == nil)
        #expect(store.journalReconcileReport.conclusions[opID]
                == .inTrash(url: trashed.path, present: false))
    }

    /// Gone from `src` with no `trash_url` is `trashURLNotRecorded`: the Trash
    /// renames on collision, so nothing can derive the name. Not repairable —
    /// but it must be *reported*, not silently treated as an ordinary trash.
    @Test func aTrashWithNoRecordedURLIsReportedAsUnderivable() throws {
        let fixture = try ReconcileFixture()
        let source = fixture.tree.root.appendingPathComponent("lib/IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: source)
            try index(source, into: store)
            try FileManager.default.removeItem(at: source)
            opID = try journalRow(store, kind: "trash", src: source)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try store.record(atPath: source.path) == nil)
        #expect(store.journalReconcileReport.conclusions[opID]
                == .trashedUnderAnUnknownName)
    }
}

// MARK: - trash: the aside rows a `replace` writes

/// An aside row (`kind = trash`, `dst` = the stash) covers three moments and
/// only the filesystem distinguishes them. The read order is `dst` →
/// `trash_url` → `src`, and reading any one field alone gets a different case
/// wrong each time.
struct JournalReconcileAsideTests {
    @Test func anAsideStillInItsStashIsReportedAtTheStash() throws {
        let fixture = try ReconcileFixture()
        let occupant = fixture.tree.root.appendingPathComponent("to/IMG_0001.jpg")
        let stash = try fixture.tree.file("to/.lightbox-replaced-abc-0-0", bytes: 64)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: occupant.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: occupant)
            try index(occupant, into: store, contentHash: "displaced")
            try FileManager.default.removeItem(at: occupant)
            opID = try journalRow(store, kind: "trash", src: occupant, dst: stash)
            try store.close()
        }

        let store = try fixture.open()
        // The stash is never removed: the reconcile only writes to `files`.
        #expect(exists(stash))
        #expect(try store.record(atPath: occupant.path) == nil)
        #expect(store.journalReconcileReport.conclusions[opID] == .inStash(stash.path))
        #expect(try rowState(store, opID) == "reconciled")
    }

    @Test func anAsideAlreadyDisposedOfIsReportedInTheTrash() throws {
        let fixture = try ReconcileFixture()
        let occupant = fixture.tree.root.appendingPathComponent("to/IMG_0001.jpg")
        let stash = fixture.tree.root.appendingPathComponent("to/.lightbox-replaced-abc-0-0")
        let trashed = try fixture.tree.file("trash/.lightbox-replaced-abc-0-0", bytes: 64)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: occupant.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: occupant)
            try index(occupant, into: store, contentHash: "displaced")
            try FileManager.default.removeItem(at: occupant)
            opID = try journalRow(store, kind: "trash", src: occupant, dst: stash,
                                  trashURL: trashed)
            try store.close()
        }

        let store = try fixture.open()
        #expect(!exists(stash))
        #expect(exists(trashed))
        #expect(try store.record(atPath: occupant.path) == nil)
        #expect(store.journalReconcileReport.conclusions[opID]
                == .inTrash(url: trashed.path, present: true))
    }

    /// The item was abandoned before staging ever ran: **neither the stash nor a
    /// Trash URL holds anything and the photo never moved.** Reading `dst` alone
    /// would call this "gone"; the occupant is untouched at `src`.
    @Test func anAsideThatWasNeverStagedLeavesTheOccupantAlone() throws {
        let fixture = try ReconcileFixture()
        let occupant = try fixture.tree.file("to/IMG_0001.jpg", bytes: 64)
        let stash = fixture.tree.root.appendingPathComponent("to/.lightbox-replaced-abc-0-0")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(occupant, into: store, contentHash: "displaced")
            opID = try journalRow(store, kind: "trash", src: occupant, dst: stash)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(occupant))
        #expect(try store.record(atPath: occupant.path)?.contentHash == "displaced")
        #expect(store.journalReconcileReport.conclusions[opID] == .neverHappened)
        #expect(try rowState(store, opID) == "reconciled")
    }

    @Test func anAsideWithNeitherStashNorURLIsReportedAsUnderivable() throws {
        let fixture = try ReconcileFixture()
        let occupant = fixture.tree.root.appendingPathComponent("to/IMG_0001.jpg")
        let stash = fixture.tree.root.appendingPathComponent("to/.lightbox-replaced-abc-0-0")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: occupant.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: occupant)
            try index(occupant, into: store)
            try FileManager.default.removeItem(at: occupant)
            opID = try journalRow(store, kind: "trash", src: occupant, dst: stash)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try store.record(atPath: occupant.path) == nil)
        #expect(store.journalReconcileReport.conclusions[opID]
                == .trashedUnderAnUnknownName)
    }
}

// MARK: - delete

struct JournalReconcileDeleteTests {
    @Test func aDeleteThatHappenedRetiresTheRow() throws {
        let fixture = try ReconcileFixture()
        let source = fixture.tree.root.appendingPathComponent("lib/IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: source)
            try index(source, into: store)
            try FileManager.default.removeItem(at: source)
            opID = try journalRow(store, kind: "delete", src: source)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try store.count() == 0)
        #expect(store.journalReconcileReport.conclusions[opID] == .happened)
        #expect(try rowState(store, opID) == "reconciled")
    }

    @Test func aDeleteThatNeverRanLeavesTheRow() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 64)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            opID = try journalRow(store, kind: "delete", src: source)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(source))
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
        #expect(store.journalReconcileReport.conclusions[opID] == .neverHappened)
    }
}

// MARK: - the staleness guard

struct JournalReconcileStalenessTests {
    /// **Never remove a row whose file is there.** Between the crash and this
    /// open, another photo took the path over and a tier 0 pass indexed it. The
    /// crashed row names that path, and retiring it on the strength of "the
    /// journal said this file went to the Trash" would delete a live photo's row
    /// — hashes, dimensions, analysis and all.
    @Test func aRowWhoseSourcePathHoldsAnIndexedPhotoIsLeftAlone() throws {
        let fixture = try ReconcileFixture()
        let path = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 64)
        var opID: Int64 = 0
        var survivorID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(path, into: store, contentHash: "the-old-photo")
            // The old photo goes; a different one arrives at the same path and
            // is indexed.
            try FileManager.default.removeItem(at: path)
            try Data(repeating: 0x42, count: 128).write(to: path)
            // No hashes on the new row: `upsertRow` clears them when size or
            // mtime change, which is exactly what happened here.
            survivorID = try #require(try index(path, into: store).id)
            opID = try journalRow(store, kind: "trash", src: path)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(path))
        let row = try #require(try store.record(atPath: path.path))
        #expect(row.id == survivorID)
        #expect(row.size == 128)
        #expect(store.journalReconcileReport.conclusions[opID] == .neverHappened)
    }

    /// The mirror of the case above: the path holds a file, but the row still
    /// describes the *old* one — different size, different inode. Keeping it
    /// leaves a stale digest at a path that now holds different bytes, which is
    /// the row duplicate detection would act on.
    @Test func aRowThatNoLongerDescribesTheFileAtItsPathIsRetired() throws {
        let fixture = try ReconcileFixture()
        let path = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 64)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(path, into: store, contentHash: "the-old-photo")
            try FileManager.default.removeItem(at: path)
            try Data(repeating: 0x42, count: 128).write(to: path)
            opID = try journalRow(store, kind: "trash", src: path)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(path))
        #expect(try store.record(atPath: path.path) == nil)
        #expect(try rowState(store, opID) == "reconciled")
    }
}

// MARK: - launch, robustness and retention

struct JournalRetentionTests {
    /// The reconcile is not something a caller opts into: opening the store runs
    /// it, before the initializer hands anything back.
    @Test func openingTheStoreIsWhatRunsTheReconcile() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        do {
            let store = try fixture.open()
            try index(source, into: store)
            try FileManager.default.moveItem(at: source, to: destination)
            try journalRow(store, kind: "move", src: source, dst: destination)
            // Nothing has reconciled it yet: this store opened before the row
            // existed.
            #expect(try store.journalRows(inState: .inFlight).count == 1)
            try store.close()
        }

        let store = try fixture.open()
        #expect(try store.journalRows(inState: .inFlight).isEmpty)
        #expect(store.journalReconcileReport.examined == 1)
        #expect(store.journalReconcileReport.reconciled == 1)
        #expect(try store.record(atPath: destination.path) != nil)
    }

    /// A `kind` or `state` string this build does not know belongs to whoever
    /// wrote it. Opening the store must not crash, and must not touch the row.
    @Test func aRowThisBuildCannotDecodeIsLeftUntouchedAndTheStoreOpens() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 64)
        do {
            let store = try fixture.open()
            try journalRow(store, kind: "teleport", src: source)
            try store.close()
        }

        let store = try fixture.open()
        #expect(store.journalReconcileReport.examined == 0)
        let kind: String? = try store.testFetchOne(sql: "SELECT kind FROM op_journal")
        let state: String? = try store.testFetchOne(sql: "SELECT state FROM op_journal")
        #expect(kind == "teleport")
        #expect(state == "in_flight")
    }

    @Test func retentionDropsBatchesOlderThanThirtyDays() throws {
        let fixture = try ReconcileFixture()
        let store = try fixture.open()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8)
        let now = 1_800_000_000.0
        let old = now - 31 * 86_400
        try journalRow(store, batch: "ancient", kind: "trash", src: source,
                       timestamp: old, state: "complete")
        try journalRow(store, batch: "recent", kind: "trash", src: source,
                       timestamp: now - 86_400, state: "complete")

        let report = try store.reconcileJournal(now: now)
        #expect(report.retired == 1)
        let batches: [String] = try store.journalRows(batchID: "ancient").map(\.batchID)
        #expect(batches.isEmpty)
        #expect(try store.journalRows(batchID: "recent").count == 1)
    }

    @Test func retentionKeepsOnlyTheNewestBatches() throws {
        let fixture = try ReconcileFixture()
        let store = try fixture.open()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8)
        let now = 1_800_000_000.0
        let total = IndexStore.journalRetentionBatches + 5
        for n in 0..<total {
            try journalRow(store, batch: String(format: "batch-%04d", n), kind: "trash",
                           src: source, timestamp: now - Double(total - n),
                           state: "complete")
        }

        let report = try store.reconcileJournal(now: now)
        #expect(report.retired == 5)
        let remaining: Int? = try store.testFetchOne(
            sql: "SELECT count(DISTINCT batch_id) FROM op_journal")
        #expect(remaining == IndexStore.journalRetentionBatches)
        // The oldest five went; the newest survived.
        #expect(try store.journalRows(batchID: "batch-0000").isEmpty)
        #expect(try store.journalRows(batchID: String(format: "batch-%04d", total - 1))
                    .count == 1)
    }

    /// Retention deletes settled rows. A row still `in_flight` — the malformed
    /// kind the reconcile refuses to interpret — is the one record that it
    /// exists, and no age makes it safe to throw away.
    @Test func retentionNeverDeletesAnInFlightRow() throws {
        let fixture = try ReconcileFixture()
        let store = try fixture.open()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8)
        let now = 1_800_000_000.0
        let opID = try journalRow(store, batch: "ancient", kind: "move", src: source,
                                  dst: nil, timestamp: now - 400 * 86_400)

        let report = try store.reconcileJournal(now: now)
        #expect(report.unresolved == 1)
        #expect(report.retired == 0)
        #expect(try rowState(store, opID) == "in_flight")
    }
}

// MARK: - The destination must be the file the row was about

/// A `move` or `copy` row names a destination. Something being *at* that
/// destination is not the same claim as **that** being the file the row was
/// about, and the gap between the two is where a stranger arrives: the plan and
/// the execution are not one instant, and a crash widens the gap to however
/// long the app was shut.
///
/// Carrying the source row onto a stranger is the `setHashes(for:)` failure with
/// a crash in place of a rowid reuse — a digest describing bytes the file does
/// not contain, on a row nothing will ever re-hash, in the table the duplicate
/// view deletes on.
struct JournalReconcileDestinationIdentityTests {
    /// src gone, dst occupied — but by a file that is not the one that moved.
    /// The hashed row must not follow it.
    @Test func aStrangerAtTheDestinationDoesNotInheritTheSourcesRow() throws {
        let fixture = try ReconcileFixture()
        let source = fixture.tree.root.appendingPathComponent("from/IMG_0001.jpg")
        let destination = try fixture.tree.file("to/IMG_0001.jpg", bytes: 999)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 64).write(to: source)
            try index(source, into: store, contentHash: "content-abc",
                      phash: "ffff0000ffff0000")
            try FileManager.default.removeItem(at: source)
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        // The stranger is untouched on disk and carries none of the row.
        #expect(exists(destination))
        #expect(try bytes(destination) == 999)
        // The harm the check prevents, named: a 999-byte stranger wearing a
        // 64-byte photo's digest, on a row nothing will ever re-hash, in the
        // table the duplicate view deletes on.
        #expect(try store.record(atPath: destination.path)?.contentHash != "content-abc")
        #expect(try store.record(atPath: destination.path) == nil)
        #expect(try store.record(atPath: source.path) == nil)
        #expect(try store.count() == 0)
        #expect(store.journalReconcileReport.conclusions[opID]
                == .destinationDiffersFromTheSource)
        #expect(try rowState(store, opID) == "reconciled")
    }

    /// The same rule for the insert side. A crash mid-`copyfile` leaves a short
    /// file; its dimensions and capture time are not the source's, and
    /// `needsReindex` keys on size and mtime alone — so a row written now would
    /// carry the source's 4000×3000 forever, because no pass would ever look at
    /// it again. Insert nothing; the walker indexes it properly.
    @Test func aCopyTheCrashLeftShortGetsNoRowAtAll() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 512)
        let destination = try fixture.tree.file("to/IMG_0001.jpg", bytes: 128)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            opID = try journalRow(store, kind: "copy", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(destination))
        #expect(try bytes(destination) == 128)
        #expect(try store.record(atPath: destination.path) == nil)
        // The source is untouched, hashes and all.
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
        #expect(store.journalReconcileReport.conclusions[opID]
                == .destinationDiffersFromTheSource)
    }

    /// A cross-volume move whose copy leg was interrupted: the source is there,
    /// and so is a short destination. Neither the "copy done" reading nor any
    /// index change is warranted — and the source must still not be touched.
    @Test func aHalfWrittenDestinationBesideALiveSourceChangesNothing() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 512)
        let destination = try fixture.tree.file("to/IMG_0001.jpg", bytes: 128)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try index(source, into: store, contentHash: "content-abc")
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(source))
        #expect(exists(destination))
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
        #expect(try store.record(atPath: destination.path) == nil)
        #expect(try store.count() == 1)
        #expect(store.journalReconcileReport.conclusions[opID]
                == .destinationDiffersFromTheSource)
    }

    /// Two `in_flight` rows naming one destination. One transaction carries
    /// every correction, so the second claim is not one bad row — it is
    /// `UNIQUE(files.path)` rolling the whole pass back, leaving everything
    /// `in_flight` for a next open that fails identically. Forever.
    @Test func twoRowsClaimingOneDestinationDoNotPoisonTheWholePass() throws {
        let fixture = try ReconcileFixture()
        let destination = fixture.tree.root.appendingPathComponent("to/IMG_0001.jpg")
        let first = fixture.tree.root.appendingPathComponent("a/IMG_0001.jpg")
        let second = fixture.tree.root.appendingPathComponent("b/IMG_0001.jpg")
        var firstOp: Int64 = 0
        var secondOp: Int64 = 0
        do {
            let store = try fixture.open()
            // Byte-identical, and stamped with one modification time, so both
            // rows genuinely describe the file that landed. Two copies of the
            // same photo in two folders, moved to one name, is the ordinary way
            // to reach this; without the shared facts the identity check would
            // answer first and the claim collision would never be reached.
            let when = Date(timeIntervalSince1970: 1_700_000_500)
            for url in [first, second] {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 64).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: when],
                                                      ofItemAtPath: url.path)
            }
            try index(first, into: store, contentHash: "hash-first")
            try index(second, into: store, contentHash: "hash-second")
            // Only one file can be at the destination; `first` is the one that
            // landed, and `rename(2)` carries its facts across.
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: first, to: destination)
            try FileManager.default.removeItem(at: second)
            firstOp = try journalRow(store, kind: "move", src: first, dst: destination)
            secondOp = try journalRow(store, kind: "move", src: second, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        // The pass ran: it did not roll back and leave everything in_flight.
        #expect(try store.journalRows(inState: .inFlight).isEmpty)
        #expect(try rowState(store, firstOp) == "reconciled")
        #expect(try rowState(store, secondOp) == "reconciled")
        // The first row won the path; the second is named, not silently dropped.
        let row = try #require(try store.record(atPath: destination.path))
        #expect(row.contentHash == "hash-first")
        #expect(store.journalReconcileReport.conclusions[firstOp] == .happened)
        #expect(store.journalReconcileReport.conclusions[secondOp]
                == .destinationClaimedByAnotherRow(destination.path))
        // The loser still gets the correction that cannot collide: its own
        // source row is gone from disk, so the row goes too.
        #expect(try store.record(atPath: second.path) == nil)
        #expect(try store.count() == 1)
    }
}

// MARK: - Retention keeps the last batch, whatever its age

struct JournalRetentionFloorTests {
    /// **The newest batch is never aged out.** Thirty idle days is an ordinary
    /// holiday, and retention that takes the last batch with it turns ⌘Z into
    /// `noSuchBatch` for an operation the user still remembers doing. The age
    /// rule exists to bound the table, and one batch does not.
    @Test func theNewestBatchSurvivesEvenWhenItIsOlderThanTheAgeLimit() throws {
        let fixture = try ReconcileFixture()
        let store = try fixture.open()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8)
        let now = 1_800_000_000.0
        try journalRow(store, batch: "the-last-thing-i-did", kind: "trash", src: source,
                       timestamp: now - 31 * 86_400, state: "complete")

        let report = try store.reconcileJournal(now: now)
        #expect(report.retired == 0)
        #expect(try store.journalRows(batchID: "the-last-thing-i-did").count == 1)
    }

    /// The floor is exactly one batch, not an amnesty on age: with a newer batch
    /// present, the 31-day-old one goes.
    @Test func theFloorIsOneBatchAndNotAnAmnestyOnAge() throws {
        let fixture = try ReconcileFixture()
        let store = try fixture.open()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8)
        let now = 1_800_000_000.0
        try journalRow(store, batch: "ancient", kind: "trash", src: source,
                       timestamp: now - 31 * 86_400, state: "complete")
        try journalRow(store, batch: "yesterday", kind: "trash", src: source,
                       timestamp: now - 86_400, state: "complete")

        let report = try store.reconcileJournal(now: now)
        #expect(report.retired == 1)
        #expect(try store.journalRows(batchID: "ancient").isEmpty)
        #expect(try store.journalRows(batchID: "yesterday").count == 1)
    }
}

// MARK: - The run says what became of it

struct JournalReconcileDispositionTests {
    @Test func anEmptyJournalIsDistinguishedFromAReconcileThatRan() throws {
        let fixture = try ReconcileFixture()
        do {
            let store = try fixture.open()
            #expect(store.journalReconcileReport.disposition == .emptyJournal)
            try journalRow(store, kind: "trash",
                           src: try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8))
            try store.close()
        }
        #expect(try fixture.open().journalReconcileReport.disposition == .ran)
    }

    /// **`init` will not wait indefinitely on a sleeping drive.** The stats hit
    /// whatever volume the rows name, and the app opens the store on the main
    /// actor before its first window draws. Past the budget the run is abandoned
    /// *before its write*, so nothing partial lands, every row stays `in_flight`
    /// and the next open tries again.
    @Test func aReconcileThatOutrunsItsBudgetIsAbandonedBeforeItWrites() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8)
        let store = try fixture.open()
        let opID = try journalRow(store, kind: "trash", src: source)

        let report = IndexStore.reconcileJournalAtOpen(
            in: store.pool, now: Date().timeIntervalSince1970, budget: 0)
        #expect(report.disposition == .deferred)
        #expect(report.examined == 0)
        // Nothing landed, and the row is still there for the next open.
        #expect(try rowState(store, opID) == "in_flight")
    }
}

// MARK: - Abandoning is atomic, and the next open finishes the job

/// `.deferred` claims every row is still `in_flight`. That claim has to survive
/// the write transaction, not just precede it: a check *outside* `pool.write`
/// leaves the whole write — acquiring the writer behind a 5 s busy timeout,
/// applying corrections computed from a snapshot up to `budget` old, and
/// committing — happening after `init` has already returned and told its caller
/// nothing landed.
struct JournalReconcileAbandonTests {
    /// The window is widened deterministically rather than raced: the seam runs
    /// inside the transaction, after the corrections are staged and before the
    /// commit, which is exactly the moment a real over-budget run is abandoned.
    @Test func aRunAbandonedInsideItsWriteRollsBackAndTheNextOneFinishesIt() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        let store = try fixture.open()
        try index(source, into: store, contentHash: "content-abc")
        try FileManager.default.moveItem(at: source, to: destination)
        let opID = try journalRow(store, kind: "move", src: source, dst: destination)

        let abandoned = LockBox<Bool>(false)
        let report = try IndexStore.reconcileJournal(
            in: store.pool, now: Date().timeIntervalSince1970,
            isAbandoned: { abandoned.withLock { $0 } },
            willCommit: { abandoned.withLock { $0 = true } })

        #expect(report.disposition == .deferred)
        // Nothing landed: not the mark, not the correction.
        #expect(try rowState(store, opID) == "in_flight")
        #expect(try store.record(atPath: destination.path) == nil)
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")

        // **The retry path.** `in_flight` means "ask the filesystem", and the
        // next open does exactly that — which is the whole reason abandoning is
        // safe.
        let second = try store.reconcileJournal()
        #expect(second.disposition == .ran)
        #expect(try rowState(store, opID) == "reconciled")
        let row = try #require(try store.record(atPath: destination.path))
        #expect(row.contentHash == "content-abc")
    }

    /// A reconcile that threw is not an empty journal, and the counts alone
    /// cannot tell them apart — both are zeros.
    @Test func aReconcileThatThrewSaysSoRatherThanLookingEmpty() throws {
        let fixture = try ReconcileFixture()
        let store = try fixture.open()
        try journalRow(store, kind: "trash",
                       src: try fixture.tree.file("lib/IMG_0001.jpg", bytes: 8))
        try store.close()

        let report = IndexStore.reconcileJournalAtOpen(in: store.pool)
        guard case .failed = report.disposition else {
            Issue.record("expected .failed, got \(report.disposition)")
            return
        }
        #expect(report.examined == 0)
    }
}

// MARK: - Identity across filesystems that do not keep nanoseconds

struct JournalReconcileTimestampTests {
    /// **The volume this app exists for is not APFS.** A library on an external
    /// drive is routinely exFAT (10 ms modification times), FAT (2 s) or SMB,
    /// and a `COPYFILE_ALL` onto one of those lands a destination whose mtime is
    /// the source's, quantised. Requiring an exact match there fails identity on
    /// the user's own file: the hashed source row is retired, no destination row
    /// is written, and the report says `destinationDiffersFromTheSource` about a
    /// perfectly good copy.
    @Test func aDestinationWhoseMtimeWasQuantisedIsStillTheSameFile() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            let record = try index(source, into: store, contentHash: "content-abc")
            try FileManager.default.copyItem(at: source, to: destination)
            // What a FAT-family volume does to the copy's timestamp: floor it to
            // the nearest two seconds.
            let floored = (record.mtime / 2).rounded(.down) * 2
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: floored)],
                ofItemAtPath: destination.path)
            opID = try journalRow(store, kind: "copy", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(store.journalReconcileReport.conclusions[opID] == .happened)
        let row = try #require(try store.record(atPath: destination.path))
        #expect(row.width == 4000)
        #expect(row.contentHash == nil)
        // The source keeps everything.
        #expect(try store.record(atPath: source.path)?.contentHash == "content-abc")
    }

    /// The tolerance is on the timestamp only. A stranger of a different length
    /// is still a stranger however close its mtime.
    @Test func aDifferentLengthIsNeverTheSameFileHoweverCloseTheTimestamp() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.file("to/IMG_0001.jpg", bytes: 65)
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            let record = try index(source, into: store, contentHash: "content-abc")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: record.mtime)],
                ofItemAtPath: destination.path)
            opID = try journalRow(store, kind: "copy", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(store.journalReconcileReport.conclusions[opID]
                == .destinationDiffersFromTheSource)
        #expect(try store.record(atPath: destination.path) == nil)
    }
}

// MARK: - A pruned source row is not a mismatched destination

/// `destinationDiffersFromTheSource` is a claim *about the user's file* — that
/// what is at the destination is not what the row was about. Reporting it
/// because there is no `files` row to compare against says something false and
/// alarming about a file nothing is wrong with. "The index no longer has a row
/// for the source" is an ordinary state: a walk pruned it while the app was shut.
struct JournalReconcilePrunedSourceTests {
    @Test func aMoveWhoseSourceRowWasPrunedIsReportedAsHappened() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.moveItem(at: source, to: destination)
            // No row for `src` at all: nothing indexed it, or a walk pruned it.
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(destination))
        #expect(store.journalReconcileReport.conclusions[opID] == .happened)
        #expect(try rowState(store, opID) == "reconciled")
        #expect(try store.count() == 0)
    }

    /// The same for the both-paths-present row. The conclusion there is about
    /// the *filesystem* — two files, one of them the copy leg's output — and a
    /// missing index row does not change what is on disk.
    @Test func aCrossVolumeMoveWhoseSourceRowWasPrunedStillReportsBothFiles() throws {
        let fixture = try ReconcileFixture()
        let source = try fixture.tree.file("from/IMG_0001.jpg", bytes: 64)
        let destination = try fixture.tree.directory("to")
            .appendingPathComponent("IMG_0001.jpg")
        var opID: Int64 = 0
        do {
            let store = try fixture.open()
            try FileManager.default.copyItem(at: source, to: destination)
            opID = try journalRow(store, kind: "move", src: source, dst: destination)
            try store.close()
        }

        let store = try fixture.open()
        #expect(exists(source))
        #expect(exists(destination))
        #expect(store.journalReconcileReport.conclusions[opID] == .copyDoneDeleteNot)
        #expect(try store.count() == 0)
    }
}
