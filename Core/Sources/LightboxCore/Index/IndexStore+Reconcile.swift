import Foundation
import GRDB

/// Where the launch-time reconcile decided one `in_flight` photo actually is.
///
/// The conclusion is the *finding*, separately from the `files` correction it
/// produces, because several different findings produce the same correction and
/// collapsing them would make the read order untestable. An aside row whose
/// stash is still on disk and one whose stash reached the Trash both leave the
/// row at `src` stale, but they are not the same fact about the user's photo,
/// and only one of them is recoverable by hand.
public enum JournalConclusion: Sendable, Equatable, Hashable {
    /// Nothing happened, or it happened and was rolled back. Everything is
    /// where the operation started.
    case neverHappened
    /// The operation ran to completion on the filesystem.
    case happened
    /// A cross-volume move whose copy landed and whose source removal did not:
    /// **both paths hold the photo.** Treated as a copy — which is the whole
    /// point of the row, because a `move` row plus "the destination exists" is
    /// exactly the inference that would unlink the source on the strength of a
    /// journal entry.
    case copyDoneDeleteNot
    /// A `replace` aside that was staged and not yet disposed of: the displaced
    /// photo is in its dot-prefixed stash, at this path. Recoverable by hand,
    /// and by nothing else — the walker treats a dot-file as junk, so no pass
    /// will ever index it.
    case inStash(String)
    /// The photo is in the Trash at this URL. `present` is what a `stat` of that
    /// URL found: false means it went there and the Trash has since been
    /// emptied, which the row alone cannot tell you.
    case inTrash(url: String, present: Bool)
    /// The photo reached the Trash and where it went was never written down —
    /// the `trashURLNotRecorded` case. The Trash renames on collision, so
    /// nothing can derive the name. Not repairable here; recorded so a report
    /// can say which photo it was.
    case trashedUnderAnUnknownName
    /// A `move` row whose `src` and `dst` both hold nothing. The journal names
    /// two paths and the filesystem has neither.
    case goneFromBoth
    /// The row cannot be reasoned about: a `move` or `copy` with a NULL `dst`.
    /// Left `in_flight` and never retired — there is nothing to believe the
    /// filesystem *about* when the row names one of the two paths.
    case malformed
}

/// What one run of the launch-time reconcile did.
public struct JournalReconcileReport: Sendable, Equatable {
    /// Rows that were `in_flight` when the store opened.
    public let examined: Int
    /// Rows marked `reconciled`.
    public let reconciled: Int
    /// Rows left `in_flight` because they were malformed.
    public let unresolved: Int
    /// `files` rows rewritten, inserted or removed.
    public let corrections: Int
    /// Journal rows retention deleted.
    public let retired: Int
    /// What was concluded about each examined row, by `op_id`.
    public let conclusions: [Int64: JournalConclusion]

    public static let none = JournalReconcileReport(
        examined: 0, reconciled: 0, unresolved: 0, corrections: 0, retired: 0,
        conclusions: [:])
}

// MARK: - Reconcile

/// The launch-time half of spec §8's "index and filesystem are reconciled, not
/// transacted".
///
/// `FileOperator` writes `op_journal` before it touches a file and marks it
/// after; anything that interrupts the middle leaves a row saying `in_flight`,
/// which is defined to mean **"ask the filesystem"**. This is where it is
/// asked. It runs inside `IndexStore.init`, before the initializer returns, so
/// no window can start a pass over rows the crash left describing files that
/// have moved.
///
/// **Three rules govern every correction here, and they are the reason this is
/// not simply "apply what the row said it would do":**
///
/// 1. **Never remove a file.** The reconcile only ever writes to `files`. A
///    photo in a stash, in the Trash, or sitting at both ends of a half-finished
///    cross-volume move is left exactly where it is, and the conclusion records
///    where that was so a human can act on it.
/// 2. **Never remove a row whose file is there.** A row is deleted only when the
///    path it names holds nothing, or holds something the row provably does not
///    describe — a different `inode`, `size` or `mtime`. Anything looser deletes
///    the row of the photo that took the path over, which is the same class of
///    bug as `setHashes(for:)`'s guard and has the same cause: `files.id` is a
///    reused rowid and a path can change hands.
/// 3. **Never carry hashes across a crash.** The one insert this makes — the
///    destination of a copy, or of a cross-volume move whose delete leg did not
///    run — is written with NULL hashes. `carryHashes` is a claim of byte
///    identity, and after a crash mid-copy nothing has verified the length, let
///    alone the bytes. One re-hash is the cost; a wrong digest on a row nothing
///    revisits is what duplicate detection deletes on.
///
/// **It never throws out of `init`.** A store that will not open is a Lightbox
/// that will not launch, over a repair whose worst case is "the rows are wrong
/// until the next pass". A failure leaves every row `in_flight` — so the next
/// open tries again — and the store opens.
extension IndexStore {
    /// How long a settled batch stays in the journal.
    ///
    /// Thirty days is roughly "this quarter's mistakes": long enough that a
    /// person coming back from leave can still see what a batch did, short
    /// enough that the table stays small on a library that gets reorganised
    /// often. Undo itself only ever reaches the *last* batch, so nothing about
    /// undo depends on this number.
    static let journalRetentionDays: Double = 30
    /// How many batches stay in the journal regardless of age.
    ///
    /// Two hundred, so a heavy day of reorganising is entirely readable
    /// afterwards while the table cannot grow without bound on a machine that
    /// never idles long enough for the age rule to bite. The two rules are an
    /// AND-keep: a row survives only if its batch is both inside 30 days and
    /// inside the newest 200.
    static let journalRetentionBatches = 200
    /// How many `?` placeholders one `path IN (…)` lookup carries.
    ///
    /// Well under SQLite's variable limit, and the read is chunked rather than
    /// issued per path so a journal of thousands of rows costs a handful of
    /// statements inside one read transaction rather than thousands of them.
    private static let pathLookupChunk = 400

    /// Runs the reconcile and swallows any failure. **The initializers' entry
    /// point**, and static because it is called while `IndexStore` is still
    /// half-initialized — the pool exists, `self` does not yet — which is also
    /// what makes the report assignable to a `let` the whole app can read.
    /// See the type-level note on why it cannot throw.
    static func reconcileJournalAtOpen(in pool: DatabasePool,
                                       now: Double = Date().timeIntervalSince1970)
        -> JournalReconcileReport {
        (try? reconcileJournal(in: pool, now: now)) ?? .none
    }

    /// Runs the reconcile again, on a store that is already open. Tests reach
    /// for this with a fixed `now`; nothing in the app does.
    @discardableResult
    func reconcileJournal(now: Double = Date().timeIntervalSince1970) throws
        -> JournalReconcileReport {
        try Self.reconcileJournal(in: pool, now: now)
    }

    /// One read, one write, and `stat` in between.
    ///
    /// The shape is forced by the constraint that this runs at open: everything
    /// the decision needs is read in a single read transaction, every `stat`
    /// happens outside any transaction, and every correction, every mark and the
    /// retention delete go in one write transaction. Holding the writer while
    /// `stat`ing a sleeping external drive would park every window behind it.
    @discardableResult
    static func reconcileJournal(in pool: DatabasePool, now: Double) throws
        -> JournalReconcileReport {
        let (rows, records, journalCount) = try readForReconcile(pool)
        guard journalCount > 0 else { return .none }

        var mutations: [IndexMutation] = []
        var marks: [JournalMark] = []
        var conclusions: [Int64: JournalConclusion] = [:]
        var unresolved = 0
        for row in rows {
            let decision = Self.decide(row, records: records, now: now)
            conclusions[row.opID] = decision.conclusion
            mutations.append(contentsOf: decision.mutations)
            if decision.conclusion == .malformed {
                unresolved += 1
            } else {
                marks.append(JournalMark(opID: row.opID, state: .reconciled, trashURL: nil))
            }
        }

        let applied = try pool.write { db -> (Int, Int) in
            let corrections = try Self.apply(db, mutations: mutations, marks: marks)
            return (corrections, try Self.retireJournal(db, now: now))
        }
        return JournalReconcileReport(
            examined: rows.count, reconciled: marks.count, unresolved: unresolved,
            corrections: applied.0, retired: applied.1, conclusions: conclusions)
    }

    /// The `in_flight` rows, the `files` rows for every path they name, and how
    /// many journal rows there are at all — in one read transaction.
    ///
    /// The count is what lets an empty journal skip the write transaction
    /// entirely. Every `IndexStore` in the suite, and every window the app
    /// opens, runs this; a write on a table with nothing in it is pure cost.
    private static func readForReconcile(_ pool: DatabasePool) throws
        -> ([OpJournalRow], [String: FileRecord], Int) {
        try pool.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM op_journal") ?? 0
            guard count > 0 else { return ([], [:], 0) }
            let rows = Self.decodeJournal(try Row.fetchAll(db, sql: """
                SELECT * FROM op_journal WHERE state = ? ORDER BY op_id
                """, arguments: [OpJournalState.inFlight.rawValue]))
            guard !rows.isEmpty else { return ([], [:], count) }

            var paths: Set<String> = []
            for row in rows {
                paths.insert(row.src)
                if let dst = row.dst { paths.insert(dst) }
            }
            var records: [String: FileRecord] = [:]
            for chunk in Array(paths).chunked(into: pathLookupChunk) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let found = try FileRecord.fetchAll(
                    db, sql: "SELECT * FROM files WHERE path IN (\(marks))",
                    arguments: StatementArguments(chunk))
                for record in found { records[record.path] = record }
            }
            return (rows, records, count)
        }
    }

    // MARK: The decision table

    private struct Decision {
        let conclusion: JournalConclusion
        var mutations: [IndexMutation] = []
    }

    /// One row, re-`stat`ed and decided.
    ///
    /// | kind | shape | conclusion | correction |
    /// |---|---|---|---|
    /// | move | src, no dst | never happened | none |
    /// | move | no src, dst | happened | rewrite the src row to dst, or drop it if dst is already indexed |
    /// | move | src and dst | copy done, delete not | leave src; insert dst without hashes |
    /// | move | neither | gone from both | drop each row that is stale |
    /// | move | dst NULL | malformed | none; left `in_flight` |
    /// | copy | dst | happened | insert dst without hashes if absent |
    /// | copy | no dst | never happened | none |
    /// | copy | dst NULL | malformed | none; left `in_flight` |
    /// | trash (aside, dst set) | stash present | in the stash | drop the src row if stale |
    /// | trash (aside) | no stash, trash_url | in the Trash | drop the src row if stale |
    /// | trash (aside) | neither, src present | never happened | none |
    /// | trash (aside) | neither, no src | trashed, name unknown | drop the src row if stale |
    /// | trash (plain, dst NULL) | src present | never happened | none |
    /// | trash (plain) | no src, trash_url | in the Trash | drop the src row if stale |
    /// | trash (plain) | no src, no trash_url | trashed, name unknown | drop the src row if stale |
    /// | delete | src present | never happened | none |
    /// | delete | no src | happened | drop the src row if stale |
    ///
    /// **Every insert is conditional on there being a source row to derive
    /// from.** Without one there is nothing to say about the destination beyond
    /// its `stat`, and a row carrying only that is worse than no row at all:
    /// `needsReindex` compares `size` and `mtime`, so a row with NULL dimensions
    /// and NULL hashes would read as up to date forever and no tier 0 pass would
    /// ever fill it in. Leaving the path unindexed hands it to the next walk,
    /// which indexes it completely.
    ///
    /// The `trash` and `delete` families all reduce to the same correction —
    /// drop the row at `src` if it is stale — which is not a coincidence and is
    /// not a reason to merge them: the *conclusions* differ, and the conclusion
    /// is what says whether the photo is recoverable and from where. The read
    /// order for an aside row (`dst` → `trash_url` → `src`) and for a plain one
    /// (`src` → `trash_url`) is the `OpJournalState` contract, and each of those
    /// orders is what produces the conclusion.
    private static func decide(_ row: OpJournalRow, records: [String: FileRecord],
                               now: Double) -> Decision {
        let src = statFacts(row.src)
        let dstPath = row.dst
        let dst = dstPath.flatMap(statFacts)

        switch row.kind {
        case .move:
            guard let dstPath else { return Decision(conclusion: .malformed) }
            switch (src != nil, dst != nil) {
            case (true, false):
                return Decision(conclusion: .neverHappened)
            case (false, true):
                var decision = Decision(conclusion: .happened)
                if records[dstPath] != nil {
                    // Something already indexed the destination — a tier 0 pass
                    // between the crash and this open. That row describes the
                    // file better than the pre-move one does, so the correction
                    // is to retire the source row, not to move it onto a path
                    // that is taken.
                    decision.mutations = removalIfStale(row.src, src, records)
                } else if let record = records[row.src], let id = record.id {
                    decision.mutations = [.move(id: id, fromPath: row.src,
                                                to: URL(fileURLWithPath: dstPath))]
                }
                return decision
            case (true, true):
                // **The row the issue calls out.** A `move` row plus a
                // destination that exists is not permission to unlink the
                // source: a cross-volume move is a copy then a delete, and this
                // is what a crash between the two legs looks like. Both files
                // stay; the index gains a row for the second one.
                var decision = Decision(conclusion: .copyDoneDeleteNot)
                if records[dstPath] == nil, let source = records[row.src], let facts = dst {
                    decision.mutations = [insert(source: source, at: dstPath,
                                                 facts: facts, now: now)]
                }
                return decision
            case (false, false):
                var decision = Decision(conclusion: .goneFromBoth)
                decision.mutations = removalIfStale(row.src, src, records)
                    + removalIfStale(dstPath, dst, records)
                return decision
            }

        case .copy:
            guard let dstPath else { return Decision(conclusion: .malformed) }
            guard let facts = dst else { return Decision(conclusion: .neverHappened) }
            var decision = Decision(conclusion: .happened)
            if records[dstPath] == nil, let source = records[row.src] {
                decision.mutations = [insert(source: source, at: dstPath,
                                             facts: facts, now: now)]
            }
            return decision

        case .trash:
            return Decision(conclusion: trashConclusion(row, src: src, stash: dst),
                            mutations: removalIfStale(row.src, src, records))

        case .delete:
            return Decision(conclusion: src == nil ? .happened : .neverHappened,
                            mutations: removalIfStale(row.src, src, records))
        }
    }

    /// Where a `trash` row's photo is, by the read order its shape demands.
    ///
    /// **An aside row and a plain one are different rows and read differently**,
    /// and reading either by one field alone is wrong — that is written out on
    /// `OpJournalState` and is repeated here because this is the only place it
    /// is executed. An aside row (`dst` names a stash) covers three moments:
    /// before the disposal the photo is at the stash, after it the photo is at
    /// `trash_url`, and if the item was abandoned before staging ever ran the
    /// photo never moved at all. A plain row has no stash and reads `src` first.
    private static func trashConclusion(
        _ row: OpJournalRow,
        src: (size: Int64, mtime: Double, device: Int64, inode: Int64)?,
        stash: (size: Int64, mtime: Double, device: Int64, inode: Int64)?
    ) -> JournalConclusion {
        if let stashPath = row.dst {
            // Aside row: dst → trash_url → src.
            if stash != nil { return .inStash(stashPath) }
            if let trash = row.trashURL {
                return .inTrash(url: trash, present: statFacts(trash) != nil)
            }
            return src != nil ? .neverHappened : .trashedUnderAnUnknownName
        }
        // Plain row: src → trash_url.
        if src != nil { return .neverHappened }
        if let trash = row.trashURL {
            return .inTrash(url: trash, present: statFacts(trash) != nil)
        }
        return .trashedUnderAnUnknownName
    }

    /// The removal for a row at `path`, **if and only if the row is stale**.
    ///
    /// Stale means the path holds nothing, or holds something this row does not
    /// describe. Presence alone is not enough in either direction: a path that
    /// is empty makes the row a lie, and a path that is full may have been taken
    /// over by another photo whose own row must survive. `inode` catches the
    /// hand-over; `size` and `mtime` catch the case where the same inode was
    /// rewritten in place, and are the same two columns tier 0 uses to decide a
    /// file is unchanged.
    private static func removalIfStale(
        _ path: String,
        _ facts: (size: Int64, mtime: Double, device: Int64, inode: Int64)?,
        _ records: [String: FileRecord]
    ) -> [IndexMutation] {
        guard let record = records[path], let id = record.id else { return [] }
        if let facts, record.inode == facts.inode, record.size == facts.size,
           record.mtime == facts.mtime {
            return []
        }
        return [.remove(id: id, path: path)]
    }

    /// A row for a destination a crash left behind, derived from the source's
    /// row and the destination's own `stat` — and **never carrying hashes**.
    ///
    /// `volume_uuid` is left NULL rather than read: a `URLResourceValues` fetch
    /// is not a `stat`, and this runs at open with the writer about to be taken.
    /// NULL is exactly what the v2 migration leaves and what the next tier 0
    /// pass stamps, and `deleteRows`' matching rule already handles a NULL row.
    private static func insert(source: FileRecord, at path: String,
                               facts: (size: Int64, mtime: Double,
                                       device: Int64, inode: Int64),
                               now: Double) -> IndexMutation {
        .insertCopy(CopyInsert(
            source: source, destination: URL(fileURLWithPath: path),
            size: facts.size, mtime: facts.mtime, device: facts.device,
            inode: facts.inode, volumeUUID: nil, indexedAt: now,
            carryHashes: false))
    }

    /// `stat(2)` by path, in the shape `FileOperator` reads it, so a record
    /// written by tier 0 and a reading taken here compare equal for a file
    /// nothing has touched.
    private static func statFacts(_ path: String)
        -> (size: Int64, mtime: Double, device: Int64, inode: Int64)? {
        FileOperator.statFacts(URL(fileURLWithPath: path))
    }

    // MARK: Retention

    /// Deletes settled rows whose batch is older than the age limit **or**
    /// outside the newest `journalRetentionBatches`, and returns how many went.
    ///
    /// `state <> 'in_flight'` is the guard that matters: by the time this runs
    /// in the same transaction, every row the reconcile could settle says
    /// `reconciled`, and the only rows still `in_flight` are the malformed ones
    /// the reconcile refused to interpret. Deleting those would throw away the
    /// only record that they exist.
    ///
    /// A batch is ranked by its newest row rather than its oldest, so a long
    /// batch is not aged out by the moment it started.
    static func retireJournal(_ db: Database, now: Double) throws -> Int {
        let cutoff = now - journalRetentionDays * 86_400
        try db.execute(sql: """
            DELETE FROM op_journal
            WHERE state <> ?
              AND batch_id IN (
                    SELECT batch_id FROM (
                        SELECT batch_id,
                               MAX(timestamp) AS last_touched,
                               ROW_NUMBER() OVER (
                                   ORDER BY MAX(timestamp) DESC, batch_id DESC) AS rn
                        FROM op_journal
                        GROUP BY batch_id
                    )
                    WHERE last_touched < ? OR rn > ?
              )
            """, arguments: [OpJournalState.inFlight.rawValue, cutoff,
                             journalRetentionBatches])
        return db.changesCount
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
