import Foundation

public enum IndexCoordinatorError: Error, Equatable, Sendable {
    /// The scan's own root could not be enumerated: it does not exist, is not
    /// readable, or its volume is not mounted.
    ///
    /// Thrown rather than reported as an empty folder. An unplugged external
    /// drive is indistinguishable from a folder whose every file was deleted,
    /// and this app is built to browse external drives — reconciling on that
    /// mistake would erase the whole index for the drive and report success.
    case rootUnreadable(String)
}

/// Drives the indexing pipeline.
///
/// Tier 0 — walk, stat, read metadata properties, upsert — runs on every folder
/// open. It decodes nothing: ImageIO's property dictionary is a header read.
/// Thumbnails are not generated here; the grid requests them for the cells it
/// is actually showing, which makes viewport priority a property of the UI
/// rather than something this actor has to model. The perceptual hash and the
/// two SHA-256 hashes need a decode or a whole-file read, so they belong to the
/// tier 1 pass.
///
/// **Reentrancy.** `indexTier0`'s body is entirely synchronous, so the actor
/// still runs a whole tier 0 pass without interleaving. `runHashingPass` is
/// not: it suspends inside the actor while a batch is hashed concurrently, and
/// during that suspension any other pass can run. Two hazards follow, and each
/// is closed by a different mechanism because they are different problems.
///
/// - *Wasted work.* Two overlapping hashing passes would both read the same
///   `hashed_at IS NULL` rows and hash every one of them twice. A hashing pass
///   therefore holds `hashingPassInFlight` across each whole batch — read,
///   hash, write — so a second pass can only ever see rows the first has
///   already finished with. The gate is released between batches, so a hashing
///   pass never blocks a folder open for longer than one batch.
/// - *A stale write.* A tier 0 pass running in the same window can re-index a
///   file whose bytes changed, clearing that row's hashes. The hashing pass
///   would then write hashes of the old bytes back over it with `hashed_at`
///   set, so no later pass would ever revisit it. This one is *not* fixed by
///   the gate: tier 0 does not take it, and nothing stops a second
///   `IndexCoordinator` from sharing this store. It is fixed in the database
///   instead — `IndexStore.setHashes(for:…)` refuses a write whose row no
///   longer has the path, size and mtime that were hashed. See that method for
///   why an id alone is not enough.
///
/// What is deliberately *not* serialised: a tier 0 pass may run between two
/// hashing batches, and should. Its reconcile is unaffected by hashing, which
/// only ever updates hash columns of rows that already exist — it inserts
/// nothing, deletes nothing, and touches no path, so it cannot make a live set
/// stale or a delete wrong.
public actor IndexCoordinator {
    private let store: IndexStore
    private let walker: Walker
    private let metadata: any MetadataReading
    private let hasher: any FileHashing
    private let grayscale: any GrayscaleRendering
    private let concurrency: Int
    /// How the volume answering at a path is read. Injected for the same reason
    /// the walker and the metadata reader are: the guards below turn on a
    /// *change* of volume between two moments in one pass, and a test cannot
    /// stage that against the real filesystem without mounting something.
    private let volumeReader: @Sendable (URL) -> VolumeIdentity?

    /// Set for the duration of a hashing batch, with the callers waiting to run
    /// one of their own. See the reentrancy note above.
    private var hashingPassInFlight = false
    private var hashingPassWaiters: [CheckedContinuation<Void, Never>] = []
    private var paused = false

    public init(store: IndexStore,
                walker: Walker = Walker(),
                metadata: any MetadataReading = MetadataReader(),
                hasher: any FileHashing = FileHasher(),
                grayscale: any GrayscaleRendering = GrayscaleRenderer(),
                concurrency: Int = 4,
                volumeReader: @escaping @Sendable (URL) -> VolumeIdentity?
                    = { VolumeIdentity(ofDirectory: $0) }) {
        self.store = store
        self.walker = walker
        self.metadata = metadata
        self.hasher = hasher
        self.grayscale = grayscale
        self.concurrency = max(1, concurrency)
        self.volumeReader = volumeReader
    }

    /// Walks `root`, re-reads whatever changed, and removes rows for files that
    /// are no longer there.
    ///
    /// **The reconcile's invariant: a row may only be deleted on the evidence
    /// of a complete look at the place that row lives.** A path's absence from
    /// an incomplete walk is not evidence that the file was deleted. Three
    /// things can make a walk incomplete, and each is handled rather than
    /// ignored:
    ///
    /// - The task was cancelled, so the walk stopped early → `CancellationError`
    ///   and no reconcile at all.
    /// - The root could not be enumerated → `IndexCoordinatorError.rootUnreadable`
    ///   and no reconcile at all.
    /// - A subtree or an individual entry could not be looked at → its rows are
    ///   protected from the delete, and the pass finishes normally.
    ///
    /// A fourth guard is not about completeness but about identity: the volume
    /// answering at `root` must be the volume the rows were indexed from, or
    /// the walk is evidence about a different filesystem. See the volume check
    /// below, and the matching rule on `IndexStore.deleteRows`.
    ///
    /// **The invariant has one deliberate exception.** Three structural changes
    /// make the walker stop producing a subtree while emitting no skip at all,
    /// so the reconcile does delete those rows: a directory replaced by a
    /// symlink (not followed, by default), a directory renamed into one of the
    /// opaque bundle extensions (`.photoslibrary`, `.app`, …), and a directory
    /// renamed to start with a dot. These are ruled correct rather than fixed:
    /// in each case the walker will never index those files again, so keeping
    /// the rows would leave the index describing files the app cannot see. The
    /// consequence is worth knowing before it surprises someone — renaming a
    /// folder to `.Archive` drops its rows, and renaming it back and rescanning
    /// restores them.
    @discardableResult
    public func indexTier0(root: URL, recursive: Bool,
                           onProgress: (@Sendable (IndexProgress) -> Void)? = nil)
        throws -> IndexProgress {
        var progress = IndexProgress(phase: .walking)
        onProgress?(progress)

        // The volume the walk is about to look at, captured *before* it starts
        // and checked again after it finishes. Both halves are needed, and for
        // different reasons.
        //
        // Capturing early is what makes the walk's results attributable. Every
        // file the walk emits is on whatever was mounted here while it ran, and
        // this is the only moment that is observable — read it afterwards and a
        // volume swapped out mid-walk hands the identity of the *impostor* to
        // rows that came off the real drive. Nothing would be deleted that pass,
        // but the stamp would be permanent: a later pass on the real volume
        // would no longer match those rows by UUID or by device, and they could
        // never be pruned again. Ghosts, with no way back short of a rebuild.
        //
        // Re-checking afterwards is what makes them trustworthy. On a long pass
        // the volume can go away or be replaced while the walk runs, and a
        // reconcile is only evidence if the thing that answered at the start is
        // still the thing answering at the end.
        guard let volume = volumeReader(root) else {
            throw IndexCoordinatorError.rootUnreadable(root.path)
        }

        var entries: [WalkEntry] = []
        var unseen: [URL] = []
        walker.scan(root: root, options: WalkOptions(includeSubdirectories: recursive)) { event in
            switch event {
            case .entry(let entry):
                entries.append(entry)
            case .skipped(let url, _):
                // Every skip reason means the same thing to the reconcile: the
                // walk did not get to look there, so it knows nothing about
                // what is or is not still inside.
                unseen.append(url)
            }
        }
        // `Walker.scan` returns early when cancelled, so `entries` may be a
        // partial view of the tree. Reconciling against a partial view would
        // delete every row the walk never reached.
        try Task.checkCancellation()

        if unseen.contains(where: { Self.isSamePath($0, root) }) {
            throw IndexCoordinatorError.rootUnreadable(root.path)
        }

        progress.phase = .reading
        progress.total = entries.count
        progress.skipped = unseen.count
        onProgress?(progress)

        var livePaths = Set<String>()
        livePaths.reserveCapacity(entries.count)
        let now = Date().timeIntervalSince1970

        for entry in entries {
            try Task.checkCancellation()
            // Every walked path, including the ones skipped as unchanged below.
            // Omitting a skipped file would make the reconcile delete it.
            livePaths.insert(entry.url.path)

            let mtime = entry.mtime.timeIntervalSince1970
            guard try store.needsReindex(path: entry.url.path, size: entry.size, mtime: mtime) else {
                continue
            }

            var record = FileRecord(entry: entry, volume: volume, indexedAt: now)
            // A file whose metadata cannot be read is still a file: it keeps
            // its row, its size, and its place in the grid. Losing it entirely
            // would make a corrupt image invisible rather than visibly broken.
            //
            // Deliberately not retried: `needsReindex` keys on size and mtime,
            // so the next pass skips this file and it keeps its null dimensions
            // until its bytes change. That is the opposite of tier 1, which
            // records `hashed_at` to mark that hashing was *attempted* — but
            // tier 1 is guarding an expensive decode it must not repeat, while
            // a header ImageIO cannot parse today it cannot parse on the next
            // folder open either. Retrying would pay for it on every open,
            // forever, for no new information. Editing the file re-arms it.
            do {
                let read = try metadata.read(entry.url)
                record.width = read.width
                record.height = read.height
                record.captureTime = read.captureTime?.timeIntervalSince1970
                record.captureOffset = read.captureOffset
                record.cameraMake = read.cameraMake
                record.cameraModel = read.cameraModel
                record.orientation = read.orientation
            } catch {
                progress.failed += 1
            }

            try store.upsert(record)
            progress.completed += 1
            if progress.completed % Self.progressReportInterval == 0 { onProgress?(progress) }
        }

        // Captured before the unseen paths join it: these are the files this
        // walk actually looked at, and only they are evidence of which volume
        // they are on. Rows protected below because the walk could *not* see
        // them are exactly the rows whose identity it may not restate.
        let walkedPaths = Array(livePaths)

        // Anything the walk could not look at keeps its rows. Protecting them
        // by name rather than narrowing the delete's scope keeps that scope a
        // single byte range and makes the protection exact: a skipped entry
        // may be a file or a directory, and both are covered by "at or under".
        //
        // One query for the whole scope, then a parent-chain lookup per row.
        // Querying per skipped entry is the obvious shape and the wrong one: a
        // permission change landing between a directory's listing and its
        // per-entry `lstat` skips every entry in it, which on a large folder
        // is tens of thousands of separate read transactions in one pass.
        if !unseen.isEmpty {
            let unseenPaths = Set(unseen.map(\.path))
            livePaths.formUnion(unseenPaths)
            for path in try store.paths(under: root.path)
            where Self.isAtOrUnder(path, anyOf: unseenPaths) {
                livePaths.insert(path)
            }
        }

        // Completeness is not enough on its own: a root can enumerate perfectly
        // and still be the wrong filesystem. A stale mount point left behind, a
        // network share that mounts empty, a drive that comes back with a fresh
        // filesystem — each reads as "every file here was deleted" while the
        // walk reports a clean, complete, zero-entry pass. The index already
        // knows which volume each row came from, so it can tell the difference.
        //
        // The pair, not either alone: the walk's results describe `volume`, and
        // they may only be written down if `current` is still that same volume.
        // A mismatch means something was swapped underneath the pass, and every
        // conclusion it reached is about a filesystem that is no longer here —
        // so neither the stamp nor the delete may proceed. Both are gated on
        // this, and both then use `current`, which is the identity the next
        // pass will present.
        guard let current = volumeReader(root), volume.matches(current) else {
            throw IndexCoordinatorError.rootUnreadable(root.path)
        }

        // Backfill, and repair after a replug: a file the walk saw is on the
        // volume that answered, whatever its row still says. Rows written
        // before schema v2 carry no `volume_uuid` at all, and tier 0 does not
        // re-upsert a file whose bytes are unchanged, so without this the
        // column would stay NULL on an existing library forever. Ahead of the
        // delete, so the very pass that stamps a row is also the one that may
        // then reconcile it.
        try store.setVolume(current, forPaths: walkedPaths)

        // Reconcile: rows for files that are no longer on disk. Scoped to what
        // this scan actually looked at — a non-recursive scan never saw the
        // subdirectories, so it must not be allowed to judge their rows — and
        // to rows recorded on the volume that answered this walk, by the
        // matching rule spelled out on `deleteRows`.
        if recursive {
            try store.deleteRows(under: root.path, keeping: livePaths,
                                 onDevice: current.device, onVolume: current.uuid)
        } else {
            try store.deleteRows(inFolder: root.path, keeping: livePaths,
                                 onDevice: current.device, onVolume: current.uuid)
        }

        progress.phase = .finished
        onProgress?(progress)
        return progress
    }

    // MARK: - Tier 1: hashing

    /// Whether new hashing work is currently suspended.
    public var isPaused: Bool { paused }

    /// Stops the tier 1 pass at the end of the batch it is working on. A paused
    /// pass returns rather than blocking, so nothing is left holding the index.
    public func pause() { paused = true }

    /// Re-arms hashing. The work itself is not resumed here: the caller starts
    /// a new pass, which picks up exactly the rows the paused one left behind.
    public func resume() { paused = false }

    /// Computes the content hash, image-data hash, and perceptual hash for
    /// every file under `root` that has not been attempted yet.
    ///
    /// **The work queue is the database** — the rows with `hashed_at IS NULL` —
    /// drained in batches. There is no separate progress record to keep in sync
    /// and none to drift, so the pass resumes across a pause, a cancellation or
    /// a quit for free: every run simply asks what is still unhashed.
    ///
    /// `hashed_at` is set even when hashing fails. Without that, an unreadable
    /// or malformed file would be re-read on every pass for the life of the
    /// index; with it, the row records that the attempt happened and carries
    /// NULL hashes. A file only re-enters the queue when its bytes change,
    /// which tier 0's upsert detects and which clears `hashed_at` again.
    ///
    /// **That last property is why this pass carries tier 0's volume check.**
    /// Marking an attempt is almost irreversible: nothing re-queues a row until
    /// its size or mtime changes, and an unmounted drive changes neither. A
    /// pass that ran against a vanished root would hash nothing, record every
    /// file as attempted, and leave the whole library permanently unhashable —
    /// the same mistake as reconciling against a missing volume, in a form that
    /// survives the remount. So the volume answering at `root` is captured
    /// before the pass and re-checked before every batch is *read* and again
    /// before its results are *written*; if it is gone or is a different
    /// filesystem, the pass throws `rootUnreadable` and writes nothing.
    ///
    /// "A different filesystem" is decided by `VolumeIdentity`: the volume UUID
    /// where the filesystem publishes one, `st_dev` where it does not. A pass
    /// long enough to span a replug is not the interesting case — the drive
    /// vanishing mid-pass is — but the UUID is what makes the check mean the
    /// volume rather than the mount.
    @discardableResult
    public func runHashingPass(root: URL,
                               onProgress: (@Sendable (IndexProgress) -> Void)? = nil)
        async throws -> IndexProgress {
        guard let volume = volumeReader(root) else {
            throw IndexCoordinatorError.rootUnreadable(root.path)
        }

        var progress = IndexProgress(phase: .hashing)
        progress.total = try store.countMissingHashes(under: root.path)
        onProgress?(progress)

        while true {
            // Ahead of the pause check so a cancelled pass reports cancellation
            // rather than the state it happened to be in, and after the writes
            // of the previous batch so it keeps everything it paid for.
            try Task.checkCancellation()
            // Checked between batches rather than inside one: a batch's results
            // are written as a unit, so stopping between batches is what makes
            // "paused" a state the database agrees with.
            if paused {
                progress.phase = .paused
                onProgress?(progress)
                return progress
            }

            let outcome = try await drainOneHashingBatch(root: root, volume: volume)
            progress.completed += outcome.hashed
            progress.failed += outcome.failed
            guard outcome.hadWork else { break }
            // Every write in the batch was refused, so something else is
            // rewriting these rows as fast as they are hashed. They are still
            // queued and the next pass takes them; re-reading them here would
            // livelock against the writer. (Not an infinite loop: with no
            // concurrent writer the re-read simply succeeds.)
            guard outcome.wrote > 0 else { break }
            onProgress?(progress)
        }

        progress.phase = .finished
        onProgress?(progress)
        return progress
    }

    /// Reads one batch of unhashed rows, hashes them `concurrency`-at-a-time,
    /// and records the outcome of every one. Holds the hashing gate for the
    /// whole of it — see the reentrancy note on the type.
    ///
    /// `volume` is the volume the pass started against. It is re-checked here
    /// twice: once before any work is read, and once after hashing and before
    /// a single row is written, because the drive can go away mid-batch and it
    /// is the write that would do the permanent damage.
    private func drainOneHashingBatch(root: URL, volume: VolumeIdentity) async throws -> BatchOutcome {
        await acquireHashingGate()
        defer { releaseHashingGate() }

        try checkStillMounted(root, volume: volume)

        var outcome = BatchOutcome()
        // `id` is a rowid alias, so in practice it is never NULL; the filter is
        // here to keep the write's unwrap total rather than to fix anything.
        let work = try store.filesMissingHashes(under: root.path,
                                                limit: Self.hashingBatchSize)
            .filter { $0.id != nil }
        guard !work.isEmpty else { return outcome }
        outcome.hadWork = true

        let results = await withTaskGroup(of: HashOutcome.self) { group in
            var collected: [HashOutcome] = []
            collected.reserveCapacity(work.count)
            var next = 0
            // A bounded window rather than one task per row: a batch is far
            // wider than the number of files worth reading from one disk at
            // once, and each hash may buffer the whole file.
            while next < work.count && next < concurrency {
                let record = work[next]
                next += 1
                group.addTask { [hasher, grayscale] in
                    Self.hash(record, hasher: hasher, grayscale: grayscale)
                }
            }
            while let result = await group.next() {
                collected.append(result)
                if next < work.count {
                    let record = work[next]
                    next += 1
                    group.addTask { [hasher, grayscale] in
                        Self.hash(record, hasher: hasher, grayscale: grayscale)
                    }
                }
            }
            return collected
        }

        // The batch is hashed; nothing is recorded yet. If the volume left
        // while that ran, none of these outcomes is evidence about anything —
        // and writing them would mark the files attempted forever.
        try checkStillMounted(root, volume: volume)

        let now = Date().timeIntervalSince1970
        for result in results {
            // `hashed_at` is written either way: it means "attempted".
            let landed = try store.setHashes(for: result.record,
                                             content: result.hashes?.contentHash,
                                             image: result.hashes?.imageHash,
                                             imageKind: result.hashes?.imageHashKind,
                                             phash: result.phash,
                                             hashedAt: now)
            guard landed else { continue }
            outcome.wrote += 1
            if result.hashes == nil { outcome.failed += 1 } else { outcome.hashed += 1 }
        }
        return outcome
    }

    /// Hashes one file, off the actor.
    ///
    /// Cancellation is deliberately not checked in here. A cancelled child that
    /// returned early would still be written as an *attempt*, and the file
    /// would then never be hashed again — the pass stops between batches
    /// instead, where stopping costs nothing but the current batch.
    private static func hash(_ record: FileRecord, hasher: any FileHashing,
                             grayscale: any GrayscaleRendering) -> HashOutcome {
        let url = URL(fileURLWithPath: record.path)
        // An extension the app does not recognise yields no hashes and is still
        // recorded as attempted: re-queueing it would cost a read per pass to
        // learn the same thing.
        let hashes = MediaType.forExtension(record.ext)
            .flatMap { try? hasher.hashes(for: url, mediaType: $0) }
        // A perceptual hash failure costs one column, not the row. The two
        // hashes answer different questions — "the same file" versus "the same
        // picture" — and a file whose pixels will not decode can still answer
        // the first.
        let phash = (try? grayscale.gray32(from: url))
            .flatMap { try? PerceptualHash(gray: $0) }?.hex
        return HashOutcome(record: record, hashes: hashes, phash: phash)
    }

    /// The result of hashing one file, carrying the row it was read from so the
    /// write can check that row still describes it.
    private struct HashOutcome: Sendable {
        let record: FileRecord
        let hashes: FileHashes?
        let phash: String?
    }

    private struct BatchOutcome {
        /// Whether there was anything left to do at all.
        var hadWork = false
        /// Rows whose outcome was actually recorded. Lower than the batch size
        /// when a row changed under the pass and its write was refused.
        var wrote = 0
        var hashed = 0
        var failed = 0
    }

    /// Throws unless `root` is still answered by the same volume the pass
    /// started against. A missing root and a root on a different filesystem are
    /// the same thing here: the pass is about to record facts about files it
    /// cannot see.
    private func checkStillMounted(_ root: URL, volume: VolumeIdentity) throws {
        guard let current = volumeReader(root), volume.matches(current) else {
            throw IndexCoordinatorError.rootUnreadable(root.path)
        }
    }

    private func acquireHashingGate() async {
        guard hashingPassInFlight else {
            hashingPassInFlight = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            hashingPassWaiters.append(continuation)
        }
        // The gate was handed over directly and is still marked in-flight.
    }

    private func releaseHashingGate() {
        // Direct handoff rather than clearing the flag and letting whoever runs
        // next take it: a caller arriving between the two could otherwise barge
        // ahead of a waiter indefinitely.
        if hashingPassWaiters.isEmpty {
            hashingPassInFlight = false
        } else {
            hashingPassWaiters.removeFirst().resume()
        }
    }

    // MARK: - Helpers

    /// Path identity, for matching a skip against the scan's own root. In
    /// practice the walker emits the very URL it was handed, but a root built
    /// by string concatenation or carrying a trailing slash must not slip past
    /// the check that guards the whole index.
    private static func isSamePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// Whether `path` is one of `roots` or lives beneath one of them.
    ///
    /// Compares whole path components by walking up the parent chain, so
    /// `/a/bc` is not treated as living under `/a/b` the way a plain prefix
    /// test would have it.
    private static func isAtOrUnder(_ path: String, anyOf roots: Set<String>) -> Bool {
        var current = path
        while true {
            if roots.contains(current) { return true }
            guard let slash = current.lastIndex(of: "/") else { return false }
            current = String(current[current.startIndex..<slash])
            if current.isEmpty { return roots.contains("/") }
        }
    }

    /// Reporting every file would push more updates than a display can show;
    /// reporting rarely makes a small folder look stuck. The pass always
    /// reports on entering each phase regardless of this.
    private static let progressReportInterval = 25

    /// How many rows one hashing batch claims. It is the unit of three
    /// separate things — the read, the gate's hold, and how much work a pause
    /// or a cancellation can discard — so it is small enough that stopping is
    /// prompt and large enough that the queue query is not the cost.
    private static let hashingBatchSize = 64
}
