import Foundation
import GRDB

/// The result of `IndexStore.checkIntegrity()`.
///
/// `corrupt` carries SQLite's own description (the `quick_check` message, or
/// the error that opening the database raised) so a failure report says more
/// than "something is wrong".
public enum IndexHealth: Sendable, Equatable {
    case ok
    case corrupt(String)
}

public enum IndexStoreError: Error, Equatable, Sendable {
    /// A scope prefix that is empty or not an absolute path. Thrown rather
    /// than trapped: the realistic bad input is a persisted setting (an
    /// unexpanded "~/Pictures", a stale relative preference), and a saved
    /// setting must surface as an error, not crash the app on launch.
    case invalidScope(String)
}

public final class IndexStore: Sendable {
    /// Reachable from `IndexStore`'s own extensions in other files —
    /// `IndexStore+FileOperations.swift` — and from nowhere else. Swift has no
    /// access level for "this type, across files", and `private` is file-scoped;
    /// `internal` plus this note is the closest thing. The rule it stands in for
    /// is unchanged: **no type but `IndexStore` holds a `DatabasePool`**, so
    /// every write to the index goes through an API that documents its guard.
    let pool: DatabasePool

    /// The database file this store is open on.
    ///
    /// Every store is file-backed, including the one `inMemory()` returns: a
    /// `DatabasePool` needs a real file, because WAL's shared-memory index has
    /// nowhere to live otherwise. Exposed internally so tests can observe the
    /// three files WAL leaves on disk.
    let fileURL: URL

    /// The throwaway directory `inMemory()` created for this store, removed
    /// when the store is released. Nil for a store opened at a caller's URL,
    /// which owns nothing and must delete nothing.
    private let ownedDirectory: URL?

    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    /// One configuration for the file-backed and in-memory stores, so tests
    /// exercise the same database production runs. Every future setting
    /// (journal mode, busy timeout, custom functions) belongs here and nowhere
    /// else.
    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // `WindowGroup` gives File → New Window (⌘N) for free, and every window
        // builds its own `BrowserModel` → `IndexStore` → `DatabasePool` on the
        // same `index.sqlite`. The pool is the reason two windows can work at
        // once: it opens a writer connection and a small set of read-only ones
        // against a WAL database, so a reader takes a snapshot instead of a
        // lock and never waits for a writer — not the writer in its own window
        // (a search behind that window's tier 1 hash batch), and not the one in
        // the other window. GRDB's `DatabasePool` puts the database into WAL
        // itself, which is why nothing here sets `journalMode`; leaving it at
        // `.default` is what asks for that.
        //
        // That hands one setting to GRDB rather than to this function, and the
        // "here and nowhere else" rule is only honest if it is named: GRDB's
        // `setUpWALMode()` also issues `PRAGMA synchronous = NORMAL`. Under WAL
        // that trades an fsync per commit for the possibility of losing the
        // last few commits to a power cut or a kernel panic — it cannot corrupt
        // the file, because a torn WAL frame fails its checksum and is ignored.
        // For a derived cache whose worst case is "rescan the folder" that is
        // the right trade, and it is the reason a rebuild is a one-button
        // operation rather than a repair tool. Anything that ever stores
        // something *not* recomputable from the filesystem has to revisit it.
        //
        // The busy timeout is still needed, for the one case WAL does not fix:
        // two *writers*. SQLite allows exactly one at a time whatever the
        // journal mode, so two windows scanning at once still serialise, and
        // GRDB's default busy mode is `.immediateError` — the second window
        // would take `SQLITE_BUSY` straight into `status = .failed` mid-pass.
        // Nothing is lost when that happens (`indexTier0` throws before its
        // reconcile, `deleteRows` is a single transaction, and `setHashes(for:)`
        // is guarded), but an ordinary gesture should not degrade the app.
        //
        // Five seconds is chosen against what actually contends: writes are
        // batched and short, so a window waits milliseconds in practice, and
        // the timeout only has to outlast one batch rather than a whole pass.
        // Long enough to be invisible, short enough that a genuinely stuck
        // writer still surfaces as an error instead of hanging the window.
        config.busyMode = .timeout(5)
        return config
    }

    /// Opens, or creates, the index at `url`.
    ///
    /// Write access is required even to open one for reading: activating WAL
    /// writes the journal-mode change and the `-wal` and `-shm` files beside
    /// the database. A read-only file, or one on a read-only or WAL-hostile
    /// volume (some network mounts), therefore throws here rather than opening.
    /// The app's own index lives in Application Support on the boot volume, but
    /// this initializer is public and takes any URL.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileURL = url
        ownedDirectory = nil
        pool = try Self.openPool(at: url)
        try Self.migrator.migrate(pool)
        // Synchronous on purpose — the reconcile has to finish before anything
        // can hold this store — but **its `stat`s do not run on this thread**.
        // The app opens its store on the main actor (`BrowserView.start` →
        // `BrowserModel(at:)`), the rows name whatever volume the library lives
        // on, and one `stat` on a spun-down external drive parks its thread for
        // seconds. `reconcileJournalAtOpen` hands the work to a dispatch queue
        // and waits on it for `reconcileBudget`, then abandons it — and the
        // abandon is read inside the write transaction and left by throwing, so
        // a run that outruns the bound rolls back rather than committing after
        // this initializer has returned saying nothing landed. Every row stays
        // `in_flight` for the next open.
        journalReconcileReport = Self.reconcileJournalAtOpen(in: pool)
    }

    private init(temporaryDirectory: URL) throws {
        let url = temporaryDirectory.appendingPathComponent("index.sqlite")
        fileURL = url
        ownedDirectory = temporaryDirectory
        pool = try Self.openPool(at: url)
        try Self.migrator.migrate(pool)
        journalReconcileReport = Self.reconcileJournalAtOpen(in: pool)
    }

    /// What the launch-time reconcile found and did when this store was opened
    /// (spec §8, `IndexStore+Reconcile.swift`).
    ///
    /// Every `in_flight` journal row is resolved against the filesystem here,
    /// **before this initializer returns**, so no window can start a pass over
    /// rows that a crash left describing files which have since moved. The
    /// report is kept rather than discarded because its `conclusions` are the
    /// only record of where a photo actually ended up when the answer was
    /// "in a stash" or "in the Trash under a name nothing can derive" — the
    /// journal row itself, once `reconciled`, no longer says.
    public let journalReconcileReport: JournalReconcileReport

    /// A store nothing else can reach, on a file nothing else will find.
    ///
    /// It was a genuine in-memory database until phase 2: a `DatabasePool`
    /// cannot be one, because WAL needs a `-shm` file for the shared index that
    /// coordinates its connections. Tests get a private temporary directory
    /// each — `swift test` runs suites in parallel, so a shared path would have
    /// them treading on one another — and the directory is removed when the
    /// store is released.
    public static func inMemory() throws -> IndexStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lightbox-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try IndexStore(temporaryDirectory: directory)
    }

    deinit {
        guard let ownedDirectory else { return }
        // Closed first, and explicitly: unlinking a file SQLite still has open
        // is a client API violation even where it happens to work, and `deinit`
        // is the last moment anything can be ordered.
        try? pool.close()
        try? FileManager.default.removeItem(at: ownedDirectory)
    }

    private static func openPool(at url: URL) throws -> DatabasePool {
        try DatabasePool(path: url.path, configuration: makeConfiguration())
    }

    /// What `close()`'s checkpoint accomplished before the pool closed.
    public enum CloseOutcome: Sendable, Equatable {
        /// The checkpoint fully completed: `-wal` is truncated to empty and
        /// `index.sqlite` alone holds everything.
        case checkpointed
        /// The checkpoint could not complete — `Database.checkpoint(.truncate)`
        /// threw `SQLITE_BUSY`, most plausibly because another connection
        /// still holds a WAL read snapshot TRUNCATE cannot reclaim. The pool
        /// still closed; `-wal` may still hold frames.
        case blocked
        /// This store was already closed; the call did nothing beyond the
        /// already-idempotent `pool.close()`.
        case alreadyClosed
    }

    /// Closes the underlying SQLite connections synchronously, first
    /// checkpointing the write-ahead log so the file left behind is
    /// self-contained.
    ///
    /// `DatabasePool.close()` closes the writer connection first and the
    /// read-only readers after, so the writer is never the *last* connection
    /// open on the file, and SQLite's automatic checkpoint-on-last-close
    /// never runs once any reader connection has ever existed — which every
    /// `IndexStore` opens, to be a pool at all. Left alone, that means a
    /// "successful" `close()` can return with `-wal` still holding
    /// everything nothing has read back from `index.sqlite` itself (measured
    /// while fixing #40: 123,632 bytes of untouched `-wal` after a close
    /// that raised no error). So this now runs `Database.checkpoint(.truncate)`
    /// — GRDB's typed wrapper around `sqlite3_wal_checkpoint_v2` in
    /// `SQLITE_CHECKPOINT_TRUNCATE` mode, deliberately not the
    /// `PRAGMA wal_checkpoint(TRUNCATE)` text form: the PRAGMA reports
    /// contention as a `busy=1` result row rather than throwing, while the
    /// typed API throws `SQLITE_BUSY`, which is what the `.blocked` case
    /// below is built on — on the writer, via `pool.barrierWriteWithoutTransaction`,
    /// before `pool.close()` runs. TRUNCATE folds every WAL frame back into
    /// `index.sqlite` and truncates `-wal` to zero bytes, which is what makes
    /// the promise below true by construction instead of by the one
    /// production caller's luck (`BrowserModel.init(at:)`'s corrupt-index
    /// path, which happens to follow `close()` with `rebuild(at:)`, itself
    /// deleting all three files): **a fresh connection, or a
    /// delete-and-recreate, can safely take over the file this leaves
    /// behind.**
    ///
    /// `barrierWriteWithoutTransaction`, not `writeWithoutTransaction`, for
    /// two reasons at once: it drains this pool's *own* reader connections
    /// before the checkpoint runs — the same ordering `DatabasePool.close()`
    /// itself uses internally — so a read this pool is still serving cannot
    /// defeat TRUNCATE; and it is what gives idempotency for free. Called
    /// after this store is already closed, `barrierWriteWithoutTransaction`
    /// throws `DatabaseError.connectionIsClosed()` (its own guard against a
    /// nil reader pool) rather than touching a closed writer connection, so
    /// a second `close()` is detected cleanly from GRDB's own state instead
    /// of state this type would otherwise have to track and keep in sync
    /// with it.
    ///
    /// The checkpoint can fail to complete without anything being wrong:
    /// SQLite cannot truncate frames a live reader might still need, so a
    /// second `IndexStore` on the same file (two windows on `index.sqlite`,
    /// or the reader-holding test below) can leave the checkpoint unable to
    /// finish, past the configured busy timeout. That is not a reason to
    /// fail *this* close — the caller closed one connection, not every
    /// window — so it is mapped to `.blocked` rather than thrown, and
    /// `pool.close()` always runs. Any other error (`SQLITE_IOERR`,
    /// `SQLITE_CORRUPT`, …) is a real failure and is rethrown rather than
    /// folded into either case.
    ///
    /// Not required for ordinary use — GRDB closes its connections when the
    /// `DatabasePool` deinitializes, and that is sufficient for a store an
    /// `IndexStore` owns for its own lifetime (`deinit` does not route
    /// through this method, and does not checkpoint: it is not synchronous
    /// enough to be relied on for that, which is why `close()` exists as an
    /// explicit step). This matters wherever a file is about to be unlinked
    /// under a live connection — `deinit` on a store that owns its temporary
    /// directory, and one case in the app: `BrowserModel.init(at:)` opens a
    /// connection to check its integrity, and, if that check fails, discards
    /// it in favor of a fresh one at the same path. `deinit` is not
    /// synchronous enough for that — the old connection's file descriptor can
    /// still be open when `rebuild(at:)` unlinks the file out from under it,
    /// which SQLite flags as a client API violation even though it happens to
    /// tolerate it. This makes closing the old connection an explicit,
    /// ordered step instead of a race with ARC. That one production caller is
    /// `@MainActor` and discards this method's return value — `rebuild(at:)`
    /// deletes all three files right after, so what the checkpoint managed
    /// plays no part there — which means it can block the main thread for up
    /// to the busy timeout if a second window's store holds a read snapshot
    /// at exactly that moment. Acceptable: reaching this path needs both a
    /// corrupt index *and* a second window open on it.
    ///
    /// - Returns: `.checkpointed` if the checkpoint fully completed;
    ///   `.blocked` if it could not, because another connection still holds a
    ///   read snapshot; `.alreadyClosed` if this store was already closed. In
    ///   every case `close()` itself has succeeded — the pool is closed. A
    ///   rethrown checkpoint error (`SQLITE_IOERR`, `SQLITE_CORRUPT`, …)
    ///   still leaves the pool closed, for the same reason.
    @discardableResult
    public func close() throws -> CloseOutcome {
        let outcome: CloseOutcome
        do {
            try pool.barrierWriteWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
            outcome = .checkpointed
        } catch let error as DatabaseError
        where error.resultCode == .SQLITE_MISUSE && error.message == "Connection is closed" {
            // `barrierWriteWithoutTransaction`'s own guard against a nil
            // reader pool — see the doc comment above. Not our own state.
            outcome = .alreadyClosed
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            outcome = .blocked
        } catch {
            // A real failure, not `.alreadyClosed` or `.blocked`. The pool
            // still has to close here, not just on the three paths above:
            // the one production caller (`BrowserModel.init(at:)`'s
            // corrupt-index path) calls this through `try?`, which would
            // otherwise swallow the error and leave the old connection live
            // for `rebuild(at:)` to unlink the file out from under it —
            // exactly the hazard `close()` exists to remove. `try?`, not
            // `try`, on the close itself: the error already being thrown is
            // the reason to report, and a second failure closing the pool
            // would have nothing more useful to say than the first.
            try? pool.close()
            throw error
        }
        try pool.close()
        return outcome
    }

    // MARK: - Schema

    /// The newest schema version this build knows how to produce.
    static let currentSchemaVersion = 2

    private static let migrator = makeMigrator()

    /// The schema, one registration per version.
    ///
    /// Parameterised by the last version to apply, and internal, so a test can
    /// build a database as it stood at an earlier version — GRDB's own
    /// `grdb_migrations` bookkeeping included — and then open it through
    /// `init(url:)` to exercise the real upgrade path. That matters more than
    /// it sounds: v2 is the first migration to run against a populated
    /// `index.sqlite`, and a migration that only ever ran against an empty
    /// database has been tested against the one case that cannot fail.
    ///
    /// Production always uses the default. A registered migration is never
    /// edited: GRDB records that it ran, so a change to it reaches only
    /// databases created after the change.
    static func makeMigrator(upTo lastVersion: Int = currentSchemaVersion) -> DatabaseMigrator {
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
        guard lastVersion >= 2 else { return m }

        // Schema v2: a stable volume identity.
        //
        // `device` is `st_dev`, which is assigned at mount time and renumbered
        // when an external drive is replugged; a row's *identity* has to
        // outlive that. See `VolumeIdentity` for the two ids and why both are
        // kept.
        //
        // Nullable, with no backfill, because a backfill is not possible: the
        // row records which volume it came from and nothing on the row can
        // recover a UUID for a volume that may not even be mounted. Rows stay
        // NULL until a tier 0 pass walks them and stamps the volume it found
        // them on, and until then they are matched by `device` exactly as they
        // were before this migration — see `deleteRows(under:keeping:…)`.
        //
        // No index on it. Nothing queries by volume alone: the reconcile's
        // predicate is already anchored on the `path` scope, and an index that
        // no query plan chooses is a write cost on every upsert for nothing.
        m.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE files ADD COLUMN volume_uuid TEXT")
        }
        return m
    }

    // MARK: - Writes

    /// Inserts the record, or updates the existing row with the same path.
    /// The row id is preserved across updates so that `analysis` rows written
    /// by later phases survive a re-scan.
    @discardableResult
    public func upsert(_ record: FileRecord) throws -> Int64 {
        try pool.write { db in try Self.upsertRow(db, record) }
    }

    /// The body of `upsert`, on a caller's `Database`.
    ///
    /// Extracted so that the file-operation writes — which insert a copy's row
    /// *and* mark its journal row in one transaction — reach exactly this SQL
    /// and this FTS maintenance rather than a second copy of them. `files_fts`
    /// is a standalone FTS5 table with nothing but this code maintaining it;
    /// two writers of it would drift, and the symptom would be filename search
    /// answering with names that no longer exist.
    static func upsertRow(_ db: Database, _ record: FileRecord) throws -> Int64 {
        guard let id = try Int64.fetchOne(db, sql: """
            INSERT INTO files
                (path, parent_dir, name, ext, size, mtime, device, inode, volume_uuid,
                 width, height,
                 capture_time, capture_offset, camera_make, camera_model, orientation,
                 content_hash, image_hash, image_hash_kind, phash, hashed_at, indexed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                parent_dir=excluded.parent_dir, name=excluded.name, ext=excluded.ext,
                size=excluded.size, mtime=excluded.mtime, device=excluded.device,
                inode=excluded.inode,
                -- Never back to NULL: see `setVolume(_:forPaths:)`. A pass
                -- whose volume published no UUID must not erase one an
                -- earlier pass established.
                volume_uuid = COALESCE(excluded.volume_uuid, files.volume_uuid),
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
                record.volumeUUID, record.width, record.height,
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

    /// Records a hashing attempt against the row `record` came from, and only
    /// if that row still describes the file that was hashed. Returns whether
    /// the write landed.
    ///
    /// `content` is optional because `hashed_at` records that hashing was
    /// *attempted*. A file that cannot be read must still be marked, or the
    /// tier 1 pass retries it on every run forever.
    ///
    /// There is deliberately no id-only variant. An unconditional hash writer
    /// on the one type whose integrity story is "the write must be guarded" is
    /// exactly the API that reintroduces the bug below, and a doc comment is
    /// not a type system.
    ///
    /// **The identity check is the point of this method.** Hashing a file takes
    /// long enough that the tier 1 pass must release its isolation while it
    /// runs, so a tier 0 pass can re-index the same file in between. Tier 0 has
    /// then already cleared this row's hashes — the bytes changed, so they were
    /// a lie — and an unconditional write would put them straight back with
    /// `hashed_at` set, permanently marking the row as hashed from bytes the
    /// file no longer has. Worse, SQLite reuses row ids after a delete, so a
    /// reconcile that removes the highest row and indexes a new file can hand
    /// that id to a different file entirely: an id-only write would then stamp
    /// one photo's content hash onto another photo's row. Duplicate detection
    /// deletes files on the strength of those hashes.
    ///
    /// Matching on `path`, `size` and `mtime` together is exactly the evidence
    /// tier 0 uses to decide a file is unchanged, so a write is refused in
    /// precisely the cases where the hashes might not describe the row. A
    /// refused write leaves `hashed_at` NULL, which re-queues the file — the
    /// safe direction: work repeated, never a wrong hash recorded.
    @discardableResult
    public func setHashes(for record: FileRecord, content: String?, image: String?,
                          imageKind: String?, phash: String?, hashedAt: Double) throws -> Bool {
        guard let id = record.id else { return false }
        return try pool.write { db in
            try db.execute(sql: """
                UPDATE files SET content_hash = ?, image_hash = ?, image_hash_kind = ?,
                                 phash = ?, hashed_at = ?
                WHERE id = ? AND path = ? AND size = ? AND mtime = ?
                """, arguments: [content, image, imageKind, phash, hashedAt,
                                 id, record.path, record.size, record.mtime])
            return db.changesCount == 1
        }
    }

    /// Records the volume a set of already-indexed files was just seen on, and
    /// returns how many rows that changed.
    ///
    /// This is the backfill for schema v2. The migration cannot fill
    /// `volume_uuid` — nothing on a row can name a UUID for a volume that may
    /// not even be mounted — and tier 0 re-reads a file only when its size or
    /// mtime changed, so a row written before v2 would otherwise keep no volume
    /// identity for as long as its bytes never change, which for a photo
    /// archive is forever. Instead every pass stamps the rows whose files it
    /// actually walked. `device` is stamped alongside, because a replug
    /// renumbers it and the NULL-UUID half of the reconcile's matching rule
    /// reads it.
    ///
    /// `paths` must be paths the walk *saw*. Not the whole scope: a row for a
    /// file on another volume that happens to sit under the same prefix keeps
    /// its own identity, or the next reconcile would start judging it.
    ///
    /// One transaction, chunked only to stay inside SQLite's bound-variable
    /// limit. A stamp per file would be a write transaction per file, which on
    /// a 50k library is the whole pass; rows already carrying this stamp are
    /// excluded in SQL, so a steady-state pass dirties no pages at all.
    @discardableResult
    public func setVolume(_ volume: VolumeIdentity, forPaths paths: [String]) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        let uuid = volume.uuid?.databaseValue ?? .null
        return try pool.write { db in
            var stamped = 0
            for start in stride(from: 0, to: paths.count, by: Self.stampChunkSize) {
                let slice = paths[start..<min(start + Self.stampChunkSize, paths.count)]
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                var args: [any DatabaseValueConvertible] = [uuid, volume.device]
                args.append(contentsOf: slice.map { $0 as any DatabaseValueConvertible })
                args.append(uuid)
                args.append(volume.device)
                // `COALESCE`, not a plain assignment. A nil UUID means "this
                // filesystem published none", which is a different claim from
                // "this file is not on the volume its row names" — and one pass
                // whose resource-value read came back nil would otherwise wipe
                // the identity off every row it walked and reinstate the replug
                // bug. By the matching rule a NULL row is strictly *less*
                // protected than a stamped one, so the wipe is a downgrade in
                // both directions. `device` is refreshed unconditionally:
                // `st_dev` is always readable, and a stale one is the thing
                // this write exists to repair.
                try db.execute(sql: """
                    UPDATE files SET volume_uuid = COALESCE(?, volume_uuid), device = ?
                    WHERE path IN (\(placeholders))
                      AND (volume_uuid IS NOT COALESCE(?, volume_uuid) OR device <> ?)
                    """, arguments: StatementArguments(args))
                stamped += db.changesCount
            }
            return stamped
        }
    }

    /// Paths per `setVolume` statement. Well under SQLite's default limit of
    /// 999 bound variables, which the four fixed parameters also come out of.
    private static let stampChunkSize = 500

    /// Records the new `size`/`mtime` and re-verified hashes for a row whose
    /// file was just rewritten by `MetadataWriter`.
    ///
    /// A metadata write changes the bytes, so the row's `size`, `mtime` and
    /// `content_hash` are all stale the instant exiftool returns. Left that
    /// way, tier 0 re-reads the file on the next pass and — worse — clears
    /// every hash on the row, throwing away a `phash` that is still perfectly
    /// valid because the pixels did not change. Writing the new facts here is
    /// what keeps a metadata edit from costing a re-hash of the file.
    ///
    /// `phash` is deliberately untouched: an EXIF edit does not move a pixel,
    /// so the perceptual hash on the row is still the right one.
    ///
    /// **Guarded exactly like `setHashes(for:)`, and for the same reason.** The
    /// `WHERE` matches on the `path`, `size` and `mtime` the row carried
    /// *before* the write. If a tier 0 pass re-indexed this file while exiftool
    /// was running, or if SQLite handed this rowid to a different file after a
    /// delete, the row no longer describes what was edited and the write is
    /// refused — leaving `hashed_at` as it was and the file queued for a real
    /// re-hash. Work repeated, never a wrong hash recorded. See the long
    /// comment on `setHashes(for:)`; do not relax this into an id-only update.
    ///
    /// Returns whether the write landed.
    @discardableResult
    public func recordMetadataWrite(for record: FileRecord, size: Int64, mtime: Double,
                                    content: String?, image: String?, imageKind: String?,
                                    hashedAt: Double) throws -> Bool {
        guard let id = record.id else { return false }
        return try pool.write { db in
            try db.execute(sql: """
                UPDATE files SET size = ?, mtime = ?, content_hash = ?, image_hash = ?,
                                 image_hash_kind = ?, hashed_at = ?
                WHERE id = ? AND path = ? AND size = ? AND mtime = ?
                """, arguments: [size, mtime, content, image, imageKind, hashedAt,
                                 id, record.path, record.size, record.mtime])
            return db.changesCount == 1
        }
    }

    /// Removes rows under `prefix` whose paths are not in `keeping`.
    /// FTS and `analysis` rows follow via the `files_ad` trigger and the
    /// `ON DELETE CASCADE` foreign key.
    ///
    /// `onDevice` and `onVolume` restrict the delete to rows recorded on one
    /// volume. A row from a different filesystem was not indexed from the one
    /// currently answering at this path, so a walk of that path is no evidence
    /// about it. Nil `onDevice` means every volume, which is only right when
    /// the caller has none to compare against; `onVolume` is ignored then.
    ///
    /// **The matching rule, in full: a row is prunable if its `volume_uuid`
    /// equals the root's, or its `volume_uuid` is NULL and its `device` equals
    /// the root's `st_dev`.** The first clause is the identity that matters —
    /// a volume UUID survives the unmount that renumbers `st_dev`, so a
    /// replugged drive still reconciles and a different filesystem handed the
    /// old `st_dev` still does not. The second is the pre-migration case: rows
    /// written before schema v2 carry no UUID, and matching them on `device`
    /// is exactly the behaviour they were written under.
    ///
    /// A root that publishes no UUID binds NULL for `onVolume`, which makes the
    /// first clause unsatisfiable (`volume_uuid = NULL` never holds). The rule
    /// then **collapses to the `device` comparison for rows that carry no
    /// UUID; a row already stamped with one is never matched by a nameless
    /// root.** That asymmetry is deliberate and is the safe direction: a row
    /// that names a volume is making a claim a nameless root cannot answer, so
    /// it is left alone rather than judged. It is also why `setVolume` and
    /// `upsert` write `volume_uuid` through `COALESCE` and never back to NULL —
    /// a stamped row must not be demoted into this weaker case by a single pass
    /// whose resource-value read came back nil.
    @discardableResult
    public func deleteRows(under prefix: String, keeping: Set<String>,
                           onDevice device: Int64? = nil,
                           onVolume volume: String? = nil) throws -> Int {
        let scope = try Self.pathScope(prefix)
        var args: [any DatabaseValueConvertible] = [scope.exact, scope.lower, scope.upper]
        return try pool.write { db in
            let stale = try String.fetchAll(db, sql: Self.scopedSQL(Self.pathsInScopeSQL,
                                                                    device: device, volume: volume,
                                                                    into: &args),
                                            arguments: StatementArguments(args))
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
    /// setting throws rather than matching nothing. `onDevice` and `onVolume`
    /// restrict the delete to one volume by exactly the rule spelled out on
    /// `deleteRows(under:keeping:onDevice:onVolume:)`.
    @discardableResult
    public func deleteRows(inFolder folder: String, keeping: Set<String>,
                           onDevice device: Int64? = nil,
                           onVolume volume: String? = nil) throws -> Int {
        let normalized = try Self.pathScope(folder).exact
        var args: [any DatabaseValueConvertible] = [normalized]
        return try pool.write { db in
            let stale = try String.fetchAll(db, sql: Self.scopedSQL(Self.staleInFolderSQL,
                                                                    device: device, volume: volume,
                                                                    into: &args),
                                            arguments: StatementArguments(args))
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
        return try pool.read { db in
            try String.fetchAll(db, sql: Self.pathsInScopeSQL,
                                arguments: [scope.exact, scope.lower, scope.upper])
        }
    }

    public func record(atPath path: String) throws -> FileRecord? {
        try pool.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?", arguments: [path])
        }
    }

    public func needsReindex(path: String, size: Int64, mtime: Double) throws -> Bool {
        guard let row = try record(atPath: path) else { return true }
        return row.size != size || row.mtime != mtime
    }

    public func filesMissingHashes(under prefix: String, limit: Int) throws -> [FileRecord] {
        let scope = try Self.pathScope(prefix)
        return try pool.read { db in
            try FileRecord.fetchAll(db, sql: Self.missingHashesSQL,
                                    arguments: [scope.exact, scope.lower, scope.upper, limit])
        }
    }

    /// How many files under `prefix` the tier 1 pass still has to attempt.
    ///
    /// The pass's queue *is* this predicate, so the count and the batches it
    /// drains cannot describe different sets of rows.
    public func countMissingHashes(under prefix: String) throws -> Int {
        let scope = try Self.pathScope(prefix)
        return try pool.read { db in
            try Int.fetchOne(db, sql: Self.countMissingHashesSQL,
                             arguments: [scope.exact, scope.lower, scope.upper])!
        }
    }

    // MARK: - Duplicates

    /// Rows in `query`'s scope that share an `image_hash` with another row in
    /// the same scope — or, where `image_hash` is NULL, a `content_hash`.
    ///
    /// The scope is `QueryCompiler.compileFilter`, the same boolean expression
    /// the grid's `WHERE` is built from, so "duplicates in this folder" and
    /// "duplicates in the whole library" are one code path with one set of
    /// scoping bugs rather than two.
    ///
    /// The `image_hash IS NULL` arm is spec §11's fallback: RAW, TIFF, GIF and
    /// PSD have no image-hash rule, so for those rows the only exact evidence
    /// is the whole-file digest. It is written as a *separate* arm rather than
    /// a `COALESCE(image_hash, content_hash)` key on purpose — coalescing would
    /// let a JPEG's `content_hash` collide with a RAW's into one group, and the
    /// two hashes are computed over different bytes, so equality between them
    /// means nothing.
    ///
    /// The grouping is deliberately evaluated *inside* the scope, not over the
    /// whole table: this answers "which files here are copies of each other",
    /// which is the question the duplicate view acts on. (`.hasDuplicates` in
    /// `QueryCompiler` asks the other question — "does this file have a twin
    /// anywhere" — and is library-wide for that reason.)
    ///
    /// Read-only. Nothing here repairs a row: `setHashes(for:)` is what keeps
    /// hashes attached to the file they were computed from, and a "fix it up
    /// here" path would be a second, unguarded writer on exactly the data
    /// duplicate deletion acts on.
    func duplicateCandidates(for query: SearchQuery) throws -> [FileRecord] {
        let filter = try QueryCompiler.compileFilter(query)
        return try pool.read { db in try Self.fetchCandidates(db, filter) }
    }

    /// Just enough of every row in scope that carries a perceptual hash to
    /// drive the near tier: its id, the two fields the ordering is defined on,
    /// and the hash itself.
    ///
    /// Deliberately not `[FileRecord]`. The near tier compares every pair in
    /// the scope, so it holds the whole scope in memory at once; four small
    /// fields per row rather than twenty-two keeps that affordable, and the
    /// full records are fetched afterwards only for the rows that matched.
    func perceptualHashRows(for query: SearchQuery) throws -> [PerceptualHashRow] {
        let filter = try QueryCompiler.compileFilter(query)
        return try pool.read { db in try Self.fetchPerceptualHashRows(db, filter) }
    }

    /// How many rows in scope carry a perceptual hash.
    ///
    /// Exists so the near tier can apply its ceiling before fetching: the
    /// ceiling bounds the pairwise scan's CPU, and fetching a million rows to
    /// then refuse them would make it bound nothing at all.
    func countPerceptualHashRows(for query: SearchQuery) throws -> Int {
        let filter = try QueryCompiler.compileFilter(query)
        return try pool.read { db in try Self.fetchPerceptualHashCount(db, filter) }
    }

    /// The full records for `ids`, in no particular order.
    ///
    /// Chunked because the id list is as long as the near tier's match set,
    /// which has no fixed bound, and SQLite caps the number of bound
    /// parameters in one statement.
    func records(ids: [Int64]) throws -> [FileRecord] {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in try Self.fetchRecords(db, ids: ids) }
    }

    /// Everything one duplicate report reads, taken from a single snapshot.
    ///
    /// The reason this exists rather than three calls: the store is a WAL
    /// `DatabasePool`, so every `pool.read` is its own snapshot, and a tier 1
    /// pass writing between two of them can re-hash a row. The report would
    /// then state a Hamming distance computed from a `phash` the record it
    /// hands back no longer carries — a number attached to the wrong file, in
    /// the one view whose output is a deletion. One snapshot makes that
    /// impossible rather than unlikely.
    ///
    /// `body` receives the two row sets and a fetch for full records, all
    /// bound to that snapshot, and does the grouping. It runs *inside* the read
    /// transaction, so it holds a reader connection for as long as the pairwise
    /// scan takes — bounded by `DuplicateFinder.nearTierCeiling` at a few
    /// seconds. Under WAL a reader blocks no writer; it only defers WAL
    /// checkpointing for that long, which is the right trade against reporting
    /// a distance for bytes that have changed.
    ///
    /// `nearTierCeiling` is applied here, against a `COUNT(*)` taken before any
    /// row is fetched, so an over-large scope costs one aggregate rather than
    /// materialising rows the caller is about to refuse.
    func withDuplicateScan<T>(for query: SearchQuery, nearTierCeiling ceiling: Int,
                              _ body: (DuplicateScan, (_ ids: [Int64]) throws -> [FileRecord])
                                  throws -> T) throws -> T {
        let filter = try QueryCompiler.compileFilter(query)
        return try pool.read { db in
            let candidates = try Self.fetchCandidates(db, filter)
            let count = try Self.fetchPerceptualHashCount(db, filter)
            let perceptual = count > ceiling
                ? nil
                : try Self.fetchPerceptualHashRows(db, filter)
            let scan = DuplicateScan(candidates: candidates, perceptual: perceptual,
                                     perceptualCount: count)
            return try body(scan) { ids in try Self.fetchRecords(db, ids: ids) }
        }
    }

    // MARK: - Duplicate SQL

    /// One CTE, read three times, so the filter's parameters are bound once and
    /// the scope cannot drift between the grouping and the selection.
    private static func candidatesSQL(_ filter: CompiledQuery) -> String {
        """
        WITH scoped AS (SELECT * FROM files WHERE \(filter.sql))
        SELECT * FROM scoped
        WHERE (image_hash IS NOT NULL AND image_hash IN (
                   SELECT image_hash FROM scoped WHERE image_hash IS NOT NULL
                   GROUP BY image_hash HAVING count(*) > 1))
           OR (image_hash IS NULL AND content_hash IS NOT NULL AND content_hash IN (
                   SELECT content_hash FROM scoped
                   WHERE image_hash IS NULL AND content_hash IS NOT NULL
                   GROUP BY content_hash HAVING count(*) > 1))
        """
    }

    private static func fetchCandidates(_ db: Database,
                                        _ filter: CompiledQuery) throws -> [FileRecord] {
        try FileRecord.fetchAll(db, sql: candidatesSQL(filter), arguments: filter.arguments)
    }

    private static func fetchPerceptualHashRows(
        _ db: Database, _ filter: CompiledQuery) throws -> [PerceptualHashRow] {
        let sql = """
            SELECT id, name, path, phash FROM files
            WHERE (\(filter.sql)) AND phash IS NOT NULL
            """
        return try Row.fetchAll(db, sql: sql, arguments: filter.arguments).compactMap { row in
            guard let id = row["id"] as Int64?, let phash = row["phash"] as String? else {
                return nil
            }
            return PerceptualHashRow(id: id, name: row["name"] as String? ?? "",
                                     path: row["path"] as String? ?? "", phash: phash)
        }
    }

    /// The same predicate as `fetchPerceptualHashRows`, counted rather than
    /// fetched, so the ceiling and the set it bounds cannot describe different
    /// rows.
    private static func fetchPerceptualHashCount(_ db: Database,
                                                 _ filter: CompiledQuery) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT count(*) FROM files WHERE (\(filter.sql)) AND phash IS NOT NULL",
            arguments: filter.arguments) ?? 0
    }

    private static func fetchRecords(_ db: Database, ids: [Int64]) throws -> [FileRecord] {
        var out: [FileRecord] = []
        out.reserveCapacity(ids.count)
        for chunk in stride(from: 0, to: ids.count, by: idChunkSize) {
            let slice = Array(ids[chunk..<min(chunk + idChunkSize, ids.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            out += try FileRecord.fetchAll(
                db, sql: "SELECT * FROM files WHERE id IN (\(placeholders))",
                arguments: StatementArguments(slice))
        }
        return out
    }

    /// Comfortably under SQLite's `SQLITE_MAX_VARIABLE_NUMBER`, which is 999 on
    /// the oldest builds this could meet and 32766 on current ones.
    private static let idChunkSize = 500

    public func search(_ query: SearchQuery) throws -> [FileRecord] {
        let compiled = try QueryCompiler.compile(query)
        return try pool.read { db in
            try FileRecord.fetchAll(db, sql: compiled.sql, arguments: compiled.arguments)
        }
    }

    public func count() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM files")! }
    }

    // MARK: - Facets

    /// Counts for the filter panel, over the *whole* result set of `query`.
    ///
    /// Whole, not the page on screen: `query.limit` and `query.offset` are
    /// ignored — `QueryCompiler.compileFilter` never emits them — because a
    /// count that described only the visible page would tell the user that
    /// ticking `.png` would find 3 files when it would find 3,000.
    ///
    /// A `NULL` or empty bucket is not a bucket. "How many files have no
    /// camera" is a different question from "how many are from a Canon", it
    /// has no filter control behind it in phase 1, and an unlabelled row in
    /// the panel would be indistinguishable from a rendering bug.
    ///
    /// Throws whatever the compiler throws — `IndexStoreError.invalidScope`
    /// for a scope that is empty or relative, and
    /// `QueryCompilerError.predicateTooDeep` — rather than reporting zero
    /// counts, because zero is a legitimate answer and must not double as an
    /// error signal.
    public func facets(for query: SearchQuery) throws -> Facets {
        let filter = try QueryCompiler.compileFilter(query)
        return try pool.read { db in
            // `column` is a compiler-side literal chosen below, never user
            // text; every value in the query is still a bound parameter.
            func counts(_ column: String) throws -> [String: Int] {
                let sql = """
                    SELECT \(column) AS bucket, count(*) AS n FROM files
                    WHERE (\(filter.sql)) AND \(column) IS NOT NULL AND \(column) <> ''
                    GROUP BY bucket
                    """
                var result: [String: Int] = [:]
                for row in try Row.fetchAll(db, sql: sql, arguments: filter.arguments) {
                    guard let bucket = row["bucket"] as String? else { continue }
                    result[bucket] = row["n"] as Int? ?? 0
                }
                return result
            }
            let total = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM files WHERE \(filter.sql)",
                arguments: filter.arguments) ?? 0
            return Facets(byExtension: try counts("ext"),
                          byCamera: try counts("camera_make"),
                          total: total)
        }
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
    /// The same predicate as `missingHashesSQL`, counted rather than fetched,
    /// so the tier 1 pass's total and its batches cannot drift apart.
    static let countMissingHashesSQL = """
        SELECT count(*) FROM files WHERE hashed_at IS NULL AND \(scopePredicateSQL)
        """

    /// Appends the optional volume restriction to a scope query, keeping the
    /// bind order in step with the SQL. One copy, so the two delete paths
    /// cannot drift apart on the check that guards against reconciling
    /// against the wrong volume. The rule itself is documented on
    /// `deleteRows(under:keeping:onDevice:onVolume:)`.
    private static func scopedSQL(_ sql: String, device: Int64?, volume: String?,
                                  into args: inout [any DatabaseValueConvertible]) -> String {
        guard let device else { return sql }
        // Bound even when nil, so the SQL is one string rather than two: with
        // NULL bound, `volume_uuid = ?` is never true and the predicate is the
        // `device` comparison alone.
        args.append(volume?.databaseValue ?? .null)
        args.append(device)
        return sql + " AND (volume_uuid = ? OR (volume_uuid IS NULL AND device = ?))"
    }

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
        try pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table')"))
        }
    }

    func ftsRowCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM files_fts")! }
    }

    /// Row ids of files whose FTS row matches `pattern` — what Task 13's
    /// filename search actually depends on.
    func ftsMatchRowIDs(_ pattern: String) throws -> [Int64] {
        try pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM files_fts WHERE files_fts MATCH ? ORDER BY rowid",
                               arguments: [pattern])
        }
    }

    /// Raw SQL escape hatches so tests can exercise schema-level behavior
    /// (triggers, cascades) that the public API deliberately does not expose.
    /// Runs outside an automatic transaction so statements like
    /// `PRAGMA foreign_keys`, which are no-ops mid-transaction, take effect.
    func testExecute(sql: String, arguments: StatementArguments = []) throws {
        try pool.writeWithoutTransaction { db in try db.execute(sql: sql, arguments: arguments) }
    }

    /// One write transaction, held open for as long as `body` runs. The
    /// difference from `testExecute` is *duration*: `testExecute` runs a single
    /// statement and lets the writer connection go, which is no use to the test
    /// that has to prove a read does not queue behind a write still in flight.
    /// That test needs the transaction demonstrably open while it times its
    /// read, and the only way to have that by construction rather than by
    /// racing a clock is to let the test body decide when to commit.
    ///
    /// GRDB opens and commits the transaction around `body`, so this leaves no
    /// dangling `BEGIN` on a pooled connection — the reason the test could not
    /// simply reach for `testExecute`.
    func testWrite(_ body: (Database) throws -> Void) throws {
        try pool.write { db in try body(db) }
    }

    /// One read transaction on a *reader* connection, held open for as long
    /// as `body` runs — `testRead`'s reason to exist alongside `testExecute`
    /// and `testWrite` is the same as `testWrite`'s reason to exist alongside
    /// `testExecute`: a test that has to prove something about a WAL
    /// snapshot still being open (a checkpoint that cannot reclaim its
    /// frames while a reader holds one) needs the read demonstrably in
    /// progress, not a query that runs and releases before the test can
    /// observe it.
    func testRead<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.read { db in try body(db) }
    }

    /// Reads on one of the pool's *reader* connections, not the writer that
    /// `testExecute` uses, so a connection-scoped pragma set through one is not
    /// visible through the other. `journal_mode` is a property of the file and
    /// reads the same either way; `foreign_keys` is per-connection and does not.
    func testFetchOne<T: DatabaseValueConvertible>(sql: String, arguments: StatementArguments = []) throws -> T? {
        try pool.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    func queryPlan(sql: String, arguments: StatementArguments = []) throws -> [String] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { $0["detail"] as String? ?? "" }
        }
    }
}

// MARK: - Integrity

// An extension rather than free functions, because both members need `pool`
// (or, for `rebuild`, the initializer that opens it), and nothing outside
// `IndexStore` gets to hold a `DatabasePool` and bypass the API above.
extension IndexStore {
    /// Runs SQLite's own consistency check against the file backing this
    /// store.
    ///
    /// `PRAGMA quick_check` rather than `integrity_check`: `integrity_check`
    /// also cross-checks every index against its table, which is real work on
    /// a database with tens of thousands of rows. This check runs once at
    /// every launch, not only when corruption is already suspected, so it has
    /// to be cheap on the common case (a healthy database) as well as
    /// sensitive on the rare one. `quick_check` skips the index cross-checks
    /// but still walks every page verifying header fields, page links and
    /// free-list structure — exactly what actually goes wrong when a file is
    /// truncated, torn by a crash mid-write, or overwritten by something else
    /// entirely, which is the corruption this app can actually encounter.
    ///
    /// A thrown error (the file cannot even be opened as SQLite) counts as
    /// corrupt too, described by the error rather than by a generic message,
    /// so a bug report says what actually failed.
    public func checkIntegrity() -> IndexHealth {
        do {
            let result = try pool.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check")
            }
            return result == "ok" ? .ok : .corrupt(result ?? "quick_check returned no result")
        } catch {
            return .corrupt(error.localizedDescription)
        }
    }

    /// Discards the index at `url` — including its `-wal` and `-shm`
    /// sidecars — and opens a fresh, empty one in its place.
    ///
    /// Always safe to call: the index is a derived cache. Every row in it is
    /// recomputed the next time its folder is scanned, so nothing the user
    /// created is lost, only time — which is exactly why a corrupt index gets
    /// a one-button rebuild rather than a repair tool.
    ///
    /// The sidecars are not optional cleanup. A corrupt main file is often
    /// corrupt precisely because a write-ahead log or shared-memory segment
    /// next to it was left in a bad state (a crash mid-checkpoint, a filesystem
    /// fault); opening a brand-new database file while leaving those in place
    /// lets SQLite replay that same bad log into the replacement on its first
    /// checkpoint, reintroducing the corruption the rebuild was supposed to
    /// clear.
    public static func rebuild(at url: URL) throws -> IndexStore {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if manager.fileExists(atPath: sidecar.path) {
                try manager.removeItem(at: sidecar)
            }
        }
        return try IndexStore(url: url)
    }
}
