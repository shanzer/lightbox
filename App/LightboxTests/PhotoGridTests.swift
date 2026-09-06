import Testing
import Foundation
import LightboxCore
@testable import Lightbox

/// Returns a scripted list per call, so a test can change what the grid is
/// showing between two reloads without going near the store or the filesystem.
///
/// The last entry repeats, so an extra reload the model decides to do on its
/// own cannot make a test depend on how many searches it issued.
private final class ScriptedSearcher: RecordSearching, @unchecked Sendable {
    private let results: [[FileRecord]]
    private let lock = NSLock()
    private var calls = 0
    private var lastReturned: [FileRecord] = []

    init(_ results: [[FileRecord]]) {
        precondition(!results.isEmpty)
        self.results = results
    }

    func search(_ query: SearchQuery) throws -> [FileRecord] {
        lock.lock()
        defer { lock.unlock() }
        let index = min(calls, results.count - 1)
        calls += 1
        lastReturned = results[index]
        return results[index]
    }

    /// Derived from the rows the *same* reload's search just returned, not
    /// from the next entry in the script: a reload asks for the rows and then
    /// for their breakdown, so counting off the script position would have the
    /// panel describing a page the grid is not showing.
    func facets(for query: SearchQuery) throws -> Facets {
        let rows = lock.withLock { lastReturned }
        return Facets(byExtension: rows.reduce(into: [:]) { $0[$1.ext, default: 0] += 1 },
                      byCamera: [:],
                      total: rows.count)
    }
}

@MainActor
struct PhotoGridTests {
    let tree: TempDirectory

    init() throws {
        tree = try TempDirectory()
    }

    /// A row as the grid sees one: already carrying an id, never written to the
    /// store.
    private func record(id: Int64, in folder: URL) -> FileRecord {
        let url = folder.appendingPathComponent("img\(id).jpg")
        return FileRecord(
            id: id, path: url.path, parentDir: folder.path, name: url.lastPathComponent,
            ext: "jpg", size: 1024, mtime: 1_700_000_000, device: 1, inode: id,
            width: 100, height: 100, captureTime: nil, captureOffset: nil, cameraMake: nil,
            cameraModel: nil, orientation: nil, contentHash: nil, imageHash: nil,
            imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 1_700_000_000)
    }

    /// A folder that is deliberately absent from disk, so the tier 0 pass
    /// following each load throws `rootUnreadable` and reconciles nothing. A
    /// folder that existed would have the pass delete every scripted row and
    /// then reload a second time, which is not what these tests are about.
    private var missingFolder: URL {
        tree.root.appendingPathComponent("not-on-disk", isDirectory: true)
    }

    private func store() throws -> IndexStore {
        try IndexStore(url: tree.root.appendingPathComponent("index.sqlite"))
    }

    // MARK: - Selection against a changing record set

    @Test func theGridsOrderTracksTheRecordsItIsShowing() async throws {
        let folder = missingFolder
        let rows = (1...4).map { record(id: $0, in: folder) }
        let model = BrowserModel(store: try store(), searcher: ScriptedSearcher([rows]))

        await model.open(folder)

        #expect(model.order == [1, 2, 3, 4],
                "the grid clicks against this on every tap; it must be the display order")
    }

    /// The reason `SelectionModel.retain(_:)` exists.
    ///
    /// A rescan deletes rows. A selection still naming them goes on to drive a
    /// copy, a move, and in phase 2 a delete, against files that are not there.
    @Test func recordsGoingAwayPrunesTheSelection() async throws {
        let folder = missingFolder
        let all = (1...4).map { record(id: $0, in: folder) }
        let survivors = [all[1], all[2]]
        let model = BrowserModel(store: try store(),
                                 searcher: ScriptedSearcher([all, survivors]))

        await model.open(folder)
        model.selection.click(2, in: model.order, shift: false, command: false)
        model.selection.click(4, in: model.order, shift: true, command: false)
        #expect(model.selection.selected == [2, 3, 4])

        await model.reload()

        #expect(model.order == [2, 3])
        #expect(model.selection.selected == [2, 3])
        #expect(model.selection.anchor == 2,
                "row 2 is still on screen, so the range must still extend from it")
    }

    /// A deleted anchor is dropped only when the selection it anchored is gone
    /// too. When rows survive it moves to the lowest of them — see
    /// `retainReAnchorsToTheLowestSurvivorWhenTheAnchorRowIsGone`.
    @Test func anAnchorThatIsDeletedIsDroppedWhenNothingSurvives() async throws {
        let folder = missingFolder
        let all = (1...4).map { record(id: $0, in: folder) }
        let survivors = [all[2], all[3]]
        let model = BrowserModel(store: try store(),
                                 searcher: ScriptedSearcher([all, survivors]))

        await model.open(folder)
        model.selection.click(1, in: model.order, shift: false, command: false)
        model.selection.click(2, in: model.order, shift: true, command: false)
        #expect(model.selection.anchor == 1)

        await model.reload()

        #expect(model.selection.selected.isEmpty)
        #expect(model.selection.anchor == nil, "nothing may extend from a row that is gone")
    }

    /// A reload that deletes the anchored row but leaves the rest of the range
    /// must not silently collapse the user's next shift-click.
    @Test func aReloadThatDeletesTheAnchorLeavesTheRangeExtendable() async throws {
        let folder = missingFolder
        let all = (1...5).map { record(id: $0, in: folder) }
        let survivors = Array(all[1...])
        let model = BrowserModel(store: try store(),
                                 searcher: ScriptedSearcher([all, survivors]))

        await model.open(folder)
        model.selection.click(1, in: model.order, shift: false, command: false)
        model.selection.click(3, in: model.order, shift: true, command: false)
        #expect(model.selection.selected == [1, 2, 3])

        await model.reload()

        #expect(model.selection.selected == [2, 3])
        #expect(model.selection.anchor == 2, "the range now extends from its lowest survivor")

        model.selection.click(5, in: model.order, shift: true, command: false)
        #expect(model.selection.selected == [2, 3, 4, 5],
                "a dropped anchor would have collapsed this to [5]")
    }

    // MARK: - Select All

    /// The menu command's target. ⌘A is a menu key equivalent, so this is the
    /// path the shortcut actually takes — `PhotoGridView` never sees the event.
    @Test func selectAllTakesEverythingOnScreen() async throws {
        let folder = missingFolder
        let rows = (1...4).map { record(id: $0, in: folder) }
        let model = BrowserModel(store: try store(), searcher: ScriptedSearcher([rows]))

        await model.open(folder)
        model.selectAll()

        #expect(model.selection.selected == [1, 2, 3, 4])
        #expect(model.selection.anchor == 1)
    }

    @Test func selectAllOnAnEmptyGridSelectsNothing() async throws {
        let model = BrowserModel(store: try store(), searcher: ScriptedSearcher([[]]))

        await model.open(missingFolder)
        model.selectAll()

        #expect(model.selection.selected.isEmpty)
        #expect(model.selection.anchor == nil)
    }

    @Test func aReloadThatChangesNothingLeavesTheSelectionAlone() async throws {
        let folder = missingFolder
        let all = (1...4).map { record(id: $0, in: folder) }
        let model = BrowserModel(store: try store(), searcher: ScriptedSearcher([all]))

        await model.open(folder)
        model.selection.click(2, in: model.order, shift: false, command: false)
        model.selection.click(4, in: model.order, shift: true, command: false)
        let before = model.selection

        await model.reload()

        #expect(model.selection == before)
    }

    // MARK: - Thumbnail cache housekeeping

    /// `ThumbnailCache` never evicts on its own — nothing in `Core` calls
    /// `evictIfNeeded()`, so its budget does nothing whatsoever until something
    /// schedules it. Opening a folder is that something, and this is the test
    /// that says so.
    @Test func openingAFolderTrimsTheThumbnailCache() async throws {
        let cacheDirectory = try tree.directory("thumbnails")
        for index in 0..<4 {
            try Data(repeating: 0x50, count: 4096)
                .write(to: cacheDirectory.appendingPathComponent("entry\(index).png"))
        }
        let cache = ThumbnailCache(directory: cacheDirectory, budgetBytes: 1)
        #expect(try await cache.cachedCount() == 4)

        let model = BrowserModel(store: try store(),
                                 searcher: ScriptedSearcher([[]]),
                                 thumbnails: cache)
        await model.open(missingFolder)
        await model.waitForThumbnailTrim()

        // One entry always survives, so that a budget set too small cannot
        // blank the grid the user is looking at.
        #expect(try await cache.cachedCount() == 1)
    }

    // MARK: - Requested thumbnail size

    @Test func theRequestedSizeIsNeverSmallerThanTheCellNeeds() {
        // Two device pixels per point, so a cell is never shown an image it has
        // to scale up.
        for side in stride(from: 64.0, through: 320.0, by: 1.0) {
            #expect(ThumbnailCell.requestedPixels(for: side) >= Int(side * 2))
        }
    }

    @Test func theRequestedSizeSteps() {
        #expect(ThumbnailCell.requestedPixels(for: 64) == 256)
        #expect(ThumbnailCell.requestedPixels(for: 128) == 256)
        #expect(ThumbnailCell.requestedPixels(for: 129) == 512)
        #expect(ThumbnailCell.requestedPixels(for: 256) == 512)
        #expect(ThumbnailCell.requestedPixels(for: 320) == 768)
    }

    @Test func theRequestedSizeIsCappedAndNeverZero() {
        #expect(ThumbnailCell.requestedPixels(for: 4000) == 1024,
                "an unbounded request would have QuickLook render a full-size image per cell")
        #expect(ThumbnailCell.requestedPixels(for: 0) > 0,
                "a zero-pixel request is not a thumbnail")
    }

    /// The property the quantisation exists for.
    ///
    /// The cache keys on the requested size, so an exact request would make
    /// every point of slider travel its own cache entry: one QuickLook render
    /// and one file on disk per point, per visible cell, for a single drag.
    @Test func draggingTheSliderEndToEndAsksForOnlyAHandfulOfSizes() {
        var requested: Set<Int> = []
        for step in 0...512 {
            let side = 64.0 + Double(step) * 0.5   // 64…320, half a point at a time
            requested.insert(ThumbnailCell.requestedPixels(for: side))
        }
        #expect(requested.count <= 4, "asked for \(requested.sorted()) across one drag")
    }

    @Test func theRequestedSizeNeverShrinksAsTheCellGrows() {
        var previous = 0
        for step in 0...512 {
            let side = 64.0 + Double(step) * 0.5
            let pixels = ThumbnailCell.requestedPixels(for: side)
            #expect(pixels >= previous)
            previous = pixels
        }
    }
}
