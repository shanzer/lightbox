import Foundation
import GRDB
@testable import LightboxCore

/// Builds a genuine schema-v1 index at `url` and inserts `rows` into it.
///
/// Not a committed `.sqlite` blob: the file is produced by the v1 migration
/// itself, so it cannot drift from the schema the app actually shipped, and it
/// carries GRDB's own `grdb_migrations` bookkeeping — which is what makes
/// opening it through `IndexStore(url:)` run the v1 → v2 upgrade rather than a
/// fresh create. Schema v2 is the first migration to meet a populated
/// `index.sqlite`, and a migration only ever tested against an empty database
/// has been tested against the one case that cannot fail.
///
/// A `DatabaseQueue`, not a pool, because that is what phase 1 wrote: a v1
/// database on disk is in rollback-journal mode, and the upgrade has to happen
/// on the way into WAL.
func makeV1Index(at url: URL, rows: (Database) throws -> Void) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: url.path)
    try IndexStore.makeMigrator(upTo: 1).migrate(queue)
    try queue.write(rows)
    try queue.close()
}

/// Inserts one row using only columns that exist in schema v1 — no
/// `volume_uuid`, because at v1 there is none.
func insertV1Row(_ db: Database, path: String, size: Int64 = 100,
                 mtime: Double = 1_700_000_000, device: Int64 = 1,
                 contentHash: String? = nil, hashedAt: Double? = nil) throws {
    try db.execute(sql: """
        INSERT INTO files (path, parent_dir, name, ext, size, mtime, device, inode,
                           width, height, orientation, content_hash, hashed_at, indexed_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, arguments: [path, (path as NSString).deletingLastPathComponent,
                         (path as NSString).lastPathComponent,
                         (path as NSString).pathExtension.lowercased(),
                         size, mtime, device, 42, 640, 480, 1,
                         contentHash, hashedAt, 1_700_000_000])
    try db.execute(sql: "INSERT INTO files_fts (rowid, name, ocr_text) VALUES (?, ?, NULL)",
                   arguments: [db.lastInsertedRowID, (path as NSString).lastPathComponent])
}
