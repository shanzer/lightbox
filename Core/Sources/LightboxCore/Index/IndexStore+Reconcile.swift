import Foundation
import GRDB
import Synchronization

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
    /// **Something is at `dst`, and it is not what the row was about.** Its
    /// `size` or `mtime` does not match the `files` row the operation started
    /// from, so it is either a stranger that arrived in the plan/execute gap —
    /// the same gap `destinationNotReplaceable` exists for — or a copy the
    /// crash left short.
    ///
    /// Nothing is carried onto it. That is the whole reason this case is
    /// distinct from `happened`: rewriting the source's row onto a stranger
    /// hands a 999-byte file a 64-byte file's `content_hash`, a digest
    /// describing bytes it does not contain, on a row nothing will re-hash and
    /// in the table the duplicate view deletes on. The source row is retired if
    /// it is stale and the path is left for the walker to index properly.
    case destinationDiffersFromTheSource
    /// Two `in_flight` rows in one journal want to write the same `files` path,
    /// and the earlier one won. Carries the path.
    ///
    /// One transaction carries every correction, so a second row claiming a
    /// taken path is not one bad row — it is `UNIQUE(files.path)` rolling back
    /// the *whole* pass, leaving every row `in_flight` for a next open that
    /// would fail in exactly the same way. Forever. The loser is marked
    /// `reconciled` with this conclusion rather than left to poison the run.
    case destinationClaimedByAnotherRow(String)
    /// The row cannot be reasoned about: a `move` or `copy` with a NULL `dst`.
    /// Left `in_flight` and never retired — there is nothing to believe the
    /// filesystem *about* when the row names one of the two paths.
    case malformed
}

/// What became of one run of the reconcile itself, as opposed to what it found.
///
/// Separate from the counts because "the journal was empty" and "the write
/// transaction threw" produce the same zeros, and a caller that cannot tell
/// them apart cannot tell a clean launch from a repair that silently did not
/// happen.
public enum JournalReconcileDisposition: Sendable, Equatable {
    /// There was nothing in `op_journal` at all.
    case emptyJournal
    /// It ran to completion.
    case ran
    /// It threw. **Every row is still `in_flight`** and the next open tries
    /// again; the store opened anyway, because a store that will not open is an
    /// app that will not launch.
    case failed(String)
    /// It did not finish inside `init`'s budget and was abandoned. Every row is
    /// still `in_flight` and the next open resolves them.
    ///
    /// **Nothing partial landed, including nothing that landed late.** The
    /// abandon flag is read inside the write transaction — on acquiring the
    /// writer, and again immediately before the commit — and leaves by throwing,
    /// which is the only thing GRDB treats as a rollback. A check merely
    /// *before* the write would let a run that `init` had already given up on
    /// queue for the writer, then commit corrections computed from a stale
    /// snapshot over rows a pass may have re-indexed since. See
    /// `reconcileBudget`.
    case deferred
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
    /// What became of the run itself.
    public let disposition: JournalReconcileDisposition

    static func nothing(_ disposition: JournalReconcileDisposition) -> JournalReconcileReport {
        JournalReconcileReport(examined: 0, reconciled: 0, unresolved: 0,
                               corrections: 0, retired: 0, conclusions: [:],
                               disposition: disposition)
    }
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
/// until the next pass". A failure — or a run abandoned for outrunning `init`'s
/// budget — leaves every row `in_flight`, so the next open tries again, and the
/// store opens either way. That claim is enforced rather than asserted: the
/// write transaction is rolled back by throwing out of it, so a run that gave
/// up cannot commit afterwards.
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
                                       now: Double = Date().timeIntervalSince1970,
                                       budget: TimeInterval = reconcileBudget)
        -> JournalReconcileReport {
        let slot = ReconcileSlot()
        let finished = DispatchSemaphore(value: 0)
        // An ordinary dispatch queue, not the cooperative pool and not the
        // calling thread. `stat` on a spun-down external drive parks a thread
        // for seconds, and the calling thread here is the **main actor**: the
        // app opens its store in `BrowserModel(at:)` before the first window
        // draws. libdispatch replaces a blocked thread on one of these; the main
        // thread has no replacement.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let report = try reconcileJournal(in: pool, now: now,
                                                  isAbandoned: slot.isAbandoned)
                slot.finish(report)
            } catch {
                slot.finish(.nothing(.failed(String(describing: error))))
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + budget) == .success else {
            // Past the budget the run is abandoned rather than waited out.
            // `isAbandoned` is read **inside** the write transaction — on
            // acquiring the writer and again just before the commit — so a run
            // `init` has given up on cannot commit after `init` has returned
            // saying nothing landed. Every row stays `in_flight`, which is
            // exactly the state the next open is built to resolve: the repair is
            // deferred, never half-done.
            slot.abandon()
            return .nothing(.deferred)
        }
        return slot.report ?? .nothing(.deferred)
    }

    /// How long `IndexStore.init` waits for the reconcile before opening anyway.
    ///
    /// Three seconds. A warm journal is nowhere near it — five thousand
    /// `in_flight` rows reconcile in about 0.19 s on the boot volume — so this
    /// only ever bites when the rows name a volume that has to spin up, and
    /// there is nothing to lose by deferring that: the rows keep saying
    /// `in_flight`, and `in_flight` already means "ask the filesystem".
    static let reconcileBudget: TimeInterval = 3

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
    static func reconcileJournal(in pool: DatabasePool, now: Double,
                                 isAbandoned: () -> Bool = { false },
                                 willCommit: () -> Void = {}) throws
        -> JournalReconcileReport {
        let (rows, records, journalCount) = try readForReconcile(pool)
        guard journalCount > 0 else { return .nothing(.emptyJournal) }

        var mutations: [IndexMutation] = []
        var marks: [JournalMark] = []
        var conclusions: [Int64: JournalConclusion] = [:]
        var unresolved = 0
        // **Every correction goes in one transaction, so one `UNIQUE(files.path)`
        // is not one bad row — it rolls the whole pass back.** Every row then
        // stays `in_flight` and the next open fails in exactly the same way,
        // forever. Two `in_flight` rows naming one destination is enough to
        // reach that: two moves interrupted onto one path, which the plan's own
        // `claimedInBatch` rule cannot prevent across two crashed batches.
        // The first claim wins; the loser is marked with a conclusion that names
        // the path rather than left to poison the run.
        var claimed: Set<String> = []
        for row in rows {
            // `stat`ed once, here, and handed to both the decision and the
            // claim loser's fallback. A second `stat` for the collision case
            // would be a second trip to a volume that may be spinning up, in the
            // path this whole function is shaped around not blocking on.
            let srcFacts = Self.statFacts(row.src)
            var decision = Self.decide(row, srcFacts: srcFacts, records: records, now: now)
            if let taken = Self.claim(&claimed, decision.mutations) {
                // The loser still gets the correction that cannot collide:
                // retire its own source row if the path it names is stale. Its
                // destination is left for the walker, exactly as
                // `destinationDiffersFromTheSource` leaves one — dropping the
                // removal too would strand a row over a file that is gone.
                decision = Decision(
                    conclusion: .destinationClaimedByAnotherRow(taken),
                    mutations: Self.removalIfStale(row.src, srcFacts, records))
            }
            conclusions[row.opID] = decision.conclusion
            mutations.append(contentsOf: decision.mutations)
            if decision.conclusion == .malformed {
                unresolved += 1
            } else {
                marks.append(JournalMark(opID: row.opID, state: .reconciled, trashURL: nil))
            }
        }

        // **Abandoning has to be atomic with the write, not merely before it.**
        // Checking out here and committing anyway is what makes `.deferred` a
        // lie: `init` has already returned, having told its caller that nothing
        // landed and every row is still `in_flight`, while this thread is still
        // queueing for the writer behind a five-second busy timeout and will
        // then commit corrections computed from a snapshot up to `budget` old.
        // `.insertCopy` goes through `upsertRow`'s `ON CONFLICT`, so one of
        // those late writes can overwrite a row a tier 0 pass indexed properly
        // in the interim.
        //
        // So the check runs *inside* the transaction — once on acquiring the
        // writer, and again immediately before the commit — and throws rather
        // than returning, because only a throw makes GRDB roll the transaction
        // back. Nothing partial ever lands, and the rows stay `in_flight` for
        // the next open, which is the retry the whole design rests on.
        let applied: (Int, Int)
        do {
            applied = try pool.write { db -> (Int, Int) in
                guard !isAbandoned() else { throw AbandonedMidWrite() }
                let corrections = try Self.apply(db, mutations: mutations, marks: marks)
                let retired = try Self.retireJournal(db, now: now)
                willCommit()
                guard !isAbandoned() else { throw AbandonedMidWrite() }
                return (corrections, retired)
            }
        } catch is AbandonedMidWrite {
            return .nothing(.deferred)
        }
        return JournalReconcileReport(
            examined: rows.count, reconciled: marks.count, unresolved: unresolved,
            corrections: applied.0, retired: applied.1, conclusions: conclusions,
            disposition: .ran)
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
    private static func decide(_ row: OpJournalRow,
                               srcFacts src: StatFacts?,
                               records: [String: FileRecord], now: Double) -> Decision {
        let dstPath = row.dst
        let dst = dstPath.flatMap(statFacts)

        switch row.kind {
        case .move:
            guard let dstPath else { return Decision(conclusion: .malformed) }
            switch (src != nil, dst != nil) {
            case (true, false):
                return Decision(conclusion: .neverHappened)
            case (false, true):
                // **No row for `src` is not a mismatch.** It is an ordinary
                // state — a walk pruned the row while the app was shut, or the
                // file was never indexed — and there is simply nothing to
                // correct. Saying `destinationDiffersFromTheSource` here would
                // be a claim about the user's file ("what is at the destination
                // is not what you moved") made on the strength of a missing
                // index row, which is evidence of nothing.
                guard let record = records[row.src] else {
                    return Decision(conclusion: .happened)
                }
                // Something is at `dst`. **That is not the same claim as "the
                // file that moved is at `dst`"**, and rewriting the source's row
                // onto whatever is there hands a stranger the source's
                // `content_hash` — a digest describing bytes it does not
                // contain, on a row nothing will re-hash.
                guard let facts = dst, destinationMatches(record, facts) else {
                    return Decision(conclusion: .destinationDiffersFromTheSource,
                                    mutations: removalIfStale(row.src, src, records))
                }
                guard records[dstPath] == nil else {
                    // A tier 0 pass indexed the destination between the crash
                    // and this open. That row was read from the file itself, so
                    // it describes it better than the pre-move one does: retire
                    // the source row rather than move it onto a taken path.
                    return Decision(conclusion: .happened,
                                    mutations: removalIfStale(row.src, src, records))
                }
                guard let id = record.id else { return Decision(conclusion: .happened) }
                return Decision(conclusion: .happened,
                                mutations: [.move(id: id, fromPath: row.src,
                                                  to: URL(fileURLWithPath: dstPath))])
            case (true, true):
                // **The row the issue calls out.** A `move` row plus a
                // destination that exists is not permission to unlink the
                // source: a cross-volume move is a copy then a delete, and this
                // is what a crash between the two legs looks like. Both files
                // stay, whatever else is decided below.
                // No row for `src`, so nothing to compare against and nothing
                // to derive a destination row from — but the *conclusion* here
                // is about the filesystem, and the filesystem is unambiguous:
                // two files, and the source is one of them. `happened` would be
                // the false half of that, claiming a source that is demonstrably
                // still there is gone.
                guard let source = records[row.src] else {
                    return Decision(conclusion: .copyDoneDeleteNot)
                }
                guard let facts = dst, destinationMatches(source, facts) else {
                    // A destination that is not the source's length is a copy
                    // leg the crash interrupted. Nothing may be carried onto it
                    // — see `insert`.
                    return Decision(conclusion: .destinationDiffersFromTheSource)
                }
                var decision = Decision(conclusion: .copyDoneDeleteNot)
                if records[dstPath] == nil {
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
            guard let source = records[row.src] else {
                // Nothing to derive a row from. The copy happened; there is just
                // no source row to carry anything across from, and the walker
                // indexes the destination on its next pass.
                return Decision(conclusion: .happened)
            }
            guard destinationMatches(source, facts) else {
                // A stranger, or a copy the crash left short. Either way the
                // path is left for the walker.
                return Decision(conclusion: .destinationDiffersFromTheSource)
            }
            var decision = Decision(conclusion: .happened)
            if records[dstPath] == nil {
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
        src: StatFacts?, stash: StatFacts?
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
    /// Records the `files` path each mutation would write, and returns the path
    /// if one of them is already spoken for.
    ///
    /// Only writes to a *new* path can collide: `.remove` names a row that is
    /// going, and two removals of one row are a second no-op `DELETE`. The set
    /// is checked before it is added to, so a decision is taken whole or not at
    /// all — a row that both moves and inserts must not have half of it applied.
    private static func claim(_ claimed: inout Set<String>,
                              _ mutations: [IndexMutation]) -> String? {
        var wanted: [String] = []
        for mutation in mutations {
            switch mutation {
            case .remove: continue
            case .move(_, _, let destination): wanted.append(destination.path)
            case .insertCopy(let insert): wanted.append(insert.destination.path)
            }
        }
        if let taken = wanted.first(where: { claimed.contains($0) }) { return taken }
        claimed.formUnion(wanted)
        return nil
    }

    /// Whether the file now at a row's `dst` is the file the row was about.
    ///
    /// `size` and `mtime`, and **this is deliberately not the same test as
    /// `removalIfStale`'s**: there the path is unchanged, so a changed inode is
    /// itself evidence of a different file; here the path changed by
    /// construction, and a cross-volume move copies the bytes to a new inode.
    /// What every leg does preserve is length and modification time —
    /// `rename(2)` touches neither, `copyfile(3)` with `COPYFILE_ALL` carries
    /// the times across, and so does `clonefile`.
    ///
    /// It is doing two jobs at once, and both matter. A **stranger** that
    /// arrived at the destination in the plan/execute gap — the same gap
    /// `destinationNotReplaceable` exists for, widened to however long the app
    /// was shut — fails on both fields. A **copy the crash left short** fails on
    /// size, which is `verifyCopyLength`'s check asked after the fact.
    ///
    /// **The timestamp is compared with a tolerance and the length is not**,
    /// because only one of the two is quantised by the filesystem. "`copyfile`
    /// carries the times across" is an APFS sentence: measured against a real
    /// `COPYFILE_ALL`, exFAT rounds a modification time to 10 ms and the FAT
    /// family to 2 s, and SMB rounds in either direction. This app exists for a
    /// library on an external drive, so those are the *ordinary* volumes here,
    /// not the exotic ones — and an exact comparison failed identity on the
    /// user's own perfectly good copy, retired the hashed source row, and
    /// reported `destinationDiffersFromTheSource` about it. Two seconds covers
    /// the coarsest of them; the tolerance is symmetric because SMB can round
    /// up. Length stays exact, so a stranger has to match the source byte for
    /// byte in size *and* land within two seconds to be mistaken for it.
    static let destinationMtimeTolerance: Double = 2

    private static func destinationMatches(
        _ record: FileRecord,
        _ facts: StatFacts
    ) -> Bool {
        guard record.size == facts.size else { return false }
        if record.mtime == facts.mtime { return true }
        return abs(record.mtime - facts.mtime) <= destinationMtimeTolerance
    }

    private static func removalIfStale(
        _ path: String,
        _ facts: StatFacts?,
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
    /// **Only ever called for a destination that passed `destinationMatches`**,
    /// which is what makes carrying the source's dimensions, capture time and
    /// camera sound: the file at `dst` has the source's exact length and
    /// modification time, and none of those fields can change when bytes are
    /// copied. A destination that failed that test gets no row at all rather
    /// than a row with NULL dimensions — `needsReindex` keys on `size` and
    /// `mtime` alone, so a row whose facts match the file is never re-read, and
    /// a NULL-dimensioned row would keep its nulls forever. A path with no row
    /// is indexed completely by the next walk; a path with a wrong row is not.
    /// Hashes stay NULL regardless: length is not byte identity, and the digest
    /// is what the duplicate view deletes on.
    ///
    /// `volume_uuid` is left NULL rather than read: a `URLResourceValues` fetch
    /// is not a `stat`, and this runs at open with the writer about to be taken.
    /// NULL is exactly what the v2 migration leaves and what the next tier 0
    /// pass stamps, and `deleteRows`' matching rule already handles a NULL row.
    private static func insert(source: FileRecord, at path: String,
                               facts: StatFacts, now: Double) -> IndexMutation {
        .insertCopy(CopyInsert(
            source: source, destination: URL(fileURLWithPath: path),
            size: facts.size, mtime: facts.mtime, device: facts.device,
            inode: facts.inode, volumeUUID: nil, indexedAt: now,
            carryHashes: false))
    }

    /// `stat(2)` by path, in the shape `FileOperator` reads it, so a record
    /// written by tier 0 and a reading taken here compare equal for a file
    /// nothing has touched.
    private static func statFacts(_ path: String) -> StatFacts? {
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
    ///
    /// **`rn > 1` floors the age rule at one batch.** Thirty idle days is an
    /// ordinary holiday, and retention that takes the last batch with it turns
    /// ⌘Z into `noSuchBatch` for an operation the user still remembers doing.
    /// The age rule exists to bound the table, and one batch does not bound
    /// anything. The count rule keeps no such floor: at `rn > 200` there are by
    /// definition 200 newer batches to undo instead.
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
                    WHERE (last_touched < ? AND rn > 1) OR rn > ?
              )
            """, arguments: [OpJournalState.inFlight.rawValue, cutoff,
                             journalRetentionBatches])
        return db.changesCount
    }
}

/// Thrown from inside the reconcile's write transaction to roll it back.
///
/// A `return` cannot do this job: GRDB commits a `write` block that returns
/// normally, so the only way to discard staged corrections is to leave by
/// throwing. Private, and caught immediately by the one caller, so it never
/// reaches anybody as an error.
private struct AbandonedMidWrite: Error {}

/// The four `stat(2)` fields the reconcile reads, in the shape
/// `FileOperator.statFacts` returns them — so a record written by tier 0 and a
/// reading taken here compare field for field.
private typealias StatFacts = (size: Int64, mtime: Double, device: Int64, inode: Int64)

/// The one value the reconcile's background thread and `init` share.
///
/// A `Mutex` cannot be captured by an escaping closure directly — it is
/// non-copyable — so it lives inside a class, which is the shape the standard
/// library documents for exactly this. No `@unchecked Sendable` anywhere: the
/// `Mutex` is what makes the class Sendable.
private final class ReconcileSlot: Sendable {
    private let state = Mutex<(report: JournalReconcileReport?, abandoned: Bool)>(
        (nil, false))

    var report: JournalReconcileReport? { state.withLock { $0.report } }
    func isAbandoned() -> Bool { state.withLock { $0.abandoned } }
    func abandon() { state.withLock { $0.abandoned = true } }
    func finish(_ report: JournalReconcileReport) {
        state.withLock { if !$0.abandoned { $0.report = report } }
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
