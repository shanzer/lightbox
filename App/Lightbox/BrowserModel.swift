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
        let token: Int
        let root: URL
        let includeSubfolders: Bool
        let sort: SearchQuery.Sort
    }

    private(set) var records: [FileRecord] = []
    private(set) var progress = IndexProgress()
    private(set) var root: URL?
    private(set) var status: Status = .ok

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

    private let store: IndexStore
    private let searcher: any RecordSearching
    private let coordinator: IndexCoordinator
    private var indexingTask: Task<Void, Never>?
    private var hashingTask: Task<Void, Never>?

    /// Monotonic; bumped by every action that changes what should be on screen.
    private var generation = 0

    init() throws {
        let store = try IndexStore(url: IndexStore.defaultURL)
        self.store = store
        self.searcher = store
        coordinator = IndexCoordinator(store: store)
    }

    /// Takes an already-open store, for tests and previews that must not touch
    /// Application Support. `searcher` defaults to the store itself and is
    /// overridden only to control search timing in a test.
    init(store: IndexStore, searcher: (any RecordSearching)? = nil) {
        self.store = store
        self.searcher = searcher ?? store
        coordinator = IndexCoordinator(store: store)
    }

    // MARK: - Generations

    /// Invalidates everything in flight and returns the snapshot that replaces
    /// it, or `nil` when there is no folder to work on.
    private func beginPass() -> Pass? {
        generation += 1
        guard let root else { return nil }
        return Pass(token: generation, root: root,
                    includeSubfolders: includeSubfolders, sort: sort)
    }

    private func isCurrent(_ pass: Pass) -> Bool { pass.token == generation }

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
        guard let pass = beginPass() else { return }
        await reload(pass)
        await rescan(pass)
    }

    // MARK: - Indexing

    /// Re-scans the current folder, then reloads the grid from the index.
    func refresh() async {
        guard let pass = beginPass() else { return }
        await rescan(pass)
    }

    private func rescan(_ pass: Pass) async {
        // A pass that was superseded before it even started must not touch the
        // task belonging to the pass that replaced it.
        guard isCurrent(pass) else { return }

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
        guard isCurrent(pass) else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.indexTier0(root: pass.root,
                                                      recursive: pass.includeSubfolders) {
                    [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrent(pass) else { return }
                        self.progress = progress
                    }
                }
            } catch is CancellationError {
                // Superseded. The pass that replaced this one owns the window.
                return
            } catch IndexCoordinatorError.rootUnreadable(let path) {
                guard self.isCurrent(pass) else { return }
                self.status = .rootUnreadable(path: path)
                self.progress = IndexProgress(phase: .idle)
                return
            } catch {
                guard self.isCurrent(pass) else { return }
                self.status = .failed(error.localizedDescription)
                self.progress = IndexProgress(phase: .idle)
                return
            }
            guard self.isCurrent(pass) else { return }
            self.status = .ok
            await self.reload(pass)
        }
        indexingTask = task
        await task.value
    }

    /// Re-runs the query against the index without touching the filesystem.
    func reload() async {
        guard let pass = beginPass() else { return }
        await reload(pass)
    }

    private func reload(_ pass: Pass) async {
        guard isCurrent(pass) else { return }
        let query = SearchQuery(scope: .folder(path: pass.root.path,
                                               recursive: pass.includeSubfolders),
                                sort: pass.sort)
        let searcher = self.searcher
        do {
            // Off the main actor: the index can hold hundreds of thousands of
            // rows and the window must not freeze while SQLite answers.
            let rows = try await Task.detached(priority: .userInitiated) {
                try searcher.search(query)
            }.value
            guard isCurrent(pass) else { return }
            records = rows
        } catch {
            // Checked on the failure path too: a slow search that fails for a
            // folder the user has already left must not put an error banner
            // over a folder that opened fine.
            guard isCurrent(pass) else { return }
            records = []
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Tier 1

    /// Starts the hashing pass for the current folder. Safe to call while one
    /// is already running: the queue is the database, so a second pass simply
    /// picks up whatever rows the first has not reached.
    func startHashingPass() {
        guard let root else { return }
        let pass = Pass(token: generation, root: root,
                        includeSubfolders: includeSubfolders, sort: sort)
        hashingTask?.cancel()
        hashingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.runHashingPass(root: pass.root) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrent(pass) else { return }
                        self.progress = progress
                    }
                }
            } catch is CancellationError {
                return
            } catch IndexCoordinatorError.rootUnreadable(let path) {
                guard self.isCurrent(pass) else { return }
                self.status = .rootUnreadable(path: path)
                self.progress = IndexProgress(phase: .idle)
            } catch {
                guard self.isCurrent(pass) else { return }
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
