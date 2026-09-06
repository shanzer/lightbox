import Testing
import Foundation
import LightboxCore
@testable import Lightbox

/// Wraps the real store and holds up one chosen search.
///
/// The ordering guarantee under test is about which of two overlapping
/// searches lands last, and that is decided by the cooperative pool: on an
/// idle machine the first-issued search reliably returns first and the bug is
/// invisible, while under load the order inverts about two times in five.
/// Delaying a specific call makes the inversion happen every time instead of
/// sometimes, so the test states a fact rather than sampling a distribution.
final class SearcherDelayingOneCall: RecordSearching, @unchecked Sendable {
    private let store: IndexStore
    private let target: Int
    private let delay: TimeInterval
    private let lock = NSLock()
    private var calls = 0

    init(_ store: IndexStore, delayingCall target: Int, by delay: TimeInterval = 0.25) {
        self.store = store
        self.target = target
        self.delay = delay
    }

    func search(_ query: SearchQuery) throws -> [FileRecord] {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        // Ahead of the store, so the delayed search is not holding the
        // database queue while the search meant to overtake it waits.
        if call == target { Thread.sleep(forTimeInterval: delay) }
        return try store.search(query)
    }

    /// Undelayed: `calls` counts searches, so the reload's aggregate must not
    /// consume a slot and shift which search the test is holding up.
    func facets(for query: SearchQuery) throws -> Facets {
        try store.facets(for: query)
    }
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's contract
/// rather than an ARC ordering inferred from where it was last used.
@MainActor
struct BrowserModelTests {
    let tree: TempDirectory

    init() throws {
        tree = try TempDirectory()
    }

    /// Seeds rows for files that do not exist on disk.
    ///
    /// Safe only because the folder they claim to be in does not exist either:
    /// a tier 0 pass over a missing root throws `rootUnreadable` and reconciles
    /// nothing, so these rows survive to be queried. Pointing them at a real
    /// but empty directory would have the pass delete every one of them.
    private func seed(_ store: IndexStore, folder: URL, count: Int) throws {
        for index in 0..<count {
            let url = folder.appendingPathComponent("img\(index).jpg")
            let record = FileRecord(
                id: nil, path: url.path, parentDir: folder.path, name: url.lastPathComponent,
                ext: "jpg", size: 1024, mtime: 1_700_000_000, device: 1,
                inode: Int64(abs(url.path.hashValue % 1_000_000_000)),
                width: 100, height: 100, captureTime: nil, captureOffset: nil, cameraMake: nil,
                cameraModel: nil, orientation: nil, contentHash: nil, imageHash: nil,
                imageHashKind: nil, phash: nil, hashedAt: nil, indexedAt: 1_700_000_000)
            _ = try store.upsert(record)
        }
    }

    /// Two overlapping loads: the one started *second* must win, whichever
    /// finishes last.
    ///
    /// `reload` issues its query, suspends while a detached task runs it, and
    /// assigns `records` on the far side of that suspension. Without a
    /// generation check the two assignments land in completion order, so the
    /// older one overwrites the newer whenever it happens to return last —
    /// leaving the grid showing a folder the user has already left.
    ///
    /// **Both folders are deliberately missing from disk.** A pass over a
    /// folder that exists finishes its scan and then reloads a second time,
    /// and that second reload papers over a stale write — which is why this
    /// bug survives a reading of the `open` path. A pass over a missing root
    /// throws `rootUnreadable` and never reaches that reload, so a stale write
    /// stays visible. That is also the shape of the `sort` path below, which
    /// has no scan after it at all.
    ///
    /// Verified by mutation: dropping the `isCurrent` checks from `reload`
    /// turns this red.
    @Test func aSupersededLoadDoesNotOverwriteTheFolderOpenedAfterIt() async throws {
        let store = try IndexStore.inMemory()
        let big = tree.root.appendingPathComponent("big", isDirectory: true)
        let small = tree.root.appendingPathComponent("small", isDirectory: true)
        try seed(store, folder: big, count: 20)
        try seed(store, folder: small, count: 1)

        // Call 1 is the search `open(big)` issues; holding it up guarantees it
        // returns after the search for the folder opened next.
        let model = BrowserModel(store: store,
                                 searcher: SearcherDelayingOneCall(store, delayingCall: 1))

        let first = Task { await model.open(big) }
        // Lets `first` reach its search before the second open replaces it.
        await Task.yield()
        let second = Task { await model.open(small) }
        await first.value
        await second.value

        #expect(model.root == small)
        #expect(model.records.count == 1)
        #expect(model.records.allSatisfy { $0.path.hasPrefix(small.path + "/") })
        // A stale pass must not write `status` either: the failure on show has
        // to be the current folder's, not the one the user already left.
        #expect(model.status == .rootUnreadable(path: small.path))
    }

    /// The `sort` path has no scan behind it, so whichever reload lands last is
    /// what the user is left looking at — permanently. No view mutates `sort`
    /// yet; Task 19 adds one.
    ///
    /// Asserted as a property — ascending means the first name sorts before the
    /// last — rather than against an expected sequence, so nothing here depends
    /// on how the query builder happens to order.
    @Test func aSupersededSortDoesNotLeaveTheGridInTheOlderOrder() async throws {
        let store = try IndexStore.inMemory()
        let folder = tree.root.appendingPathComponent("many", isDirectory: true)
        try seed(store, folder: folder, count: 200)

        // Call 1 belongs to `open`; call 2 is the superseded sort's search.
        let model = BrowserModel(store: store,
                                 searcher: SearcherDelayingOneCall(store, delayingCall: 2))
        await model.open(folder)
        #expect(model.records.count == 200)

        // Note the shape. `didSet` spawns a task that calls `reload`, and
        // `reload` reads `sort` when it *runs*, not when the property changed —
        // so two assignments in a row both end up querying the newer value and
        // no stale query is ever issued. A genuinely superseded pass has to be
        // started, allowed to capture the older sort, and only then replaced.
        model.sort = SearchQuery.Sort(field: .name, ascending: false)
        let stale = Task { await model.reload() }
        await Task.yield()
        model.sort = SearchQuery.Sort(field: .name, ascending: true)
        await stale.value

        // The reload `didSet` fired is not handed back, so wait past the
        // held-up search rather than for a handle.
        try await Task.sleep(for: .milliseconds(600))

        let names = model.records.map(\.name)
        #expect(names.count == 200)
        #expect(names.first! < names.last!, "grid left in the superseded order")
    }

    /// A root that cannot be enumerated has to reach `status`. `Core` throws
    /// rather than reporting an empty folder precisely so this is not silently
    /// mistaken for "every file was deleted", and the rows are kept.
    @Test func anUnreadableRootIsSurfacedAndItsRowsAreKept() async throws {
        let store = try IndexStore.inMemory()
        let locked = try tree.directory("locked")
        try tree.file("locked/a.jpg")

        let model = BrowserModel(store: store)
        await model.open(locked)
        #expect(model.status == .ok)
        #expect(model.records.count == 1)

        try tree.chmod("locked", 0o000)
        await model.refreshCurrentFolder()

        #expect(model.status == .rootUnreadable(path: locked.path))
        #expect(model.records.count == 1)
    }

    /// `open` ignores the folder already open, so reconnecting a drive and
    /// re-picking it recovers nothing. `refreshCurrentFolder` is the way out,
    /// and is what the `rootUnreadable` message tells the user to press.
    @Test func refreshRescansTheCurrentFolderWhereReopeningItDoesNot() async throws {
        let store = try IndexStore.inMemory()
        let folder = try tree.directory("photos")
        try tree.file("photos/one.jpg")

        let model = BrowserModel(store: store)
        await model.open(folder)
        #expect(model.records.count == 1)

        try tree.file("photos/two.jpg")

        await model.open(folder)
        #expect(model.records.count == 1)   // no rescan: same folder

        await model.refreshCurrentFolder()
        #expect(model.records.count == 2)
    }

    /// The status message has to name the recovery, or the user is told to
    /// reconnect a drive and then given nothing that acts on it.
    @Test func theUnreadableRootMessageNamesTheRecovery() {
        let message = BrowserModel.Status.rootUnreadable(path: "/Volumes/Photos").message
        #expect(message?.contains("/Volumes/Photos") == true)
        #expect(message?.contains("⌘R") == true)
        #expect(BrowserModel.Status.ok.message == nil)
    }
}
