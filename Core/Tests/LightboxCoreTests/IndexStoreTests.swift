import Testing
import Foundation
import GRDB
@testable import LightboxCore

private func sampleRecord(path: String, size: Int64 = 100, mtime: Double = 1_700_000_000,
                          device: Int64 = 1, volumeUUID: String? = nil) -> FileRecord {
    FileRecord(
        id: nil, path: path,
        parentDir: (path as NSString).deletingLastPathComponent,
        name: (path as NSString).lastPathComponent,
        ext: (path as NSString).pathExtension.lowercased(),
        size: size, mtime: mtime, device: device, inode: 42, volumeUUID: volumeUUID,
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

    /// v2 is the first migration to run against a populated `index.sqlite`, so
    /// it is tested against one: a real v1 database with rows in it, opened
    /// through the initializer the app uses. Nothing may be lost, and the new
    /// column arrives empty because no row can name a UUID for a volume that
    /// may not even be mounted.
    @Test func migratingAPopulatedV1IndexKeepsEveryRowAndLeavesTheVolumeUnknown() throws {
        let url = tree.root.appendingPathComponent("v1/index.sqlite")
        try makeV1Index(at: url) { db in
            for i in 0..<5 { try insertV1Row(db, path: "/lib/img\(i).jpg", device: 7) }
            try insertV1Row(db, path: "/lib/hashed.jpg", device: 7,
                            contentHash: "abc123", hashedAt: 1_700_000_100)
        }

        let store = try IndexStore(url: url)
        #expect(try store.count() == 6)
        #expect(try store.ftsRowCount() == 6)
        for i in 0..<5 {
            let row = try #require(try store.record(atPath: "/lib/img\(i).jpg"))
            #expect(row.volumeUUID == nil)
            #expect(row.device == 7)
        }
        // The row with hashes is the one a botched migration would show first:
        // its columns are the expensive ones to recompute.
        let hashed = try #require(try store.record(atPath: "/lib/hashed.jpg"))
        #expect(hashed.contentHash == "abc123")
        #expect(hashed.hashedAt == 1_700_000_100)
        #expect(hashed.volumeUUID == nil)

        let hasColumn: Int = try #require(try store.testFetchOne(
            sql: "SELECT count(*) FROM pragma_table_info('files') WHERE name = 'volume_uuid'"))
        #expect(hasColumn == 1)
        // Closed explicitly: the tree is unlinked when this suite instance is
        // released, and unlinking a file SQLite still has open is a client API
        // violation even where it happens to work.
        try store.close()
    }

    /// Until a pass stamps them, v1 rows have to keep reconciling exactly as
    /// they did before the column existed — that is the whole point of the
    /// NULL half of the matching rule.
    @Test func aMigratedV1RowIsStillPrunableByItsDeviceAlone() throws {
        let url = tree.root.appendingPathComponent("v1/index.sqlite")
        try makeV1Index(at: url) { db in
            try insertV1Row(db, path: "/lib/a.jpg", device: 7)
            try insertV1Row(db, path: "/lib/b.jpg", device: 8)
        }

        let store = try IndexStore(url: url)
        #expect(try store.deleteRows(under: "/lib", keeping: [],
                                     onDevice: 7, onVolume: "VOL-A") == 1)
        #expect(try store.record(atPath: "/lib/a.jpg") == nil)
        #expect(try store.record(atPath: "/lib/b.jpg") != nil)
        try store.close()
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

    @Test func recordMetadataWriteStoresTheNewStatAndKeepsThePhash() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        let seeded = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(try store.setHashes(for: seeded, content: "cc", image: "ii",
                                    imageKind: "jpeg-scan-v1",
                                    phash: "0123456789abcdef", hashedAt: 500))
        let hashed = try #require(try store.record(atPath: "/a/b.jpg"))

        #expect(try store.recordMetadataWrite(for: hashed, size: 140, mtime: 1_700_000_900,
                                              content: "dd", image: "ii",
                                              imageKind: "jpeg-scan-v1", hashedAt: 900))

        let row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.size == 140)
        #expect(row.mtime == 1_700_000_900)
        #expect(row.contentHash == "dd")
        #expect(row.imageHash == "ii")
        #expect(row.hashedAt == 900)
        // No pixel moved, so the perceptual hash is still the right one and
        // must not be thrown away.
        #expect(row.phash == "0123456789abcdef")
        // And tier 0 now agrees the row describes the file, so it is not re-read.
        #expect(try store.needsReindex(path: "/a/b.jpg", size: 140,
                                       mtime: 1_700_000_900) == false)
    }

    /// The same guard as `setHashes(for:)`, and for the same reason: `files.id`
    /// is a reused rowid, and a tier 0 pass can re-index the file while exiftool
    /// is still running. A write against a row that no longer describes what was
    /// edited would stamp one photo's hashes onto another photo's row.
    @Test func recordMetadataWriteRefusesARowThatNoLongerMatches() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        let stale = try #require(try store.record(atPath: "/a/b.jpg"))

        // Tier 0 re-indexes the file mid-write: the row's size and mtime move.
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 222, mtime: 1_700_000_050))

        #expect(try store.recordMetadataWrite(for: stale, size: 140, mtime: 1_700_000_900,
                                              content: "dd", image: "ii",
                                              imageKind: "jpeg-scan-v1",
                                              hashedAt: 900) == false)
        let row = try #require(try store.record(atPath: "/a/b.jpg"))
        #expect(row.size == 222)
        #expect(row.contentHash == nil)
        #expect(row.hashedAt == nil)
    }

    /// A row id belonging to a different path is not this file's row, even
    /// though SQLite happily hands the id back after a delete.
    @Test func recordMetadataWriteRefusesAReusedRowID() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg", size: 100, mtime: 1_700_000_000))
        var stale = try #require(try store.record(atPath: "/a/b.jpg"))
        _ = try store.upsert(sampleRecord(path: "/a/other.jpg", size: 100, mtime: 1_700_000_000))
        let other = try #require(try store.record(atPath: "/a/other.jpg"))

        // Same size and mtime, same id — but a different path.
        stale.id = other.id
        #expect(try store.recordMetadataWrite(for: stale, size: 140, mtime: 1_700_000_900,
                                              content: "dd", image: nil, imageKind: nil,
                                              hashedAt: 900) == false)
        #expect(try #require(try store.record(atPath: "/a/other.jpg")).contentHash == nil)
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

    /// The half of the matching rule that `device` alone cannot express: a
    /// replug renumbers `st_dev`, so two rows can share a device id and still
    /// be from different filesystems. The UUID decides.
    @Test func deleteRowsRestrictedToAVolumeIgnoresTheDeviceWhenAUUIDIsPresent() throws {
        let store = try IndexStore.inMemory()
        // Same device id on every row, so only the UUID can tell them apart.
        _ = try store.upsert(sampleRecord(path: "/lib/mine.jpg", device: 3, volumeUUID: "VOL-A"))
        _ = try store.upsert(sampleRecord(path: "/lib/theirs.jpg", device: 3, volumeUUID: "VOL-B"))
        _ = try store.upsert(sampleRecord(path: "/lib/sub/mine2.jpg", device: 3, volumeUUID: "VOL-A"))

        #expect(try store.deleteRows(under: "/lib", keeping: [],
                                     onDevice: 3, onVolume: "VOL-A") == 2)
        #expect(try store.record(atPath: "/lib/theirs.jpg") != nil)
        #expect(try store.count() == 1)
        #expect(try store.ftsRowCount() == 1)
    }

    /// The converse, and the reason a row from a replugged drive is reachable
    /// at all: a matching UUID prunes even though the stored `device` is a
    /// mount id that no longer exists.
    @Test func deleteRowsMatchesAVolumeWhoseDeviceIDHasChanged() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", device: 111, volumeUUID: "VOL-A"))
        #expect(try store.deleteRows(under: "/lib", keeping: [],
                                     onDevice: 222, onVolume: "VOL-A") == 1)
        #expect(try store.count() == 0)
    }

    /// The pre-migration case, spelled out: a row with no UUID falls back to
    /// `device`, and one with a UUID is never matched by `device` alone.
    @Test func deleteRowsFallsBackToTheDeviceOnlyForRowsWithNoVolume() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/pre.jpg", device: 3, volumeUUID: nil))
        _ = try store.upsert(sampleRecord(path: "/lib/other.jpg", device: 9, volumeUUID: nil))
        _ = try store.upsert(sampleRecord(path: "/lib/stamped.jpg", device: 3, volumeUUID: "VOL-B"))

        #expect(try store.deleteRows(under: "/lib", keeping: [],
                                     onDevice: 3, onVolume: "VOL-A") == 1)
        #expect(try store.record(atPath: "/lib/pre.jpg") == nil)
        #expect(try store.record(atPath: "/lib/other.jpg") != nil)   // wrong device
        #expect(try store.record(atPath: "/lib/stamped.jpg") != nil) // wrong volume
    }

    /// A root on a filesystem that publishes no UUID (SMB, some FAT). The rule
    /// has to collapse cleanly to what it was before schema v2 rather than
    /// matching nothing.
    @Test func aRootWithNoUUIDStillPrunesByDeviceAlone() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", device: 3, volumeUUID: nil))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg", device: 9, volumeUUID: nil))
        _ = try store.upsert(sampleRecord(path: "/lib/c.jpg", device: 3, volumeUUID: "VOL-A"))

        #expect(try store.deleteRows(under: "/lib", keeping: [],
                                     onDevice: 3, onVolume: nil) == 1)
        #expect(try store.record(atPath: "/lib/a.jpg") == nil)
        #expect(try store.record(atPath: "/lib/b.jpg") != nil)
        // Not this one: it is stamped as belonging to a volume that does
        // publish a UUID, so a nameless volume is not it.
        #expect(try store.record(atPath: "/lib/c.jpg") != nil)
    }

    /// Omitting the device keeps the old meaning: every row in scope.
    @Test func deleteRowsWithoutADeviceStillCoversEveryVolume() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", device: 1))
        _ = try store.upsert(sampleRecord(path: "/lib/b.jpg", device: 2))
        #expect(try store.deleteRows(under: "/lib", keeping: []) == 2)
        #expect(try store.count() == 0)
    }

    /// The backfill. A v1 row keeps NULL until a pass walks its file, and only
    /// the paths the walk actually saw may be stamped.
    @Test func setVolumeStampsOnlyThePathsItIsGiven() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/walked.jpg", device: 111, volumeUUID: nil))
        _ = try store.upsert(sampleRecord(path: "/lib/unwalked.jpg", device: 111, volumeUUID: nil))

        let volume = VolumeIdentity(device: 3, uuid: "VOL-A")
        #expect(try store.setVolume(volume, forPaths: ["/lib/walked.jpg"]) == 1)

        let walked = try #require(try store.record(atPath: "/lib/walked.jpg"))
        #expect(walked.volumeUUID == "VOL-A")
        #expect(walked.device == 3)          // the mount id is refreshed with it
        let unwalked = try #require(try store.record(atPath: "/lib/unwalked.jpg"))
        #expect(unwalked.volumeUUID == nil)
        #expect(unwalked.device == 111)

        // Idempotent: a steady-state pass must not dirty a page.
        #expect(try store.setVolume(volume, forPaths: ["/lib/walked.jpg"]) == 0)
    }

    /// The stamp must not disturb anything else on the row — in particular the
    /// hashes, which cost a full read to recompute. `files_au_invalidate` fires
    /// on `size` and `mtime`, and this write touches neither.
    @Test func setVolumeLeavesTheRestOfTheRowAlone() throws {
        let store = try IndexStore.inMemory()
        var record = sampleRecord(path: "/lib/a.jpg")
        record.contentHash = "abc"
        record.hashedAt = 1_700_000_100
        _ = try store.upsert(record)

        _ = try store.setVolume(VolumeIdentity(device: 3, uuid: "VOL-A"),
                                forPaths: ["/lib/a.jpg"])
        let row = try #require(try store.record(atPath: "/lib/a.jpg"))
        #expect(row.contentHash == "abc")
        #expect(row.hashedAt == 1_700_000_100)
        #expect(row.size == 100)
        #expect(row.mtime == 1_700_000_000)
    }

    /// A nil UUID refreshes the device and leaves a known identity alone.
    ///
    /// "This filesystem published no UUID" is not the claim "this file is not on
    /// the volume its row names", and one pass whose resource-value read came
    /// back nil must not wipe the column on every row it walked — by the
    /// matching rule a NULL row is *less* protected than a stamped one, so the
    /// wipe would reinstate the replug bug it was added to fix.
    @Test func setVolumeWithNoUUIDPreservesAKnownOneAndStillRefreshesTheDevice() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/known.jpg", device: 111, volumeUUID: "VOL-A"))
        _ = try store.upsert(sampleRecord(path: "/lib/blank.jpg", device: 111, volumeUUID: nil))

        #expect(try store.setVolume(VolumeIdentity(device: 3, uuid: nil),
                                    forPaths: ["/lib/known.jpg", "/lib/blank.jpg"]) == 2)

        let known = try #require(try store.record(atPath: "/lib/known.jpg"))
        #expect(known.volumeUUID == "VOL-A")     // preserved, not erased
        #expect(known.device == 3)               // st_dev is always readable, so always refreshed
        let blank = try #require(try store.record(atPath: "/lib/blank.jpg"))
        #expect(blank.volumeUUID == nil)         // nothing to preserve, nothing invented
        #expect(blank.device == 3)

        // And still idempotent: with the device now current, a repeat changes
        // nothing rather than rewriting the same values.
        #expect(try store.setVolume(VolumeIdentity(device: 3, uuid: nil),
                                    forPaths: ["/lib/known.jpg", "/lib/blank.jpg"]) == 0)
    }

    /// The same guarantee on the other writer. `upsert` refreshes the whole
    /// identity of a re-indexed file, and a nil UUID there is the same
    /// unreliable read it is in `setVolume`.
    @Test func upsertWithNoUUIDPreservesAKnownOneAndStillRefreshesTheDevice() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", size: 100,
                                          device: 111, volumeUUID: "VOL-A"))
        // The file's bytes changed, so tier 0 re-upserts it — this time from a
        // pass whose volume reported no UUID.
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", size: 999,
                                          device: 3, volumeUUID: nil))

        let row = try #require(try store.record(atPath: "/lib/a.jpg"))
        #expect(row.volumeUUID == "VOL-A")
        #expect(row.device == 3)
        #expect(row.size == 999)                 // the rest of the row did update
    }

    /// The converse, so preservation is not mistaken for "the column is
    /// write-once": a real UUID replaces whatever was there.
    @Test func aRealUUIDStillOverwritesTheStoredOne() throws {
        let store = try IndexStore.inMemory()
        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", device: 111, volumeUUID: "VOL-A"))
        #expect(try store.setVolume(VolumeIdentity(device: 3, uuid: "VOL-B"),
                                    forPaths: ["/lib/a.jpg"]) == 1)
        #expect(try store.record(atPath: "/lib/a.jpg")?.volumeUUID == "VOL-B")

        _ = try store.upsert(sampleRecord(path: "/lib/a.jpg", device: 3, volumeUUID: "VOL-C"))
        #expect(try store.record(atPath: "/lib/a.jpg")?.volumeUUID == "VOL-C")
    }

    /// More paths than fit in one statement's bound variables. The chunking is
    /// an implementation detail the caller must not have to know about.
    @Test func setVolumeStampsMorePathsThanOneStatementCanBind() throws {
        let store = try IndexStore.inMemory()
        let paths = (0..<1200).map { "/lib/img\($0).jpg" }
        for path in paths { _ = try store.upsert(sampleRecord(path: path, device: 111)) }

        #expect(try store.setVolume(VolumeIdentity(device: 3, uuid: "VOL-A"),
                                    forPaths: paths) == 1200)
        for path in [paths.first!, paths[700], paths.last!] {
            #expect(try store.record(atPath: path)?.volumeUUID == "VOL-A")
        }
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

    // MARK: - Write-ahead logging

    /// The journal mode is the whole mechanism behind "readers never block on
    /// the writer", and it is a property of the *file*, not of the process, so
    /// a store that quietly opened in `delete` mode would still pass every
    /// behavioural test on an uncontended run and only show up as a stall in
    /// front of a user. Assert it directly.
    @Test func aFileBackedStoreOpensInWALMode() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        let mode: String? = try store.testFetchOne(sql: "PRAGMA journal_mode")
        #expect(mode == "wal")
    }

    /// `inMemory()` shares `makeConfiguration()` with the file-backed store so
    /// the 305 tests exercise the database production runs. That equivalence is
    /// worth asserting rather than assuming, now that the in-memory store is
    /// backed by a temporary file for the pool's sake.
    @Test func theInMemoryStoreOpensInWALModeToo() throws {
        let store = try IndexStore.inMemory()
        let mode: String? = try store.testFetchOne(sql: "PRAGMA journal_mode")
        #expect(mode == "wal")
    }

    /// The point of the pool: a read does not queue behind a write on the same
    /// store. One `IndexStore` per window means a window's own search would
    /// otherwise wait for its own tier 1 hash batch — a `DatabaseQueue`
    /// serialises every access through one connection, whoever asked.
    ///
    /// The write is *held* open across the timed read rather than raced
    /// against a clock. An earlier version started a ~1 s recursive-CTE write,
    /// slept 200 ms and asserted the probe had not finished yet; on a loaded
    /// three-core CI runner (run 34140355843) the sleep resumed late, the probe
    /// had already committed, and the timed read proved nothing. Here the
    /// writer inserts, publishes `holding`, and then waits for `release` —
    /// which the reader sets only after its `count()` has returned. "The write
    /// was in flight during the read" is true by construction, so the only
    /// load-bearing assertion left is the latency one.
    ///
    /// The hold has its own deadline: exceeding it sets `heldTooLong` and
    /// returns, so a broken handshake is a red test rather than a hung suite.
    @Test func aReadDoesNotWaitForAWriteInFlightOnTheSameStore() async throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        try store.testExecute(sql: "CREATE TABLE slow_probe (x INTEGER)")

        let holding = LockBox(false)
        let release = LockBox(false)
        let finished = LockBox(false)
        let heldTooLong = LockBox(false)

        // One read thrown away first. A pool opens its reader connections
        // lazily, so the first read of a store's life also pays for opening a
        // connection, reading the schema and preparing the statement — work
        // that has nothing to do with waiting on a writer and would land inside
        // the timed region below.
        _ = try store.count()

        // A plain thread, not a `Task`: the writer parks for the whole hold,
        // and blocking a cooperative-pool thread starves every other suite
        // running in parallel. Same reason
        // `aWriteWaitsForAnotherConnectionsLockRatherThanFailingBusy` uses one.
        Thread.detachNewThread {
            try? store.testWrite { db in
                // The INSERT is what takes the write lock; an empty transaction
                // would block nobody and prove nothing.
                try db.execute(sql: "INSERT INTO slow_probe (x) VALUES (1)")
                holding.withLock { $0 = true }
                let giveUp = Date().addingTimeInterval(30)
                while release.withLock({ !$0 }) {
                    guard Date() < giveUp else {
                        heldTooLong.withLock { $0 = true }
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            finished.withLock { $0 = true }
        }

        // If the transaction never opens, the writer may still be parked on
        // `release`; the join below has to run either way, or the suite unlinks
        // `tree` under a live connection. `waitUntil` has already recorded the
        // issue by then, so the failure is not lost.
        var opened = true
        do {
            try await Self.waitUntil(holding, orFail: "the writer never opened its transaction",
                                     timeout: .seconds(30))
        } catch {
            opened = false
        }

        var readTook = 0.0
        if opened {
            let started = Date()
            _ = try store.count()
            readTook = Date().timeIntervalSince(started)
        }
        release.withLock { $0 = true }

        // Joined rather than abandoned: the writer holds the store, and the
        // store holds a file in `tree`, which the suite removes the moment this
        // returns. Polled rather than waited on, so nothing blocks here either.
        try await Self.waitUntil(finished, orFail: "the probe write never finished")

        guard opened else { return }
        #expect(heldTooLong.withLock { !$0 }, "the writer gave up waiting to be released")
        #expect(readTook < 0.05, "the read waited \(readTook)s for the in-flight write")
    }

    /// A join that gave up.
    private struct WaitTimedOut: Error {}

    /// Polls `flag` until it is set, yielding rather than blocking. The tests
    /// below hand long synchronous work to plain threads; this is how they join
    /// one without a blocking wait.
    ///
    /// A timeout records the issue and then **throws**, ending the test. It
    /// must not return: the threads it failed to join are still writing to a
    /// store in `tree`, and the suite unlinks `tree` the moment the test body
    /// returns — pulling the file out from under live connections and turning
    /// one clear failure into a spray of unrelated ones.
    private static func waitUntil(_ flag: LockBox<Bool>, orFail message: String,
                                  timeout: Duration = .seconds(120)) async throws {
        let giveUp = ContinuousClock.now + timeout
        while flag.withLock({ !$0 }) {
            guard ContinuousClock.now < giveUp else {
                Issue.record(Comment(rawValue: message))
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The two-window soak. A second `IndexStore` on the same file reads
    /// continuously while the first writes batches for several seconds; not one
    /// read may fail.
    ///
    /// **This is a regression soak, not evidence for WAL.** It also passes on
    /// the old rollback-journal `DatabaseQueue`, where the 5 s busy timeout
    /// absorbs the contention, and it passes under the pool with
    /// `busyMode = .immediateError`, where a single writer means the busy
    /// handler is never reached. `aReadDoesNotWaitForAWriteInFlightOnTheSameStore`
    /// is what actually pins the pool — measured at 856 ms against 50 ms.
    ///
    /// What this one pins that nothing else does is the snapshot invariant a
    /// reader gets under a pool: counts may repeat, because a read sees a
    /// consistent moment rather than the newest row, but they must never go
    /// backwards, and none may exceed what was actually written.
    @Test func sustainedWritesInOneStoreNeverMakeAnotherStoresReadsFail() async throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let writerStore = try IndexStore(url: url)
        let readerStore = try IndexStore(url: url)
        let deadline = Date().addingTimeInterval(3)
        let query = SearchQuery(scope: .everywhere, predicate: .all)

        // Errors are collected rather than thrown, so a failure on either side
        // names every occurrence instead of the first, and neither thread is
        // left running against a store the test has already walked away from.
        let failures = LockBox<[String]>([])
        let counts = LockBox<[Int]>([])
        let written = LockBox(0)
        let writerDone = LockBox(false)
        let readerDone = LockBox(false)

        // Plain threads: three seconds of synchronous SQLite each. On the
        // cooperative pool that is two of its threads parked for the duration,
        // which the rest of the suite is running on.
        Thread.detachNewThread {
            while Date() < deadline {
                for _ in 0..<50 {
                    do {
                        let n = written.withLock { $0 }
                        _ = try writerStore.upsert(sampleRecord(path: "/w/\(n).jpg"))
                        written.withLock { $0 += 1 }
                    } catch {
                        failures.withLock { $0.append("write: \(error)") }
                    }
                }
            }
            writerDone.withLock { $0 = true }
        }
        Thread.detachNewThread {
            while Date() < deadline {
                do {
                    let n = try readerStore.count()
                    counts.withLock { $0.append(n) }
                    _ = try readerStore.search(query)
                    _ = try readerStore.facets(for: query)
                } catch {
                    failures.withLock { $0.append("read: \(error)") }
                }
            }
            readerDone.withLock { $0 = true }
        }

        try await Self.waitUntil(writerDone, orFail: "the writing thread never finished")
        try await Self.waitUntil(readerDone, orFail: "the reading thread never finished")
        let total = written.withLock { $0 }

        #expect(failures.withLock { $0 }.isEmpty,
                "a store failed while the other one wrote: \(failures.withLock { $0 })")
        let observed = counts.withLock { $0 }
        #expect(observed.count > 10, "the reader only managed \(observed.count) reads")
        #expect(total > 50, "the writer only managed \(total) upserts")
        // A snapshot is a snapshot: counts may repeat, but they must never go
        // backwards, and the last one must not exceed what was actually written.
        #expect(observed == observed.sorted(), "the reader saw counts go backwards")
        #expect((observed.last ?? 0) <= total)
        #expect(try readerStore.count() == total)
    }

    /// WAL puts two sidecars next to the database, and the in-memory store is
    /// now a real file. A test store that leaked all three into the temporary
    /// directory on every one of the 305 tests would be a slow, invisible mess.
    @Test func theInMemoryStoreRemovesItsBackingFilesWhenItIsReleased() throws {
        // A function rather than a `do` block: the store is released when the
        // call returns, which is a language guarantee, where the end of a
        // lexical scope is only usually one.
        func makeAndDiscard() throws -> URL {
            let store = try IndexStore.inMemory()
            _ = try store.upsert(sampleRecord(path: "/a/b.jpg"))
            #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
            return store.fileURL
        }
        let url = try makeAndDiscard()

        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: url.path + suffix),
                    "left \(url.lastPathComponent + suffix) behind")
        }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    /// "Delete the index and it rebuilds" is a documented guarantee, and users
    /// delete the file they can see — leaving `index.sqlite-wal` and
    /// `index.sqlite-shm` behind, which no Finder window ever showed them. A
    /// write-ahead log replayed into a brand-new database would be a silently
    /// wrong index, and the store has no code guarding against it: SQLite
    /// discards a log whose database is missing or zero-length rather than
    /// recovering from it.
    ///
    /// So this test pins a guarantee the app leans on and does not implement.
    /// If a future SQLite or GRDB ever recovers that log instead, deleting the
    /// index by hand starts producing an index nobody wrote, and this is the
    /// only thing that would say so. It runs both legs — same log, database
    /// present and absent — because "the rows did not come back" is worth
    /// nothing unless the same bytes are shown putting them back.
    @Test func aStaleWriteAheadLogBesideAMissingDatabaseIsDiscarded() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")

        // All three files as a crash would have left them: rows committed to
        // the log, nothing checkpointed into the database yet. Captured while
        // the connection is open and *before* `store.close()` runs below,
        // because that is the only moment the sidecars still hold this
        // genuinely uncheckpointed state — since #40, `close()` itself
        // checkpoints the WAL, so capturing after it would hand this test an
        // already-folded-back log instead of a crash-shaped one. (It would
        // not change the outcome either way: `restore()` below overwrites
        // whatever `close()` leaves regardless, so what `close()` does or
        // doesn't do to these three files plays no part in this test — only
        // the ordering of the capture does.)
        let store = try IndexStore(url: url)
        for i in 0..<5 { _ = try store.upsert(sampleRecord(path: "/a/\(i).jpg")) }
        let crash = (database: try Data(contentsOf: url),
                     wal: try Data(contentsOf: walURL),
                     shm: try Data(contentsOf: shmURL))
        try store.close()

        func restore(database: Bool) throws {
            try? FileManager.default.removeItem(at: url)
            if database { try crash.database.write(to: url) }
            try crash.wal.write(to: walURL)
            try crash.shm.write(to: shmURL)
        }

        // The control leg, and the whole reason this test is not vacuous:
        // replayed against the database it belongs to, this log does bring the
        // five rows back. So the log is valid, recoverable, and not empty, and
        // the discard below is SQLite refusing an *orphan* rather than failing
        // to read anything.
        try restore(database: true)
        let recovered = try IndexStore(url: url)
        #expect(try recovered.count() == 5)
        try recovered.close()

        // The mistake being modelled: the user deletes `index.sqlite` and
        // leaves the two sidecars their Finder window never showed them.
        try restore(database: false)
        let reopened = try IndexStore(url: url)
        #expect(try reopened.count() == 0)
    }

    // MARK: - close() checkpoints the WAL (#40)

    /// `close()`'s whole job. GRDB's `DatabasePool.close()` closes the writer
    /// before the readers, so SQLite's checkpoint-on-last-close never runs
    /// once a reader connection has ever existed, and a "closed" store could
    /// leave `-wal` holding everything nothing has read back from
    /// `index.sqlite` itself. This proves the opposite by construction, not
    /// by inspecting `-wal`'s size alone: after `close()`, both sidecars are
    /// deleted outright, so the readback below cannot be satisfied by SQLite
    /// quietly replaying whatever the log still held — only what `close()`
    /// actually folded into `index.sqlite` can answer it.
    @Test func closeCheckpointsSoAFreshStoreReadsEverythingWithNoWALLeft() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")

        let store = try IndexStore(url: url)
        for i in 0..<10 { _ = try store.upsert(sampleRecord(path: "/a/\(i).jpg")) }
        #expect(try store.count() == 10)

        #expect(try store.close() == .checkpointed)

        // The WAL is gone or empty on its own terms.
        if FileManager.default.fileExists(atPath: walURL.path) {
            let walSize = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int ?? -1
            #expect(walSize == 0, "close() left a non-empty WAL (\(walSize) bytes)")
        }
        // The main file holds the schema and rows, not a bare page-1 stub —
        // see `IntegrityTests.aGarbledHeaderFailsToOpenRatherThanBeingAcceptedSilently`
        // for why 4096 is the bar a schema-and-rows file clears.
        #expect(try Data(contentsOf: url).count > 4096)

        for sidecar in [walURL, shmURL] {
            try? FileManager.default.removeItem(at: sidecar)
        }

        let reopened = try IndexStore(url: url)
        #expect(try reopened.count() == 10)
        for i in 0..<10 {
            #expect(try reopened.record(atPath: "/a/\(i).jpg") != nil)
        }
        try reopened.close()
    }

    /// `close()`'s idempotency comes from GRDB's own state, not a flag this
    /// type tracks: `pool.barrierWriteWithoutTransaction` throws
    /// `DatabaseError.connectionIsClosed()` once `pool.close()` has run
    /// (its own guard against a nil reader pool), and `close()` maps that to
    /// `.alreadyClosed` rather than letting it escape. This is the test for
    /// the second call reporting that cleanly instead of throwing.
    @Test func aSecondCloseIsANoOpThatDoesNotThrow() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        _ = try store.upsert(sampleRecord(path: "/a/b.jpg"))
        #expect(try store.close() == .checkpointed)
        #expect(try store.close() == .alreadyClosed)
    }

    /// The case `close()`'s doc comment calls out: a second `IndexStore` on
    /// the same file holding an open read transaction, so the checkpoint
    /// cannot reclaim every frame. `close()` must still return — reporting
    /// the incomplete checkpoint through its return value — rather than
    /// throwing past the close, and the file must still be openable
    /// afterward.
    ///
    /// This costs the full 5 s busy timeout (`IndexStore.makeConfiguration()`)
    /// by design, not by accident: `Database.checkpoint(.truncate)` retries
    /// through GRDB's busy handler for the whole window before giving up and
    /// throwing `SQLITE_BUSY`, and that retry is exactly the mechanism this
    /// test is proving doesn't hang forever or throw past the close. A
    /// future pass "fixing the slow test" by shortening or deleting this
    /// wait would delete the thing it verifies. `two`'s reader lives on its
    /// own `IndexStore`/`DatabasePool` — a distinct set of connections from
    /// `one`'s — so `pool.barrierWriteWithoutTransaction`'s draining of
    /// `one`'s *own* readers (see `close()`'s doc comment) does not touch it,
    /// and the checkpoint still blocks on `two`'s snapshot the same way it
    /// would across two real app windows.
    @Test func closeStillReturnsWhenAnotherStoresReadSnapshotBlocksTheCheckpoint() throws {
        let url = tree.root.appendingPathComponent("index.sqlite")
        let one = try IndexStore(url: url)
        for i in 0..<5 { _ = try one.upsert(sampleRecord(path: "/a/\(i).jpg")) }

        let two = try IndexStore(url: url)
        let readerReady = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        // A plain thread, not a `Task`: the reader blocks holding its
        // snapshot open, and blocking a cooperative-pool thread to test a
        // blocking API is how a test deadlocks its own executor.
        Thread.detachNewThread {
            try? two.testRead { db in
                // The read statement is what actually takes the WAL
                // snapshot; entering the closure alone does not.
                _ = try? Int.fetchOne(db, sql: "SELECT count(*) FROM files")
                readerReady.signal()
                _ = releaseReader.wait(timeout: .now() + 10)
            }
        }
        if case .timedOut = readerReady.wait(timeout: .now() + 10) {
            Issue.record("the reader never took its snapshot")
            releaseReader.signal()
            return
        }

        #expect(try one.close() == .blocked)

        releaseReader.signal()
        try two.close()

        // Not fully checkpointed is not the same as unsafe to reopen.
        let reopened = try IndexStore(url: url)
        #expect(try reopened.count() == 5)
        try reopened.close()
    }
}
