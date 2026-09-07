import Foundation

/// One planned replacement bound to the journal row that was written for it.
///
/// **The binding is the point of this type.** The aside rows are written up
/// front, one per `PlannedItem.replacements` entry, before anything is touched.
/// Staging then skips any replacement whose occupant has vanished in the
/// plan/execute gap — so the staged list is a *subset*, and anything that pairs
/// the two by position afterwards attributes each row to the wrong file from
/// the first gap onwards. The observed result: the row for a file that was
/// never trashed acquired another file's Trash URL, and the file that really
/// was trashed kept no record at all. #6 reading that would restore a sidecar's
/// bytes over a RAW's path.
///
/// Carrying the `opID` alongside the replacement makes the mistake
/// unrepresentable: there is no offset to get wrong.
struct StagedReplacement {
    let replacement: PlannedReplacement
    /// The `op_journal` row written for this replacement, up front.
    let opID: Int64
    /// Whether the occupant was actually moved aside. False when it had already
    /// gone by the time the item ran — nothing was staged, and nothing has to be
    /// put back or disposed of.
    let staged: Bool

    var occupant: URL { replacement.occupant }
    var stash: URL { replacement.stash }
}

extension FileOperator {
    /// Moves every file this item will displace aside, pairing each with its
    /// journal row.
    ///
    /// Aside rather than deleted, and sent to the Trash only once the item has
    /// succeeded. The obvious implementation — unlink the destination, then
    /// move — has a window in which the user has neither file, and it is reached
    /// by something as ordinary as a full disk.
    ///
    /// **Every replacement comes back**, staged or not, so the caller's later
    /// passes over them stay aligned with the rows. A failure returns the whole
    /// `ItemExecution` the caller should hand back, because staging failure has
    /// two different shapes — one where the aside was cleanly undone and one
    /// where it was not — and only this function knows which happened.
    func prepareReplacements(_ item: PlannedItem, asideOps: [Int64],
                             batchSources: Set<String>)
        -> Result<[StagedReplacement], ItemExecution> {
        guard item.effectiveResolution == .replace, !item.replacements.isEmpty else {
            return .success([])
        }
        var staged: [StagedReplacement] = []
        for (replacement, opID) in zip(item.replacements, asideOps) {
            // A path this batch reads from is never "the existing file":
            // displacing it destroys one of the user's own selected photos. The
            // plan's `claimedInBatch` rule covers every route to this that the
            // public API can produce *except* one — an earlier item resolved to
            // `skip` claims no name, so a later item can see that item's source
            // as an ordinary occupant. This is the guard for that case.
            let path = replacement.occupant.path
            guard !batchSources.contains(path) else {
                return .failure(unwind(staged, allAsideOps: asideOps,
                                       reason: .destinationNotReplaceable))
            }
            // Gone already. Nothing to stage, nothing to restore, and nothing to
            // dispose of — but the row exists and must be settled explicitly
            // rather than left `in_flight` pointing at a stash that was never
            // created.
            guard FileManager.default.fileExists(atPath: path) else {
                staged.append(StagedReplacement(replacement: replacement, opID: opID,
                                                staged: false))
                continue
            }
            do {
                try FileManager.default.moveItem(at: replacement.occupant,
                                                 to: replacement.stash)
                staged.append(StagedReplacement(replacement: replacement, opID: opID,
                                                staged: true))
            } catch {
                return .failure(unwind(staged, allAsideOps: asideOps,
                                       reason: FileOperationErrorMap.classify(error)))
            }
        }
        return .success(staged)
    }

    /// Puts back whatever staging managed before it gave up, and reports the
    /// failure at the honesty the result deserves.
    ///
    /// A clean unwind is an ordinary `failed`: nothing changed, for the
    /// replacements that were staged and for the ones never reached alike — so
    /// **every** aside row is settled, not only the ones this call put back.
    /// Leaving the rest `in_flight` would send the reconcile looking for stashes
    /// that were never created.
    ///
    /// An unwind that could not put a file back is `rollbackIncomplete` with the
    /// rows left `in_flight`, because `failed` is defined as "nothing changed"
    /// and the reconcile is built never to re-examine it.
    private func unwind(_ staged: [StagedReplacement], allAsideOps: [Int64],
                        reason: FileOperationFailure) -> ItemExecution {
        let problems = Self.restore(staged, rollbackSucceeded: true)
        guard problems.isEmpty else {
            return .failure(.rollbackIncomplete(problems.joined(separator: "; ")),
                            marksJournal: false)
        }
        return .failure(reason, asideMarks: allAsideOps.map {
            JournalMark(opID: $0, state: .failed, trashURL: nil)
        })
    }

    /// Sends each displaced file to the Trash and settles its aside row.
    ///
    /// A failure carries the marks already earned, because those describe things
    /// that really happened: a photo already in the Trash whose row was dropped
    /// on the way out is a photo nobody can find.
    func disposeOfStash(_ staged: [StagedReplacement]) -> StashDisposal {
        guard !staged.isEmpty else { return .settled([]) }
        var marks: [JournalMark] = []
        for entry in staged {
            guard entry.staged else {
                // The occupant was gone before the item ran. Terminal, and
                // `failed` is the accurate word: the displacement was attempted
                // and nothing changed.
                marks.append(JournalMark(opID: entry.opID, state: .failed, trashURL: nil))
                continue
            }
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: entry.stash, resultingItemURL: &resulting)
            } catch {
                return .refused(FileOperationErrorMap.classify(error), marks)
            }
            guard let url = resulting as URL? else {
                // Trashed, and the system declined to say where. The row must
                // not say `complete` — there is nothing to undo it by — and it
                // must not say `failed`, which would claim the file is still at
                // `src`. Left `in_flight`, which means "ask the filesystem".
                return .refused(.trashURLNotRecorded(
                    "\(entry.occupant.lastPathComponent) was trashed but the system "
                    + "reported no destination"), marks)
            }
            do {
                try store.recordTrashURL(opID: entry.opID, path: url.path)
            } catch {
                // The one record of where this photo went could not be
                // persisted. Say so loudly and put the URL in the message: it is
                // the only copy of it that will survive this call.
                marks.append(JournalMark(opID: entry.opID, state: .complete,
                                         trashURL: url.path))
                return .refused(.trashURLNotRecorded(
                    "\(entry.occupant.lastPathComponent) is at \(url.path) but the "
                    + "journal could not be told: \(error)"), marks)
            }
            marks.append(JournalMark(opID: entry.opID, state: .complete, trashURL: url.path))
        }
        return .settled(marks)
    }

    /// Puts displaced files back, and reports what it could not.
    ///
    /// **It never deletes what is at the original path.** If the rollback that
    /// should have cleared that path failed, whatever is sitting there may be the
    /// user's own file — the source of a move that could not be undone — and
    /// removing it to make room would be the very loss this whole path exists to
    /// prevent. The stash is left where it is instead: it is journalled, so
    /// nothing is stranded, and the caller reports `.rollbackIncomplete`.
    ///
    /// Internal rather than private so the guard can be tested directly. The loss
    /// it prevents needs a same-volume move whose mid-item rename fails *and*
    /// whose rollback then fails, which is not constructible on demand against a
    /// real filesystem — and a safety guard nothing can exercise is a safety
    /// guard nothing will notice the removal of.
    static func restore(_ staged: [StagedReplacement],
                        rollbackSucceeded: Bool) -> [String] {
        var problems: [String] = []
        for entry in staged.reversed() where entry.staged {
            if !rollbackSucceeded || FileManager.default.fileExists(atPath: entry.occupant.path) {
                problems.append("\(entry.occupant.lastPathComponent) is still set aside at "
                                + entry.stash.path)
                continue
            }
            do {
                try FileManager.default.moveItem(at: entry.stash, to: entry.occupant)
            } catch {
                problems.append("\(entry.occupant.lastPathComponent) could not be put back "
                                + "from \(entry.stash.path): \(error)")
            }
        }
        return problems
    }

    /// The index rows of the files a `replace` displaced.
    ///
    /// **Over every replacement, not only the staged ones.** A replacement whose
    /// occupant had already vanished still has a row, and that row still names
    /// the exact path the move is about to write — so leaving it turns a move
    /// that succeeded completely on disk into `indexWriteFailed(UNIQUE
    /// files.path)`, with two stale rows left behind, one of them carrying a
    /// dead photo's `content_hash` at a path that now holds different bytes.
    ///
    /// The lookup is by the occupant's **real** path, which is why the plan
    /// carries it: on a case-insensitive volume the destination being written
    /// may differ in case from the file that is actually there, and
    /// `record(atPath:)` matches exactly.
    static func replacedRowRemovals(_ replacements: [PlannedReplacement],
                                    store: IndexStore) -> [IndexMutation] {
        replacements.compactMap { replacement in
            guard let row = try? store.record(atPath: replacement.occupant.path),
                  let id = row.id else { return nil }
            return .remove(id: id, path: replacement.occupant.path)
        }
    }
}

/// What became of the files a `replace` displaced.
enum StashDisposal {
    /// Every displaced file reached the Trash (or had already gone), and these
    /// marks settle their rows.
    case settled([JournalMark])
    /// Disposal stopped. The marks are the ones already earned and **must still
    /// be written**: they describe files that really did reach the Trash.
    case refused(FileOperationFailure, [JournalMark])
}
