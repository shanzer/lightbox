import Testing
import Foundation
@testable import LightboxCore
@testable import Lightbox

/// The App half of #28's rule (#30).
///
/// `Core`'s `CooperativePoolTests` holds the line inside the module — the
/// sample in `BlockingWork` is a stack from `IndexCoordinator` — but the rule
/// is about the *process*, and the App target parks cooperative threads on
/// exactly the same calls. A `Task.detached` here is not a hop off the
/// cooperative pool; it is a new task *on* it, and everything `BrowserModel`
/// asks the searcher for is synchronous SQLite.
///
/// Asserted with the same label technique and against the same constant, so a
/// refactor on either side of the module boundary fails in the same legible
/// way rather than as a stalled CI job. `@testable import LightboxCore` rather
/// than a plain import, so that `BlockingWork`'s labels can stay internal:
/// nothing here needs public API that production code does not.
@MainActor
struct CooperativePoolTests {
    let tree: TempDirectory

    init() throws { tree = try TempDirectory() }

    /// A folder that exists nowhere on disk, so the tier 0 pass that follows a
    /// reload throws `rootUnreadable` and reconciles nothing — seeded rows for
    /// files that were never written survive to be queried. The same trick
    /// `BrowserFilterTests` uses, and for the same reason.
    private var ghost: URL { tree.root.appendingPathComponent("ghost", isDirectory: true) }

    /// Records the dispatch queue the browser ran its index reads on.
    ///
    /// The `RecordSearching` seam already exists to control *when* a search
    /// returns; this uses it to observe *where* one ran. Both halves of a
    /// reload are covered, because `reload` issues two or three queries and a
    /// hop that covered only the first would still park a thread in the rest.
    private final class QueueNamingSearcher: RecordSearching, @unchecked Sendable {
        private let store: IndexStore
        private let lock = NSLock()
        private var seen: Set<String> = []

        init(_ store: IndexStore) { self.store = store }

        var labels: Set<String> { lock.withLock { seen } }

        private func record() {
            let label = BlockingWork.currentQueueLabel
            lock.withLock { _ = seen.insert(label) }
        }

        func search(_ query: SearchQuery) throws -> [FileRecord] {
            record()
            return try store.search(query)
        }

        func facets(for query: SearchQuery) throws -> Facets {
            record()
            return try store.facets(for: query)
        }
    }

    private func seededStore() throws -> IndexStore {
        let store = try IndexStore.inMemory()
        for (index, name) in ["a.jpg", "b.png", "c.jpg"].enumerated() {
            _ = try store.upsert(FileRecord(
                id: nil, path: ghost.appendingPathComponent(name).path,
                parentDir: ghost.path, name: name,
                ext: (name as NSString).pathExtension, size: 1024, mtime: 1_700_000_000,
                device: 1, inode: Int64(index + 1), width: 1920, height: 1080,
                captureTime: nil, captureOffset: nil, cameraMake: nil,
                cameraModel: nil, orientation: nil, contentHash: nil, imageHash: nil,
                imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 1_700_000_000))
        }
        return store
    }

    /// `RecordSearching` is `IndexStore.search` and `IndexStore.facets`, which
    /// are synchronous SQLite: a `SELECT` over a table that holds one row per
    /// photo in the library, plus two aggregates over the same predicate. On
    /// the 50k benchmark library the widest of those is 474 ms, and it is 474 ms
    /// of a cooperative thread parked in SQLite's own read — not of a thread
    /// doing arithmetic the pool can account for.
    ///
    /// Nothing about a key window or a real index is needed to observe that:
    /// the store is in memory, the folder does not exist, and the model is the
    /// one `BrowserFilterTests` builds.
    @Test func theBrowsersSearchRunsOffTheCooperativePool() async throws {
        let searcher = QueueNamingSearcher(try seededStore())
        let model = BrowserModel(store: try IndexStore.inMemory(), searcher: searcher,
                                 preferences: MemoryPreferences())
        model.searchDebounce = .zero

        await model.open(ghost)

        #expect(model.records.count == 3, "the reload did not reach the searcher at all")
        #expect(searcher.labels == [BlockingWork.runLabel],
                "the browser searched on a thread that was not a blocking-work thread")
    }

    /// The extension filter takes the second branch of `reload`, which issues a
    /// third query against a wider predicate. Covered separately because it is
    /// a different closure: a hop applied to the common path and not to this
    /// one would leave the more expensive of the two reloads on the pool.
    @Test func theWiderFacetQueryRunsOffTheCooperativePoolToo() async throws {
        let searcher = QueueNamingSearcher(try seededStore())
        let model = BrowserModel(store: try IndexStore.inMemory(), searcher: searcher,
                                 preferences: MemoryPreferences())
        model.searchDebounce = .zero
        await model.open(ghost)

        model.selectedExtensions = ["jpg"]
        await model.waitForPendingSearch()

        #expect(model.records.count == 2, "the extension filter did not take effect")
        #expect(searcher.labels == [BlockingWork.runLabel],
                "the wider facet query ran on a thread that was not a blocking-work thread")
    }
}
