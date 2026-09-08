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

    /// **Every filesystem call in this type is synchronous and blocking**, and
    /// there are a lot of them: a `rename(2)` per file, a `copyfile(3)` that
    /// runs for as long as the bytes take, a `trashItem` that talks to another
    /// process, and a `stat` before and after each. On an external drive that
    /// has gone to sleep, one of those parks a thread for seconds.
    ///
    /// The cooperative pool is exactly `activeProcessorCount` threads wide and
    /// never grows, so a thread parked in file IO is a thread the process has
    /// lost — three of them stalled CI about one run in two, which is issue #28.
    /// `BlockingWork` carries the `sample` that showed it. A batch of 300 files
    /// is the largest single lump of blocking work in Core, so this actor is the
    /// last place that should be running on that pool.
    ///
    /// An executor rather than hopping each call through `BlockingWork.run`:
    /// hopping would add a suspension point per file, and the item-level
    /// rollback argument is written in terms of what cannot interleave with
    /// what. The executor moves the whole body off the pool and introduces no
    /// new reentrancy at all.
    private let queue = BlockingWork.serialQueue(BlockingWork.fileOperatorLabel)

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Test seam for #28: the queue this actor's body actually ran on.
    ///
    /// Asserted on rather than trusted, because an executor is the kind of thing
    /// a later refactor drops without noticing — and its absence shows up only
    /// as an intermittently stalled CI job on a machine nobody is watching.
    func currentQueueLabel() -> String { BlockingWork.currentQueueLabel }

    /// Internal so the replacement machinery in `FileOperator+Replacements.swift`
    /// can reach it. Nothing outside `FileOperator` holds one.
    let store: IndexStore
    // Internal, not private: `FileOperator`'s own extensions live in
    // `FileOperator+Transfer.swift` and `FileOperator+Replacements.swift`, and
    // Swift has no access level for "this type, across files". Nothing but
    // `FileOperator` touches them.
    let volumeReader: @Sendable (URL) -> VolumeIdentity?
    let copier: Copying
    let clock: @Sendable () -> Double

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
                    // Not `?? []`. An unlistable directory is not an empty one,
                    // and treating it as empty moves the RAW and orphans the
                    // `.xmp` — silently, which is the worst way to arrive at the
                    // thing companion handling exists to prevent.
                    guard let listed = try? FileManager.default
                        .contentsOfDirectory(atPath: directory.path) else {
                        throw FileOperatorError.sourceDirectoryUnreadable(directory.path)
                    }
                    siblings = listed
                    siblingsByDirectory[directory.path] = listed
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
        // **The plan-time degrade is the guard against displacing the batch's
        // own photos** — a collision whose kind is `claimedInBatch` turns
        // `replace` into `rename` before anything runs, and `PlannedItem`'s
        // members are `let`s derived from `inputs`, so no caller can hand
        // `execute` a plan that says otherwise.
        //
        // What remains here is narrower and is not a second copy of that rule: a
        // replacement whose occupant is a *source* of this batch. The plan's rule
        // covers every route to that but one — an earlier item resolved to `skip`
        // claims no name, so a later item can meet that item's source as an
        // ordinary on-disk occupant. A destination-based check was tried here and
        // removed: an item's replacements are by construction at its own
        // destinations, so subtracting its own destinations left the test unable
        // to fire at all.
        let batchSources = Set(plan.items.flatMap(\.files).map(\.path))

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

            var execution = perform(item, plan: plan, ops: ops, asideOps: asideOps,
                                    batchSources: batchSources)
            // **Aside marks are written whatever became of the item.** They
            // describe a photo the user did not select that really was displaced
            // and really did reach the Trash; dropping them because the item
            // that displaced it then failed leaves that photo in the Trash under
            // a row naming nothing. The item's *own* rows still go unmarked when
            // the operator cannot say what happened to them.
            let marks = (execution.marksJournal ? Self.marks(ops, execution) : [])
                + execution.asideMarks
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

    /// Internal, not private: `FileOperator+Undo.swift` marks its own rows by
    /// exactly this rule, and a second copy of "per-file state overrides the
    /// item's, and only `trash` carries a URL" is a second copy to get wrong.
    static func marks(_ ops: [Int64], _ execution: ItemExecution) -> [JournalMark] {
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
    struct ItemExecution: Error {
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
                         batchSources: Set<String>) -> ItemExecution {
        switch plan.kind {
        case .move, .copy:
            performTransfer(item, kind: plan.kind, asideOps: asideOps,
                            batchSources: batchSources)
        case .trash: performTrash(item, ops: ops)
        case .delete: performDelete(item)
        }
    }

    /// Whether `row`'s hashes describe the bytes now at `source`.
    ///
    /// This is `setHashes(for:)`'s guard, read rather than written. `path` is
    /// already established — the row was fetched by it — so what is left to
    /// check is `size` and `mtime`, which together are exactly the evidence
    /// tier 0 uses to decide a file is unchanged. Anything else means the hashes
    /// on the row predate the bytes being copied. A false costs one re-hash. A wrong
    /// true writes a digest that describes different bytes onto a brand-new row
    /// that nothing will ever revisit — and the duplicate view deletes on those.
    static func hashesStillDescribe(_ row: FileRecord, at source: URL) -> Bool {
        guard row.hashedAt != nil, let facts = statFacts(source) else { return false }
        return row.size == facts.size && row.mtime == facts.mtime
    }

    /// Whether the file now at `url` is still the one `row` — and the plan —
    /// described.
    ///
    /// `setHashes(for:)`'s guard, read rather than written, and matching it
    /// field for field: the id the plan recorded, and `size`/`mtime`, which
    /// together are exactly the evidence tier 0 uses to decide a file is
    /// unchanged. The id matters on its own because `files.id` is a reused
    /// rowid — a reconcile that dropped this row and indexed a new file can
    /// hand the id straight to a different photo.
    ///
    /// **`inode` is deliberately not compared here, and is compared on the
    /// transfer's window.** The reading this one is judged against comes off a
    /// row that may be arbitrarily old, and `recordMetadataWrite` refreshes a
    /// row's `size`/`mtime` after an exiftool write without refreshing its
    /// `inode` — exiftool renames a rebuilt file into place, so the inode moves
    /// and the row keeps the old one forever after. Comparing it would refuse
    /// to delete every photo the app has ever edited. The transfer's facts are
    /// seconds old and taken by this same execution, so they carry no such
    /// staleness and use all four fields.
    ///
    /// **A row that is gone is not a row that agrees**, when the plan read one.
    /// A reconcile can prune a row between the plan and the batch, and a
    /// stranger can then take the path with nothing in the index describing it;
    /// falling through to `removeItem` there is the pre-#33 unlink, decided by
    /// the path alone. A nil `plannedID` is the other case entirely — a
    /// companion is not indexed in its own right, so there is nothing recorded
    /// about it to disagree with, and refusing would make a sidecar
    /// undeletable.
    ///
    /// **This is stricter than undo's** `modifiedSinceOperation` check
    /// (`FileOperator+Undo.swift`), which tolerates a missing row and carries
    /// on. The asymmetry is the point: undo *displaces* — it moves a file back,
    /// or sends a copy to the Trash — and a wrong guess there is recoverable,
    /// while `delete` unlinks and a wrong guess is not. When the evidence is
    /// missing the two paths must fall different ways.
    ///
    /// A `stat` that fails is not a mismatch: the file is gone, and
    /// `removeItem` reports that as `sourceVanished`, which is the truer
    /// sentence than "it changed".
    static func rowStillDescribes(_ row: FileRecord?, at url: URL,
                                  plannedID: Int64?) -> Bool {
        guard let row else { return plannedID == nil }
        // Not `let id = row.id, id != plannedID`: a nil id there would pass the
        // check silently, and silence is the wrong direction for a guard whose
        // false is one re-read and whose true is an `unlink`.
        if let plannedID, row.id != plannedID { return false }
        guard let facts = statFacts(url) else { return true }
        return row.size == facts.size && row.mtime == facts.mtime
    }

    // MARK: Trash

    /// Internal, not private, for the same reason `performTransfer` is: undo
    /// reverses a `copy` by trashing the copy, and it does it through *this*
    /// function rather than a second one. A separate trash path in the undo
    /// would be a second place to forget that the Trash URL is written in its
    /// own transaction before the item's, and that the row may only go once the
    /// file is confirmed to be in the Trash.
    func performTrash(_ item: PlannedItem, ops: [Int64]) -> ItemExecution {
        var execution = ItemExecution()
        var trashed: [(original: URL, trash: URL)] = []
        for (offset, file) in item.files.enumerated() {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
                guard let url = resulting as URL? else {
                    // The file is in the Trash and the system declined to say
                    // where. Throwing here would put it under a `failed` row,
                    // which claims it is still at `src`. Leave the row
                    // `in_flight` — "ask the filesystem" — and name the file.
                    return .failure(.trashURLNotRecorded(
                        "\(file.lastPathComponent) was trashed but the system reported "
                        + "no destination"), marksJournal: false)
                }
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
                    do {
                        try store.recordTrashURL(opID: ops[offset], path: url.path)
                    } catch {
                        // The only record of where this photo went could not be
                        // persisted. Fail loudly with the URL in the message,
                        // and leave the row `in_flight` rather than `failed`,
                        // which would claim the file never moved.
                        return .failure(.trashURLNotRecorded(
                            "\(file.lastPathComponent) is at \(url.path) but the journal "
                            + "could not be told: \(error)"), marksJournal: false)
                    }
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
        do {
            for file in item.files {
                guard let row = try store.record(atPath: file.path),
                      let id = row.id else { continue }
                execution.mutations.append(.remove(id: id, path: file.path))
            }
        } catch {
            // A read that threw is not "there is no row". The files are in the
            // Trash and their rows are not gone, so the journal must not say
            // `complete`; `in_flight` is the truth, and the trash URLs are
            // already persisted.
            return .failure(.indexWriteFailed(String(describing: error)),
                            marksJournal: false)
        }
        return execution
    }

    // MARK: Delete

    private func performDelete(_ item: PlannedItem) -> ItemExecution {
        var execution = ItemExecution()
        var firstFailure: FileOperationFailure?
        // The selected file carries the id the plan read for it; a companion has
        // none of its own, and neither does a selected file that was never
        // indexed — a nil `plannedID` makes the guard permissive for that file
        // by construction, because there is nothing recorded about it to
        // disagree with. Carried *in the element* rather than as a second list
        // indexed alongside `files`, which is how two of phase 2's photo-losing
        // bugs were written.
        let planned: [(url: URL, plannedID: Int64?)] =
            [(item.source, item.recordID)] + item.companions.map { ($0, nil) }
        // **Pre-sized, and `failed` until a file is actually unlinked.** The
        // states are read back by offset against this item's journal rows, and
        // `marks(_:_:)` falls back to `journalState` — `.complete` — for any
        // offset this array does not reach. An array built by appending is one
        // early exit away from marking an untouched row `complete`, which is the
        // one lie the journal must never tell: `complete` is the state the
        // reconcile is defined never to re-examine. Every path out of an
        // iteration therefore leaves the default in place, and only a successful
        // `removeItem` overwrites it.
        execution.perFileState = Array(repeating: .failed, count: planned.count)
        // The one non-atomic item. An unlinked file does not come back, so rather
        // than pretend the item failed as a whole, each file's journal row
        // records what happened to that file. The row is only marked after
        // `removeItem` has returned without throwing.
        for (offset, entry) in planned.enumerated() {
            let (file, plannedID) = entry
            do {
                // Read first, and let a failed read throw: unlinking a photo
                // whose row could not be looked up leaves the index describing
                // a file that is gone, with nothing recorded to fix it.
                let row = try store.record(atPath: file.path)
                // **The unlink is guarded on identity, not on the path** — the
                // read half of `setHashes(for:)`'s write guard (#33). This is
                // the one irreversible path in the type, and the plan/execute
                // gap is a human-length pause: a confirmation sheet, a
                // re-sorted grid. A file that arrived in that gap is a photo
                // nobody selected, and `removeItem` on the strength of the path
                // alone destroys it. Nothing has happened yet, so this is an
                // ordinary `failed`.
                if !Self.rowStillDescribes(row, at: file, plannedID: plannedID) {
                    if firstFailure == nil { firstFailure = .modifiedSinceOperation }
                    // **A refusal on the selected file refuses the whole item**,
                    // and this is the half of the guard that saves a file rather
                    // than merely declining to destroy one. A companion is a
                    // companion only because it shares the source's basename, so
                    // once the source is not the file that was planned for, its
                    // sidecars belong to *that* file: carrying on down the list
                    // would leave the stranger's photo untouched and unlink the
                    // stranger's `.xmp` — and a sidecar has no row of its own,
                    // so nothing else stands between it and `removeItem`.
                    // Every remaining row keeps its `failed` default, which is
                    // exactly true: nothing was touched.
                    if offset == 0 { break }
                    continue
                }
                try FileManager.default.removeItem(at: file)
                if let row, let id = row.id {
                    execution.mutations.append(.remove(id: id, path: file.path))
                }
                execution.perFileState[offset] = .complete
            } catch {
                let reason = FileOperationErrorMap.classify(error)
                if firstFailure == nil { firstFailure = reason }
            }
        }
        if let firstFailure { execution.outcome = .failed(firstFailure) }
        return execution
    }


    // MARK: - Filesystem helpers

    static func destinations(of item: PlannedItem) -> [URL]? {
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
    static func onSameVolume(_ source: VolumeIdentity?,
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
    ///
    /// **Returns the source's reading**, because that reading is the evidence
    /// the unlink needs later: a cross-volume move removes the source once
    /// every copy has landed, and "the file that was copied" is the only file
    /// it may remove. Taken here rather than re-`stat`ed at the unlink for the
    /// same reason it is taken here at all — this is the moment the copy is
    /// known to describe the source. See `TransferState.Landing`.
    @discardableResult
    static func verifyCopyLength(source: URL, destination: URL) throws -> StatFacts {
        guard let from = statFacts(source), let to = statFacts(destination) else {
            throw FileOperationCheckError.copyIncomplete
        }
        guard from.size == to.size else { throw FileOperationCheckError.copyIncomplete }
        return from
    }

    /// The four `stat(2)` fields this type compares, in the shape tier 0 writes
    /// them, so a record written by the walker and a reading taken here compare
    /// field for field.
    typealias StatFacts = (size: Int64, mtime: Double, device: Int64, inode: Int64)

    static func statFacts(_ url: URL) -> StatFacts? {
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
    /// A copy's destination could not be `stat`ed after it landed.
    case destinationUnstatable
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
