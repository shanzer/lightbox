import Foundation

/// Why a batch cannot be reversed.
///
/// Thrown by `undo(batch:)` and reported ahead of time by `undoability(of:)`,
/// which is the point: **the UI has to be able to say "this cannot be undone"
/// before the user commits to it**, not after. A permanent delete is the case
/// that matters — a confirmation that arrives after the files are gone is not a
/// confirmation.
public enum UndoRefusal: Error, Sendable, Equatable, Hashable {
    /// No journal rows carry this `batch_id`. Either nothing has been done yet,
    /// or retention has aged the batch out.
    case noSuchBatch
    /// The batch permanently deleted files. Unlinking is not reversible and no
    /// amount of journal is going to make it so.
    case permanentDelete
    /// The batch has rows still `in_flight`: their outcome was never written
    /// down. The launch-time reconcile settles those, so this is what a batch
    /// interrupted *in this session* looks like — the crash case has already
    /// been resolved by the time a window is up.
    case unsettled(rows: Int)
    /// The batch has rows the launch-time reconcile had to resolve against the
    /// filesystem. What they did was reconstructed from two `stat`s after the
    /// fact, not recorded as it happened, and reversing an inference is how a
    /// half-finished cross-volume move turns into a lost photo. The reconcile's
    /// `JournalConclusion` says where each file actually is.
    case reconciledAfterACrash(rows: Int)
    /// The batch has `failed` rows. `failed` means nothing changed, so there is
    /// genuinely nothing to reverse for those — but a batch is offered as one
    /// undoable unit, and quietly reversing the half that worked while calling
    /// it "undo the batch" is the kind of partial truth this design keeps
    /// refusing elsewhere. The summary sheet already listed the failures.
    case someItemsFailed(rows: Int)
    /// Every row is `skipped`: the batch was journalled and then deliberately
    /// not attempted, so nothing happened to reverse.
    case nothingToUndo
}

/// Whether a batch can be reversed, and what reversing it would touch.
public struct BatchUndoability: Sendable, Equatable {
    public let batchID: String
    /// What the batch did, ignoring the aside rows a `replace` adds.
    public let kind: FileOperationKind?
    /// How many journal rows a reversal would act on.
    public let items: Int
    /// Nil when the batch can be undone.
    public let refusal: UndoRefusal?

    public var isUndoable: Bool { refusal == nil }
}

/// One reversal, and what it is reversing.
///
/// The `origin` row travels with the step rather than being looked up again by
/// position. Steps are built from a filtered subset of the batch's rows — a
/// `skipped` row produces none — so anything that indexed one list by the
/// other's offsets would attribute a reversal to the wrong photo the moment a
/// batch contained a skip. That is the mistake `StagedReplacement` exists to
/// make unrepresentable, in a second place.
struct UndoStep {
    /// The row being reversed.
    let origin: OpJournalRow
    /// The kind of the *reversing* operation, which is what its own journal row
    /// says — so that undoing the undo is the redo, with no extra state.
    let kind: FileOperationKind
    /// Where the file is now.
    let source: URL
    /// Where it goes back to. Nil when the reversal is a trash.
    let destination: URL?
    /// Whether `source` is a recorded Trash URL, which changes what a missing
    /// source means: an emptied Trash, not a vanished photo.
    let fromTrash: Bool
    /// A failure the step is known to have before it is attempted, so it can
    /// still be journalled and still produce a per-item result rather than
    /// disappearing from the list.
    let preFailure: FileOperationFailure?
}

/// The result of an undo: the new batch it ran as, and one result per step.
public struct UndoBatch: Sendable {
    /// The `batch_id` the reversal was journalled under. Undoing *this* is the
    /// redo.
    public let batchID: String
    public let results: [FileOperationResult]
}

extension FileOperator {
    // MARK: - What can be undone

    /// The newest batch in the journal, undoable or not.
    public func lastBatchID() throws -> String? { try store.lastJournalBatchID() }

    /// Whether `batchID` can be reversed, and why not when it cannot.
    ///
    /// **Only an all-`complete` batch is undoable**, and the order the refusals
    /// are tested in is the order the user needs to hear them: a permanent
    /// delete is reported first, whatever else the batch contains, because that
    /// is the one answer that has to arrive before the operation rather than
    /// after it.
    ///
    /// `skipped` rows do not block. Their contract is the strongest in the
    /// enumeration — journalled, deliberately not attempted, nothing changed —
    /// so a batch that lost its last three items to an unplugged drive is still
    /// exactly as undoable as the twelve items that ran. `failed` rows do block,
    /// even though they carry the same "nothing changed" promise, because a
    /// failure is something the user was shown and may have acted on; a skip is
    /// not.
    public func undoability(of batchID: String) throws -> BatchUndoability {
        let rows = try store.journalRows(batchID: batchID)
        guard !rows.isEmpty else {
            return BatchUndoability(batchID: batchID, kind: nil, items: 0,
                                    refusal: .noSuchBatch)
        }
        // The batch's kind is the kind of the rows the user's selection
        // produced. A `replace` adds `.trash` rows for photos the user did not
        // select, and reading the first row would report a move batch as a
        // trash batch.
        let kind = rows.first { !Self.isAside($0) }?.kind ?? rows[0].kind
        let refusal = Self.refusal(for: rows)
        let steps = refusal == nil ? Self.undoSteps(for: rows).count : 0
        return BatchUndoability(batchID: batchID, kind: kind, items: steps,
                                refusal: refusal)
    }

    private static func refusal(for rows: [OpJournalRow]) -> UndoRefusal? {
        if rows.contains(where: { $0.kind == .delete }) { return .permanentDelete }
        let inFlight = rows.count { $0.state == .inFlight }
        if inFlight > 0 { return .unsettled(rows: inFlight) }
        let reconciled = rows.count { $0.state == .reconciled }
        if reconciled > 0 { return .reconciledAfterACrash(rows: reconciled) }
        let failed = rows.count { $0.state == .failed }
        if failed > 0 { return .someItemsFailed(rows: failed) }
        guard rows.contains(where: { $0.state == .complete }) else { return .nothingToUndo }
        return nil
    }

    /// An aside row: the `.trash` row a `replace` writes for the photo it
    /// displaces, distinguished from a user's own trash by carrying a `dst` —
    /// the stash the occupant waited in.
    static func isAside(_ row: OpJournalRow) -> Bool {
        row.kind == .trash && row.dst != nil
    }

    // MARK: - Undo

    /// Reverses `batchID` **as a new batch**, one result per row it reversed.
    ///
    /// A new batch, with its own `batch_id` and its own `op_journal` rows, is
    /// what makes redo free: the reversal of a reversal is the original
    /// operation, so ⌘⇧Z is `undo(batch:)` on whatever `lastBatchID()` now
    /// returns. It is also what makes an undo as recoverable as anything else —
    /// it moves, trashes and restores real photos, and a crash in the middle of
    /// one leaves rows the same reconcile resolves.
    ///
    /// **Steps run in reverse journal order**, which is what puts an aside row
    /// after the item that displaced its occupant: the item's own reversal has
    /// to vacate the path before the displaced photo can come back to it.
    ///
    /// Reversal per kind:
    ///
    /// - `move` → move `dst` back to `src`. A cross-volume move undoes as a
    ///   cross-volume move, through the same `performTransfer` that made it, so
    ///   the copy-then-delete legs and the "the copies are the only copies"
    ///   guard are the ones already written and tested.
    /// - `copy` → **trash** the copy, never unlink it. A copy the user undoes is
    ///   still a file, and the whole design says a file this app removes goes
    ///   somewhere recoverable.
    /// - `trash`, plain or aside → move `trash_url` back to `src`. An emptied
    ///   Trash is a per-item `.trashEmptied`, not an exception.
    /// - `delete` → never reached; `undoability` refuses the whole batch.
    ///
    /// Nothing is skipped silently. A file that has been modified, moved away,
    /// or whose original path is now occupied produces a per-item failure with
    /// the reason, and the rest of the batch still reverses.
    @discardableResult
    public func undo(batch batchID: String,
                     onProgress: ProgressHandler? = nil) async throws -> UndoBatch {
        let rows = try store.journalRows(batchID: batchID)
        if let refusal = Self.refusal(for: rows) { throw refusal }
        let steps = Self.undoSteps(for: rows)

        let undoBatchID = UUID().uuidString
        let drafts = steps.map {
            JournalDraft(kind: $0.kind, src: $0.source, dst: $0.destination)
        }
        let opIDs = try store.journal(drafts, batchID: undoBatchID, timestamp: clock())

        var results: [FileOperationResult] = []
        results.reserveCapacity(steps.count)
        for (index, step) in steps.enumerated() {
            do {
                try Task.checkCancellation()
            } catch {
                throw FileOperatorError.cancelled(completed: results)
            }
            var execution = reverse(step, op: opIDs[index])
            let marks = execution.marksJournal ? Self.marks([opIDs[index]], execution) : []
            do {
                if !execution.mutations.isEmpty || !marks.isEmpty {
                    try store.applyAndMark(execution.mutations, marks: marks)
                }
            } catch {
                // Same rule as `execute`: the files moved and the rows did not,
                // so the journal must not claim otherwise. `in_flight` is the
                // honest record and the reconcile is what repairs it.
                execution.outcome = .failed(.indexWriteFailed(String(describing: error)))
            }
            results.append(FileOperationResult(
                source: step.source, destination: step.destination,
                trashURL: execution.trashURLs.first ?? nil, companions: [],
                outcome: execution.outcome))
            onProgress?(index + 1, steps.count, step.source)
            await itemBoundaryHook?(index + 1)
        }
        return UndoBatch(batchID: undoBatchID, results: results)
    }

    /// The steps that reverse `rows`, newest row first.
    ///
    /// **One step per journal row, and therefore one result per file** rather
    /// than per item. `execute` reports per item because an image and its
    /// sidecar succeed or fail together; an undo has no items to speak of — it
    /// has rows, each naming exactly one file, and a sidecar whose own reversal
    /// fails is a fact the user needs rather than one to fold into its image's
    /// verdict.
    static func undoSteps(for rows: [OpJournalRow]) -> [UndoStep] {
        rows.sorted { $0.opID > $1.opID }.compactMap { row -> UndoStep? in
            // `skipped` rows record an intent that was never carried out, and
            // `failed`/`reconciled` rows never reach here — `refusal` has
            // already turned the batch away.
            guard row.state == .complete else { return nil }
            switch row.kind {
            case .move:
                guard let dst = row.dst else { return nil }
                return UndoStep(origin: row, kind: .move,
                                source: URL(fileURLWithPath: dst),
                                destination: URL(fileURLWithPath: row.src),
                                fromTrash: false, preFailure: nil)
            case .copy:
                guard let dst = row.dst else { return nil }
                return UndoStep(origin: row, kind: .trash,
                                source: URL(fileURLWithPath: dst), destination: nil,
                                fromTrash: false, preFailure: nil)
            case .trash:
                // Plain and aside alike: both put a photo in the Trash and both
                // recorded where. The aside row's `dst` names the stash it
                // passed through, which is not where it is now.
                guard let trash = row.trashURL else {
                    // A `complete` trash row always carries one — `execute`
                    // records it before it may say `complete`. If one does not,
                    // the photo is in the Trash under a name nothing derives,
                    // and that is a per-item failure with a reason rather than a
                    // row quietly dropped from the list.
                    return UndoStep(origin: row, kind: .move,
                                    source: URL(fileURLWithPath: row.src),
                                    destination: URL(fileURLWithPath: row.src),
                                    fromTrash: true,
                                    preFailure: .trashURLNotRecorded(
                                        "\(URL(fileURLWithPath: row.src).lastPathComponent) "
                                        + "was trashed and no location was recorded"))
                }
                return UndoStep(origin: row, kind: .move,
                                source: URL(fileURLWithPath: trash),
                                destination: URL(fileURLWithPath: row.src),
                                fromTrash: true, preFailure: nil)
            case .delete:
                return nil
            }
        }
    }

    // MARK: One step

    /// Checks the world still matches what the row recorded, then reverses one
    /// step through the ordinary transfer and trash machinery.
    ///
    /// The pre-checks are the difference between an undo and a blind replay.
    /// Each one is a per-item failure that changes nothing:
    ///
    /// - the file is not where the row says it is → `.sourceVanished`, or
    ///   `.trashEmptied` when the row's `trash_url` is what is missing;
    /// - the path it would go back to is occupied → `.destinationNotReplaceable`
    ///   — **this is the check that stops an undone trash overwriting whatever
    ///   took the original path**, which after a trash is exactly the situation
    ///   the user would create by saving a new export there;
    /// - the file's `files` row no longer describes it → `.modifiedSinceOperation`.
    ///
    /// The last one reads the row rather than remembering a size, because the
    /// row *is* what the batch recorded: a move rewrites `path`, `parent_dir`
    /// and `name` and nothing else, so `size` and `mtime` on the row are still
    /// the ones from before the operation. A file with no row at all is still
    /// reversed — the photo is demonstrably where the journal says, and an index
    /// that has been rebuilt since is not a reason to refuse to move it back.
    private func reverse(_ step: UndoStep, op: Int64) -> ItemExecution {
        if let preFailure = step.preFailure { return .failure(preFailure) }
        guard let facts = Self.statFacts(step.source) else {
            return .failure(step.fromTrash ? .trashEmptied : .sourceVanished)
        }
        do {
            if let row = try store.record(atPath: step.source.path) {
                guard row.size == facts.size, row.mtime == facts.mtime else {
                    return .failure(.modifiedSinceOperation)
                }
            }
        } catch {
            // "There is no row" and "the index could not be asked" are different
            // answers; flattening them with `try?` would move a file on the
            // strength of a failed read.
            return .failure(.other("the index could not be read: \(error)"))
        }

        let item = PlannedItem(recordID: nil, source: step.source, companions: [],
                               destination: step.destination, companionDestinations: [],
                               collisions: [], resolution: nil,
                               effectiveResolution: nil, replacements: [])
        switch step.kind {
        case .move:
            guard let destination = step.destination else {
                return .failure(.other("a reversal of a move was built without a destination"))
            }
            guard Self.statFacts(destination) == nil else {
                return .failure(.destinationNotReplaceable)
            }
            // The same code path that made the move makes the move back,
            // including the cross-volume copy-then-delete legs and the guard
            // that refuses to remove a copy whose source has gone.
            return performTransfer(item, kind: .move, asideOps: [], batchSources: [])
        case .trash:
            return performTrash(item, ops: [op])
        case .copy, .delete:
            return .failure(.other("\(step.kind.rawValue) is not a reversal"))
        }
    }
}
