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
    /// One file this transfer has put at its destination, **carrying the
    /// reading taken of its source at the moment the copy was verified**.
    ///
    /// The reading rides in the element rather than in a second array indexed
    /// alongside this one: the source-removal loop is the last thing standing
    /// between a stranger's file and an `unlink`, and a list paired by position
    /// is how both of phase 2's photo-losing bugs were written.
    struct Landing {
        let from: URL
        let to: URL
        /// `verifyCopyLength`'s `stat` of `from`, or nil for a `rename(2)` —
        /// which copies nothing and removes no source, so it never reaches the
        /// guard that reads this.
        let sourceFacts: FileOperator.StatFacts?
    }

    /// Every source→destination landing, in the order it landed.
    var moved: [Landing] = []
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
            // **Read before the attempt, because afterwards it is unanswerable.**
            // `copyfileCopy` passes `COPYFILE_EXCL` and `moveItem` refuses an
            // occupied path, so a copy that fails with `EEXIST` leaves a file at
            // the destination that this batch did not put there — one that
            // arrived in the plan/execute gap, the same gap the design already
            // documents for sources. "There is a file here now" is not "we
            // created it", and cleaning up on that reading unlinks a stranger's
            // photo, permanently, under a row saying nothing changed.
            let destinationPreexisted = !state.byRename
                && FileManager.default.fileExists(atPath: destination.path)
            do {
                var sourceFacts: FileOperator.StatFacts?
                if state.byRename {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try copier(source, destination, sameVolume && !isMove)
                    sourceFacts = try Self.verifyCopyLength(source: source,
                                                            destination: destination)
                }
                state.moved.append(TransferState.Landing(from: source, to: destination,
                                                         sourceFacts: sourceFacts))
            } catch {
                var cleanup: [String] = []
                var reason = FileOperationErrorMap.classify(error)
                if destinationPreexisted {
                    // Not ours. Say what actually happened — something is in the
                    // way that the plan never offered a resolution for — and
                    // leave it exactly where it is.
                    reason = .destinationNotReplaceable
                } else if !state.byRename,
                          FileManager.default.fileExists(atPath: destination.path) {
                    // This attempt created it, so this attempt clears it. A
                    // partial copy left behind under a row saying `failed` is
                    // the same lie every other swallowed cleanup told, so a
                    // removal that will not happen is reported rather than
                    // dropped.
                    do {
                        try FileManager.default.removeItem(at: destination)
                    } catch {
                        cleanup.append("a partial \(destination.lastPathComponent) is still "
                                       + "at \(destination.path): \(error)")
                    }
                }
                return undo(state, staged: staged, extraProblems: cleanup, failing: reason)
            }
        }

        if isMove && !state.byRename {
            // Over the landings, not over `files`: the only sources this may
            // unlink are the ones whose copies are known to have landed, and
            // each landing carries the reading its copy was verified against.
            for landing in state.moved {
                // **The unlink is guarded on identity, not on the path** (#33).
                // The window is narrow — the copies of the item's remaining
                // files, plus the unlinks of the ones before this one — but it
                // is a window in which the file at `from` can stop being the
                // file that was copied, and this is one of the two places in
                // the type where such a file is destroyed rather than
                // displaced.
                //
                // A landing with no reading is unreachable here: only a
                // `rename(2)` produces one, and this loop runs under
                // `isMove && !byRename`. It refuses rather than trusting the
                // path, because that is the safe direction for the one branch
                // no test can reach.
                guard let stamped = landing.sourceFacts else {
                    return abandon(state, marks: [], reason: .modifiedSinceOperation)
                }
                // **A `stat` that fails is not a mismatch**, which is the rule
                // `rowStillDescribes` states for the delete, read the same way
                // here. Something else removed the source between the copy and
                // this moment: "gone from the source, present at the
                // destination" is the shape a finished move leaves behind, and
                // there is nothing left to unlink. The copies are the only
                // copies from now on, so the undo must be told — that is what
                // `sourcesRemoved` is.
                guard let current = Self.statFacts(landing.from) else {
                    state.sourcesRemoved = true
                    continue
                }
                // A file that is there and is not the one that was copied.
                // `abandon` rather than an ordinary failure: the copy is
                // already at the destination, so "nothing changed" is not a
                // promise this path can make, and the rows stay `in_flight`
                // carrying both paths for the reconcile to re-`stat`.
                guard current == stamped else {
                    return abandon(state, marks: [], reason: .modifiedSinceOperation)
                }
                do {
                    try FileManager.default.removeItem(at: landing.from)
                    // Set per file, so a removal that fails part way through
                    // still tells the undo that *some* source is gone.
                    state.sourcesRemoved = true
                } catch {
                    // Through `undo`, so `sourcesRemoved` governs a live
                    // decision rather than being bookkeeping. The two branches
                    // are genuinely different: if nothing has been unlinked yet
                    // the copies are still undoable and this is an ordinary
                    // failure that leaves the world as it started; once anything
                    // has been unlinked they are the only copies of it, and
                    // `undo` declines rather than removing them.
                    return undo(state, staged: staged,
                                failing: state.sourcesRemoved
                                    ? .sourceRemovalFailed
                                    : FileOperationErrorMap.classify(error))
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
            return abandon(state, marks: earned, reason: reason)
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
                    guard let row = try store.record(atPath: source.path) else { continue }
                    guard let facts = Self.statFacts(destination) else {
                        // The copy landed — `verifyCopyLength` already `stat`ed
                        // it — so a `stat` that fails now is the filesystem
                        // going away underneath, not an absent row. Skipping it
                        // would mark the journal `complete` for a file with no
                        // index row at all.
                        throw FileOperationCheckError.destinationUnstatable
                    }
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
    ///
    /// **The `sourcesRemoved` branch is the one that saves a photo**, and it is
    /// reached from the source-removal loop, not from the copy loop: by the time
    /// a cross-volume move is unlinking, its copies are the only copies, and
    /// rolling them back would delete the file. It is a live decision — the
    /// other caller, the copy loop, runs before anything has been unlinked and
    /// takes the ordinary path.
    func undo(_ state: TransferState, staged: [StagedReplacement],
              extraProblems: [String] = [],
              failing reason: FileOperationFailure) -> ItemExecution {
        guard !state.sourcesRemoved else {
            return abandon(state, marks: [], reason: reason)
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

    /// Stops without undoing anything, and says where everything is.
    ///
    /// Two callers, and they arrive for different reasons. From the
    /// source-removal loop, because a cross-volume move has already unlinked
    /// something and the copies are now the only copies. From the disposal
    /// failure, because the displaced occupant is already in its stash or in the
    /// Trash, so putting the transfer back would leave the destination holding
    /// nothing at all — worse than leaving it holding the new file.
    ///
    /// The rows stay `in_flight` carrying both paths — the shape #6 already has
    /// to handle — and **the message describes where the files actually are**,
    /// which is not the same sentence in any of the four cases: a copy leaves
    /// its originals untouched; a same-volume move leaves them renamed to the
    /// destination; a cross-volume move that unlinked everything leaves the
    /// destination holding the last copies; and one stopped part way through
    /// its unlink loop — which the #33 identity guard can do at any landing —
    /// has some originals gone and some still where they were, so it names
    /// which are which rather than claiming either for all of them.
    /// Internal so the four wordings can be asserted directly. A same-volume
    /// move offers no seam between the `rename(2)` and the disposal — no
    /// injected closure is called in between — so the branch that describes it
    /// is unreachable end to end, and a description nothing checks is a
    /// description that drifts.
    func abandon(_ state: TransferState, marks: [JournalMark],
                 reason: FileOperationFailure) -> ItemExecution {
        // `sourceRemovalFailed` already means exactly what this function
        // produces — copy landed, source did not go, both paths exist — so it
        // is reported as itself rather than wrapped in a second description of
        // the same state.
        if case .sourceRemovalFailed = reason {
            return .failure(.sourceRemovalFailed, marksJournal: false, asideMarks: marks)
        }
        let directory = state.moved.first?.to.deletingLastPathComponent().path
            ?? "the destination"
        let names = state.moved.map(\.to.lastPathComponent).joined(separator: ", ")
        let fate: String
        if state.sourcesRemoved {
            // **Which ones**, when the unlink loop stopped part way through.
            // `sourcesRemoved` is set by the first removal, and the #33 identity
            // guard can refuse the very next file — so "the originals are gone"
            // would send the user to the destination for files that never left
            // their folder, and stop them looking at the source for the one
            // that is still sitting there. Read from the filesystem rather than
            // counted, because that is the question being answered.
            let manager = FileManager.default
            let partitioned = Dictionary(grouping: state.moved) {
                manager.fileExists(atPath: $0.from.path)
            }
            let sourceNames = { (landings: [TransferState.Landing]) in
                landings.map(\.from.lastPathComponent).joined(separator: ", ")
            }
            if let stillThere = partitioned[true], !stillThere.isEmpty {
                // Phrased as labelled lists rather than as sentences, so the
                // verb never has to agree with a count that is one file as
                // often as it is three.
                fate = "gone from their original paths and now only at "
                     + "\(directory): \(sourceNames(partitioned[false] ?? [])); "
                     + "still at their original paths: \(sourceNames(stillThere)); "
                     + "copies of everything are at \(directory)"
            } else {
                fate = "the originals are gone and \(names) are now only at \(directory)"
            }
        } else if state.byRename {
            fate = "\(names) have been moved to \(directory) and are no longer at their "
                 + "original paths"
        } else {
            fate = "\(names) have been copied to \(directory); the originals are untouched"
        }
        return .failure(.rollbackIncomplete("\(reason); \(fate)"),
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
    static func rollbackMoves(_ moved: [TransferState.Landing],
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
