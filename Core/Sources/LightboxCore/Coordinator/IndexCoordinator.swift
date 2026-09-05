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
/// Reentrancy: `indexTier0`'s body is entirely synchronous, so the actor
/// serialises whole passes today and two callers cannot interleave. Task 15's
/// concurrent hashing puts the first `await` inside a pass, and from that
/// moment two overlapping passes over the same root can interleave — one
/// pass's live set going stale while the other reconciles against it. Whoever
/// adds that `await` must also add a guard: an in-flight set keyed by root, or
/// a queue of pending roots.
public actor IndexCoordinator {
    private let store: IndexStore
    private let walker: Walker
    private let metadata: any MetadataReading
    // Unused by tier 0 and deliberately so: `runHashingPass` lands on this same
    // actor and needs both, and taking them now keeps that change from
    // rewriting every call site and test written against this initializer.
    private let hasher: any FileHashing
    private let grayscale: any GrayscaleRendering
    private let concurrency: Int

    public init(store: IndexStore,
                walker: Walker = Walker(),
                metadata: any MetadataReading = MetadataReader(),
                hasher: any FileHashing = FileHasher(),
                grayscale: any GrayscaleRendering = GrayscaleRenderer(),
                concurrency: Int = 4) {
        self.store = store
        self.walker = walker
        self.metadata = metadata
        self.hasher = hasher
        self.grayscale = grayscale
        self.concurrency = max(1, concurrency)
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
    /// the walk is evidence about a different filesystem. See the device check
    /// below.
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

            var record = FileRecord(entry: entry, indexedAt: now)
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
        // walk reports a clean, complete, zero-entry pass. `files.device`
        // exists precisely because an inode is unique only within a volume, so
        // the index already knows which volume each row came from.
        //
        // Re-stat here rather than before the walk: on a long pass the volume
        // can go away while it runs, and the value that must be trusted is the
        // one current at the moment of the delete.
        guard let rootDevice = Self.device(ofDirectory: root) else {
            throw IndexCoordinatorError.rootUnreadable(root.path)
        }

        // Reconcile: rows for files that are no longer on disk. Scoped to what
        // this scan actually looked at — a non-recursive scan never saw the
        // subdirectories, so it must not be allowed to judge their rows — and
        // to rows recorded on the volume that answered this walk.
        if recursive {
            try store.deleteRows(under: root.path, keeping: livePaths, onDevice: rootDevice)
        } else {
            try store.deleteRows(inFolder: root.path, keeping: livePaths, onDevice: rootDevice)
        }

        progress.phase = .finished
        onProgress?(progress)
        return progress
    }

    /// Path identity, for matching a skip against the scan's own root. In
    /// practice the walker emits the very URL it was handed, but a root built
    /// by string concatenation or carrying a trailing slash must not slip past
    /// the check that guards the whole index.
    private static func isSamePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// The device of the volume currently answering at `url`, or nil if it is
    /// gone or is no longer a directory.
    private static func device(ofDirectory url: URL) -> Int64? {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Int64(st.st_dev)
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
}
