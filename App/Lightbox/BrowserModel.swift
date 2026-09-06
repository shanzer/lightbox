import Foundation
import Observation
import LightboxCore

/// The read side of the index, as the browser uses it.
///
/// A protocol rather than the concrete store for one reason: two overlapping
/// searches complete in whichever order the cooperative pool happens to start
/// them. On an idle machine that is reliably the order they were issued, and
/// on a busy one it is a coin flip — measured at roughly two inversions in
/// five while the pool was saturated. A guarantee that only breaks under load
/// cannot be tested by timing, so the seam exists to let a test decide when a
/// search returns. Production always passes the real `IndexStore`.
protocol RecordSearching: Sendable {
    func search(_ query: SearchQuery) throws -> [FileRecord]

    /// The breakdown of the same result set, for the filter panel. On the
    /// protocol rather than taken straight off the store so that the seam
    /// covers a reload whole: a test that holds up one reload holds up its
    /// facets with it, and cannot accidentally certify an ordering guarantee
    /// that the counts do not share.
    func facets(for query: SearchQuery) throws -> Facets
}

extension IndexStore: RecordSearching {}

/// The state behind one browser window: which folder is open, what the index
/// says is in it, and how far the current pass has got.
///
/// Everything the views bind to lives here so the views stay declarative and
/// this stays the only place that knows the `Core` API.
///
/// **Every asynchronous step carries a `Pass`.** The model is a mutable
/// snapshot of "what the window should be showing", and each user action —
/// opening a folder, flipping the subfolder toggle, changing the sort —
/// replaces that snapshot while work started for the previous one is still in
/// flight. Nothing may read `root`, `includeSubfolders` or `sort` after a
/// suspension, because by then they may describe a different folder than the
/// one this work was started for; and nothing may write `records`, `status` or
/// `progress` without first checking that its snapshot is still the current
/// one. Without that, two overlapping searches finish in arbitrary order and
/// whichever loses the race wins the grid.
@MainActor
@Observable
final class BrowserModel {
    /// What the last pass had to say for itself.
    ///
    /// Cancellation is deliberately absent: the user changing folders or
    /// flipping the subfolders toggle supersedes the pass in flight, and that
    /// is ordinary operation, not a condition to report.
    enum Status: Equatable, Sendable {
        case ok
        /// The folder could not be enumerated — it was deleted, its permissions
        /// changed, or, the case this app is built around, its drive was
        /// unplugged. `Core` refuses to reconcile the index against a walk it
        /// could not complete, so the rows survive; the user just needs to know
        /// that what they are looking at is stale rather than empty, and needs
        /// a way to try again once the drive is back.
        case rootUnreadable(path: String)
        case failed(String)

        var message: String? {
            switch self {
            case .ok:
                nil
            case .rootUnreadable(let path):
                "Could not read \(path). If it is on a removable drive, reconnect it "
                    + "and press ⌘R to try again — the index for it has been kept."
            case .failed(let description):
                description
            }
        }
    }

    /// A snapshot of what the window is meant to be showing, taken at the
    /// moment the user acts and carried through every suspension after it.
    ///
    /// `Sendable` because the tier 0 progress callback is `@Sendable` and hops
    /// back to the main actor carrying one.
    private struct Pass: Sendable {
        /// Which folder, and how much of it, this pass is for. Bumped only by
        /// the things that change the answer to that: opening a folder, the
        /// subfolder toggle, and an explicit refresh.
        let scopeToken: Int
        /// Which *question* this pass is asking of the index. Bumped by every
        /// reload, including one a keystroke scheduled.
        let queryToken: Int
        let root: URL
        let includeSubfolders: Bool
        let sort: SearchQuery.Sort
        /// The filter state, snapshotted with everything else. A search that
        /// suspends and then rebuilt its query from `self.searchText` would
        /// query for whatever the user has typed *since* — which under a
        /// debounce is routinely a different string.
        let searchText: String
        let extensions: Set<String>
        let minimumWidth: Double?
    }

    private(set) var records: [FileRecord] = []

    /// `records` reduced to ids, in display order.
    ///
    /// Derived once here rather than recomputed by the grid, because the grid
    /// needs it on every body evaluation *and* on every click, and Task 18
    /// measures that grid at 50,000 items. `compactMap` over 50,000 records per
    /// keystroke is the kind of cost that only shows up at the size this app is
    /// built for.
    private(set) var order: [Int64] = []

    private(set) var progress = IndexProgress()
    private(set) var root: URL?
    private(set) var status: Status = .ok

    /// Set once, in `init(at:)`, when the on-disk index failed its launch
    /// integrity check and was rebuilt empty. `BrowserView` reads it to show
    /// the one-time banner — without it, a rebuild would look exactly like
    /// data loss: the window would just quietly open onto an empty grid.
    private(set) var didRebuildIndex = false

    /// Which rows are selected. `SelectionModel` lives in `Core`; this is just
    /// where the window keeps its copy.
    var selection = SelectionModel()

    /// The side of a thumbnail cell in points, driven by the size slider.
    var thumbnailSide: CGFloat = 128

    let thumbnails: ThumbnailCache

    var includeSubfolders = true {
        didSet {
            guard includeSubfolders != oldValue else { return }
            Task { await reloadThenRescan() }
        }
    }

    var sort = SearchQuery.Sort() {
        didSet {
            guard sort != oldValue else { return }
            Task { await reload() }
        }
    }

    // MARK: - Filters

    /// How the current result set breaks down, for the filter panel.
    ///
    /// Always describes the *whole* result set, never the page on screen —
    /// see `IndexStore.facets(for:)`. Reset to `.empty` on a failed reload
    /// rather than left standing, because stale counts next to an empty grid
    /// are worse than no counts.
    private(set) var facets: Facets = .empty

    /// Filename search. Debounced — see `searchDebounce`.
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            filtersChanged(debounced: true)
        }
    }

    /// Extensions ticked in the filter panel. Empty means "no file-type
    /// filter", not "match nothing".
    var selectedExtensions: Set<String> = [] {
        didSet {
            guard selectedExtensions != oldValue else { return }
            filtersChanged(debounced: false)
        }
    }

    var minimumWidth: Double? {
        didSet {
            guard minimumWidth != oldValue else { return }
            filtersChanged(debounced: false)
        }
    }

    var hasActiveFilters: Bool {
        !searchText.isEmpty || !selectedExtensions.isEmpty || minimumWidth != nil
    }

    /// Set while `clearFilters()` assigns all three filters, so the three
    /// `didSet`s do not start three passes for one button press. Only ever
    /// true within one synchronous stretch on the main actor, so nothing can
    /// observe it half-set.
    private var suppressFilterReload = false

    private func filtersChanged(debounced: Bool) {
        guard !suppressFilterReload else { return }
        // A tick or a menu choice is one deliberate gesture, not a stream of
        // them, so it reloads at once where a keystroke waits.
        scheduleReload(after: debounced ? searchDebounce : .zero)
    }

    /// Clears every filter, in one reload rather than three.
    func clearFilters() {
        guard hasActiveFilters else { return }
        suppressFilterReload = true
        searchText = ""
        selectedExtensions = []
        minimumWidth = nil
        suppressFilterReload = false
        scheduleReload(after: .zero)
    }

    // MARK: - Search debounce

    /// How long the search field waits after the last keystroke before it
    /// queries.
    ///
    /// A reload is a search plus one or two aggregates, and Task 18 measured a
    /// `width >= 1920` search over 50,000 rows at ~474 ms — dominated by row
    /// materialisation, so the aggregates are much cheaper than the search but
    /// none of it is free. Querying per character would leave a keystroke's
    /// worth of work queued behind every other keystroke; 250 ms is below the
    /// threshold where a filter feels laggy and above a fast typist's
    /// inter-key interval, so a typed word costs one reload rather than five.
    ///
    /// Settable so a test can drive it to zero. Nothing in the UI changes it.
    var searchDebounce: Duration = .milliseconds(250)

    /// The one reload a filter change has outstanding.
    ///
    /// Single, and cancelled before a replacement is scheduled, so a change to
    /// each of the three filters in a row costs one reload rather than three
    /// racing ones. Three independent `Task`s would also complete in arbitrary
    /// order, and while the generation guard means the *newest* pass always
    /// wins the grid, whichever pass was newest would be decided by the
    /// scheduler rather than by what the user did last.
    private var pendingReloadTask: Task<Void, Never>?

    private func scheduleReload(after interval: Duration) {
        pendingReloadTask?.cancel()
        pendingReloadTask = Task { [weak self] in
            if interval > .zero { try? await Task.sleep(for: interval) }
            // Outside the `if`, deliberately. A zero-interval reload is still
            // cancellable — three ticks in quick succession schedule three
            // tasks and cancel two of them — and checking only after a sleep
            // would let all three run. The generation guard would still make
            // the *result* right, so this is two wasted round trips to SQLite
            // rather than a wrong grid; it is still two more than the user
            // asked for.
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Awaits the reload a filter change has outstanding, if any.
    ///
    /// Exists for tests: a filter change is deliberately fire-and-forget for
    /// the UI, and a test that slept for the debounce instead would be
    /// asserting on the scheduler.
    func waitForPendingSearch() async { await pendingReloadTask?.value }

    /// The query the window is currently showing.
    ///
    /// `applyingExtensionFilter: false` builds the same query with the
    /// file-type ticks left out. That is what the extension facet is counted
    /// over, and it is not an approximation: counting extensions under the
    /// extension filter leaves `byExtension` holding only the types already
    /// ticked, so every other type vanishes from the panel and the filter
    /// becomes a one-way door — tick `jpg` and there is no longer a `png` row
    /// to tick. Every other constraint still applies, so the counts still
    /// answer "how many would ticking this find".
    private static func query(for pass: Pass,
                              applyingExtensionFilter: Bool = true) -> SearchQuery {
        var parts: [SearchPredicate] = []
        // Whitespace-only text is not empty but is not a filter either;
        // `FTS5Query.sanitize` resolves that, and `.noSearchableTerms` — text
        // that survives as nothing — deliberately matches nothing.
        if !pass.searchText.isEmpty { parts.append(.filenameText(pass.searchText)) }
        if applyingExtensionFilter, !pass.extensions.isEmpty {
            parts.append(.fileExtension(pass.extensions))
        }
        if let minimumWidth = pass.minimumWidth { parts.append(.width(.atLeast(minimumWidth))) }
        return SearchQuery(scope: .folder(path: pass.root.path,
                                          recursive: pass.includeSubfolders),
                           predicate: parts.isEmpty ? .all : .and(parts),
                           sort: pass.sort)
    }

    private let store: IndexStore
    private let searcher: any RecordSearching
    private let coordinator: IndexCoordinator
    private var indexingTask: Task<Void, Never>?
    private var hashingTask: Task<Void, Never>?

    /// Two monotonic counters, not one.
    ///
    /// A single counter conflates "the user is looking at a different folder"
    /// with "the user is asking a different question about the same folder",
    /// and the filesystem scan only cares about the first. With one counter,
    /// `reload()` bumps it, and `rescan`'s opening `guard isCurrent(pass)`
    /// then sees a superseded pass and returns — so **one keystroke landing
    /// during `open()` skips tier 0 entirely.** Measured over 300 real files:
    /// opening the folder untouched indexes 300 rows, opening it and typing a
    /// single character mid-flight indexes 0, and the user is shown an empty
    /// grid, an idle progress bar and no error at all, because the pass that
    /// would have reported the failure is the one that never ran. The window
    /// is the initial reload's round trip to SQLite, which Task 18 measured at
    /// ~474 ms on 50,000 rows: click a folder and start typing, which is the
    /// gesture the search field exists for.
    ///
    /// The defect predates the search field — `sort`'s `didSet` has the same
    /// shape — but was unreachable in practice, because nobody changes the
    /// sort order within 400 ms of clicking a folder. Three filter properties
    /// firing on every keystroke make it routine.
    ///
    /// So: `scopeGeneration` invalidates filesystem work, `queryGeneration`
    /// invalidates index reads, and a scope change bumps *both* — a new folder
    /// does invalidate an in-flight query, while a new query has no business
    /// invalidating a scan.
    private var scopeGeneration = 0
    private var queryGeneration = 0

    /// Where thumbnails are cached. Under `Caches` rather than Application
    /// Support because every one of them is reproducible from the original
    /// file, so the system is welcome to reclaim the space.
    static var defaultThumbnailDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox/thumbnails", isDirectory: true)
    }

    /// Opens the on-disk index, checked for corruption first.
    ///
    /// `url` defaults to `IndexStore.defaultURL` and is overridden only by a
    /// test — production always takes the default, so this is the same path
    /// `BrowserView` runs at launch, exercised without writing into the real
    /// Application Support directory.
    ///
    /// A failed `IndexStore(url:)` and a store that opens but fails
    /// `checkIntegrity()` are handled the same way: the index is a derived
    /// cache, so neither case can lose anything a rebuild wouldn't also
    /// recompute, and leaving the app unable to open at all over either one
    /// would be strictly worse than a rescan.
    init(at url: URL = IndexStore.defaultURL) throws {
        let store: IndexStore
        // Bound outside the `if` so a corrupt-but-openable connection is
        // still reachable in the `else` branch to be closed — see below.
        let opened = try? IndexStore(url: url)
        if let opened, opened.checkIntegrity() == .ok {
            store = opened
        } else {
            // `opened` may be a live connection to exactly the file
            // `rebuild(at:)` is about to delete. `deinit` closing it is not
            // synchronous enough: the old file descriptor can still be open
            // when `FileManager.removeItem` unlinks the file, which SQLite
            // logs as a client API violation (`vnode unlinked while in
            // use`) even on a build where it happens not to fail outright.
            // Closing it explicitly, in order, before the delete removes the
            // race rather than relying on it resolving in our favor.
            try? opened?.close()
            store = try IndexStore.rebuild(at: url)
            didRebuildIndex = true
        }
        self.store = store
        self.searcher = store
        coordinator = IndexCoordinator(store: store)
        thumbnails = ThumbnailCache(directory: Self.defaultThumbnailDirectory)
    }

    /// Takes an already-open store, for tests and previews that must not touch
    /// Application Support. `searcher` defaults to the store itself and is
    /// overridden only to control search timing in a test; `thumbnails`
    /// likewise exists so a test can point the cache somewhere disposable and
    /// give it a budget small enough to observe eviction.
    init(store: IndexStore,
         searcher: (any RecordSearching)? = nil,
         thumbnails: ThumbnailCache? = nil) {
        self.store = store
        self.searcher = searcher ?? store
        coordinator = IndexCoordinator(store: store)
        self.thumbnails = thumbnails ?? ThumbnailCache(directory: Self.defaultThumbnailDirectory)
    }

    // MARK: - Records

    /// The only place `records` is assigned.
    ///
    /// Single-entry because two things have to move with it. `order` is derived
    /// state the grid reads on every click, and the selection has to be pruned:
    /// a rescan deletes rows, and a selection still naming them would go on to
    /// drive a copy, a move, or — in phase 2 — a delete against files that are
    /// no longer there.
    ///
    /// Pruning is `SelectionModel.retain(_:)` and not a rebuild by replaying
    /// clicks over the surviving ids, because a replay depends on `Set`
    /// iteration order and silently re-anchors the user's range on whichever id
    /// came out last.
    private func setRecords(_ rows: [FileRecord]) {
        records = rows
        order = rows.compactMap(\.id)
        var pruned = selection
        // The ordered array, not a `Set`: `retain` re-anchors to the topmost
        // surviving row, which it can only identify from display order.
        pruned.retain(order)
        // Compared rather than assigned unconditionally: `selection` is
        // observed, and a reload that changed nothing about it must not
        // invalidate every cell in the grid.
        if pruned != selection { selection = pruned }
    }

    /// Selects everything on screen.
    ///
    /// Here rather than in the view because `order` is the model's derived
    /// state and the Select All menu command has no view to reach into: the
    /// command posts, `BrowserView` forwards, and this is the one place that
    /// knows what "everything" currently means.
    func selectAll() {
        selection.selectAll(order)
    }

    /// The selected rows, in display order, for the inspector.
    ///
    /// Derived here rather than in the view so the filter runs once per
    /// change instead of once per body evaluation, and short-circuited on an
    /// empty selection: no selection is the common case and a linear pass over
    /// 50,000 records to produce an empty array is pure waste.
    var selectedRecords: [FileRecord] {
        guard !selection.selected.isEmpty else { return [] }
        return records.filter { record in
            record.id.map(selection.selected.contains) ?? false
        }
    }

    // MARK: - Generations

    /// Invalidates *everything* in flight — scans included — and returns the
    /// snapshot that replaces it, or `nil` when there is no folder to work on.
    ///
    /// For the things that change which files are in scope: opening a folder,
    /// the subfolder toggle, and refresh.
    private func beginScopePass() -> Pass? {
        scopeGeneration += 1
        return beginQueryPass()
    }

    /// Invalidates index reads only. A scan already running for this folder
    /// keeps running, because the folder has not changed.
    private func beginQueryPass() -> Pass? {
        queryGeneration += 1
        guard let root else { return nil }
        return Pass(scopeToken: scopeGeneration, queryToken: queryGeneration,
                    root: root,
                    includeSubfolders: includeSubfolders, sort: sort,
                    searchText: searchText, extensions: selectedExtensions,
                    minimumWidth: minimumWidth)
    }

    /// Checked by everything that touches the filesystem or reports on it:
    /// `rescan`, the tier 0 progress callback, and the hashing pass.
    private func isCurrentScope(_ pass: Pass) -> Bool { pass.scopeToken == scopeGeneration }

    /// Checked only where `records`, `order` and `facets` are assigned. A
    /// scope change bumps the query token too, so this fails for a stale
    /// folder as well as for a stale query.
    private func isCurrentQuery(_ pass: Pass) -> Bool { pass.queryToken == queryGeneration }

    // MARK: - Navigation

    /// Opens `url`, unless it is already open.
    ///
    /// Re-opening the folder already showing is a no-op on purpose — clicking
    /// the selected row in the sidebar should not cost a full re-index. The way
    /// to deliberately re-read the current folder is `refreshCurrentFolder()`.
    func open(_ url: URL) async {
        guard url != root else { return }
        root = url
        status = .ok
        await reloadThenRescan()
    }

    /// Re-queries and re-scans the folder already open, whether or not anything
    /// about it changed.
    ///
    /// This is the recovery path out of `.rootUnreadable`: `open(_:)` ignores a
    /// repeat of the current folder, so after reconnecting a drive there would
    /// otherwise be no way back short of navigating somewhere else and
    /// returning. Bound to ⌘R, which is what the error message points at.
    func refreshCurrentFolder() async {
        status = .ok
        await reloadThenRescan()
    }

    /// Answers from the index first, which is instant for a folder that has
    /// been opened before, then goes to the filesystem for whatever the index
    /// does not know yet.
    private func reloadThenRescan() async {
        guard let pass = beginScopePass() else { return }
        trimThumbnailCache()
        await reload(pass)
        await rescan(pass)
    }

    // MARK: - Thumbnail cache

    private var trimTask: Task<Void, Never>?

    /// Brings the thumbnail cache back inside its budget.
    ///
    /// `ThumbnailCache` never evicts on its own — nothing in `Core` calls
    /// `evictIfNeeded()`, so the budget does nothing at all until something
    /// schedules it, and this is the first code that generates thumbnails. It
    /// runs when a folder is opened, and deliberately nowhere else:
    ///
    /// - `evictIfNeeded()` enumerates the entire cache directory, which is tens
    ///   of thousands of files once a library has been browsed. That cannot
    ///   happen per cell, or per scroll event.
    /// - Eviction sorts by write time, so it is least-recently-*generated*, not
    ///   least-recently-used: a thumbnail the user is staring at right now ages
    ///   exactly like one they have never seen. Running it as the user scrolls
    ///   would therefore delete tiles out of the viewport they are looking at.
    ///   Running it before the incoming folder's thumbnails have been generated
    ///   puts the oldest entries — the ones for folders left long ago — at the
    ///   front of the queue instead, which is the closest this policy gets to
    ///   the right answer.
    ///
    /// Fire-and-forget, and coalesced: opening four folders quickly must not
    /// queue four directory walks behind each other. A failure is deliberately
    /// silent — a cache that is temporarily over budget is not something to
    /// interrupt the user about, and the next folder tries again.
    private func trimThumbnailCache() {
        guard trimTask == nil else { return }
        trimTask = Task { [weak self, thumbnails] in
            try? await thumbnails.evictIfNeeded()
            self?.trimTask = nil
        }
    }

    /// Awaits the trim started by the last folder change, if one is still
    /// running.
    ///
    /// Exists for tests. The trim is fire-and-forget by design — the user is
    /// not waiting on cache housekeeping — and a test asserting on its effect
    /// must not do so by sleeping.
    func waitForThumbnailTrim() async { await trimTask?.value }

    // MARK: - Indexing

    /// Re-scans the current folder, then reloads the grid from the index.
    func refresh() async {
        guard let pass = beginScopePass() else { return }
        await rescan(pass)
    }

    private func rescan(_ pass: Pass) async {
        // A pass that was superseded before it even started must not touch the
        // task belonging to the pass that replaced it.
        //
        // *Scope*, not query: a keystroke landing during the reload this pass
        // just finished must not cancel the folder's scan before it starts.
        guard isCurrentScope(pass) else { return }

        // Awaited, not cancel-and-forget. Today `IndexCoordinator.indexTier0`
        // is a synchronous actor method, so a superseded pass throws at its
        // first `checkCancellation()` without ever interleaving with its
        // replacement, and simply dropping the old task would happen to be
        // safe. Relying on that would make parallelising tier 0's metadata
        // reads — an obvious future optimisation — silently turn into two
        // passes reconciling the same root against each other, and that
        // reconcile deletes rows. So wait for the old one to actually finish.
        if let inFlight = indexingTask {
            inFlight.cancel()
            await inFlight.value
        }
        guard isCurrentScope(pass) else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.indexTier0(root: pass.root,
                                                      recursive: pass.includeSubfolders) {
                    [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrentScope(pass) else { return }
                        self.progress = progress
                    }
                }
            } catch is CancellationError {
                // Superseded. The pass that replaced this one owns the window.
                return
            } catch IndexCoordinatorError.rootUnreadable(let path) {
                guard self.isCurrentScope(pass) else { return }
                self.status = .rootUnreadable(path: path)
                self.progress = IndexProgress(phase: .idle)
                return
            } catch {
                guard self.isCurrentScope(pass) else { return }
                self.status = .failed(error.localizedDescription)
                self.progress = IndexProgress(phase: .idle)
                return
            }
            guard self.isCurrentScope(pass) else { return }
            self.status = .ok
            // A *fresh* query pass, not `pass`: the scan may have taken
            // minutes, and the filters the user set while it ran are the ones
            // the grid should come back showing. Replaying `pass` would lose
            // to the query guard and leave the newly indexed rows invisible.
            await self.reload()
        }
        indexingTask = task
        await task.value
    }

    /// Re-runs the query against the index without touching the filesystem.
    func reload() async {
        guard let pass = beginQueryPass() else { return }
        await reload(pass)
    }

    private func reload(_ pass: Pass) async {
        guard isCurrentQuery(pass) else { return }
        let query = Self.query(for: pass)
        // Only when a file-type filter is actually on: with none ticked the
        // two queries are identical, and a second aggregate per keystroke for
        // an identical answer is not worth paying for.
        let unfilteredByExtension = pass.extensions.isEmpty
            ? nil
            : Self.query(for: pass, applyingExtensionFilter: false)
        let searcher = self.searcher
        do {
            // Off the main actor: the index can hold hundreds of thousands of
            // rows and the window must not freeze while SQLite answers.
            let answer = try await Task.detached(priority: .userInitiated) {
                let rows = try searcher.search(query)
                let counts = try searcher.facets(for: query)
                guard let unfilteredByExtension else { return (rows, counts) }
                // `total` and the camera breakdown describe what is on screen;
                // only the file-type buckets come from the wider query.
                let wider = try searcher.facets(for: unfilteredByExtension)
                return (rows, Facets(byExtension: wider.byExtension,
                                     byCamera: counts.byCamera,
                                     total: counts.total))
            }.value
            guard isCurrentQuery(pass) else { return }
            setRecords(answer.0)
            facets = answer.1
        } catch {
            // Checked on the failure path too: a slow search that fails for a
            // folder the user has already left must not put an error banner
            // over a folder that opened fine.
            guard isCurrentQuery(pass) else { return }
            setRecords([])
            facets = .empty
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Tier 1

    /// Starts the hashing pass for the current folder. Safe to call while one
    /// is already running: the queue is the database, so a second pass simply
    /// picks up whatever rows the first has not reached.
    func startHashingPass() {
        guard let root else { return }
        // Neither counter is bumped: starting a hashing pass supersedes
        // nothing. It snapshots the scope so navigating away stops its
        // progress reports, and because it checks the *scope* token, typing in
        // the search field no longer freezes its progress bar or swallows the
        // `rootUnreadable` it needs to report.
        let pass = Pass(scopeToken: scopeGeneration, queryToken: queryGeneration,
                        root: root,
                        includeSubfolders: includeSubfolders, sort: sort,
                        searchText: searchText, extensions: selectedExtensions,
                        minimumWidth: minimumWidth)
        hashingTask?.cancel()
        hashingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.runHashingPass(root: pass.root) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrentScope(pass) else { return }
                        self.progress = progress
                    }
                }
            } catch is CancellationError {
                return
            } catch IndexCoordinatorError.rootUnreadable(let path) {
                guard self.isCurrentScope(pass) else { return }
                self.status = .rootUnreadable(path: path)
                self.progress = IndexProgress(phase: .idle)
            } catch {
                guard self.isCurrentScope(pass) else { return }
                self.status = .failed(error.localizedDescription)
                self.progress = IndexProgress(phase: .idle)
            }
        }
    }

    func pauseHashing() async { await coordinator.pause() }

    func resumeHashing() async {
        await coordinator.resume()
        startHashingPass()
    }
}
