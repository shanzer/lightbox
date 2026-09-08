import Testing
import Foundation
@testable import LightboxCore

/// The launch-time check that keeps a corrupt index from leaving the app
/// unusable. See `BrowserModel` for where this runs, and `IndexStore.swift`
/// for `checkIntegrity()` and `rebuild(at:)` themselves.
struct IntegrityTests {
    @Test func aHealthyIndexReportsOK() throws {
        let store = try IndexStore.inMemory()
        #expect(store.checkIntegrity() == .ok)
    }

    /// Smashing the header is the obvious corruption to try, and it is
    /// checked here — but on this SQLite build it makes `IndexStore(url:)`
    /// itself throw (verified empirically: opening never succeeds once the
    /// first 64 bytes are garbage), because GRDB's migrator has to read the
    /// schema before this initializer returns. That is still real detection —
    /// `BrowserModel`'s `try? IndexStore(...)` treats a throw exactly like a
    /// failed check — but it means this particular test can never reach
    /// `checkIntegrity()`, and would keep passing even if that method's body
    /// were replaced with `return .ok`. `aDamagedTablePageIsReportedCorrupt`
    /// below is the test that actually exercises the pragma; this one only
    /// pins down the open-throws half of "detection", asserted explicitly
    /// rather than left to an `if let` that could silently skip its body.
    @Test func aGarbledHeaderFailsToOpenRatherThanBeingAcceptedSilently() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("index.sqlite")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        let first = try IndexStore(url: url)
        // Explicit close, not `_ = try IndexStore(url: url)` relying on ARC:
        // this is a `DatabasePool` in WAL mode (CLAUDE.md's GRDB/WAL gotcha),
        // and the schema this initializer just wrote (via the migrator) lands
        // in `index.sqlite-wal`, not in `index.sqlite` itself, until something
        // checkpoints it back. If a connection is still open — or ARC just
        // hasn't run the pool's `deinit` yet — when the bytes below overwrite
        // the file's header, the reopened store can still validate page 1
        // against a frame sitting in `-wal`/`-shm` and never look at the
        // garbled header on disk at all. (Confirmed empirically: holding a
        // second connection open across the overwrite reproduces exactly
        // this — the reopened store reports healthy every time in a loop.)
        //
        // `IndexStore.close()` alone is not enough to prevent it either:
        // `DatabasePool.close()` closes the writer connection first and the
        // readers after, so the writer is not the *last* connection to close,
        // and SQLite's automatic checkpoint-on-last-close never runs at all
        // once a reader connection exists — it only fires on the connection
        // that turns out to be the last one open, and by the time any reader
        // closes last it cannot write, so it cannot checkpoint. Empirically,
        // `close()` alone left `-wal` on disk at its full pre-close size, and
        // the reopened store still read the garbled header's page right out
        // of it. So the checkpoint has to be forced explicitly, on the
        // writer, before anything closes — `testExecute` is the documented
        // seam for reaching the writer connection from a test rather than
        // touching `pool` directly (`pool` is documented as reachable only
        // from `IndexStore`'s own extensions, not from outside the type).
        // `PRAGMA wal_checkpoint(TRUNCATE)` checkpoints every frame back into
        // `index.sqlite` and resets `-wal` to empty. The sidecars are then
        // removed outright (as `IndexStore.rebuild(at:)` does) so "gone" is
        // verifiable by existence, not by trusting the checkpoint left
        // nothing readable.
        try first.testExecute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        try first.close()
        for sidecar in [walURL, shmURL] {
            try? FileManager.default.removeItem(at: sidecar)
        }
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: shmURL.path))
        // The checkpoint is load-bearing, not incidental cleanup: without it,
        // everything the migrator wrote is still sitting in the (now-removed)
        // `-wal`, and `index.sqlite` on disk is a bare 4096-byte page-1 stub —
        // a valid header over no schema. A garbled version of that stub would
        // still fail to open, so the detection assertions below would pass
        // whether or not the checkpoint ran, proving nothing. This assertion
        // pins the checkpoint as the thing that put the schema where the
        // garble can actually reach it. (Verified by mutation: drop the
        // checkpoint above but keep the sidecar removals, and this goes red —
        // the file is exactly 4096 bytes.)
        #expect(try Data(contentsOf: url).count > 4096)

        // Overwrite the SQLite header with garbage.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x7F, count: 64))
        try handle.close()

        do {
            let store = try IndexStore(url: url)
            // If a future SQLite/GRDB version tolerates the garbled header
            // well enough to open, the check still has to catch it.
            guard case .corrupt = store.checkIntegrity() else {
                Issue.record("a corrupted database was reported healthy")
                return
            }
        } catch {
            // Refusing to open at all is detection too.
        }
    }

    /// Corrupts live rows in the `files` table rather than the header, so the
    /// file opens without throwing and `checkIntegrity()` itself has to catch
    /// the damage — unlike the header test above, this one cannot pass
    /// without actually running `PRAGMA quick_check` against real corruption.
    /// If `checkIntegrity()` were stubbed to always return `.ok`, this is the
    /// test that goes red.
    ///
    /// Five hundred rows spread the table over enough pages that flipping
    /// bytes every 4KB past the schema/migration bookkeeping (which lives in
    /// the first handful of pages) reliably lands on live cell data rather
    /// than an empty or unused page `quick_check` has nothing to say about.
    @Test func aDamagedTablePageIsReportedCorrupt() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        for i in 0..<500 {
            _ = try store.upsert(FileRecord(
                id: nil, path: "/a/\(i).jpg", parentDir: "/a", name: "\(i).jpg", ext: "jpg",
                size: 1, mtime: 1, device: 1, inode: Int64(i), width: nil, height: nil,
                captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
                orientation: nil, contentHash: nil, imageHash: nil, imageHashKind: nil,
                phash: nil, hashedAt: nil, indexedAt: 1))
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int

        let handle = try FileHandle(forWritingTo: url)
        var offset = 24_576  // past the schema and migration-bookkeeping pages
        while offset + 200 < size {
            try handle.seek(toOffset: UInt64(offset + 50))
            try handle.write(contentsOf: Data(repeating: 0x7F, count: 200))
            offset += 4_096
        }
        try handle.close()

        // The file must still open — this test is worthless if it doesn't
        // reach `checkIntegrity()`.
        let reopened = try IndexStore(url: url)
        guard case .corrupt = reopened.checkIntegrity() else {
            Issue.record("a database with damaged table pages was reported healthy")
            return
        }
    }

    /// `close()` exists so `BrowserModel.init(at:)` can release a
    /// corrupt-but-openable connection before `rebuild(at:)` deletes the file
    /// it points at, rather than trusting `deinit` to have finished first. A
    /// connection that claims to be closed but still answers queries would
    /// defeat the entire point, so this pins both halves of the contract:
    /// the connection stops working, and the file it was holding is left in
    /// a state a fresh connection (or a delete-and-recreate) can safely take
    /// over.
    @Test func closeReleasesTheConnectionSoTheFileCanBeSafelyReplaced() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        _ = try store.upsert(FileRecord(
            id: nil, path: "/a/b.jpg", parentDir: "/a", name: "b.jpg", ext: "jpg",
            size: 1, mtime: 1, device: 1, inode: 1, width: nil, height: nil, captureTime: nil,
            captureOffset: nil, cameraMake: nil, cameraModel: nil, orientation: nil,
            contentHash: nil, imageHash: nil, imageHashKind: nil, phash: nil,
            hashedAt: nil, indexedAt: 1))

        try store.close()

        #expect(throws: (any Error).self) {
            try store.count()
        }
        // The file must still be a valid, independent database that a
        // rebuild can safely delete and replace now that nothing holds it open.
        let rebuilt = try IndexStore.rebuild(at: url)
        #expect(try rebuilt.count() == 0)
    }

    @Test func rebuildReplacesTheFileWithAnEmptyIndex() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: url)
        _ = try store.upsert(FileRecord(
            id: nil, path: "/a/b.jpg", parentDir: "/a", name: "b.jpg", ext: "jpg",
            size: 1, mtime: 1, device: 1, inode: 1, width: nil, height: nil, captureTime: nil,
            captureOffset: nil, cameraMake: nil, cameraModel: nil, orientation: nil,
            contentHash: nil, imageHash: nil, imageHashKind: nil, phash: nil,
            hashedAt: nil, indexedAt: 1))
        #expect(try store.count() == 1)

        let rebuilt = try IndexStore.rebuild(at: url)
        #expect(try rebuilt.count() == 0)
        #expect(rebuilt.checkIntegrity() == .ok)
        #expect(try rebuilt.tableNames().contains("files"))
    }

    /// A rebuild must not depend on a prior file existing — the corruption
    /// might be a missing/unreadable file rather than a damaged one, and the
    /// nested path must not trip on missing intermediate directories either.
    @Test func rebuildWorksEvenWhenNoFileExists() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("nested/index.sqlite")
        let rebuilt = try IndexStore.rebuild(at: url)
        #expect(try rebuilt.count() == 0)
    }

    /// A rebuild must also clear the SQLite sidecars, or a fresh database can
    /// inherit a write-ahead log or shared-memory file left over from the
    /// corrupt one — the exact failure mode `rebuild(at:)` exists to avoid.
    ///
    /// The index is a WAL database, so the rebuilt store immediately makes its
    /// own `-wal` and `-shm`. "Removed" therefore has to be observed as
    /// *unlinked and replaced* — a different inode — and not as absence or as
    /// changed bytes. Both weaker forms are vacuous here: absence would be
    /// asserting the replacement never opened, and the bytes change either way
    /// because GRDB's `setUpWALMode()` rewrites the log header at open.
    ///
    /// The `-shm` leg is the one that pins `rebuild(at:)`. Deleting a stale
    /// `-wal` is belt and braces that SQLite performs anyway — it unlinks a log
    /// whose database is missing — so that leg is asserted for symmetry and
    /// cannot fail on its own. Verified by mutation: shortening the suffix list
    /// to `[""]` leaves the `-shm` inode unchanged and takes this test red.
    @Test func rebuildRemovesTheWriteAheadLogAndSharedMemorySidecars() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("index.sqlite")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")

        // Seeded from a live connection rather than from junk bytes: a one-byte
        // "log" has no valid header, so SQLite discards it on sight and the
        // test would pass without the rebuild having done anything.
        let store = try IndexStore(url: url)
        for i in 0..<5 {
            _ = try store.upsert(FileRecord(
                id: nil, path: "/a/\(i).jpg", parentDir: "/a", name: "\(i).jpg", ext: "jpg",
                size: 1, mtime: 1, device: 1, inode: Int64(i), width: nil, height: nil,
                captureTime: nil, captureOffset: nil, cameraMake: nil, cameraModel: nil,
                orientation: nil, contentHash: nil, imageHash: nil, imageHashKind: nil,
                phash: nil, hashedAt: nil, indexedAt: 1))
        }
        let liveWAL = try Data(contentsOf: walURL)
        let liveSHM = try Data(contentsOf: shmURL)
        #expect(!liveWAL.isEmpty)
        #expect(!liveSHM.isEmpty)
        // Closing checkpoints and removes the sidecars, so they are written
        // back to stand in for the pair a crash would have left behind.
        try store.close()
        try liveWAL.write(to: walURL)
        try liveSHM.write(to: shmURL)

        func inode(_ url: URL) -> UInt64? {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        let staleWALInode = inode(walURL)
        let staleSHMInode = inode(shmURL)
        #expect(staleWALInode != nil)
        #expect(staleSHMInode != nil)

        let rebuilt = try IndexStore.rebuild(at: url)

        #expect(inode(shmURL) != staleSHMInode, "the rebuild kept the stale -shm")
        #expect(inode(walURL) != staleWALInode, "the rebuild kept the stale -wal")
        #expect(try rebuilt.count() == 0)
        #expect(rebuilt.checkIntegrity() == .ok)
    }
}

