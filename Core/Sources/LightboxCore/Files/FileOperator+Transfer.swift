import Foundation

/// What a transfer has actually done to the filesystem so far.
///
/// **`sourcesRemoved` is load-bearing, not bookkeeping.** A cross-volume move is
/// a copy followed by unlinking the sources, and the moment it has unlinked
/// them the copies at the destination are *the only copies*. Every undo path has
/// to be able to ask that question, and before this type existed none of them
/// could: the undo was handed a list of `(from, to)` pairs and removed every
/// `to`, which after the unlink deletes the user's photo and leaves a journal
/// row naming two paths that hold nothing.
///
/// That was reachable on the app's most ordinary gesture. The library lives on
/// an external drive, so a move off it is cross-volume by definition; the
/// disposal that triggers the undo needs only a destination volume that cannot
/// create a `.Trashes` (exFAT, an SMB share, a folder the user cannot write), a
/// `trashItem` that returns no URL, or a `SQLITE_BUSY` on the journal write.
struct TransferState {
    /// Every `(source, destination)` pair that landed, in the order it landed.
    var moved: [(from: URL, to: URL)] = []
    /// Whether the sources have been unlinked. Only a cross-volume move ever
    /// sets it, and once it is set the destinations are irreplaceable.
    var sourcesRemoved = false
    /// Whether the transfer was `rename(2)` rather than copy-then-delete. A
    /// rename is undone by renaming back; a copy by removing the copy — and the
    /// second of those is the dangerous one.
    let byRename: Bool
}

extension FileOperator {
    // MARK: Move and copy

    func performTransfer(_ item: PlannedItem, kind: FileOperationKind,
                         asideOps: [Int64], batchSources: Set<String>) -> ItemExecution {
        let files = item.files
        guard let destinations = Self.destinations(of: item) else {
            return .failure(.other("\(kind.rawValue) planned without a destination"))
        }

        var staged: [StagedReplacement] = []
        switch prepareReplacements(item, asideOps: asideOps, batchSources: batchSources) {
        case .failure(let execution): return execution
        case .success(let prepared): staged = prepared
        }

        let sourceDirectory = item.source.deletingLastPathComponent()
        let sameVolume = Self.onSameVolume(volumeReader(sourceDirectory),
                                           volumeReader(destinations[0]
                                               .deletingLastPathComponent()))
        let isMove = kind == .move
        // Within one volume a move is `rename(2)`. Across volumes — and for
        // every copy — it is a copy, written out rather than left to `moveItem`
        // precisely so the intermediate state is reachable: if the copy lands and
        // the source removal does not, both paths exist and the journal has to be
        // able to say so.
        var state = TransferState(byRename: isMove && sameVolume)

        for (source, destination) in zip(files, destinations) {
            do {
                if state.byRename {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try copier(source, destination, sameVolume && !isMove)
                    try Self.verifyCopyLength(source: source, destination: destination)
                }
                state.moved.append((source, destination))
            } catch {
                // A failed copy can leave a partial file; a failed `rename(2)`
                // leaves nothing. Clear the one that just failed before undoing
                // the ones that succeeded — and if it will not clear, say so: a
                // partial file left at the destination under a row saying
                // `failed` is the same lie every other swallowed cleanup told.
                var cleanup: [String] = []
                if !state.byRename, FileManager.default.fileExists(atPath: destination.path) {
                    do {
                        try FileManager.default.removeItem(at: destination)
                    } catch {
                        cleanup.append("a partial \(destination.lastPathComponent) is still "
                                       + "at \(destination.path): \(error)")
                    }
                }
                return undo(state, staged: staged, extraProblems: cleanup,
                            failing: FileOperationErrorMap.classify(error))
            }
        }

        if isMove && !state.byRename {
            for source in files {
                do {
                    try FileManager.default.removeItem(at: source)
                    // Set per file, so a removal that fails part way through
                    // still tells the undo that *some* source is gone.
                    state.sourcesRemoved = true
                } catch {
                    // Deliberately not rolled back and deliberately not
                    // journalled: the copy is good, the source is still there,
                    // and deleting either one on a guess is how a photo gets
                    // lost. The `in_flight` row is the correct record.
                    return .failure(.sourceRemovalFailed, marksJournal: false)
                }
            }
        }

        var execution = ItemExecution()
        // The displaced files go to the Trash now that the operation that took
        // their place has succeeded — to the Trash rather than to `unlink`,
        // because `replace` must be as undoable as `trash` is, and because a
        // journal row naming a Trash URL is a row #6 already knows how to
        // reverse.
        switch disposeOfStash(staged) {
        case .refused(let reason, let earned):
            // The operation landed but a displaced file could not be disposed
            // of. The item is not settled — but by now the sources of a
            // cross-volume move are already gone, so this must not be treated as
            // undoable work.
            return abandon(state, marks: earned,
                           because: "displaced file not disposed of: \(reason)")
        case .settled(let marks):
            execution.asideMarks = marks
        }

        do {
            execution.mutations = try Self.replacedRowRemovals(item.replacements, store: store)
            for (source, destination) in zip(files, destinations) {
                if isMove {
                    guard let row = try store.record(atPath: source.path),
                          let id = row.id else { continue }
                    execution.mutations.append(.move(id: id, fromPath: source.path,
                                                     to: destination))
                } else {
                    guard let row = try store.record(atPath: source.path),
                          let facts = Self.statFacts(destination) else { continue }
                    execution.mutations.append(.insertCopy(CopyInsert(
                        source: row, destination: destination,
                        size: facts.size, mtime: facts.mtime,
                        device: facts.device, inode: facts.inode,
                        volumeUUID: volumeReader(destination.deletingLastPathComponent())?.uuid,
                        indexedAt: self.clock(),
                        carryHashes: Self.hashesStillDescribe(row, at: source))))
                }
            }
        } catch {
            // **A read that threw is not "there is no row".** Flattening the two
            // with `try?` would build a short mutation list, mark the journal
            // `complete`, and leave the index describing files that have moved.
            // The filesystem work stands; the rows stay `in_flight`.
            return .failure(.indexWriteFailed(String(describing: error)),
                            marksJournal: false, asideMarks: execution.asideMarks)
        }
        return execution
    }

    // MARK: Undo

    /// Puts back what this item already did, and **says whether it managed to**.
    ///
    /// The `try?` this replaces was the quiet failure: a rollback that silently
    /// did nothing left a file at the destination under a journal row saying
    /// `failed`, and `failed` is defined to mean "nothing changed" — a claim the
    /// reconcile is built never to re-examine. An item that could not be undone
    /// reports `.rollbackIncomplete` and keeps its rows `in_flight` instead.
    func undo(_ state: TransferState, staged: [StagedReplacement],
              extraProblems: [String] = [],
              failing reason: FileOperationFailure) -> ItemExecution {
        guard !state.sourcesRemoved else {
            return abandon(state, marks: [], because: String(describing: reason))
        }
        var problems = extraProblems + Self.rollbackMoves(state.moved, byRename: state.byRename)
        problems += Self.restore(staged, rollbackSucceeded: problems.isEmpty)
        guard problems.isEmpty else {
            return .failure(.rollbackIncomplete(problems.joined(separator: "; ")),
                            marksJournal: false)
        }
        // Everything is back where it started, including any displaced file, so
        // the aside genuinely did not happen either.
        return .failure(reason)
    }

    /// Stops, without undoing anything, because undoing would destroy the file.
    ///
    /// Reached once a cross-volume move has unlinked its sources: the copies at
    /// the destination are the only copies, so the correct response to a later
    /// failure is to leave them exactly where they are and say so. The rows stay
    /// `in_flight` carrying both paths — the copy-landed, source-gone shape #6
    /// already has to handle — and the message names the directory to look in,
    /// rather than describing a rollback that must not happen.
    private func abandon(_ state: TransferState, marks: [JournalMark],
                         because reason: String) -> ItemExecution {
        let directory = state.moved.first?.to.deletingLastPathComponent().path ?? "the destination"
        let names = state.moved.map(\.to.lastPathComponent).joined(separator: ", ")
        return .failure(.rollbackIncomplete(
            "\(reason); the originals are gone and \(names) are now only at \(directory)"),
            marksJournal: false, asideMarks: marks)
    }

    /// Undoes the transfers this item already made, returning what it could not
    /// undo.
    ///
    /// **The non-rename branch refuses to remove a copy whose source has gone.**
    /// That is the second line of the same defence `TransferState.sourcesRemoved`
    /// provides at the call site: a copy is only undoable while the thing it was
    /// copied from still exists, and once it does not, removing the copy is the
    /// loss rather than the undo. Kept as well as the flag, because the flag is
    /// the kind of thing a later refactor forgets to thread through.
    static func rollbackMoves(_ moved: [(from: URL, to: URL)],
                              byRename: Bool) -> [String] {
        var problems: [String] = []
        for entry in moved.reversed() {
            do {
                if byRename {
                    try FileManager.default.moveItem(at: entry.to, to: entry.from)
                } else {
                    guard FileManager.default.fileExists(atPath: entry.from.path) else {
                        problems.append("\(entry.to.lastPathComponent) is the only copy left "
                                        + "and stays at \(entry.to.path)")
                        continue
                    }
                    try FileManager.default.removeItem(at: entry.to)
                }
            } catch {
                problems.append("\(entry.to.lastPathComponent) is still at \(entry.to.path): "
                                + "\(error)")
            }
        }
        return problems
    }
}
