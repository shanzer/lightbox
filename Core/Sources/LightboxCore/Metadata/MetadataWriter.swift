import Foundation

/// Writes the metadata fields of spec §9, through exiftool.
///
/// **The only code in Lightbox that shells out.** Reads stay on ImageIO —
/// indexing 50k files must not fork 50k subprocesses (`MetadataReader`) — but
/// there is no in-process API that writes EXIF, IPTC and XMP consistently, and
/// hand-rolling three container formats is exactly how files get corrupted.
///
/// ## The mapping (spec §9: "documented in the code")
///
/// Writing "description" into only one tag family produces a file that
/// different readers disagree about, so each logical field writes a *set*. The
/// set is not hand-assembled here: exiftool's **MWG composite tags** are its own
/// implementation of the Metadata Working Group rules, and they already know
/// which EXIF, IPTC and XMP tags belong together and in what precedence. Using
/// them means the sync rules are maintained by exiftool rather than re-derived
/// (and drifted) here.
///
/// | Logical field | Written as | Reaches |
/// |---|---|---|
/// | Description | `-MWG:Description` | `EXIF:ImageDescription`, `IPTC:Caption-Abstract`, `XMP-dc:description` |
/// | Keywords | `-MWG:Keywords` (cleared, then one per value) | `IPTC:Keywords`, `XMP-dc:subject` |
/// | Artist | `-MWG:Creator` | `EXIF:Artist`, `IPTC:By-line`, `XMP-dc:creator` |
/// | Copyright | `-MWG:Copyright` | `EXIF:Copyright`, `IPTC:CopyrightNotice`, `XMP-dc:rights` |
/// | Rating | `-MWG:Rating` | `XMP-xmp:Rating` |
/// | Capture time | `-MWG:DateTimeOriginal` + `-EXIF:OffsetTimeOriginal` + `-EXIF:SubSecTimeOriginal` | `EXIF:DateTimeOriginal`, `IPTC:DateCreated`/`TimeCreated`, `XMP-photoshop:DateCreated` |
/// | Label | `-XMP-xmp:Label` | `XMP-xmp:Label` |
/// | GPS | `-EXIF:GPSLatitude`/`Ref`, `-EXIF:GPSLongitude`/`Ref`, `-XMP-exif:GPSLatitude`/`Longitude` | `GPS:*`, `XMP-exif:*` |
///
/// Two fields are hand-mapped because MWG does not cover them. **Label** has no
/// MWG composite and lives only in XMP. **GPS** has none either, and the two
/// families disagree on representation: EXIF stores an unsigned magnitude plus
/// a `N`/`S`/`E`/`W` reference, XMP stores a signed decimal. Writing one and
/// not the other leaves the two disagreeing about the hemisphere.
///
/// Every write also carries `-IPTCDigest=new`. Without it the Photoshop IPTC
/// digest goes stale the moment IPTC changes, and every later MWG *read* —
/// exiftool's, Bridge's, Lightroom's — declares "IPTCDigest is not current, XMP
/// may be out of sync" and silently prefers a different family than the one
/// just written.
///
/// ## Write, verify, then commit (spec §9, constraint 3)
///
/// exiftool writes with its `_original` backup; the tags are read back and
/// compared against what was asked for; only a match removes the backup. A
/// mismatch restores the backup and reports a per-item failure, so a batch
/// never leaves a half-written file behind silently.
///
/// ## RAW (constraint 2)
///
/// Anything `MediaKind.raw` gets a `<basename>.xmp` sidecar and its container is
/// never opened for writing. Everything else — JPEG, PNG, WebP, HEIC, TIFF,
/// GIF, PSD — is edited in place.
public actor MetadataWriter {
    /// Whether exiftool can be used at all. Resolved at first use and cached,
    /// so a batch of 500 files does not fork 500 `-ver` probes.
    ///
    /// Tests gate on exactly this, so a skip guard cannot drift away from the
    /// lookup the writer performs (CONTRIBUTING: "its skip guard must consult
    /// the same path the code under test reads").
    public static var availability: ExiftoolAvailability { availabilityCache.value }

    /// Re-runs the lookup and replaces the cached answer.
    ///
    /// A cached `static let` and an explanation reading "reopen the window" do
    /// not go together: reopening a window re-reads the cache, not `PATH`, so
    /// a user who installs exiftool and follows the instruction sees the same
    /// message and concludes the app is broken. Rather than weaken the sentence
    /// to "restart Lightbox", the cache is refreshable, so the inspector can
    /// offer a *Try Again* that actually tries again.
    @discardableResult
    public static func recheckAvailability() -> ExiftoolAvailability {
        availabilityCache.recheck()
    }

    private static let availabilityCache = AvailabilityCache()

    /// A lock rather than a `static let`, purely so `recheckAvailability` can
    /// exist. Contended once per batch at most.
    private final class AvailabilityCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ExiftoolAvailability?

        var value: ExiftoolAvailability {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            let fresh = ExiftoolLocator.check()
            cached = fresh
            return fresh
        }

        func recheck() -> ExiftoolAvailability {
            let fresh = ExiftoolLocator.check()
            lock.lock()
            cached = fresh
            lock.unlock()
            return fresh
        }
    }

    private let exiftool: ExiftoolAvailability
    private let hasher: any FileHashing
    private var runner: ExiftoolRunner?

    /// Test seam: when set, stands in for the read-back step and returns the
    /// tag keys that "did not match".
    ///
    /// The restore-from-backup path is the most consequential code here and the
    /// hardest to provoke honestly — every container this app writes stores
    /// what exiftool tells it to, so a real mismatch needs a real corruption.
    /// Rather than leave spec §9's constraint 3 untested, the read-back is
    /// replaceable. Nothing outside the test target sets it.
    private var verificationOverride: (@Sendable (URL) -> [String])?

    func setVerificationOverride(_ hook: (@Sendable (URL) -> [String])?) {
        verificationOverride = hook
    }

    public init(availability: ExiftoolAvailability = MetadataWriter.availability,
                hasher: any FileHashing = FileHasher()) {
        self.exiftool = availability
        self.hasher = hasher
    }

    // No `deinit` here: an actor's deinit is nonisolated and cannot touch a
    // non-`Sendable` stored property. The `-stay_open` process is torn down by
    // `ExiftoolRunner`'s own deinit when this actor releases it — which runs on
    // whichever cooperative-pool thread drops the last reference, so that
    // teardown must be *bounded* rather than merely correct. It is; see
    // `ExiftoolRunner.endProcess`, which exists because a `waitUntilExit` there
    // was sampled blocking a pool thread for ten minutes. `close()` remains for
    // a caller that wants the fork gone sooner and on a thread of its choosing.

    /// Releases the long-lived `-stay_open` process.
    public func close() {
        runner?.shutdown()
        runner = nil
    }

    /// Applies `edit` to each URL. Never throws: a batch returns a per-item
    /// result list (spec §11) so one unwritable file does not abandon the rest.
    /// - Parameter progress: called after each item with `(completed, total)`,
    ///   so a sheet can move without waiting for the batch. Called on the
    ///   actor, once per item, in order.
    @discardableResult
    public func write(_ edit: MetadataEdit, to urls: [URL],
                      options: WriteOptions = WriteOptions(),
                      updating store: IndexStore? = nil,
                      progress: (@Sendable (Int, Int) -> Void)? = nil) -> [WriteOutcome] {
        guard case .available(let path, _) = exiftool else {
            let reason = exiftool.explanation ?? "exiftool is unavailable"
            return urls.enumerated().map { index, url in
                progress?(index + 1, urls.count)
                return WriteOutcome(source: url,
                                    result: .failure(.exiftoolUnavailable(reason)))
            }
        }
        if let validation = Self.validate(edit) {
            return urls.enumerated().map { index, url in
                progress?(index + 1, urls.count)
                return WriteOutcome(source: url, result: .failure(validation))
            }
        }

        let live: ExiftoolRunner
        if let runner {
            live = runner
        } else {
            live = ExiftoolRunner(executable: path)
            runner = live
        }

        var outcomes: [WriteOutcome] = []
        outcomes.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            // Cancellation is checked *between* items, never inside one: a
            // half-written file is worse than an unwritten one, and the write /
            // verify / commit sequence for a single item has to finish. Items
            // already done stay done — a metadata edit is not a transaction.
            if Task.isCancelled {
                outcomes.append(WriteOutcome(source: url, result: .failure(.cancelled)))
                progress?(index + 1, urls.count)
                continue
            }
            do {
                let success = try writeOne(edit, to: url, options: options,
                                           runner: live, store: store)
                outcomes.append(WriteOutcome(source: url, result: .success(success)))
            } catch let error as MetadataWriteError {
                outcomes.append(WriteOutcome(source: url, result: .failure(error)))
            } catch {
                outcomes.append(WriteOutcome(
                    source: url,
                    result: .failure(.exiftoolFailed(String(describing: error)))))
            }
            progress?(index + 1, urls.count)
        }
        return outcomes
    }

    // MARK: - Validation

    /// The API-level refusals. Spec §9's constraints are enforced here rather
    /// than in the inspector: a UI that merely discourages a zoneless capture
    /// time is a UI that writes one the first time a batch path skips it.
    static func validate(_ edit: MetadataEdit) -> MetadataWriteError? {
        if edit.isEmpty { return .nothingToWrite }
        if let capture = edit.captureTime {
            guard let offset = capture.offset,
                  !offset.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .captureTimeRequiresTimeZone
            }
            // Reuses the reader's parser deliberately: an offset this writer
            // emits that the reader cannot parse would round-trip to a
            // different instant, which is the bug the constraint exists to
            // prevent.
            guard MetadataReader.timeZone(fromOffset: offset) != nil else {
                return .invalidTimeZoneOffset(offset)
            }
            if let sub = capture.subSeconds {
                guard !sub.isEmpty, sub.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    return .invalidSubSeconds(sub)
                }
            }
        }
        if let rating = edit.rating, !(0...5).contains(rating) {
            return .invalidRating(rating)
        }
        if let gps = edit.gps {
            let latitudeOK = gps.latitude >= -90 && gps.latitude <= 90
            let longitudeOK = gps.longitude >= -180 && gps.longitude <= 180
            guard latitudeOK, longitudeOK, gps.latitude.isFinite, gps.longitude.isFinite else {
                return .invalidCoordinate(latitude: gps.latitude, longitude: gps.longitude)
            }
        }
        return nil
    }

    // MARK: - One file

    private func writeOne(_ edit: MetadataEdit, to url: URL, options: WriteOptions,
                          runner: ExiftoolRunner, store: IndexStore?) throws -> WriteSuccess {
        guard let mediaType = MediaType.forExtension(url.pathExtension) else {
            throw MetadataWriteError.unsupportedFormat(url.pathExtension)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataWriteError.fileMissing(url.path)
        }

        let isSidecar = mediaType.kind == .raw
        let destination = isSidecar ? Self.sidecarURL(for: url) : url
        let sidecarExistedBefore = isSidecar
            && FileManager.default.fileExists(atPath: destination.path)

        // The record is read *before* the write, so the guard on the index
        // update compares against the size/mtime the row is supposed to still
        // carry. Reading it afterwards would compare the row against the file
        // this very write just changed, which proves nothing.
        // "The row is not there" and "the row could not be read" both mean the
        // index will *not* be updated for this file. Neither is swallowed: both
        // fall through to the `indexRowNotUpdated` warning below, because a
        // silently skipped update is how an index drifts out of step with the
        // disk it describes.
        var recordBefore: FileRecord?
        if let store { recordBefore = (try? store.record(atPath: url.path)) ?? nil }

        // A sidecar write must leave the container byte-identical, so its stat
        // is captured to compare against; an in-place write needs the
        // pre-write image hash instead, to compare against after. Neither
        // path pays for the other's read.
        let containerBefore = isSidecar ? try? Self.stat(url) : nil

        // **Not `try?`.** A pre-write hash that cannot be read leaves the
        // tripwire below with nothing to compare against, and the post-write
        // hash then goes into the index on trust — for a value the duplicate
        // view deletes on. A mid-read I/O error on an external volume is
        // exactly this project's scenario, so the item fails here, before
        // anything is written, rather than being recorded unverified.
        var hashesBefore: FileHashes?
        if !isSidecar {
            do {
                hashesBefore = try hasher.hashes(for: url, mediaType: mediaType)
            } catch {
                throw MetadataWriteError.imageHashUnreadable(url.path)
            }
        }

        // Not "is this a sidecar" but "what can this destination hold": a GIF
        // is written in place yet carries XMP only.
        let families: TagFamilies = isSidecar ? .xmpOnly : .of(mediaType.kind)
        let plan = Self.plan(edit, families: families, options: options)

        // **A pre-existing `_original` is not our rollback, and it is not ours
        // to delete.** exiftool declines to overwrite an existing backup and
        // still reports success — measured on 13.55: with a stale `_original`
        // present it prints "1 image files updated" and exits 0, leaving the
        // stale file untouched. A writer that stats the backup path *after* the
        // write therefore mistakes somebody else's leftover (a crash between
        // write and commit, an interrupted run, another tool) for its own
        // backup, and a verification failure then copies that leftover over the
        // photo. So the path is cleared beforehand and the leftover put back
        // afterwards, exactly as found.
        let backup = URL(fileURLWithPath: destination.path + "_original")
        // A run killed between stashing and restoring leaves its stash behind.
        // Swept here rather than left to accumulate beside the photo, and named
        // in a warning so the sweep is visible rather than silent.
        let sweptStashes = Self.sweepOrphanedStashes(besides: backup)
        let stashedBackup = try Self.stashAside(backup)
        defer {
            if let stashedBackup {
                // The restore and commit paths both consume `backup` first, so
                // this lands on a free path. If it somehow does not, the
                // leftover stays under its stash name rather than being lost.
                try? FileManager.default.moveItem(at: stashedBackup, to: backup)
            }
        }

        let run: ExiftoolRun
        do {
            run = try runner.run(arguments: plan.writeArguments, files: [destination.path])
        } catch {
            throw MetadataWriteError.exiftoolFailed(String(describing: error))
        }
        guard run.ok else {
            throw MetadataWriteError.exiftoolFailed(Self.diagnostic(run))
        }

        // With the path cleared beforehand, anything here now is unambiguously
        // this run's backup. Its absence means exiftool made none — it found
        // nothing to change — and there is nothing to roll back to.
        let ourBackup = FileManager.default.fileExists(atPath: backup.path) ? backup : nil
        let createdSidecar = isSidecar && !sidecarExistedBefore

        /// Puts the file back and throws the error that says what actually
        /// happened to it. Never called with a file this run did not create.
        ///
        /// The three outcomes are kept distinct because they call for different
        /// actions: the file was restored, the file could not be restored, or
        /// there was never a backup and the file is as exiftool left it.
        /// `restore` is a no-op when there is no backup, so reporting
        /// `verificationFailed` — which promises restoration — off the back of
        /// it would tell the user their photo is fine when it may not be.
        ///
        /// - Parameter reason: the error to throw when the rollback *succeeded*.
        func rollBack(tags: [String], reason: MetadataWriteError) throws -> Never {
            let restored: Bool
            do {
                restored = try Self.restore(backup: ourBackup, to: destination,
                                            created: createdSidecar, tags: tags)
            } catch let error as MetadataWriteError {
                throw error
            }
            guard restored else {
                throw MetadataWriteError.verificationFailedWithoutRollback(tags: tags)
            }
            throw reason
        }

        // Verify.
        let mismatched: [String]
        do {
            if let verificationOverride {
                mismatched = verificationOverride(destination)
            } else {
                mismatched = try Self.verify(plan.expectations, at: destination, runner: runner)
            }
        } catch {
            try rollBack(tags: ["<read-back failed>"],
                         reason: .exiftoolFailed(String(describing: error)))
        }
        if !mismatched.isEmpty {
            try rollBack(tags: mismatched, reason: .verificationFailed(mismatched))
        }

        // The tripwire, checked *before* the commit so it can still roll back.
        // `image_hash` is defined to survive a metadata edit (HANDOFF §6); if it
        // moved, the format's rule in `Hashing/` is wrong, duplicate grouping
        // for that format is unreliable, and duplicate detection deletes files
        // on the strength of those hashes. Rolled back and reported, never
        // repaired here — those rules are binding.
        var hashesAfter: FileHashes?
        if !isSidecar {
            do {
                hashesAfter = try hasher.hashes(for: url, mediaType: mediaType)
            } catch {
                try rollBack(tags: ["<rehash failed>"],
                             reason: .imageHashUnreadable(url.path))
            }
            if let was = hashesBefore?.imageHash, let now = hashesAfter?.imageHash, was != now {
                let kind = hashesAfter?.imageHashKind ?? mediaType.kind.rawValue
                try rollBack(tags: ["image_hash"],
                             reason: .imageHashChanged(kind: kind, before: was, after: now))
            }
        }

        // Commit: this run's backup only goes away once the tags have been read
        // back *and* the image hash has been shown to have survived.
        if let ourBackup { try? FileManager.default.removeItem(at: ourBackup) }

        var warnings: [WriteWarning] = sweptStashes.map { .sweptOrphanedBackup($0) }
        let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { warnings.append(.exiftool(stderr)) }

        guard !isSidecar else {
            // A sidecar write must not have touched the container at all.
            if let before = containerBefore, let after = try? Self.stat(url),
               before != after {
                warnings.append(.containerModifiedBySidecarWrite)
            }
            return WriteSuccess(written: destination, target: .sidecar(destination),
                                rehash: nil, warnings: warnings)
        }

        let after = try Self.stat(url)
        // Non-nil for every in-place write: the tripwire above computed it.
        guard let hashesAfter else {
            throw MetadataWriteError.exiftoolFailed("rehash after write was skipped")
        }

        // HEIC, TIFF, GIF and PSD have no image-hash rule in version 1, so the
        // only hash of theirs that survives a metadata edit is the `phash`.
        // The write is correct; the file is just temporarily ungrouped from
        // its exact copies, and the inspector should be able to say so.
        if hashesAfter.imageHash == nil {
            warnings.append(.imageHashUnavailable(kind: mediaType.kind.rawValue))
        }

        let rehash = RehashResult(size: after.size, mtime: after.mtime,
                                  contentHash: hashesAfter.contentHash,
                                  imageHash: hashesAfter.imageHash,
                                  imageHashKind: hashesAfter.imageHashKind)

        if store != nil {
            var landed = false
            if let record = recordBefore {
                landed = (try? store?.recordMetadataWrite(
                    for: record, size: rehash.size, mtime: rehash.mtime,
                    content: rehash.contentHash, image: rehash.imageHash,
                    imageKind: rehash.imageHashKind,
                    hashedAt: Date().timeIntervalSince1970)) ?? false == true
            }
            if !landed { warnings.append(.indexRowNotUpdated) }
        }

        return WriteSuccess(written: url, target: .inPlace, rehash: rehash, warnings: warnings)
    }

    /// `IMG_0001.CR2` → `IMG_0001.xmp`, the convention Lightroom and Bridge use.
    static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: - Backup and restore

    /// Moves anything already sitting at exiftool's `_original` path out of the
    /// way, returning where it went, or nil if the path was already free.
    ///
    /// A sibling name in the same directory, so the move is a rename within one
    /// filesystem and cannot half-succeed. Throws rather than proceeding if the
    /// path cannot be cleared: a write with no rollback available is refused
    /// before it starts, not performed and hoped over.
    static func stashAside(_ backup: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: backup.path) else { return nil }
        let stash = URL(fileURLWithPath:
            backup.path + stashSuffixPrefix + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: backup, to: stash)
        } catch {
            throw MetadataWriteError.backupPathOccupied(backup.path)
        }
        return stash
    }

    /// - Returns: whether the file was actually put back. False means there
    ///   was nothing to put it back from, which the caller must report
    ///   differently — this used to be a silent no-op, and every caller then
    ///   claimed a rollback that had not happened.
    @discardableResult
    static func restore(backup: URL?, to destination: URL, created: Bool,
                        tags: [String]) throws -> Bool {
        if let backup, FileManager.default.fileExists(atPath: backup.path) {
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: backup)
            } catch {
                throw MetadataWriteError.restoreFailed(tags: tags,
                                                       reason: String(describing: error))
            }
            return true
        }
        if created {
            // A sidecar exiftool had to create has no `_original`; undoing the
            // write means removing the file it made.
            do { try FileManager.default.removeItem(at: destination) } catch {
                throw MetadataWriteError.restoreFailed(tags: tags,
                                                       reason: String(describing: error))
            }
            return true
        }
        return false
    }

    /// The suffix a stashed pre-existing backup is parked under.
    static let stashSuffixPrefix = ".lightbox-stash-"

    /// Removes `<backup>.lightbox-stash-*` siblings left by a run that died
    /// between stashing a pre-existing backup and putting it back, returning
    /// the names removed.
    ///
    /// Matched on the exact suffix pattern and nothing looser: a file merely
    /// *near* the backup path belongs to somebody else.
    static func sweepOrphanedStashes(besides backup: URL) -> [String] {
        let directory = backup.deletingLastPathComponent()
        let prefix = backup.lastPathComponent + stashSuffixPrefix
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path) else { return [] }
        var swept: [String] = []
        for entry in entries where entry.hasPrefix(prefix) && entry.count > prefix.count {
            let url = directory.appendingPathComponent(entry)
            if (try? FileManager.default.removeItem(at: url)) != nil { swept.append(entry) }
        }
        return swept.sorted()
    }

    struct Stat: Equatable {
        var size: Int64
        var mtime: Double
    }

    static func stat(_ url: URL) throws -> Stat {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else {
            throw MetadataWriteError.fileMissing(url.path)
        }
        return Stat(size: size, mtime: modified.timeIntervalSince1970)
    }

    private static func diagnostic(_ run: ExiftoolRun) -> String {
        let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "exiftool reported no output" : stdout
    }
}
