import Foundation

/// Moves, copies, trashes and deletes a selection, one cancellable batch at a
/// time (spec §8).
///
/// **The ordering invariant, which is the whole point of this type: journal,
/// then filesystem, then index.** The filesystem is not transactional, so the
/// three are reconciled rather than transacted. A row in `op_journal` exists
/// with `state = 'in_flight'` before a single byte moves; the index is only
/// changed after the filesystem operation has been confirmed to have
/// succeeded; and the index change and the `complete` mark are one transaction,
/// so there is no window in which the index has moved on and the journal has
/// not. Anything that interrupts the middle leaves an `in_flight` row, and
/// `in_flight` means exactly "ask the filesystem" — see `OpJournalState`, which
/// is the contract the launch-time reconcile (#6) reads.
///
/// **What is atomic and what is not.** An *item* — an image and the companions
/// travelling with it — is all-or-nothing for `move`, `copy` and `trash`: a
/// failure part way through undoes what that item already did, so a RAW is
/// never separated from its `.xmp`. It cannot be for `delete`, because an
/// unlinked file does not come back; there the journal records per file which
/// ones went. A *batch* is never all-or-nothing (spec §11): it returns
/// per-item results, and one unreadable file does not abandon the other 299.
///
/// **What this type does not do.** It does not import AppKit, it does not
/// undo (that is #6, which reads the journal this writes), and it does not
/// watch the filesystem.
public actor FileOperator {
    /// How bytes get from one path to another. Injected so a test can stage
    /// `ENOSPC`, a read-only filesystem, or a copy that returns success having
    /// written half the file — none of which can be produced on demand against
    /// a real temporary directory.
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
    /// The snapshot is deliberately not re-read when a resolution is applied.
    /// A file that appears in the destination directory between planning and
    /// executing is handled by the operation itself failing (`COPYFILE_EXCL`,
    /// and `moveItem` onto an occupied path), not by a second pre-flight that
    /// would only narrow the same race.
    public func plan(kind: FileOperationKind, sources: [URL], destination: URL?,
                     includeCompanions: Bool = true) throws -> FileOperationPlan {
        switch kind {
        case .move, .copy:
            guard destination != nil else { throw FileOperatorError.destinationRequired }
        case .trash, .delete:
            guard destination == nil else { throw FileOperatorError.destinationNotAllowed }
        }

        var occupied: Set<String> = []
        if let destination {
            guard let contents = try? FileManager.default
                    .contentsOfDirectory(atPath: destination.path),
                  volumeReader(destination) != nil else {
                throw FileOperatorError.destinationUnreadable(destination.path)
            }
            occupied = Set(contents.map { $0.lowercased() })
        }

        // Order-preserving de-duplication: the same file selected twice would
        // otherwise be journalled twice and, on a move, fail the second time
        // with a source that is no longer there.
        var seen: Set<String> = []
        let unique = sources.filter { seen.insert($0.path).inserted }
        let selected = Set(unique.map(\.path))

        var siblingsByDirectory: [String: [String]] = [:]
        var inputs: [PlanInput] = []
        inputs.reserveCapacity(unique.count)
        for source in unique {
            var companions: [URL] = []
            if includeCompanions {
                let directory = source.deletingLastPathComponent()
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
                                 occupiedNames: occupied, inputs: inputs)
    }

    // MARK: - Execution

    /// Runs a resolved plan and returns one result per item, in plan order.
    ///
    /// Cancellation is checked **between** items and never inside one: a batch
    /// stopped half way through a copy would leave a partial file, and the
    /// whole design rests on the filesystem being left in a state the journal
    /// describes. Items already finished stay finished and stay journalled;
    /// the rows of items never reached stay `in_flight`, which is precisely the
    /// signal #6's reconcile is built to resolve.
    @discardableResult
    public func execute(_ plan: FileOperationPlan,
                        onProgress: ProgressHandler? = nil) async throws
        -> [FileOperationResult] {
        guard !plan.hasUnresolvedCollisions else {
            throw FileOperatorError.unresolvedCollisions(plan.unresolvedCollisionIndices)
        }

        let dispositions = plan.items.map { Self.disposition(of: $0, kind: plan.kind) }
        let batchSources = Set(plan.items.flatMap(\.files).map(\.path))

        // The journal, up front and in one transaction: every file the batch
        // intends to touch, before the first one is touched. An item resolved
        // to `skip` gets no row — the journal records intent, and there is
        // none.
        var drafts: [JournalDraft] = []
        var journalRanges: [Range<Int>] = []
        for (index, item) in plan.items.enumerated() {
            guard case .attempt = dispositions[index] else {
                journalRanges.append(drafts.count..<drafts.count)
                continue
            }
            let start = drafts.count
            for (offset, file) in item.files.enumerated() {
                drafts.append(JournalDraft(kind: plan.kind, src: file,
                                           dst: Self.destination(of: item, at: offset)))
            }
            journalRanges.append(start..<drafts.count)
        }
        let opIDs = try store.journal(drafts, batchID: plan.batchID, timestamp: clock())

        let expectedDestinationVolume = plan.destinationDirectory.flatMap(volumeReader)
        var results: [FileOperationResult] = []
        results.reserveCapacity(plan.items.count)
        var volumeGone = false

        for (index, item) in plan.items.enumerated() {
            try Task.checkCancellation()
            let ops = Array(opIDs[journalRanges[index]])

            if volumeGone {
                try store.markJournal(ops.map {
                    JournalMark(opID: $0, state: .skipped, trashURL: nil)
                })
                results.append(Self.result(item, plan, .skipped(.volumeUnmounted)))
                onProgress?(index + 1, plan.items.count, item.source)
                continue
            }
            if case .skip(let reason) = dispositions[index] {
                results.append(Self.result(item, plan, .skipped(reason)))
                onProgress?(index + 1, plan.items.count, item.source)
                continue
            }
            // Re-read both volumes before every item rather than trusting the
            // one read at the start. An external drive can go away at file 12
            // of 300, and the cost of noticing is two `stat`s against the cost
            // of writing 288 files to whatever mounts at that path next.
            guard volumesStillAnswering(item, plan, expectedDestinationVolume) else {
                volumeGone = true
                try store.markJournal(ops.map {
                    JournalMark(opID: $0, state: .skipped, trashURL: nil)
                })
                results.append(Self.result(item, plan, .skipped(.volumeUnmounted)))
                onProgress?(index + 1, plan.items.count, item.source)
                continue
            }

            var execution = perform(item, plan: plan, batchSources: batchSources)
            let marks = execution.marksJournal ? Self.marks(ops, execution) : []
            do {
                if !execution.mutations.isEmpty || !marks.isEmpty {
                    // The applied count is deliberately not checked. A mutation
                    // a guard refused is one whose row no longer describes the
                    // file that was planned against — another pass has already
                    // moved on — and the filesystem operation still happened,
                    // so `complete` is the truth about the filesystem and the
                    // next tier 0 pass reconciles the row. Refusing to journal
                    // it would make an undoable operation un-undoable to
                    // protect an index entry that self-heals.
                    try store.applyAndMark(execution.mutations, marks: marks)
                }
            } catch {
                // The files moved and the rows did not. Leaving the journal
                // `in_flight` is the honest record of that: the filesystem is
                // ahead of the index, which is exactly the state the reconcile
                // exists to repair.
                execution.outcome = .failed(.indexWriteFailed(String(describing: error)))
            }
            results.append(Self.result(item, plan, execution.outcome,
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
        if item.resolution == .skip { return .skip(.collisionResolved) }
        // A move onto the path the file already occupies is not a move. It is
        // also the one case where `replace` would be catastrophic — unlink the
        // destination, then move a source that no longer exists — so it is
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

    private static func result(_ item: PlannedItem, _ plan: FileOperationPlan,
                               _ outcome: FileOperationOutcome,
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

    /// Whether the volumes this item needs are the ones that were there when
    /// planning started.
    private func volumesStillAnswering(_ item: PlannedItem, _ plan: FileOperationPlan,
                                       _ expectedDestination: VolumeIdentity?) -> Bool {
        if let destination = plan.destinationDirectory {
            guard let expectedDestination, let current = volumeReader(destination),
                  expectedDestination.matches(current) else { return false }
        }
        return volumeReader(item.source.deletingLastPathComponent()) != nil
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
        /// False for the one outcome the operator cannot describe: a
        /// cross-volume move whose copy landed and whose source removal did
        /// not. Both paths exist; only the filesystem knows what to do about
        /// it, so the rows stay `in_flight` for the reconcile.
        var marksJournal: Bool = true

        static func failure(_ reason: FileOperationFailure,
                            marksJournal: Bool = true) -> ItemExecution {
            ItemExecution(outcome: .failed(reason), journalState: .failed,
                          marksJournal: marksJournal)
        }
    }

    private func perform(_ item: PlannedItem, plan: FileOperationPlan,
                         batchSources: Set<String>) -> ItemExecution {
        switch plan.kind {
        case .move: performMove(item, batchSources: batchSources)
        case .copy: performCopy(item, batchSources: batchSources)
        case .trash: performTrash(item)
        case .delete: performDelete(item)
        }
    }

    // MARK: Move

    private func performMove(_ item: PlannedItem,
                             batchSources: Set<String>) -> ItemExecution {
        let files = item.files
        guard let destinations = Self.destinations(of: item) else {
            return .failure(.other("move planned without a destination"))
        }

        var stash: [Stashed] = []
        switch prepareReplacements(destinations, resolution: item.resolution,
                                   batchSources: batchSources) {
        case .failure(let reason): return .failure(reason)
        case .success(let prepared): stash = prepared
        }

        let sourceDirectory = item.source.deletingLastPathComponent()
        let sameVolume = Self.onSameVolume(volumeReader(sourceDirectory),
                                           volumeReader(destinations[0]
                                               .deletingLastPathComponent()))

        var moved: [(from: URL, to: URL)] = []
        for (source, destination) in zip(files, destinations) {
            do {
                if sameVolume {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    // A cross-volume move is a copy and then a delete. It is
                    // written out rather than left to `moveItem` precisely so
                    // the intermediate state is reachable and describable: if
                    // the copy lands and the removal does not, both paths
                    // exist, and the journal has to say so.
                    try copier(source, destination, false)
                    try Self.verifyCopyLength(source: source, destination: destination)
                }
                moved.append((source, destination))
            } catch {
                Self.rollbackMoves(moved, crossVolume: !sameVolume)
                Self.restore(stash)
                return .failure(FileOperationErrorMap.classify(error))
            }
        }

        if !sameVolume {
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
        execution.mutations = Self.replacedRowRemovals(stash, store: store)
        for (offset, destination) in destinations.enumerated() {
            guard let row = try? store.record(atPath: files[offset].path),
                  let id = row.id else { continue }
            execution.mutations.append(
                .move(id: id, fromPath: files[offset].path, to: destination))
        }
        Self.discard(stash)
        return execution
    }

    // MARK: Copy

    private func performCopy(_ item: PlannedItem,
                             batchSources: Set<String>) -> ItemExecution {
        let files = item.files
        guard let destinations = Self.destinations(of: item) else {
            return .failure(.other("copy planned without a destination"))
        }

        var stash: [Stashed] = []
        switch prepareReplacements(destinations, resolution: item.resolution,
                                   batchSources: batchSources) {
        case .failure(let reason): return .failure(reason)
        case .success(let prepared): stash = prepared
        }

        let sourceDirectory = item.source.deletingLastPathComponent()
        let clone = Self.onSameVolume(volumeReader(sourceDirectory),
                                      volumeReader(destinations[0]
                                          .deletingLastPathComponent()))

        var written: [URL] = []
        for (source, destination) in zip(files, destinations) {
            do {
                try copier(source, destination, clone)
                try Self.verifyCopyLength(source: source, destination: destination)
                written.append(destination)
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                try? FileManager.default.removeItem(at: destination)
                Self.restore(stash)
                return .failure(FileOperationErrorMap.classify(error))
            }
        }

        var execution = ItemExecution()
        execution.mutations = Self.replacedRowRemovals(stash, store: store)
        let indexedAt = clock()
        for (offset, destination) in destinations.enumerated() {
            let source = files[offset]
            guard let row = try? store.record(atPath: source.path),
                  let facts = Self.statFacts(destination) else { continue }
            execution.mutations.append(.insertCopy(CopyInsert(
                source: row, destination: destination,
                size: facts.size, mtime: facts.mtime,
                device: facts.device, inode: facts.inode,
                volumeUUID: volumeReader(destination.deletingLastPathComponent())?.uuid,
                indexedAt: indexedAt,
                carryHashes: Self.hashesStillDescribe(row, at: source))))
        }
        Self.discard(stash)
        return execution
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

    private func performTrash(_ item: PlannedItem) -> ItemExecution {
        var execution = ItemExecution()
        var trashed: [(original: URL, trash: URL)] = []
        for file in item.files {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
                guard let url = resulting as URL? else {
                    throw POSIXError(.EIO)
                }
                trashed.append((file, url))
                execution.trashURLs.append(url)
            } catch {
                // Undo the part that happened, so an image and its sidecar are
                // never half in the Trash.
                for entry in trashed.reversed() {
                    try? FileManager.default.moveItem(at: entry.trash, to: entry.original)
                }
                return .failure(FileOperationErrorMap.classify(error))
            }
        }
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
        // The one non-atomic item. An unlinked file does not come back, so
        // rather than pretend the item failed as a whole, each file's journal
        // row records what happened to that file.
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

    /// A destination moved out of the way so `replace` can be undone if the
    /// operation that was supposed to take its place fails.
    private struct Stashed {
        let original: URL
        let stash: URL
    }

    /// Moves every occupied destination aside.
    ///
    /// Aside rather than deleted, and deleted only once the item has succeeded.
    /// The obvious implementation — unlink the destination, then move — has a
    /// window in which the user has neither file, and it is reached by
    /// something as ordinary as a full disk. This one has no such window.
    private func prepareReplacements(_ destinations: [URL],
                                     resolution: CollisionResolution?,
                                     batchSources: Set<String>)
        -> Result<[Stashed], FileOperationFailure> {
        guard resolution == .replace else { return .success([]) }
        var stash: [Stashed] = []
        for destination in destinations
        where FileManager.default.fileExists(atPath: destination.path) {
            // A destination that is also one of this batch's sources must never
            // be moved aside: it is the file the batch is about to read.
            guard !batchSources.contains(destination.path) else {
                Self.restore(stash)
                return .failure(.destinationNotReplaceable)
            }
            let stashed = destination.deletingLastPathComponent()
                .appendingPathComponent(".lightbox-replaced-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: destination, to: stashed)
                stash.append(Stashed(original: destination, stash: stashed))
            } catch {
                Self.restore(stash)
                return .failure(FileOperationErrorMap.classify(error))
            }
        }
        return .success(stash)
    }

    private static func restore(_ stash: [Stashed]) {
        for entry in stash.reversed() {
            try? FileManager.default.removeItem(at: entry.original)
            try? FileManager.default.moveItem(at: entry.stash, to: entry.original)
        }
    }

    private static func discard(_ stash: [Stashed]) {
        for entry in stash { try? FileManager.default.removeItem(at: entry.stash) }
    }

    /// The index rows of the files a `replace` overwrote. They are removed in
    /// the same transaction as the rows taking their place — a replaced file's
    /// row left behind is a row for bytes that no longer exist, in a table
    /// duplicate detection reads.
    private static func replacedRowRemovals(_ stash: [Stashed],
                                            store: IndexStore) -> [IndexMutation] {
        stash.compactMap { entry in
            guard let row = try? store.record(atPath: entry.original.path),
                  let id = row.id else { return nil }
            return .remove(id: id, path: entry.original.path)
        }
    }

    private static func rollbackMoves(_ moved: [(from: URL, to: URL)], crossVolume: Bool) {
        for entry in moved.reversed() {
            if crossVolume {
                // The source was never removed on this path — only the copy
                // needs undoing.
                try? FileManager.default.removeItem(at: entry.to)
            } else {
                try? FileManager.default.moveItem(at: entry.to, to: entry.from)
            }
        }
    }

    // MARK: - Filesystem helpers

    private static func destinations(of item: PlannedItem) -> [URL]? {
        guard let destination = item.destination else { return nil }
        return [destination] + item.companionDestinations
    }

    /// The clone decision, and the cross-volume decision behind it.
    ///
    /// By `VolumeIdentity`, never by path prefix: `/Volumes/Photos` and
    /// `/Volumes/Photos Backup` share a prefix and are two drives, and a
    /// firmlink or a mounted disk image shares a prefix with the boot volume
    /// while being another filesystem. Either mistake turns a `rename(2)` into
    /// a cross-device `EXDEV` at best, and at worst asks `copyfile` to clone
    /// across volumes, which it cannot.
    ///
    /// Unknown on either side is treated as "not the same volume", which costs
    /// a copy where a clone would have done and is never wrong in the direction
    /// that matters.
    private static func onSameVolume(_ source: VolumeIdentity?,
                                     _ destination: VolumeIdentity?) -> Bool {
        guard let source, let destination else { return false }
        return source.matches(destination)
    }

    /// Confirms the copy is as long as its source, and throws if it is not.
    ///
    /// `copyfile(3)` reports failure by returning -1, but a filesystem that
    /// ran out of room under a buffered write can leave a short file behind a
    /// success. The length check is what makes hash carry-over safe to do at
    /// all: without it, a truncated copy would inherit the original's
    /// `content_hash` and become a file whose recorded digest describes bytes
    /// it does not contain, on a row nothing will ever re-hash.
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
        // The same expression the walker uses, so a record written by tier 0
        // and a `stat` taken here compare equal for an unchanged file.
        let seconds = TimeInterval(st.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return (size: Int64(st.st_size), mtime: seconds + nanoseconds,
                device: Int64(st.st_dev), inode: Int64(bitPattern: UInt64(st.st_ino)))
    }

    /// The production copier: `copyfile(3)`, cloning when both sides are on one
    /// volume.
    ///
    /// `COPYFILE_CLONE` implies `COPYFILE_EXCL`, and `COPYFILE_EXCL` is passed
    /// explicitly on the non-clone path too, so neither ever overwrites
    /// silently. Overwriting is the `replace` policy's job, and it does it by
    /// moving the existing file aside first.
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
    /// `FileOperationCheckError` has no errno, so it is mapped before the
    /// POSIX table is consulted.
    static func classify(_ error: any Error) -> FileOperationFailure {
        if error is FileOperationCheckError { return .copyIncomplete }
        switch posixCode(error) {
        case ENOENT?: return .sourceVanished
        case EACCES?, EPERM?: return .permissionDenied
        case EROFS?: return .destinationReadOnly
        case ENOSPC?, EDQUOT?: return .diskFull
        case ENXIO?, ENODEV?, ESTALE?: return .volumeUnmounted
        default: return .other(String(describing: error))
        }
    }
}
