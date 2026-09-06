import Testing
import Foundation
import LightboxCore
@testable import Lightbox

/// Counts what a reload actually costs the index.
///
/// The debounce is a performance decision, and a performance decision that is
/// not asserted is a comment. Counting queries states it as a fact without
/// measuring wall-clock time, which would make the test a benchmark and
/// therefore flaky on a loaded machine.
final class CountingSearcher: RecordSearching, @unchecked Sendable {
    private let store: IndexStore
    private let lock = NSLock()
    private var searchCount = 0
    private var facetCount = 0

    init(_ store: IndexStore) { self.store = store }

    var searches: Int { lock.withLock { searchCount } }
    var facetQueries: Int { lock.withLock { facetCount } }

    func search(_ query: SearchQuery) throws -> [FileRecord] {
        lock.withLock { searchCount += 1 }
        return try store.search(query)
    }

    func facets(for query: SearchQuery) throws -> Facets {
        lock.withLock { facetCount += 1 }
        return try store.facets(for: query)
    }
}

/// Holds up the search for one particular piece of search text.
///
/// Keyed on *what* is being asked rather than on which call number it is,
/// because a reload issues its search and its aggregate from a detached task:
/// two overlapping reloads reach the searcher in whichever order the pool
/// starts them, so a counting double would delay an arbitrary one of them and
/// the test would assert on the scheduler. Matching the predicate makes the
/// delayed pass the one the test names, every run.
final class SearcherDelayingSearchText: RecordSearching, @unchecked Sendable {
    private let store: IndexStore
    private let target: String
    private let delay: TimeInterval

    init(_ store: IndexStore, delaying target: String, by delay: TimeInterval = 0.25) {
        self.store = store
        self.target = target
        self.delay = delay
    }

    func search(_ query: SearchQuery) throws -> [FileRecord] {
        // Ahead of the store, so the delayed search is not holding the
        // database queue while the search meant to overtake it waits.
        if Self.mentions(target, query.predicate) { Thread.sleep(forTimeInterval: delay) }
        return try store.search(query)
    }

    func facets(for query: SearchQuery) throws -> Facets {
        if Self.mentions(target, query.predicate) { Thread.sleep(forTimeInterval: delay) }
        return try store.facets(for: query)
    }

    private static func mentions(_ text: String, _ predicate: SearchPredicate) -> Bool {
        switch predicate {
        case .filenameText(let value): value == text
        case .and(let parts), .or(let parts): parts.contains { mentions(text, $0) }
        case .not(let inner): mentions(text, inner)
        default: false
        }
    }
}

@MainActor
struct BrowserFilterTests {
    let tree: TempDirectory

    init() throws {
        tree = try TempDirectory()
    }

    /// A folder that exists nowhere on disk.
    ///
    /// Load-bearing, and the same trick `BrowserModelTests` uses: a tier 0
    /// pass over a missing root throws `rootUnreadable` and reconciles
    /// nothing, so seeded rows for files that were never written survive to be
    /// queried. Pointing them at a real but empty directory would have the
    /// scan delete every one of them out from under the test.
    private var ghost: URL { tree.root.appendingPathComponent("ghost", isDirectory: true) }

    /// `(name, width, camera)`. The extensions are deliberately uneven so a
    /// count of 1 cannot be confused with a count of 3.
    private static let library: [(String, Int, String?)] = [
        ("beach.jpg", 4000, "Canon"),
        ("beach.png", 800, nil),
        ("mountain.jpg", 1920, "Canon"),
        ("mountain.heic", 200, "Apple"),
        ("sunset.jpg", 100, nil),
    ]

    private func seededStore() throws -> IndexStore {
        let store = try IndexStore.inMemory()
        var inode: Int64 = 0
        for (name, width, camera) in Self.library {
            inode += 1
            let url = ghost.appendingPathComponent(name)
            _ = try store.upsert(FileRecord(
                id: nil, path: url.path, parentDir: ghost.path, name: name,
                ext: (name as NSString).pathExtension, size: 1024, mtime: 1_700_000_000,
                device: 1, inode: inode, width: width, height: 100,
                captureTime: nil, captureOffset: nil, cameraMake: camera,
                cameraModel: nil, orientation: nil, contentHash: nil, imageHash: nil,
                imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 1_700_000_000))
        }
        return store
    }

    /// Opens `ghost` with the debounce driven to zero.
    ///
    /// Zero rather than a short sleep: the test is about what the search
    /// produces, not about how long the model waits, and every test that had
    /// to sleep for the real interval would add a quarter second to the suite
    /// for nothing. `theSearchFieldQueriesOncePerPauseNotOncePerCharacter`
    /// keeps the real interval and asserts the waiting separately.
    private func openedModel(searcher: (any RecordSearching)? = nil) async throws -> BrowserModel {
        let model = BrowserModel(store: try seededStore(), searcher: searcher)
        model.searchDebounce = .zero
        await model.open(ghost)
        return model
    }

    private func names(_ model: BrowserModel) -> [String] { model.records.map(\.name) }

    // MARK: - Search

    @Test func searchTextNarrowsTheGridAndTheFacets() async throws {
        let model = try await openedModel()
        #expect(model.records.count == Self.library.count)
        #expect(model.facets.total == Self.library.count)

        model.searchText = "beach"
        await model.waitForPendingSearch()

        #expect(names(model).sorted() == ["beach.jpg", "beach.png"])
        #expect(model.facets.total == 2)
        #expect(model.facets.byExtension == ["jpg": 1, "png": 1])
    }

    /// The last word is a prefix, so a half-typed word still matches — which is
    /// the entire point of a search field that narrows as you type.
    @Test func aPartialWordStillMatches() async throws {
        let model = try await openedModel()
        model.searchText = "bea"
        await model.waitForPendingSearch()
        #expect(names(model).sorted() == ["beach.jpg", "beach.png"])
    }

    /// Text that tokenizes to nothing must match nothing.
    ///
    /// `FTS5Query` distinguishes an empty field from typed-but-unsearchable
    /// text precisely so this case does not show the entire library. Typing
    /// `***` and being shown every file is a far worse answer than being shown
    /// none, because it looks like the filter silently failed.
    @Test func hostileSearchTextShowsNothingRatherThanEverything() async throws {
        let model = try await openedModel()
        for hostile in ["***", "\"", "🙂"] {
            model.searchText = hostile
            await model.waitForPendingSearch()
            #expect(model.records.isEmpty, "\(hostile) showed \(names(model))")
            #expect(model.facets.total == 0)
            if case .failed(let description) = model.status {
                Issue.record("\(hostile) crashed the query rather than matching nothing: \(description)")
            }
        }
    }

    @Test func emptyingTheSearchFieldRestoresTheWholeFolder() async throws {
        let model = try await openedModel()
        model.searchText = "beach"
        await model.waitForPendingSearch()
        #expect(model.records.count == 2)

        model.searchText = ""
        await model.waitForPendingSearch()
        #expect(model.records.count == Self.library.count)
    }

    /// One query per pause, not one per character.
    ///
    /// Keeps the real debounce interval — driving it to zero here would assert
    /// nothing. The baseline is taken after `open` rather than written as a
    /// number, so the expectation is "the word cost one reload" and not a
    /// count copied out of the model.
    @Test func theSearchFieldQueriesOncePerPauseNotOncePerCharacter() async throws {
        let store = try seededStore()
        let searcher = CountingSearcher(store)
        let model = BrowserModel(store: store, searcher: searcher)
        await model.open(ghost)

        let searchBaseline = searcher.searches
        let facetBaseline = searcher.facetQueries
        for character in "beach" { model.searchText.append(character) }
        await model.waitForPendingSearch()

        #expect(searcher.searches - searchBaseline == 1,
                "typing five characters cost \(searcher.searches - searchBaseline) searches")
        #expect(searcher.facetQueries - facetBaseline == 1)
        #expect(names(model).sorted() == ["beach.jpg", "beach.png"])
    }

    /// Two overlapping searches: the one started *second* wins, whichever
    /// finishes last.
    ///
    /// The same generation guarantee `BrowserModelTests` pins for `open` and
    /// `sort`, restated for the filter path — which is a genuinely new way in,
    /// because the debounce means a query can be issued for text the user has
    /// already replaced.
    @Test func aSupersededSearchDoesNotLeaveTheOlderResultsOnScreen() async throws {
        let store = try seededStore()
        let model = BrowserModel(store: store,
                                 searcher: SearcherDelayingSearchText(store, delaying: "beach"))
        model.searchDebounce = .zero
        await model.open(ghost)

        // Held up inside the searcher, so this pass is guaranteed to finish
        // last however the pool schedules it.
        model.searchText = "beach"
        // Lets the "beach" reload take its generation and issue its query
        // before the search that supersedes it exists. Cancelling its wrapper
        // task, which the next assignment does, does not stop it: it is
        // already awaiting a detached search, and that is precisely the
        // in-flight pass the generation guard has to reject.
        await Task.yield()
        model.searchText = "sunset"
        await model.waitForPendingSearch()
        #expect(names(model) == ["sunset.jpg"], "the newer search never landed")

        // Past the held-up search, whose reload was never handed back.
        try await Task.sleep(for: .milliseconds(600))
        #expect(names(model) == ["sunset.jpg"],
                "grid left showing a superseded search: \(names(model))")
        #expect(model.facets.total == 1,
                "the facet counts came from the superseded search")
    }

    // MARK: - Facets

    @Test func facetsCountTheWholeFolderNotTheSelection() async throws {
        let model = try await openedModel()
        #expect(model.facets.byExtension == ["jpg": 3, "png": 1, "heic": 1])
        #expect(model.facets.byCamera == ["Canon": 2, "Apple": 1])
        #expect(model.facets.total == Self.library.count)
    }

    @Test func tickingAFileTypeNarrowsTheGrid() async throws {
        let model = try await openedModel()
        model.selectedExtensions = ["png"]
        await model.waitForPendingSearch()

        #expect(names(model) == ["beach.png"])
        #expect(model.facets.total == 1)
    }

    /// The file-type filter must not be a one-way door.
    ///
    /// Counting extensions *under* the extension filter leaves `byExtension`
    /// holding only the types already ticked, so every other row disappears
    /// from the panel and there is no longer a `.png` to tick. The extension
    /// facet is therefore counted over the query with the type filter left
    /// out, while `total` and the camera breakdown still describe what is on
    /// screen.
    @Test func tickingOneFileTypeLeavesTheOthersTickableInThePanel() async throws {
        let model = try await openedModel()
        let unfiltered = model.facets.byExtension

        model.selectedExtensions = ["jpg"]
        await model.waitForPendingSearch()

        #expect(model.facets.byExtension == unfiltered,
                "the other file types vanished from the panel and cannot be ticked")
        #expect(model.facets.total == 3, "total must still describe the grid")
        #expect(model.records.count == 3)
    }

    /// The extension facet stays honest about the *other* filters, though: it
    /// is the type filter alone that is lifted, not the search.
    @Test func theExtensionFacetStillRespectsTheSearchText() async throws {
        let model = try await openedModel()
        model.searchText = "beach"
        await model.waitForPendingSearch()
        model.selectedExtensions = ["jpg"]
        await model.waitForPendingSearch()

        #expect(model.facets.byExtension == ["jpg": 1, "png": 1],
                "the extension facet ignored the search text: \(model.facets.byExtension)")
        #expect(names(model) == ["beach.jpg"])
    }

    @Test func minimumWidthNarrowsTheGridAndTheFacets() async throws {
        let model = try await openedModel()
        model.minimumWidth = 1920
        await model.waitForPendingSearch()

        #expect(names(model).sorted() == ["beach.jpg", "mountain.jpg"])
        #expect(model.facets.byExtension == ["jpg": 2])
        #expect(model.facets.total == 2)
    }

    @Test func clearFiltersRestoresTheWholeFolder() async throws {
        let model = try await openedModel()
        model.searchText = "beach"
        model.selectedExtensions = ["png"]
        model.minimumWidth = 100
        await model.waitForPendingSearch()
        #expect(model.hasActiveFilters)
        #expect(names(model) == ["beach.png"])

        model.clearFilters()
        await model.waitForPendingSearch()

        #expect(!model.hasActiveFilters)
        #expect(model.searchText.isEmpty)
        #expect(model.selectedExtensions.isEmpty)
        #expect(model.minimumWidth == nil)
        #expect(model.records.count == Self.library.count)
    }

    /// A filter that produces nothing must leave the panel saying nothing
    /// matched, not showing the counts from before.
    @Test func aFilterThatMatchesNothingEmptiesTheFacetsToo() async throws {
        let model = try await openedModel()
        model.selectedExtensions = ["gif"]
        await model.waitForPendingSearch()

        #expect(model.records.isEmpty)
        #expect(model.facets.total == 0)
        #expect(model.facets.byCamera.isEmpty)
        // The *extension* facet is deliberately still populated: it is counted
        // with the type filter lifted, which is the only way back out of a
        // filter that matched nothing.
        #expect(!model.facets.byExtension.isEmpty)
    }

    // MARK: - Selection and the inspector

    @Test func selectedRecordsFollowTheSelectionInDisplayOrder() async throws {
        let model = try await openedModel()
        #expect(model.selectedRecords.isEmpty)

        model.selectAll()
        #expect(model.selectedRecords.map(\.name) == names(model))

        let second = try #require(model.order.dropFirst().first)
        model.selection.click(second, in: model.order, shift: false, command: false)
        #expect(model.selectedRecords.count == 1)
        #expect(model.selectedRecords[0].id == second)
    }

    /// Filtering rows out of the grid has to prune the selection with them.
    ///
    /// A selection still naming rows that are no longer on screen would go on
    /// to drive a copy, a move, or — in phase 2 — a delete against files the
    /// user cannot see. The anchor moves to the topmost surviving row rather
    /// than being dropped, so the next shift-click extends a range instead of
    /// collapsing one.
    @Test func filteringOutSelectedRowsPrunesTheSelection() async throws {
        let model = try await openedModel()
        model.selectAll()
        #expect(model.selection.selected.count == Self.library.count)

        model.searchText = "beach"
        await model.waitForPendingSearch()

        #expect(model.records.count == 2)
        #expect(model.selection.selected == Set(model.order))
        #expect(model.selection.anchor == model.order.first,
                "the anchor must survive as the topmost row still on screen")
    }
}
