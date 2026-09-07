import Foundation
import GRDB

/// One row's worth of index change, produced by `FileOperator` once the
/// filesystem operation for an item has already succeeded.
enum IndexMutation: Sendable {
    /// The file at `fromPath`, which is row `id`, is now at `to`.
    case move(id: Int64, fromPath: String, to: URL)
    /// A new row for a byte-identical copy of `source`.
    case insertCopy(CopyInsert)
    /// Row `id`, which is the file at `path`, is gone.
    case remove(id: Int64, path: String)
}

/// The facts about a copy's destination, read from the destination itself
/// rather than assumed from the source.
struct CopyInsert: Sendable {
    let source: FileRecord
    let destination: URL
    let size: Int64
    let mtime: Double
    let device: Int64
    let inode: Int64
    let volumeUUID: String?
    let indexedAt: Double
    /// Whether the source's hashes describe these bytes.
    ///
    /// False whenever anything at all is uncertain — a short copy, a source
    /// that changed since it was hashed, a source that was never hashed. A
    /// false here costs one re-hash; a wrong true is a permanently incorrect
    /// digest on a file the tier 1 pass will never look at again, and
    /// duplicate detection deletes on those.
    let carryHashes: Bool
}

/// What to write into one journal row when its item finishes.
struct JournalMark: Sendable {
    let opID: Int64
    let state: OpJournalState
    /// Where `trashItem` put the file. Only ever non-nil for `.trash`.
    let trashURL: String?
}

// MARK: - Journal and row mutations

/// The writes `FileOperator` needs, in their own file so that the parallel
/// metadata-writer branch's single addition next to `setHashes` and this
/// branch's several additions do not touch the same lines.
///
/// Every mutator here is **guarded on the row's id *and* its path**, for the
/// reason spelled out at length on `setHashes(for:)`: `files.id` is a reused
/// rowid, so a batch that planned against row 412 and executes after a
/// reconcile has deleted and re-created that row would otherwise move, copy or
/// delete a different photo's row. The guard makes a stale plan a no-op rather
/// than a corruption, and the return value says which happened.
extension IndexStore {
    /// Writes the batch's intent: one `in_flight` row per file the batch will
    /// touch, in a single transaction, before anything is done to the
    /// filesystem. Returns the `op_id`s in the order the drafts were given.
    ///
    /// **One row per file, not per item.** Spec §8 says "one row per item", and
    /// for an item with no companions those are the same thing. They are not
    /// the same thing for an image with an `.xmp` beside it, and the journal is
    /// what undo reverses: the schema has one `src` and one `dst` per row and
    /// no way to name companions, so a row per file is the only shape in which
    /// undo can put a sidecar back. Every row of one batch shares its
    /// `batch_id`, which is what keeps them one undoable unit.
    @discardableResult
    func journal(_ drafts: [JournalDraft], batchID: String,
                 timestamp: Double) throws -> [Int64] {
        guard !drafts.isEmpty else { return [] }
        return try pool.write { db in
            var ids: [Int64] = []
            ids.reserveCapacity(drafts.count)
            for draft in drafts {
                try db.execute(sql: """
                    INSERT INTO op_journal (batch_id, kind, src, dst, trash_url, timestamp, state)
                    VALUES (?,?,?,?,NULL,?,?)
                    """, arguments: [batchID, draft.kind.rawValue, draft.src.path,
                                     draft.dst?.path, timestamp,
                                     OpJournalState.inFlight.rawValue])
                ids.append(db.lastInsertedRowID)
            }
            return ids
        }
    }

    /// Applies an item's index changes and marks its journal rows, in **one
    /// transaction**.
    ///
    /// One transaction rather than two because the alternative has a window:
    /// index updated, journal still `in_flight`, and a crash inside it leaves
    /// the launch-time reconcile looking at rows it has already been told about
    /// but that claim otherwise. Removals run before moves and inserts so that
    /// a `replace` policy — which deletes the row of the file it overwrote —
    /// cannot collide with the `UNIQUE(path)` index on the row taking its
    /// place.
    ///
    /// Returns how many mutations actually landed; a count short of
    /// `mutations.count` means a guard refused a write because the row no
    /// longer describes the file that was planned against.
    @discardableResult
    func applyAndMark(_ mutations: [IndexMutation], marks: [JournalMark]) throws -> Int {
        try pool.write { db in try Self.apply(db, mutations: mutations, marks: marks) }
    }

    /// The body of `applyAndMark`, on a caller's `Database`.
    ///
    /// Extracted so the launch-time reconcile can put its `files` corrections,
    /// its `reconciled` marks **and** its retention delete in one write
    /// transaction rather than three. The rules the mutations obey — removals
    /// first, the id-and-path guard on every write, the hand-maintained
    /// `files_fts` rename — are the same rules whichever side is calling, and
    /// duplicating them in the reconcile is how the two would drift.
    @discardableResult
    static func apply(_ db: Database, mutations: [IndexMutation],
                      marks: [JournalMark]) throws -> Int {
        var applied = 0
        for case .remove(let id, let path) in mutations {
            try db.execute(sql: "DELETE FROM files WHERE id = ? AND path = ?",
                           arguments: [id, path])
            applied += db.changesCount
        }
        for mutation in mutations {
            switch mutation {
            case .remove:
                continue
            case .move(let id, let fromPath, let destination):
                // `parent_dir` carries no trailing slash, matching what
                // `FileRecord.init(entry:…)` and `pathScope` produce; a
                // trailing slash here would make the moved row invisible to
                // the non-recursive folder scope.
                try db.execute(sql: """
                    UPDATE files SET path = ?, parent_dir = ?, name = ?
                    WHERE id = ? AND path = ?
                    """, arguments: [destination.path,
                                     destination.deletingLastPathComponent().path,
                                     destination.lastPathComponent, id, fromPath])
                guard db.changesCount == 1 else { continue }
                applied += 1
                // `files_fts` is a standalone FTS5 table, so a *rename* has
                // to be mirrored by hand: nothing else does it, and a move
                // that leaves the old name behind makes filename search
                // answer with a path that is gone. Deletes need no such
                // line — the `files_ad` trigger clears the FTS row and the
                // `analysis` row whenever a `files` row goes, whichever code
                // path removed it.
                try db.execute(sql: "UPDATE files_fts SET name = ? WHERE rowid = ?",
                               arguments: [destination.lastPathComponent, id])
            case .insertCopy(let insert):
                _ = try Self.upsertRow(db, insert.record)
                applied += 1
            }
        }
        for mark in marks {
            try db.execute(sql: """
                UPDATE op_journal SET state = ?, trash_url = COALESCE(?, trash_url)
                WHERE op_id = ?
                """, arguments: [mark.state.rawValue, mark.trashURL, mark.opID])
        }
        return applied
    }

    /// Records where `trashItem` put a file, on its own, immediately.
    ///
    /// Its own transaction on purpose. Between `trashItem` returning and the
    /// item's index transaction committing, this path is the **only** record of
    /// where the photo went — the Trash renames on collision, so the name cannot
    /// be derived from the original — and an index write that fails, or an
    /// item-level rollback that discards the in-memory results, would lose it. A
    /// row that says `in_flight` and names a Trash URL is recoverable; one that
    /// says `in_flight` and names nothing is a photo the user has to go looking
    /// for.
    func recordTrashURL(opID: Int64, path: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE op_journal SET trash_url = ? WHERE op_id = ?",
                           arguments: [path, opID])
        }
    }

    /// Marks journal rows without touching `files`. Used for the states that
    /// describe *not* having acted: `skipped` when a volume went away before an
    /// item's turn, `failed` when the filesystem refused.
    func markJournal(_ marks: [JournalMark]) throws {
        guard !marks.isEmpty else { return }
        try pool.write { db in
            for mark in marks {
                try db.execute(sql: """
                    UPDATE op_journal SET state = ?, trash_url = COALESCE(?, trash_url)
                    WHERE op_id = ?
                    """, arguments: [mark.state.rawValue, mark.trashURL, mark.opID])
            }
        }
    }

    /// Every journal row of one batch, oldest first.
    public func journalRows(batchID: String) throws -> [OpJournalRow] {
        try pool.read { db in
            try Self.decodeJournal(
                Row.fetchAll(db, sql: """
                    SELECT * FROM op_journal WHERE batch_id = ? ORDER BY op_id
                    """, arguments: [batchID]))
        }
    }

    /// Every journal row in `state`, oldest first.
    ///
    /// This is what #6's launch-time reconcile reads: the `in_flight` rows are
    /// exactly the operations whose outcome nothing recorded, and the
    /// filesystem is the authority on each of them.
    public func journalRows(inState state: OpJournalState) throws -> [OpJournalRow] {
        try pool.read { db in
            try Self.decodeJournal(
                Row.fetchAll(db, sql: """
                    SELECT * FROM op_journal WHERE state = ? ORDER BY op_id
                    """, arguments: [state.rawValue]))
        }
    }

    /// The `batch_id` of the most recently journalled batch, or nil if the
    /// journal is empty.
    ///
    /// By `op_id`, not by `timestamp`: `timestamp` is one clock reading shared
    /// by every row a batch writes up front, so two batches started inside the
    /// same tick tie, and the injected clock in tests can repeat a value
    /// outright. `op_id` is the rowid — monotonic by construction, and the
    /// order the rows were really written in.
    ///
    /// This is what "undo the last batch" means: the newest batch, whatever
    /// state it is in. Deliberately not "the newest *undoable* batch" —
    /// stepping silently back to an older one would reverse an operation the
    /// user was not looking at. `FileOperator.undoability(of:)` says why the
    /// newest one cannot be undone instead.
    public func lastJournalBatchID() throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT batch_id FROM op_journal ORDER BY op_id DESC LIMIT 1
                """)
        }
    }

    /// A row whose `kind` or `state` this build does not know is dropped rather
    /// than trapped. The journal is persisted and read by later builds; a
    /// string nobody recognises is a reason to leave that row to whoever wrote
    /// it, not a reason to crash on launch.
    static func decodeJournal(_ rows: [Row]) -> [OpJournalRow] {
        rows.compactMap { row in
            guard let opID = row["op_id"] as Int64?,
                  let batchID = row["batch_id"] as String?,
                  let kindRaw = row["kind"] as String?,
                  let kind = FileOperationKind(rawValue: kindRaw),
                  let src = row["src"] as String?,
                  let stateRaw = row["state"] as String?,
                  let state = OpJournalState(rawValue: stateRaw) else { return nil }
            return OpJournalRow(opID: opID, batchID: batchID, kind: kind, src: src,
                                dst: row["dst"] as String?,
                                trashURL: row["trash_url"] as String?,
                                timestamp: row["timestamp"] as Double? ?? 0,
                                state: state)
        }
    }
}

/// One row of intent, before it has an `op_id`.
struct JournalDraft: Sendable {
    let kind: FileOperationKind
    let src: URL
    let dst: URL?
}

extension CopyInsert {
    /// The row for the copy: the destination's own `stat` facts, the source's
    /// metadata (dimensions and camera do not change when bytes are copied),
    /// and its hashes only if `carryHashes` says they still describe the bytes.
    var record: FileRecord {
        FileRecord(
            id: nil, path: destination.path,
            parentDir: destination.deletingLastPathComponent().path,
            name: destination.lastPathComponent,
            ext: destination.pathExtension.lowercased(),
            size: size, mtime: mtime, device: device, inode: inode,
            volumeUUID: volumeUUID,
            width: source.width, height: source.height,
            captureTime: source.captureTime, captureOffset: source.captureOffset,
            cameraMake: source.cameraMake, cameraModel: source.cameraModel,
            orientation: source.orientation,
            contentHash: carryHashes ? source.contentHash : nil,
            imageHash: carryHashes ? source.imageHash : nil,
            imageHashKind: carryHashes ? source.imageHashKind : nil,
            phash: carryHashes ? source.phash : nil,
            hashedAt: carryHashes ? source.hashedAt : nil,
            indexedAt: indexedAt)
    }
}
