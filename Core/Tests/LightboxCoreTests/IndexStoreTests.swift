import Testing
import Foundation
import GRDB
@testable import LightboxCore

private func sampleRecord(path: String, size: Int64 = 100, mtime: Double = 1_700_000_000,
                          device: Int64 = 1) -> FileRecord {
    FileRecord(
        id: nil, path: path,
        parentDir: (path as NSString).deletingLastPathComponent,
        name: (path as NSString).lastPathComponent,
        ext: (path as NSString).pathExtension.lowercased(),
        size: size, mtime: mtime, device: device, inode: 42,
        width: 200, height: 200,
        captureTime: nil, captureOffset: nil,
        cameraMake: nil, cameraModel: nil, orientation: 1,
        contentHash: nil, imageHash: nil, imageHashKind: nil,
        phash: nil, hashedAt: nil, indexedAt: 1_700_000_000)
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct IndexStoreTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    @Test func migrationCreatesEveryTable() throws {
        let store = try IndexStore.inMemory()
        let tables = try store.tableNames()
        #expect(tables.contains("files"))
        #expect(tables.contains("files_fts"))
        #expect(tables.contains("analysis"))
        #expect(tables.contains("saved_searches"))
        #expect(tables.contains("op_journal"))
    }

    @Test func upsertInsertsThenUpdatesKeepingTheSameRowID() throws {
        let store = try IndexStore.inMemory()
        let first = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100))
        var changed = sampleRecord(path: "/a/b.jpg", size: 999)
        changed.width = 4000
        let second = try store.upsert(changed)
        #expect(first == second)
        #expect(try store.count() == 1)
        let row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.size == 999)
        #expect(row.width == 4000)
    }

    @Test func deviceRoundTripsAndIsRefreshedOnUpdate() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", device: 5))
        var row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.device == 5)
        // The same path re-appearing with a different st_dev (drive re-indexed
        // after a remount) must refresh the stored identity, exactly like inode.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", device: 7))
        row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.device == 7)
    }

    @Test func needsReindexTracksSizeAndModificationTime() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        #expect(try store.needsReindex(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000) == false)
        #expect(try store.needsReindex(path: "/a/b.jpg", size: 101, mtime: 1_700_000_000) == true)
        #expect(try store.needsReindex(path: "/a/b.jpg", size: 100, mtime: 1_700_000_001) == true)
        #expect(try store.needsReindex(path: "/nope.jpg", size: 100, mtime: 1_700_000_000) == true)
    }

    /// The whole reason mtime is REAL and `Double`, not GRDB's text `Date`:
    /// sub-second precision must survive a round trip exactly, and a change in
    /// the fractional part alone must read as stale.
    @Test func fractionalMtimeRoundTripsExactlyAndTriggersReindex() throws {
        let store = try IndexStore.inMemory()
        let fractional = 1_700_000_000.123456
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", mtime: fractional))
        let row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.mtime == fractional)
        #expect(try store.needsReindex(path: "/a/b.jpg", size: 100, mtime: fractional) == false)
        #expect(try store.needsReindex(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000.123457) == true)
    }

    @Test func upsertMirrorsTheFilenameIntoTheSearchIndex() throws {
        let store = try IndexStore.inMemory()
        let id = try store.upsert(sampleRecord(path: "/a/holiday-invoice.jpg"))
        #expect(try store.ftsRowCount() == 1)
        #expect(try store.ftsMatchRowIDs("holiday") == [id])   // tokens searchable, right rowid
        _ = try store.upsert(sampleRecord(path: "/a/holiday-invoice.jpg"))
        #expect(try store.ftsRowCount() == 1)   // updated, not duplicated
        #expect(try store.ftsMatchRowIDs("invoice") == [id])
    }

    @Test func upsertPreservesOCRTextInTheSearchIndex() throws {
        let store = try IndexStore.inMemory()
        let id = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        // Phase 3 writes OCR text into the fts row; a rescan of the unchanged
        // file must not destroy it.
        try store.testExecute(sql: "UPDATE files_fts SET ocr_text = 'receipt total' WHERE rowid = ?",
                              arguments: [id])
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        let ocr: String? = try store.testFetchOne(
            sql: "SELECT ocr_text FROM files_fts WHERE rowid = ?", arguments: [id])
        #expect(ocr == "receipt total")
        #expect(try store.ftsMatchRowIDs("receipt") == [id])
    }

    @Test func setHashesStoresAllThreeAndTheKind() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        let seeded = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(try store.setHashes(for: seeded, content: "aa", image: "bb",
                                    imageKind: "jpeg-scan-v1",
                                    phash: "0123456789abcdef", hashedAt: 1_700_000_500))
        let row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.contentHash == "aa")
        #expect(row.imageHash == "bb")
        #expect(row.imageHashKind == "jpeg-scan-v1")
        #expect(row.phash == "0123456789abcdef")
        #expect(row.hashedAt == 1_700_000_500)
    }

    @Test func filesMissingHashesReturnsOnlyUnhashedRowsUnderThePrefix() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg"))
        _ = try store.upsert(sampleRecord(path: "/other/c.jpg"))
        let a = try #require(try store.record(atPath: "/lib/a.jpg"))
        #expect(try store.setHashes(for: a, content: "aa", image: nil, imageKind: nil,
                                    phash: nil, hashedAt: 1))
        let pending = try store.filesMissingHashes(under: "/lib", limit: 10)
        #expect(pending.map(\.name) == ["b.jpg"])
    }

    @Test func upsertClearsHashesOnlyWhenTheFileActuallyChanged() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        let seeded = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(try store.setHashes(for: seeded, content: "cc", image: "ii",
                                    imageKind: "jpeg-scan-v1",
                                    phash: "0123456789abcdef", hashedAt: 500))

        // Re-indexing an unchanged file must not throw away work the tier 1 pass
        // already paid for.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        var row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.contentHash == "cc")
        #expect(row.imageHash == "ii")
        #expect(row.imageHashKind == "jpeg-scan-v1")
        #expect(row.phash == "0123456789abcdef")
        #expect(row.hashedAt == 500)

        // A changed file's hashes are lies; clearing hashed_at re-enqueues it.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 101, mtime: 1_700_000_000))
        row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.contentHash == nil)
        #expect(row.imageHash == nil)
        #expect(row.imageHashKind == nil)
        #expect(row.phash == nil)
        #expect(row.hashedAt == nil)
    }

    @Test func upsertClearsHashesWhenOnlyMtimeChanged() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        let seeded = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(try store.setHashes(for: seeded, content: "cc", image: "ii",
                                    imageKind: "jpeg-scan-v1",
                                    phash: "0123456789abcdef", hashedAt: 500))
        // Same size, touched mtime: an edit that preserves length still
        // invalidates every hash.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000.5))
        let row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.contentHash == nil)
        #expect(row.imageHash == nil)
        #expect(row.imageHashKind == nil)
        #expect(row.phash == nil)
        #expect(row.hashedAt == nil)
    }

    @Test func deleteRowsRemovesVanishedFilesAndTheirSearchRows() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg"))
        _ = try store.upsert(sampleRecord(path: "/other/c.jpg"))
        let removed = try store.deleteRows(under: "/lib", keeping: ["/lib/a.jpg"])
        #expect(removed == 1)
        #expect(try store.count() == 2)          // /lib/a.jpg and /other/c.jpg
        #expect(try store.ftsRowCount() == 2)
    }

    /// The non-recursive scan's reconcile. It knows nothing about
    /// subdirectories, so it must confine itself to its immediate children.
    @Test func deleteRowsInFolderTouchesOnlyItsImmediateChildren() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg"))
        _ = try store.upsert(sampleRecord(path: "/lib/sub/c.jpg"))
        _ = try store.upsert(sampleRecord(path: "/other/d.jpg"))

        let removed = try store.deleteRows(inFolder: "/lib", keeping: ["/lib/a.jpg"])
        #expect(removed == 1)                    // only /lib/b.jpg
        #expect(try store.record(atPath: "/lib/b.jpg") == nil)
        #expect(try store.record(atPath: "/lib/a.jpg") != nil)
        #expect(try store.record(atPath: "/lib/sub/c.jpg") != nil)
        #expect(try store.record(atPath: "/other/d.jpg") != nil)
        #expect(try store.count() == 3)
        #expect(try store.ftsRowCount() == 3)    // the trigger cleaned up with it
    }

    /// A row recorded on another volume is not this walk's to judge, whichever
    /// scope the reconcile uses.
    @Test func deleteRowsRestrictedToADeviceLeavesOtherVolumesAlone() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", device: 1))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg", device: 2))
        _ = try store.upsert(sampleRecord(path: "/lib/sub/c.jpg", device: 2))

        #expect(try store.deleteRows(under: "/lib", keeping: [], onDevice: 2) == 2)
        #expect(try store.record(atPath: "/lib/a.jpg") != nil)
        #expect(try store.count() == 1)
        #expect(try store.ftsRowCount() == 1)

        _ = try store.upsert(sampleRecord(path: "/lib/d.jpg", device: 2))
        #expect(try store.deleteRows(inFolder: "/lib", keeping: [], onDevice: 2) == 1)
        #expect(try store.record(atPath: "/lib/a.jpg") != nil)     // device 1, still untouched
        #expect(try store.count() == 1)
    }

    /// Omitting the device keeps the old meaning: every row in scope.
    @Test func deleteRowsWithoutADeviceStillCoversEveryVolume() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", device: 1))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg", device: 2))
        #expect(try store.deleteRows(under: "/lib", keeping: []) == 2)
        #expect(try store.count() == 0)
    }

    @Test func deleteRowsInFolderNormalizesATrailingSlash() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        // parent_dir is stored without a trailing slash; a root URL that has
        // one must not silently match nothing and delete nothing.
        #expect(try store.deleteRows(inFolder: "/lib/", keeping: []) == 1)
        #expect(try store.count() == 0)
    }

    @Test func deleteRowsInFolderRejectsARelativeFolder() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        #expect(throws: IndexStoreError.invalidScope("")) {
            try store.deleteRows(inFolder: "", keeping: [])
        }
        #expect(throws: IndexStoreError.invalidScope("~/Pictures")) {
            try store.deleteRows(inFolder: "~/Pictures", keeping: [])
        }
        #expect(try store.count() == 1)
    }

    /// What the reconcile uses to protect a subtree the walk could not enter.
    @Test func pathsUnderReturnsTheWholeScopeAndNothingOutsideIt() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        _ = try store.upsert(sampleRecord(path: "/lib/sub/c.jpg"))
        _ = try store.upsert(sampleRecord(path: "/LIB/b.jpg"))
        _ = try store.upsert(sampleRecord(path: "/library/d.jpg"))

        #expect(try store.paths(under: "/lib").sorted() == ["/lib/a.jpg", "/lib/sub/c.jpg"])
        #expect(try store.paths(under: "/lib/a.jpg") == ["/lib/a.jpg"])   // a file scopes to itself
        #expect(throws: IndexStoreError.invalidScope("Pictures")) {
            _ = try store.paths(under: "Pictures")
        }
    }

    /// SQLite's LIKE folds ASCII case, so a LIKE-based scope would make
    /// `deleteRows(under: "/lib")` destroy `/LIB` on a case-sensitive volume.
    /// The byte-range scope must not leak across case-variant siblings.
    @Test func scopeDoesNotLeakAcrossCaseVariantSiblings() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        _ = try store.upsert(sampleRecord(path: "/LIB/b.jpg"))
        _ = try store.upsert(sampleRecord(path: "/Lib/c.jpg"))
        #expect(try store.filesMissingHashes(under: "/lib", limit: 10).map(\.name) == ["a.jpg"])
        let removed = try store.deleteRows(under: "/lib", keeping: [])
        #expect(removed == 1)
        #expect(try store.count() == 2)          // /LIB/b.jpg and /Lib/c.jpg survive
        #expect(try store.record(atPath: "/LIB/b.jpg") != nil)
        #expect(try store.record(atPath: "/Lib/c.jpg") != nil)
    }

    @Test func invalidScopePrefixThrowsAndDeletesNothing() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        // An unexpanded or relative persisted root must surface as an error,
        // not wipe the index (empty prefix scoped every absolute path).
        #expect(throws: IndexStoreError.invalidScope("")) {
            try store.deleteRows(under: "", keeping: [])
        }
        #expect(throws: IndexStoreError.invalidScope("~/Pictures")) {
            try store.deleteRows(under: "~/Pictures", keeping: [])
        }
        #expect(throws: IndexStoreError.invalidScope("Pictures")) {
            _ = try store.filesMissingHashes(under: "Pictures", limit: 10)
        }
        #expect(try store.count() == 1)
        #expect(try store.ftsRowCount() == 1)
    }

    @Test func scopeQueriesSearchThePathIndexRatherThanScanning() throws {
        let store = try IndexStore.inMemory()
        let scope = try IndexStore.pathScope("/lib")
        let args: [any DatabaseValueConvertible] = [scope.exact, scope.lower, scope.upper]
        // Plan the exact SQL production runs — the constants are the single
        // copy shared with deleteRows, paths(under:) and filesMissingHashes,
        // so this test
        // cannot drift from the shipped queries. A LIKE predicate plans the
        // stale-paths query as a SCAN; the byte-range plans as a MULTI-INDEX
        // OR whose children each SEARCH the unique path index.
        let stalePlan = try store.queryPlan(sql: IndexStore.pathsInScopeSQL,
                                            arguments: StatementArguments(args))
        #expect(stalePlan.contains { $0.contains("SEARCH") })
        #expect(!stalePlan.contains { $0.contains("SCAN") })
        // The missing-hashes query is planned off files_on_hashed_at under
        // either predicate, so SEARCH-vs-SCAN cannot certify its scope; its
        // case-correctness is pinned behaviorally by the case-variant test.
        // Assert it stays off a full-table SCAN, which is all the plan says.
        let missingPlan = try store.queryPlan(sql: IndexStore.missingHashesSQL,
                                              arguments: StatementArguments(args + [10]))
        #expect(!missingPlan.contains { $0.contains("SCAN") })
    }

    @Test func deletingAFileRowDropsSearchAndAnalysisRowsViaTrigger() throws {
        let store = try IndexStore.inMemory()
        let id = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        try store.testExecute(sql: "INSERT INTO analysis (file_id, ocr_text) VALUES (?, 'x')",
                              arguments: [id])
        // foreign_keys is per-connection; triggers are schema-level. Turning
        // the pragma off isolates files_ad from the ON DELETE CASCADE, so the
        // analysis assertion below fails if the trigger's DELETE FROM analysis
        // line is removed — the cascade cannot mask it.
        try store.testExecute(sql: "PRAGMA foreign_keys = OFF")
        // Raw DELETE bypasses deleteRows entirely: only the trigger can clean
        // up here.
        try store.testExecute(sql: "DELETE FROM files WHERE id = ?", arguments: [id])
        try store.testExecute(sql: "PRAGMA foreign_keys = ON")
        #expect(try store.ftsRowCount() == 0)
        let analysisCount: Int? = try store.testFetchOne(sql: "SELECT count(*) FROM analysis")
        #expect(analysisCount == 0)
    }

    @Test func changingAFileDropsItsStaleAnalysisRowViaTrigger() throws {
        let store = try IndexStore.inMemory()
        let id = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        try store.testExecute(sql: "INSERT INTO analysis (file_id, ocr_text) VALUES (?, 'old text')",
                              arguments: [id])
        // A rescan that finds the file unchanged keeps the analysis row.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        var analysisCount: Int? = try store.testFetchOne(
            sql: "SELECT count(*) FROM analysis WHERE file_id = ?", arguments: [id])
        #expect(analysisCount == 1)
        // A changed mtime invalidates the OCR/embedding row along with the hashes.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_001))
        analysisCount = try store.testFetchOne(
            sql: "SELECT count(*) FROM analysis WHERE file_id = ?", arguments: [id])
        #expect(analysisCount == 0)
    }

    @Test func migrationIsIdempotentAcrossReopens() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        _ = try IndexStore(url: url).upsert(sampleRecord(path: "/a/b.jpg"))
        let reopened = try IndexStore(url: url)
        #expect(try reopened.count() == 1)
    }

    // MARK: - Two windows, one file

    /// File → New Window is free with `WindowGroup`, and each window builds its
    /// own `IndexStore` on the same `index.sqlite`. GRDB's default busy mode
    /// hands `SQLITE_BUSY` to the second connection the instant the first holds
    /// the write lock; the configured busy timeout makes it wait instead.
    ///
    /// The lock is *held* rather than raced for, so this fails on every run
    /// without the timeout rather than on the unlucky ones.
    @Test func aWriteWaitsForAnotherConnectionsLockRatherThanFailingBusy() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        // Created up front so the holder only has to INSERT: a CREATE TABLE
        // inside the held transaction would change the schema under the
        // connection being tested and muddy what the wait is being blamed on.
        try store.testExecute(sql: "CREATE TABLE busy_probe (x)")

        let locked = DispatchSemaphore(value: 0)
        let holdTime = 0.3
        let path = url.path
        // A plain thread, not a `Task`: the holder blocks for the whole hold,
        // and blocking a cooperative-pool thread in order to test a blocking
        // API is how a test deadlocks its own executor.
        Thread.detachNewThread {
            guard let holder = try? DatabaseQueue(path: path) else { return }
            try? holder.write { db in
                // The write statement is what takes the RESERVED lock. Opening
                // a deferred transaction and sleeping would block nobody.
                try db.execute(sql: "INSERT INTO busy_probe (x) VALUES (1)")
                locked.signal()
                Thread.sleep(forTimeInterval: holdTime)
            }
        }
        if case .timedOut = locked.wait(timeout: .now() + 10) {
            Issue.record("the holding connection never took the write lock")
            return
        }

        let started = Date()
        // The assertion is that this does not throw. Without the busy timeout
        // it throws SQLITE_BUSY before the holder has let go.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        let waited = Date().timeIntervalSince(started)
        #expect(try store.count() == 1)
        // And it genuinely had to wait, so a pass here cannot mean the lock had
        // already been released before the write was attempted.
        #expect(waited > holdTime / 2, "the write did not wait for the lock (\(waited)s)")
    }

    /// The same thing from the app's angle: two live stores on one file, both
    /// reading and writing, neither throwing.
    @Test func twoStoresOnOneFileBothWorkWithoutThrowing() async throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let one = try IndexStore(url: url)
        let two = try IndexStore(url: url)
        let query = SearchQuery(scope: .everywhere, predicate: .all)

        // Detached and concurrent, because a serialised pair would contend for
        // nothing: `DatabaseQueue` only serialises its *own* connection.
        async let firstWindow: Void = Task.detached {
            for i in 0..<100 {
                _ = try one.upsert(sampleRecord(path: "/one/\(i).jpg"))
                _ = try one.search(query)
            }
        }.value
        async let secondWindow: Void = Task.detached {
            for i in 0..<100 {
                _ = try two.upsert(sampleRecord(path: "/two/\(i).jpg"))
                _ = try two.facets(for: query)
            }
        }.value

        // A throw from either window fails the test here rather than being
        // swallowed; the counts are asserted afterwards, once both are done,
        // because a count taken mid-flight would race the other window.
        try await firstWindow
        try await secondWindow
        #expect(try one.count() == 200)
        #expect(try two.count() == 200)
    }
}
