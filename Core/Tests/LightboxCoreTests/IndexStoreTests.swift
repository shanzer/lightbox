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
        let id = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        try store.setHashes(fileID: id, content: "aa", image: "bb", imageKind: "jpeg-scan-v1",
                            phash: "0123456789abcdef", hashedAt: 1_700_000_500)
        let row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.contentHash == "aa")
        #expect(row.imageHash == "bb")
        #expect(row.imageHashKind == "jpeg-scan-v1")
        #expect(row.phash == "0123456789abcdef")
        #expect(row.hashedAt == 1_700_000_500)
    }

    @Test func filesMissingHashesReturnsOnlyUnhashedRowsUnderThePrefix() throws {
        let store = try IndexStore.inMemory()
        let a = try store.upsert(sampleRecord(path: "/lib/a.jpg"))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg"))
        _ = try store.upsert(sampleRecord(path: "/other/c.jpg"))
        try store.setHashes(fileID: a, content: "aa", image: nil, imageKind: nil,
                            phash: nil, hashedAt: 1)
        let pending = try store.filesMissingHashes(under: "/lib", limit: 10)
        #expect(pending.map(\.name) == ["b.jpg"])
    }

    @Test func upsertClearsHashesOnlyWhenTheFileActuallyChanged() throws {
        let store = try IndexStore.inMemory()
        let id = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        try store.setHashes(fileID: id, content: "cc", image: "ii", imageKind: "jpeg-scan-v1",
                            phash: "0123456789abcdef", hashedAt: 500)

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
        let id = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        try store.setHashes(fileID: id, content: "cc", image: "ii", imageKind: "jpeg-scan-v1",
                            phash: "0123456789abcdef", hashedAt: 500)
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

    @Test func scopeQueriesSearchThePathIndexRatherThanScanning() throws {
        let store = try IndexStore.inMemory()
        let scope = IndexStore.pathScope("/lib")
        let plan = try store.queryPlan(sql: """
            SELECT path FROM files WHERE path = '\(scope.exact)'
                OR (path > '\(scope.lower)' AND path < '\(scope.upper)')
            """)
        // The OR shows up as a MULTI-INDEX OR node whose children each
        // SEARCH the unique path index; a LIKE predicate plans as a SCAN.
        #expect(plan.contains { $0.contains("SEARCH") })
        #expect(!plan.contains { $0.contains("SCAN") })
    }

    @Test func deletingAFileRowRemovesItsSearchRowViaTrigger() throws {
        let store = try IndexStore.inMemory()
        let id = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        // Raw DELETE bypasses deleteRows entirely: only the files_ad trigger
        // can clean up here.
        try store.testExecute(sql: "DELETE FROM files WHERE id = ?", arguments: [id])
        #expect(try store.ftsRowCount() == 0)
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
}
