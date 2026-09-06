import Foundation
import Observation
import LightboxCore

/// The state behind one browser window: which folder is open, what the index
/// says is in it, and how far the current pass has got.
///
/// Everything the views bind to lives here so the views stay declarative and
/// this stays the only place that knows the `Core` API.
@MainActor
@Observable
final class BrowserModel {
    /// What the last pass had to say for itself.
    ///
    /// Cancellation is deliberately absent: the user changing folders or
    /// flipping the subfolders toggle cancels the pass in flight, and that is
    /// ordinary operation, not a condition to report.
    enum Status: Equatable, Sendable {
        case ok
        /// The folder could not be enumerated — it was deleted, its permissions
        /// changed, or, the case this app is built around, its drive was
        /// unplugged. `Core` refuses to reconcile the index against a walk it
        /// could not complete, so the rows survive; the user just needs to know
        /// that what they are looking at is stale rather than empty.
        case rootUnreadable(path: String)
        case failed(String)

        var message: String? {
            switch self {
            case .ok:
                nil
            case .rootUnreadable(let path):
                "Could not read \(path). If it is on a removable drive, reconnect it — "
                    + "the index for it has been kept."
            case .failed(let description):
                description
            }
        }
    }

    private(set) var records: [FileRecord] = []
    private(set) var progress = IndexProgress()
    private(set) var root: URL?
    private(set) var status: Status = .ok

    var includeSubfolders = true {
        didSet {
            guard includeSubfolders != oldValue else { return }
            Task { await scopeChanged() }
        }
    }

    var sort = SearchQuery.Sort() {
        didSet {
            guard sort != oldValue else { return }
            Task { await reload() }
        }
    }

    private let store: IndexStore
    private let coordinator: IndexCoordinator
    private var indexingTask: Task<Void, Never>?
    private var hashingTask: Task<Void, Never>?

    init() throws {
        store = try IndexStore(url: IndexStore.defaultURL)
        coordinator = IndexCoordinator(store: store)
    }

    init(store: IndexStore) {
        self.store = store
        coordinator = IndexCoordinator(store: store)
    }

    // MARK: - Navigation

    func open(_ url: URL) async {
        guard url != root else { return }
        root = url
        status = .ok
        // Show whatever the index already knows about this folder before the
        // rescan starts, so a folder that has been opened before is instant.
        await reload()
        await refresh()
    }

    /// The subfolder toggle changes the scope of both the query and the walk.
    /// The query part is immediate; the walk part may find files the narrower
    /// pass never visited.
    private func scopeChanged() async {
        await reload()
        await refresh()
    }

    // MARK: - Indexing

    /// Re-scans the current folder, then reloads the grid from the index.
    func refresh() async {
        guard let root else { return }
        indexingTask?.cancel()
        let recursive = includeSubfolders
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.indexTier0(root: root, recursive: recursive) {
                    [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                }
            } catch is CancellationError {
                // The pass was superseded — the user picked another folder or
                // changed the scope. The pass that replaced this one owns the
                // grid now, so do not reload over the top of it and do not
                // clear a status the newer pass may have set.
                return
            } catch IndexCoordinatorError.rootUnreadable(let path) {
                self.status = .rootUnreadable(path: path)
                self.progress = IndexProgress(phase: .idle)
                return
            } catch {
                self.status = .failed(error.localizedDescription)
                self.progress = IndexProgress(phase: .idle)
                return
            }
            self.status = .ok
            await self.reload()
        }
        indexingTask = task
        await task.value
    }

    /// Re-runs the query against the index without touching the filesystem.
    func reload() async {
        guard let root else { return }
        let query = SearchQuery(scope: .folder(path: root.path, recursive: includeSubfolders),
                                sort: sort)
        let store = self.store
        do {
            // Off the main actor: the index can hold hundreds of thousands of
            // rows and the window must not freeze while SQLite answers.
            records = try await Task.detached(priority: .userInitiated) {
                try store.search(query)
            }.value
        } catch {
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
        hashingTask?.cancel()
        hashingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.runHashingPass(root: root) { [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                }
            } catch is CancellationError {
                return
            } catch IndexCoordinatorError.rootUnreadable(let path) {
                self.status = .rootUnreadable(path: path)
                self.progress = IndexProgress(phase: .idle)
            } catch {
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
