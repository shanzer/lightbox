import Foundation

/// Moves, copies, trashes and deletes a selection, one cancellable batch at a
/// time (spec §8).
///
/// **The ordering invariant, which is the whole point of this type: journal,
/// then filesystem, then index.** The filesystem is not transactional, so the
/// three are reconciled rather than transacted. A row in `op_journal` exists
/// with `state = 'in_flight'` before a single byte moves — including a row for
/// the file a `replace` displaces, which is a mutation of a photo the user did
/// not even select. The index is only changed after the filesystem operation has
/// been confirmed to have succeeded; the index change and the `complete` mark
/// are one transaction, so there is no window in which the index has moved on
/// and the journal has not. Anything that interrupts the middle leaves an
/// `in_flight` row, and `in_flight` means exactly "ask the filesystem" — see
/// `OpJournalState`, which is the contract the launch-time reconcile (#6) reads.
///
/// **What is atomic and what is not.** An *item* — an image and the companions
/// travelling with it — is all-or-nothing for `move`, `copy` and `trash`: a
/// failure part way through undoes what that item already did, so a RAW is never
/// separated from its `.xmp`. It cannot be for `delete`, because an unlinked
/// file does not come back; there the journal records per file which ones went.
/// A *batch* is never all-or-nothing (spec §11): it returns per-item results,
/// and one unreadable file does not abandon the other 299.
///
/// **When a rollback itself fails, the item stops claiming to know anything.**
/// Every undo path reports what it could not put back, and an item whose
/// rollback was incomplete is reported `.rollbackIncomplete` with its journal
/// rows left `in_flight`. Swallowing that — the natural `try?` — produces the
/// one genuinely unrecoverable record: a file sitting at the destination under a
/// row that says `failed`, which the reconcile is defined never to look at.
///
/// **What this type does not do.** It does not import AppKit, it does not undo
/// (that is #6, which reads the journal this writes), and it does not watch the
/// filesystem.
public actor FileOperator {
    /// How bytes get from one path to another. Injected so a test can stage
    /// `ENOSPC`, a read-only filesystem, or a copy that returns success having
    /// written half the file — none of which can be produced on demand against a
    /// real temporary directory.
    public typealias Copying =
        @Sendable (_ source: URL, _ destination: URL, _ clone: Bool) throws -> Void

    /// `(completed, total, currentPath)`, called once per finished item.
    public typealias ProgressHandler =
        @Sendable (_ completed: Int, _ total: Int, _ current: URL) -> Void

    private let store: IndexStore
    private let volumeReader: @Sendable (URL) -> VolumeIdentity?
    private let copier: Copying
    private let clock: @Sendable () -> Double

    public init(store: IndexStore,
                volumeReader: @escaping @Sendable (URL) -> VolumeIdentity?
                    = { VolumeIdentity(ofDirectory: $0) },
                copier: @escaping Copying = FileOperator.copyfileCopy,
                clock: @escaping @Sendable () -> Double
                    = { Date().timeIntervalSince1970 }) {
        self.store = store
        self.volumeReader = volumeReader
        self.copier = copier
        self.clock = clock
    }

    // MARK: - Pre-flight

    /// Works out what the batch would do, without doing any of it.
    ///
    /// The plan is what the UI shows and what `execute` runs; **`execute` only
    /// runs a plan whose collisions have all been resolved.** That is spec §8's
    /// "no batch discovers a collision at file 300": every destination is
    /// resolved here, against one snapshot of the destination directory taken
    /// once, so the answer cannot change between the sheet and the work.
    ///
    /// The snapshot is deliberately not re-read when a resolution is applied. A
    /// file that appears in the destination directory between planning and
    /// executing is handled by the operation itself failing (`COPYFILE_EXCL`,
    /// and `moveItem` onto an occupied path), not by a second pre-flight that
    /// would only narrow the same race.
    ///
    /// The volume answering at every distinct source directory, and at the
    /// destination, is captured here too. It is *this* moment the user chose,
    /// and an identity captured now is what lets each item ask "is this still
    /// the same drive?" rather than only "is something mounted here?".
    public func plan(kind: FileOperationKind, sources: [URL], destination: URL?,
                     includeCompanions: Bool = true) throws -> FileOperationPlan {
        switch kind {
        case .move, .copy:
            guard destination != nil else { throw FileOperatorError.destinationRequired }
        case .trash, .delete:
            guard destination == nil else { throw FileOperatorError.destinationNotAllowed }
        }

        var occupants: [String: String] = [:]
        var destinationVolume: VolumeIdentity?
        if let destination {
            guard let contents = try? FileManager.default
                    .contentsOfDirectory(atPath: destination.path),
                  let volume = volumeReader(destination) else {
                throw FileOperatorError.destinationUnreadable(destination.path)
            }
            destinationVolume = volume
            // Last writer wins for two names differing only in case, which can
            // only happen on a case-sensitive volume. Either is a real file and
            // either is a correct thing to refuse to overwrite silently.
            for name in contents { occupants[name.lowercased()] = name }
        }

        // Order-preserving de-duplication: the same file selected twice would
        // otherwise be journalled twice and, on a move, fail the second time
        // with a source that is no longer there.
        var seen: Set<String> = []
        let unique = sources.filter { seen.insert($0.path).inserted }
        let selected = Set(unique.map(\.path))

        var siblingsByDirectory: [String: [String]] = [:]
        var sourceVolumes: [String: VolumeIdentity] = [:]
        var inputs: [PlanInput] = []
        inputs.reserveCapacity(unique.count)
        for source in unique {
            let directory = source.deletingLastPathComponent()
            if sourceVolumes[directory.path] == nil, let volume = volumeReader(directory) {
                sourceVolumes[directory.path] = volume
            }
            var companions: [URL] = []
            if includeCompanions {
                var siblings = siblingsByDirectory[directory.path]
                if siblings == nil {
                    siblings = (try? FileManager.default
                        .contentsOfDirectory(atPath: directory.path)) ?? []
                    siblingsByDirectory[directory.path] = siblings
                }
                companions = CompanionFiles.companions(of: source,
                                                       siblingNames: siblings ?? [],
                                                       excluding: selected)
            }
            inputs.append(PlanInput(recordID: try store.record(atPath: source.path)?.id,
                                    source: source, companions: companions,
                                    resolution: nil))
        }

        return FileOperationPlan(batchID: UUID().uuidString, kind: kind,
                                 destinationDirectory: destination,
                                 includeCompanions: includeCompanions,
                                 occupants: occupants, sourceVolumes: sourceVolumes,
                                 destinationVolume: destinationVolume, inputs: inputs)
    }

    // MARK: - Execution

    /// Runs a resolved plan and returns one result per item, in plan order.
    ///
    /// Cancellation is checked **between** items and never inside one: a batch
    /// stopped half way through a copy would leave a partial file, and the whole
    /// design rests on the filesystem being left in a state the journal
    /// describes. Items already finished stay finished and stay journalled; the
    /// rows of items never reached stay `in_flight`, which is precisely the
    /// signal #6's reconcile is built to resolve. The results collected so far
    /// are carried out on `FileOperatorError.cancelled`, because a cancelled
    /// batch has done real work and the summary sheet has to be able to say
    /// what.
    @discardableResult
    public func execute(_ plan: FileOperationPlan,
                        onProgress: ProgressHandler? = nil) async throws
        -> [FileOperationResult] {
        guard !plan.hasUnresolvedCollisions else {
            throw FileOperatorError.unresolvedCollisions(plan.unresolvedCollisionIndices)
        }

        let dispositions = plan.items.map { Self.disposition(of: $0, kind: plan.kind) }
        let batchSources = Set(plan.items.flatMap(\.files).map(\.path))
        // Every path this batch is going to write. A `replace` must never
        // displace one of these: it would be either a source the batch is about
        // to read or an earlier item's landed photo. The plan already refuses the
        // second (`FileOperationCollision.Kind.claimedInBatch`); this is the
        // execute-time backstop, so a plan assembled some other way cannot get
        // past it either.
        let batchDestinations = Set(plan.items.flatMap { item -> [String] in
            guard let destination = item.destination else { return [] }
            return ([destination] + item.companionDestinations).map(\.path)
        })

        // The journal, up front and in one transaction: every file the batch
        // intends to touch, before the first one is touched. An item resolved to
        // `skip` gets no row — the journal records intent, and there is none.
        var drafts: [JournalDraft] = []
        var fileRanges: [Range<Int>] = []
        var asideRanges: [Range<Int>] = []
        for (index, item) in plan.items.enumerated() {
            guard case .attempt = dispositions[index] else {
                fileRanges.append(drafts.count..<drafts.count)
                asideRanges.append(drafts.count..<drafts.count)
                continue
            }
            let asideStart = drafts.count
            for replacement in item.replacements {
                // `kind = .trash` because that is where the displaced file ends
                // up, so #6 restores it by exactly the rule it uses for any other
                // trashed file. `dst` names the stash, which is the only place
                // the photo exists between the aside and the disposal — without
                // it a crash in that window leaves an unreferenced dot-file and a
                // journal that says nothing happened.
                drafts.append(JournalDraft(kind: .trash, src: replacement.occupant,
                                           dst: replacement.stash))
            }
            asideRanges.append(asideStart..<drafts.count)
            let start = drafts.count
            for (offset, file) in item.files.enumerated() {
                drafts.append(JournalDraft(kind: plan.kind, src: file,
                                           dst: Self.destination(of: item, at: offset)))
            }
            fileRanges.append(start..<drafts.count)
        }
        let opIDs = try store.journal(drafts, batchID: plan.batchID, timestamp: clock())

        var results: [FileOperationResult] = []
        results.reserveCapacity(plan.items.count)
        var volumeGone = false

        for (index, item) in plan.items.enumerated() {
            let ops = Array(opIDs[fileRanges[index]])
            let asideOps = Array(opIDs[asideRanges[index]])
            do {
                try Task.checkCancellation()
            } catch {
                throw FileOperatorError.cancelled(completed: results)
            }

            func skip(_ reason: FileOperationSkip, journalling: Bool) throws {
                if journalling {
                    try store.markJournal((ops + asideOps).map {
                        JournalMark(opID: $0, state: .skipped, trashURL: nil)
                    })
                }
                results.append(Self.result(item, .skipped(reason)))
                onProgress?(index + 1, plan.items.count, item.source)
            }

            if volumeGone {
                try skip(.volumeUnmounted, journalling: true)
                continue
            }
            if case .skip(let reason) = dispositions[index] {
                try skip(reason, journalling: false)
                continue
            }
            // Re-read the volumes before every item rather than trusting the one
            // read at plan time, and compare *identity* rather than presence. An
            // external drive can go away at file 12 of 300, and something else
            // can mount at that path; presence-only checking would hand the
            // remaining 288 files to whatever that is. The cost of knowing is two
            // `stat`s and a resource-value read.
            guard volumesStillAnswering(item, plan) else {
                volumeGone = true
                try skip(.volumeUnmounted, journalling: true)
                continue
            }

            // This item's own destinations are excluded from the backstop: the
            // file a `replace` displaces is by definition at the path this item
            // is writing to. What must never be displaced is a path *another*
            // item reads from or writes to.
            let ownDestinations = Set(([item.destination].compactMap { $0 }
                + item.companionDestinations).map(\.path))
            var execution = perform(item, plan: plan, ops: ops, asideOps: asideOps,
                                    batchSources: batchSources,
                                    batchDestinations:
                                        batchDestinations.subtracting(ownDestinations))
            let marks = execution.marksJournal
                ? Self.marks(ops, execution) + execution.asideMarks
                : []
            do {
                if !execution.mutations.isEmpty || !marks.isEmpty {
                    // The applied count is deliberately not checked. A mutation a
                    // guard refused is one whose row no longer describes the file
                    // that was planned against — another pass has already moved
                    // on — and the filesystem operation still happened, so
                    // `complete` is the truth about the filesystem and the next
                    // tier 0 pass reconciles the row. Refusing to journal it
                    // would make an undoable operation un-undoable to protect an
                    // index entry that self-heals.
                    try store.applyAndMark(execution.mutations, marks: marks)
                }
            } catch {
                // The files moved and the rows did not. Leaving the journal
                // `in_flight` is the honest record of that: the filesystem is
                // ahead of the index, which is exactly the state the reconcile
                // exists to repair.
                execution.outcome = .failed(.indexWriteFailed(String(describing: error)))
            }
            results.append(Self.result(item, execution.outcome,
                                       trashURL: execution.trashURLs.first ?? nil))
            onProgress?(index + 1, plan.items.count, item.source)
        }
        return results
    }

    // MARK: - Dispositions

    private enum Disposition {
        case attempt
        case skip(FileOperationSkip)
    }

    private static func disposition(of item: PlannedItem,
                                    kind: FileOperationKind) -> Disposition {
        if item.effectiveResolution == .skip { return .skip(.collisionResolved) }
        // A move onto the path the file already occupies is not a move. It is
        // also the one case where `replace` would be catastrophic — displace the
        // destination, then move a source that is no longer there — so it is
        // caught here rather than relied on not to arise.
        if kind == .move, let destination = item.destination,
           destination.path == item.source.path {
            return .skip(.alreadyAtDestination)
        }
        return .attempt
    }

    private static func destination(of item: PlannedItem, at offset: Int) -> URL? {
        guard item.destination != nil else { return nil }
        return offset == 0 ? item.destination : item.companionDestinations[offset - 1]
    }

    private static func result(_ item: PlannedItem, _ outcome: FileOperationOutcome,
                               trashURL: URL? = nil) -> FileOperationResult {
        FileOperationResult(source: item.source, destination: item.destination,
                            trashURL: trashURL, companions: item.companions,
                            outcome: outcome)
    }

    private static func marks(_ ops: [Int64], _ execution: ItemExecution) -> [JournalMark] {
        ops.enumerated().map { offset, opID in
            JournalMark(opID: opID,
                        state: execution.perFileState.indices.contains(offset)
                            ? execution.perFileState[offset]
                            : execution.journalState,
                        trashURL: execution.trashURLs.indices.contains(offset)
                            ? execution.trashURLs[offset]?.path
                            : nil)
        }
    }

    /// Whether the volumes this item needs are the ones the plan was made
    /// against.
    ///
    /// Identity, not presence, and for both the source and the destination —
    /// including for `trash` and `delete`, which have no destination but do have
    /// a source, and which are the two operations where getting it wrong
    /// destroys something. A source directory the plan could not read a volume
    /// for falls back to presence, which is all that is knowable about it.
    private func volumesStillAnswering(_ item: PlannedItem,
                                       _ plan: FileOperationPlan) -> Bool {
        if let destination = plan.destinationDirectory {
            guard let expected = plan.destinationVolume,
                  let current = volumeReader(destination),
                  expected.matches(current) else { return false }
        }
        let directory = item.source.deletingLastPathComponent()
        guard let current = volumeReader(directory) else { return false }
        guard let expected = plan.sourceVolumes[directory.path] else { return true }
        return expected.matches(current)
    }

    // MARK: - One item

    /// What one item's filesystem work produced, before any of it reaches the
    /// index.
    private struct ItemExecution {
        var outcome: FileOperationOutcome = .completed
        var mutations: [IndexMutation] = []
        /// Parallel to the item's files; nil for every kind but `trash`.
        var trashURLs: [URL?] = []
        /// Per-file journal states, used only where an item is not atomic —
        /// `delete`, where a failure part way through cannot be undone.
        var perFileState: [OpJournalState] = []
        /// The state every one of this item's journal rows gets. Overridden per
        /// file by `perFileState`.
        var journalState: OpJournalState = .complete
        /// Marks for the replacement-aside rows, which have their own lifecycle:
        /// `complete` once the displaced file has reached the Trash, `failed`
        /// once it has been put back, and left `in_flight` whenever neither is
        /// certain.
        var asideMarks: [JournalMark] = []
        /// False for the outcomes the operator cannot describe: a cross-volume
        /// move whose copy landed and whose source removal did not, and any item
        /// whose rollback could not put everything back. The rows stay
        /// `in_flight` for the reconcile.
        var marksJournal: Bool = true

        static func failure(_ reason: FileOperationFailure,
                            marksJournal: Bool = true,
                            asideMarks: [JournalMark] = []) -> ItemExecution {
            ItemExecution(outcome: .failed(reason), journalState: .failed,
                          asideMarks: asideMarks, marksJournal: marksJournal)
        }
    }

    private func perform(_ item: PlannedItem, plan: FileOperationPlan,
                         ops: [Int64], asideOps: [Int64],
                         batchSources: Set<String>,
                         batchDestinations: Set<String>) -> ItemExecution {
        switch plan.kind {
        case .move, .copy:
            performTransfer(item, kind: plan.kind, asideOps: asideOps,
                            batchSources: batchSources,
                            batchDestinations: batchDestinations)
        case .trash: performTrash(item, ops: ops)
        case .delete: performDelete(item)
        }
    }

    // MARK: Move and copy

    private func performTransfer(_ item: PlannedItem, kind: FileOperationKind,
                                 asideOps: [Int64], batchSources: Set<String>,
                                 batchDestinations: Set<String>) -> ItemExecution {
        let files = item.files
        guard let destinations = Self.destinations(of: item) else {
            return .failure(.other("\(kind.rawValue) planned without a destination"))
        }

        var stash: [PlannedReplacement] = []
        switch prepareReplacements(item, batchSources: batchSources,
                                   batchDestinations: batchDestinations) {
        case .failure(let reason): return .failure(reason)
        case .success(let prepared): stash = prepared
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
        let byRename = isMove && sameVolume

        var moved: [(from: URL, to: URL)] = []
        for (source, destination) in zip(files, destinations) {
            do {
                if byRename {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try copier(source, destination, sameVolume && !isMove)
                    try Self.verifyCopyLength(source: source, destination: destination)
                }
                moved.append((source, destination))
            } catch {
                // A failed copy can leave a partial file; a failed `rename(2)`
                // leaves nothing. Clear the one that just failed before undoing
                // the ones that succeeded.
                if !byRename { try? FileManager.default.removeItem(at: destination) }
                return undo(moved, stash: stash, byRename: byRename,
                            failing: FileOperationErrorMap.classify(error))
            }
        }

        if isMove && !byRename {
            for source in files {
                do {
                    try FileManager.default.removeItem(at: source)
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
        switch disposeOfStash(stash, ops: asideOps) {
        case .failure(let reason):
            // The operation landed but the displaced file could not be disposed
            // of. Nothing is lost — it is in its stash, and the aside row names
            // it — but the operator cannot claim the item is settled.
            _ = reason
            return undoAfterDisposalFailure(moved, byRename: byRename)
        case .success(let marks):
            execution.asideMarks = marks
        }

        execution.mutations = Self.replacedRowRemovals(stash, store: store)
        for (offset, destination) in destinations.enumerated() {
            let source = files[offset]
            if isMove {
                guard let row = try? store.record(atPath: source.path),
                      let id = row.id else { continue }
                execution.mutations.append(.move(id: id, fromPath: source.path,
                                                 to: destination))
            } else {
                guard let row = try? store.record(atPath: source.path),
                      let facts = Self.statFacts(destination) else { continue }
                execution.mutations.append(.insertCopy(CopyInsert(
                    source: row, destination: destination,
                    size: facts.size, mtime: facts.mtime,
                    device: facts.device, inode: facts.inode,
                    volumeUUID: volumeReader(destination.deletingLastPathComponent())?.uuid,
                    indexedAt: clock(),
                    carryHashes: Self.hashesStillDescribe(row, at: source))))
            }
        }
        return execution
    }

    /// Puts back what this item already did, and **says whether it managed to**.
    ///
    /// The `try?` this replaces was the quiet failure: a rollback that silently
    /// did nothing left a file at the destination under a journal row saying
    /// `failed`, and `failed` is defined to mean "nothing changed" — a claim the
    /// reconcile is built never to re-examine. An item that could not be undone
    /// reports `.rollbackIncomplete` and keeps its rows `in_flight` instead.
    private func undo(_ moved: [(from: URL, to: URL)], stash: [PlannedReplacement],
                      byRename: Bool,
                      failing reason: FileOperationFailure) -> ItemExecution {
        var problems = Self.rollbackMoves(moved, byRename: byRename)
        problems += Self.restore(stash, rollbackSucceeded: problems.isEmpty)
        guard problems.isEmpty else {
            return .failure(.rollbackIncomplete(problems.joined(separator: "; ")),
                            marksJournal: false)
        }
        // Everything is back where it started, including any displaced file, so
        // the aside genuinely did not happen either.
        return .failure(reason)
    }

    private func undoAfterDisposalFailure(_ moved: [(from: URL, to: URL)],
                                          byRename: Bool) -> ItemExecution {
        let problems = Self.rollbackMoves(moved, byRename: byRename)
        let combined = (problems + ["displaced file left in its stash"])
            .joined(separator: "; ")
        return .failure(.rollbackIncomplete(combined), marksJournal: false)
    }

    /// Whether `row`'s hashes describe the bytes now at `source`.
    ///
    /// This is `setHashes(for:)`'s guard, read rather than written: the row's
    /// `path`, `size` and `mtime` together are exactly the evidence tier 0 uses
    /// to decide a file is unchanged, so anything else means the hashes on the
    /// row predate the bytes being copied. A false costs one re-hash. A wrong
    /// true writes a digest that describes different bytes onto a brand-new row
    /// that nothing will ever revisit — and the duplicate view deletes on those.
    private static func hashesStillDescribe(_ row: FileRecord, at source: URL) -> Bool {
        guard row.hashedAt != nil, let facts = statFacts(source) else { return false }
        return row.size == facts.size && row.mtime == facts.mtime
    }

    // MARK: Trash

    private func performTrash(_ item: PlannedItem, ops: [Int64]) -> ItemExecution {
        var execution = ItemExecution()
        var trashed: [(original: URL, trash: URL)] = []
        for (offset, file) in item.files.enumerated() {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
                guard let url = resulting as URL? else { throw POSIXError(.EIO) }
                trashed.append((file, url))
                execution.trashURLs.append(url)
                // Written now, in its own small transaction, rather than waiting
                // for the index transaction at the end of the item. Between
                // `trashItem` returning and that transaction committing this URL
                // is the *only* record of where the photo went — the Trash
                // renames on collision, so the name is not derivable — and an
                // index write that fails, or the rollback below discarding the
                // in-memory results, would lose it for good.
                if ops.indices.contains(offset) {
                    try? store.recordTrashURL(opID: ops[offset], path: url.path)
                }
            } catch {
                // Undo the part that happened, so an image and its sidecar are
                // never half in the Trash.
                var problems: [String] = []
                for entry in trashed.reversed() {
                    do {
                        try FileManager.default.moveItem(at: entry.trash, to: entry.original)
                    } catch {
                        problems.append("\(entry.original.lastPathComponent) is still in the "
                                        + "Trash at \(entry.trash.path)")
                    }
                }
                guard problems.isEmpty else {
                    return .failure(.rollbackIncomplete(problems.joined(separator: "; ")),
                                    marksJournal: false)
                }
                return .failure(FileOperationErrorMap.classify(error))
            }
        }
        // Only now, with every file confirmed in the Trash, may a row go.
        for file in item.files {
            guard let row = try? store.record(atPath: file.path), let id = row.id else { continue }
            execution.mutations.append(.remove(id: id, path: file.path))
        }
        return execution
    }

    // MARK: Delete

    private func performDelete(_ item: PlannedItem) -> ItemExecution {
        var execution = ItemExecution()
        var firstFailure: FileOperationFailure?
        // The one non-atomic item. An unlinked file does not come back, so rather
        // than pretend the item failed as a whole, each file's journal row
        // records what happened to that file. The row is built only after
        // `removeItem` has returned without throwing.
        for file in item.files {
            do {
                let row = try? store.record(atPath: file.path)
                try FileManager.default.removeItem(at: file)
                if let row, let id = row.id {
                    execution.mutations.append(.remove(id: id, path: file.path))
                }
                execution.perFileState.append(.complete)
            } catch {
                let reason = FileOperationErrorMap.classify(error)
                if firstFailure == nil { firstFailure = reason }
                execution.perFileState.append(.failed)
            }
        }
        if let firstFailure { execution.outcome = .failed(firstFailure) }
        return execution
    }

    // MARK: - Replacement staging

    /// Moves every file this item will displace aside.
    ///
    /// Aside rather than deleted, and sent to the Trash only once the item has
    /// succeeded. The obvious implementation — unlink the destination, then
    /// move — has a window in which the user has neither file, and it is reached
    /// by something as ordinary as a full disk.
    private func prepareReplacements(_ item: PlannedItem, batchSources: Set<String>,
                                     batchDestinations: Set<String>)
        -> Result<[PlannedReplacement], FileOperationFailure> {
        guard item.effectiveResolution == .replace, !item.replacements.isEmpty else {
            return .success([])
        }
        var stash: [PlannedReplacement] = []
        for replacement in item.replacements {
            // The execute-time backstop for the plan's `claimedInBatch` rule. A
            // path this batch reads from, or that another item writes to, is
            // never "the existing file": displacing it destroys one of the
            // user's own selected photos. The plan already refuses to produce
            // such a replacement; this refuses to act on one however it arrived.
            let path = replacement.occupant.path
            guard !batchSources.contains(path), !batchDestinations.contains(path) else {
                _ = Self.restore(stash, rollbackSucceeded: true)
                return .failure(.destinationNotReplaceable)
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.moveItem(at: replacement.occupant,
                                                 to: replacement.stash)
                stash.append(replacement)
            } catch {
                _ = Self.restore(stash, rollbackSucceeded: true)
                return .failure(FileOperationErrorMap.classify(error))
            }
        }
        return .success(stash)
    }

    /// Sends each displaced file to the Trash and marks its aside row.
    private func disposeOfStash(_ stash: [PlannedReplacement], ops: [Int64])
        -> Result<[JournalMark], FileOperationFailure> {
        guard !stash.isEmpty else { return .success([]) }
        var marks: [JournalMark] = []
        for (offset, entry) in stash.enumerated() {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: entry.stash, resultingItemURL: &resulting)
                guard let url = resulting as URL?, ops.indices.contains(offset) else {
                    throw POSIXError(.EIO)
                }
                try? store.recordTrashURL(opID: ops[offset], path: url.path)
                marks.append(JournalMark(opID: ops[offset], state: .complete,
                                         trashURL: url.path))
            } catch {
                return .failure(FileOperationErrorMap.classify(error))
            }
        }
        return .success(marks)
    }

    /// Puts displaced files back, and reports what it could not.
    ///
    /// **It never deletes what is at the original path.** If the rollback that
    /// should have cleared that path failed, whatever is sitting there may be the
    /// user's own file — the source of a move that could not be undone — and
    /// removing it to make room would be the very loss this whole path exists to
    /// prevent. The stash is left where it is instead: it is journalled, so
    /// nothing is stranded, and the caller reports `.rollbackIncomplete`.
    private static func restore(_ stash: [PlannedReplacement],
                                rollbackSucceeded: Bool) -> [String] {
        var problems: [String] = []
        for entry in stash.reversed() {
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

    /// The index rows of the files a `replace` displaced. They are removed in the
    /// same transaction as the rows taking their place — a displaced file's row
    /// left behind is a row for bytes that are no longer at that path, in a table
    /// duplicate detection reads. The lookup is by the occupant's **real** path,
    /// which is why the plan carries it: on a case-insensitive volume the
    /// destination being written may differ in case from the file that is
    /// actually there, and `record(atPath:)` matches exactly.
    private static func replacedRowRemovals(_ stash: [PlannedReplacement],
                                            store: IndexStore) -> [IndexMutation] {
        stash.compactMap { entry in
            guard let row = try? store.record(atPath: entry.occupant.path),
                  let id = row.id else { return nil }
            return .remove(id: id, path: entry.occupant.path)
        }
    }

    /// Undoes the transfers this item already made, returning what it could not
    /// undo.
    private static func rollbackMoves(_ moved: [(from: URL, to: URL)],
                                      byRename: Bool) -> [String] {
        var problems: [String] = []
        for entry in moved.reversed() {
            do {
                if byRename {
                    try FileManager.default.moveItem(at: entry.to, to: entry.from)
                } else {
                    // The source was never removed on this path — only the copy
                    // needs undoing.
                    try FileManager.default.removeItem(at: entry.to)
                }
            } catch {
                problems.append("\(entry.to.lastPathComponent) is still at \(entry.to.path): "
                                + "\(error)")
            }
        }
        return problems
    }

    // MARK: - Filesystem helpers

    private static func destinations(of item: PlannedItem) -> [URL]? {
        guard let destination = item.destination else { return nil }
        return [destination] + item.companionDestinations
    }

    /// The clone decision, and the cross-volume decision behind it.
    ///
    /// By `VolumeIdentity`, never by path prefix: `/Volumes/Photos` and
    /// `/Volumes/Photos Backup` share a prefix and are two drives, and a firmlink
    /// or a mounted disk image shares a prefix with the boot volume while being
    /// another filesystem. Either mistake turns a `rename(2)` into a cross-device
    /// `EXDEV` at best, and at worst asks `copyfile` to clone across volumes,
    /// which it cannot.
    ///
    /// Unknown on either side is treated as "not the same volume", which costs a
    /// copy where a clone would have done and is never wrong in the direction
    /// that matters.
    private static func onSameVolume(_ source: VolumeIdentity?,
                                     _ destination: VolumeIdentity?) -> Bool {
        guard let source, let destination else { return false }
        return source.matches(destination)
    }

    /// Confirms the copy is as long as its source, and throws if it is not.
    ///
    /// `copyfile(3)` reports failure by returning -1, but a filesystem that ran
    /// out of room under a buffered write can leave a short file behind a
    /// success. The length check is what makes hash carry-over safe to do at all:
    /// without it, a truncated copy would inherit the original's `content_hash`
    /// and become a file whose recorded digest describes bytes it does not
    /// contain, on a row nothing will ever re-hash.
    private static func verifyCopyLength(source: URL, destination: URL) throws {
        guard let from = statFacts(source), let to = statFacts(destination) else {
            throw FileOperationCheckError.copyIncomplete
        }
        guard from.size == to.size else { throw FileOperationCheckError.copyIncomplete }
    }

    static func statFacts(_ url: URL)
        -> (size: Int64, mtime: Double, device: Int64, inode: Int64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        // The same expression the walker uses, so a record written by tier 0 and
        // a `stat` taken here compare equal for an unchanged file.
        let seconds = TimeInterval(st.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return (size: Int64(st.st_size), mtime: seconds + nanoseconds,
                device: Int64(st.st_dev), inode: Int64(bitPattern: UInt64(st.st_ino)))
    }

    /// The production copier: `copyfile(3)`, cloning when both sides are on one
    /// volume.
    ///
    /// `COPYFILE_CLONE` implies `COPYFILE_EXCL`, and `COPYFILE_EXCL` is passed
    /// explicitly on the non-clone path too, so neither ever overwrites silently.
    /// Overwriting is the `replace` policy's job, and it does it by moving the
    /// existing file aside first.
    public static let copyfileCopy: Copying = { source, destination, clone in
        let flags: copyfile_flags_t = clone
            ? copyfile_flags_t(COPYFILE_CLONE)
            : copyfile_flags_t(COPYFILE_ALL) | copyfile_flags_t(COPYFILE_EXCL)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }
}

/// Failures this type detects itself rather than receiving from the system.
enum FileOperationCheckError: Error {
    case copyIncomplete
}

extension FileOperationErrorMap {
    /// errno first, then the Cocoa and OSStatus domains.
    ///
    /// The order matters: a `FileManager` path operation carries a POSIX code
    /// under a Cocoa one and errno is the more specific of the two, while
    /// `trashItem` carries no POSIX code at all and would otherwise fall all the
    /// way through to `.other`.
    static func classify(_ error: any Error) -> FileOperationFailure {
        if error is FileOperationCheckError { return .copyIncomplete }
        if let code = posixCode(error) {
            switch code {
            case ENOENT: return .sourceVanished
            case EACCES, EPERM: return .permissionDenied
            case EROFS: return .destinationReadOnly
            case ENOSPC, EDQUOT: return .diskFull
            case ENXIO, ENODEV, ESTALE: return .volumeUnmounted
            default: break
            }
        }
        if let mapped = domainFailure(error) { return mapped }
        return .other(String(describing: error))
    }
}
