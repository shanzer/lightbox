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
        _ = try IndexStore(url: url)          // create and close

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
    @Test func rebuildRemovesTheWriteAheadLogAndSharedMemorySidecars() throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("index.sqlite")
        _ = try IndexStore(url: url)          // create and close

        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        try Data([0xFF]).write(to: walURL)
        try Data([0xFF]).write(to: shmURL)

        _ = try IndexStore.rebuild(at: url)

        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: shmURL.path))
    }
}

