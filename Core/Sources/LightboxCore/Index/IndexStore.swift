import Foundation
import GRDB

public enum IndexStoreError: Error, Equatable, Sendable {
    /// A scope prefix that is empty or not an absolute path. Thrown rather
    /// than trapped: the realistic bad input is a persisted setting (an
    /// unexpanded "~/Pictures", a stale relative preference), and a saved
    /// setting must surface as an error, not crash the app on launch.
    case invalidScope(String)
}

public final class IndexStore: Sendable {
    private let dbq: DatabaseQueue

    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    /// One configuration for the file-backed and in-memory stores, so tests
    /// exercise the same database production runs. Every future setting (WAL,
    /// busy timeout, custom functions) belongs here and nowhere else.
    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbq = try DatabaseQueue(path: url.path, configuration: Self.makeConfiguration())
        try Self.migrator.migrate(dbq)
    }

    private init() throws {
        dbq = try DatabaseQueue(configuration: Self.makeConfiguration())
        try Self.migrator.migrate(dbq)
    }

    public static func inMemory() throws -> IndexStore { try IndexStore() }

    // MARK: - Schema

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    parent_dir TEXT NOT NULL,
                    name TEXT NOT NULL,
                    ext TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    device INTEGER NOT NULL,
                    inode INTEGER NOT NULL,
                    width INTEGER,
                    height INTEGER,
                    capture_time REAL,
                    capture_offset TEXT,
                    camera_make TEXT,
                    camera_model TEXT,
                    orientation INTEGER,
                    content_hash TEXT,
                    image_hash TEXT,
                    image_hash_kind TEXT,
                    phash TEXT,
                    hashed_at REAL,
                    indexed_at REAL NOT NULL
                );
                CREATE INDEX files_on_parent_dir ON files(parent_dir);
                CREATE INDEX files_on_capture_time ON files(capture_time);
                CREATE INDEX files_on_size ON files(size);
                CREATE INDEX files_on_dimensions ON files(width, height);
                CREATE INDEX files_on_content_hash ON files(content_hash);
                CREATE INDEX files_on_image_hash ON files(image_hash);
                CREATE INDEX files_on_hashed_at ON files(hashed_at);

                CREATE VIRTUAL TABLE files_fts USING fts5(name, ocr_text);

                CREATE TABLE analysis (
                    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                    ocr_text TEXT,
                    text_coverage REAL,
                    top_labels TEXT,
                    has_faces INTEGER,
                    feature_print BLOB,
                    clip_embedding BLOB,
                    analyzer_versions TEXT,
                    analyzed_at REAL
                );

                CREATE TABLE saved_searches (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    query TEXT NOT NULL,
                    is_builtin INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE op_journal (
                    op_id INTEGER PRIMARY KEY,
                    batch_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    src TEXT NOT NULL,
                    dst TEXT,
                    trash_url TEXT,
                    timestamp REAL NOT NULL,
                    state TEXT NOT NULL
                );
                CREATE INDEX op_journal_on_batch ON op_journal(batch_id);

                -- The FTS row is a shadow of its files row; deleting the file
                -- must never leave a ghost in the search index, no matter which
                -- code path (or later phase) performs the delete.
                CREATE TRIGGER files_ad AFTER DELETE ON files BEGIN
                  DELETE FROM analysis WHERE file_id = old.id;
                  DELETE FROM files_fts WHERE rowid = old.id;
                END;

                -- A changed file's OCR text, feature print and CLIP embedding
                -- are as stale as its hashes, and analysis carries no
                -- source_size/source_mtime to detect that later. Drop the row
                -- at the moment the change is recorded.
                CREATE TRIGGER files_au_invalidate AFTER UPDATE OF size, mtime ON files
                  WHEN old.size <> new.size OR old.mtime <> new.mtime BEGIN
                  DELETE FROM analysis WHERE file_id = new.id;
                END;
                """)
        }
        return m
    }()

    // MARK: - Writes

    /// Inserts the record, or updates the existing row with the same path.
    /// The row id is preserved across updates so that `analysis` rows written
    /// by later phases survive a re-scan.
    @discardableResult
    public func upsert(_ record: FileRecord) throws -> Int64 {
        try dbq.write { db in
            guard let id = try Int64.fetchOne(db, sql: """
                INSERT INTO files
                    (path, parent_dir, name, ext, size, mtime, device, inode, width, height,
                     capture_time, capture_offset, camera_make, camera_model, orientation,
                     content_hash, image_hash, image_hash_kind, phash, hashed_at, indexed_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                    parent_dir=excluded.parent_dir, name=excluded.name, ext=excluded.ext,
                    size=excluded.size, mtime=excluded.mtime, device=excluded.device,
                    inode=excluded.inode,
                    width=excluded.width, height=excluded.height,
                    capture_time=excluded.capture_time, capture_offset=excluded.capture_offset,
                    camera_make=excluded.camera_make, camera_model=excluded.camera_model,
                    orientation=excluded.orientation, indexed_at=excluded.indexed_at,
                    -- A changed size or mtime means the bytes changed, so every
                    -- hash on this row is now a lie. Clearing hashed_at also
                    -- re-enqueues the file for the tier 1 pass.
                    content_hash = CASE WHEN files.size <> excluded.size
                                          OR files.mtime <> excluded.mtime
                                     THEN NULL ELSE files.content_hash END,
                    image_hash = CASE WHEN files.size <> excluded.size
                                        OR files.mtime <> excluded.mtime
                                   THEN NULL ELSE files.image_hash END,
                    image_hash_kind = CASE WHEN files.size <> excluded.size
                                             OR files.mtime <> excluded.mtime
                                        THEN NULL ELSE files.image_hash_kind END,
                    phash = CASE WHEN files.size <> excluded.size
                                   OR files.mtime <> excluded.mtime
                              THEN NULL ELSE files.phash END,
                    hashed_at = CASE WHEN files.size <> excluded.size
                                       OR files.mtime <> excluded.mtime
                                  THEN NULL ELSE files.hashed_at END
                RETURNING id
                """, arguments: [
                    record.path, record.parentDir, record.name, record.ext,
                    record.size, record.mtime, record.device, record.inode,
                    record.width, record.height,
                    record.captureTime, record.captureOffset, record.cameraMake,
                    record.cameraModel, record.orientation, record.contentHash,
                    record.imageHash, record.imageHashKind, record.phash,
                    record.hashedAt, record.indexedAt,
                ]) else {
                throw DatabaseError(resultCode: .SQLITE_ERROR,
                                    message: "upsert returned no row id for \(record.path)")
            }
            // Update-in-place rather than delete-and-reinsert: phase 3 writes
            // ocr_text into this row, and a rescan of an unchanged file must
            // not destroy it.
            try db.execute(sql: "UPDATE files_fts SET name = ? WHERE rowid = ?",
                           arguments: [record.name, id])
            if db.changesCount == 0 {
                try db.execute(
                    sql: "INSERT INTO files_fts (rowid, name, ocr_text) VALUES (?, ?, NULL)",
                    arguments: [id, record.name])
            }
            return id
        }
    }

    /// `content` is optional because `hashed_at` records that hashing was
    /// *attempted*. A file that cannot be read must still be marked, or the
    /// tier 1 pass retries it on every run forever.
    public func setHashes(fileID: Int64, content: String?, image: String?,
                          imageKind: String?, phash: String?, hashedAt: Double) throws {
        try dbq.write { db in
            try db.execute(sql: """
                UPDATE files SET content_hash = ?, image_hash = ?, image_hash_kind = ?,
                                 phash = ?, hashed_at = ?
                WHERE id = ?
                """, arguments: [content, image, imageKind, phash, hashedAt, fileID])
        }
    }

    /// Removes rows under `prefix` whose paths are not in `keeping`.
    /// FTS and `analysis` rows follow via the `files_ad` trigger and the
    /// `ON DELETE CASCADE` foreign key.
    @discardableResult
    public func deleteRows(under prefix: String, keeping: Set<String>) throws -> Int {
        let scope = try Self.pathScope(prefix)
        return try dbq.write { db in
            let stale = try String.fetchAll(db, sql: Self.pathsInScopeSQL,
                                            arguments: [scope.exact, scope.lower, scope.upper])
                .filter { !keeping.contains($0) }
            for path in stale {
                try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [path])
            }
            return stale.count
        }
    }

    /// Removes rows whose immediate parent is `folder` and whose paths are not
    /// in `keeping`. Used after a non-recursive scan, which knows nothing about
    /// subdirectories and must not be allowed to delete their rows.
    ///
    /// `folder` is validated and normalized exactly as a recursive scope is, so
    /// a trailing slash matches the stored `parent_dir` and a relative or empty
    /// setting throws rather than matching nothing.
    @discardableResult
    public func deleteRows(inFolder folder: String, keeping: Set<String>) throws -> Int {
        let normalized = try Self.pathScope(folder).exact
        return try dbq.write { db in
            let stale = try String.fetchAll(db, sql: Self.staleInFolderSQL,
                                            arguments: [normalized])
                .filter { !keeping.contains($0) }
            for path in stale {
                try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [path])
            }
            return stale.count
        }
    }

    // MARK: - Reads

    /// Every indexed path at or under `prefix`.
    ///
    /// Exists for the reconcile: a subtree the walk could not enter must have
    /// its rows protected from the delete, and protecting them by name is
    /// exact where narrowing the delete's byte-range scope would not be.
    public func paths(under prefix: String) throws -> [String] {
        let scope = try Self.pathScope(prefix)
        return try dbq.read { db in
            try String.fetchAll(db, sql: Self.pathsInScopeSQL,
                                arguments: [scope.exact, scope.lower, scope.upper])
        }
    }

    public func record(atPath path: String) throws -> FileRecord? {
        try dbq.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?", arguments: [path])
        }
    }

    public func needsReindex(path: String, size: Int64, mtime: Double) throws -> Bool {
        guard let row = try record(atPath: path) else { return true }
        return row.size != size || row.mtime != mtime
    }

    public func filesMissingHashes(under prefix: String, limit: Int) throws -> [FileRecord] {
        let scope = try Self.pathScope(prefix)
        return try dbq.read { db in
            try FileRecord.fetchAll(db, sql: Self.missingHashesSQL,
                                    arguments: [scope.exact, scope.lower, scope.upper, limit])
        }
    }

    public func search(_ query: SearchQuery) throws -> [FileRecord] {
        let compiled = try QueryCompiler.compile(query)
        return try dbq.read { db in
            try FileRecord.fetchAll(db, sql: compiled.sql, arguments: compiled.arguments)
        }
    }

    public func count() throws -> Int {
        try dbq.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM files")! }
    }

    // MARK: - Path scoping

    /// The one copy of the scope predicate. Production queries and the
    /// query-plan test both use these constants, so the test certifies the
    /// SQL that actually runs and cannot drift from it.
    /// Bind order: exact, lower, upper (from `pathScope`).
    static let scopePredicateSQL = "(path = ? OR (path > ? AND path < ?))"
    /// Every indexed path at or under a scope. Shared by the reconcile's
    /// delete and by the read that protects an unwalkable subtree from it.
    static let pathsInScopeSQL = "SELECT path FROM files WHERE " + scopePredicateSQL
    /// The non-recursive counterpart, off `files_on_parent_dir`.
    static let staleInFolderSQL = "SELECT path FROM files WHERE parent_dir = ?"
    static let missingHashesSQL = """
        SELECT * FROM files
        WHERE hashed_at IS NULL AND \(scopePredicateSQL)
        ORDER BY id LIMIT ?
        """

    /// Bounds for "every path at or under `prefix`" as byte comparisons.
    ///
    /// `LIKE` is the obvious tool and the wrong one: SQLite folds ASCII case in
    /// `LIKE` regardless of `ESCAPE` or `COLLATE`, so a scope of `/lib` would
    /// also match `/LIB` — and `deleteRows` would silently destroy a sibling
    /// directory's index on a case-sensitive volume. `LIKE` also defeats the
    /// index on `path`. Byte ranges have neither problem and need no wildcard
    /// escaping: descendants of `p` are exactly the paths strictly between
    /// `p + "/"` and `p + "0"`, because `'0'` (0x30) is the next byte after
    /// `'/'` (0x2F). Usage: `path = exact OR (path > lower AND path < upper)`.
    static func pathScope(_ prefix: String) throws -> (exact: String, lower: String, upper: String) {
        guard prefix.hasPrefix("/") else { throw IndexStoreError.invalidScope(prefix) }
        var p = prefix
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p == "/" { return (exact: "/", lower: "/", upper: "0") }
        return (exact: p, lower: p + "/", upper: p + "0")
    }

    // MARK: - Test support

    func tableNames() throws -> Set<String> {
        try dbq.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table')"))
        }
    }

    func ftsRowCount() throws -> Int {
        try dbq.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM files_fts")! }
    }

    /// Row ids of files whose FTS row matches `pattern` — what Task 13's
    /// filename search actually depends on.
    func ftsMatchRowIDs(_ pattern: String) throws -> [Int64] {
        try dbq.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM files_fts WHERE files_fts MATCH ? ORDER BY rowid",
                               arguments: [pattern])
        }
    }

    /// Raw SQL escape hatches so tests can exercise schema-level behavior
    /// (triggers, cascades) that the public API deliberately does not expose.
    /// Runs outside an automatic transaction so statements like
    /// `PRAGMA foreign_keys`, which are no-ops mid-transaction, take effect.
    func testExecute(sql: String, arguments: StatementArguments = []) throws {
        try dbq.writeWithoutTransaction { db in try db.execute(sql: sql, arguments: arguments) }
    }

    func testFetchOne<T: DatabaseValueConvertible>(sql: String, arguments: StatementArguments = []) throws -> T? {
        try dbq.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    func queryPlan(sql: String, arguments: StatementArguments = []) throws -> [String] {
        try dbq.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { $0["detail"] as String? ?? "" }
        }
    }
}
