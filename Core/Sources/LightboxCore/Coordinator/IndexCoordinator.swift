import Foundation

/// Drives the indexing pipeline.
///
/// Tier 0 — walk, stat, read metadata properties, upsert — runs on every folder
/// open. It decodes nothing: ImageIO's property dictionary is a header read.
/// Thumbnails are not generated here; the grid requests them for the cells it
/// is actually showing, which makes viewport priority a property of the UI
/// rather than something this actor has to model. The perceptual hash and the
/// two SHA-256 hashes need a decode or a whole-file read, so they belong to the
/// tier 1 pass instead.
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
    /// Throws `CancellationError` if the task is cancelled: the caller must not
    /// be able to mistake a half-finished pass for a completed one, because the
    /// difference between the two is whether the reconcile below ran.
    @discardableResult
    public func indexTier0(root: URL, recursive: Bool,
                           onProgress: (@Sendable (IndexProgress) -> Void)? = nil)
        throws -> IndexProgress {
        var progress = IndexProgress(phase: .walking)
        onProgress?(progress)

        var entries: [WalkEntry] = []
        walker.scan(root: root, options: WalkOptions(includeSubdirectories: recursive)) { event in
            if case .entry(let entry) = event { entries.append(entry) }
        }
        // `Walker.scan` returns early when cancelled, so `entries` may be a
        // partial view of the tree. Reconciling against a partial view would
        // delete every row the walk never reached.
        try Task.checkCancellation()

        progress.phase = .reading
        progress.total = entries.count
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

        // Reconcile: rows for files that are no longer on disk. Scoped to what
        // this scan actually looked at — a non-recursive scan never saw the
        // subdirectories, so it must not be allowed to judge their rows.
        if recursive {
            try store.deleteRows(under: root.path, keeping: livePaths)
        } else {
            try store.deleteRows(inFolder: root.path, keeping: livePaths)
        }

        progress.phase = .finished
        onProgress?(progress)
        return progress
    }

    /// Reporting every file would push more updates than a display can show;
    /// reporting rarely makes a small folder look stuck. The pass always
    /// reports on entering each phase regardless of this.
    private static let progressReportInterval = 25
}
