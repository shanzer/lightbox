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
    /// Whether exiftool can be used at all. Resolved once, at first use, and
    /// cached for the life of the process.
    ///
    /// Tests gate on exactly this, so a skip guard cannot drift away from the
    /// lookup the writer performs (CONTRIBUTING: "its skip guard must consult
    /// the same path the code under test reads").
    public static let availability: ExiftoolAvailability = ExiftoolLocator.check()

    private let exiftool: ExiftoolAvailability
    private let hasher: FileHasher
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
                hasher: FileHasher = FileHasher()) {
        self.exiftool = availability
        self.hasher = hasher
    }

    // No `deinit` here: an actor's deinit is nonisolated and cannot touch a
    // non-`Sendable` stored property. The `-stay_open` process is torn down by
    // `ExiftoolRunner`'s own deinit when this actor releases it, so nothing
    // leaks; `close()` exists for a caller that wants the fork gone sooner.

    /// Releases the long-lived `-stay_open` process.
    public func close() {
        runner?.shutdown()
        runner = nil
    }

    /// Applies `edit` to each URL. Never throws: a batch returns a per-item
    /// result list (spec §11) so one unwritable file does not abandon the rest.
    @discardableResult
    public func write(_ edit: MetadataEdit, to urls: [URL],
                      options: WriteOptions = WriteOptions(),
                      updating store: IndexStore? = nil) -> [WriteOutcome] {
        guard case .available(let path, _) = exiftool else {
            let reason = exiftool.explanation ?? "exiftool is unavailable"
            return urls.map {
                WriteOutcome(source: $0, result: .failure(.exiftoolUnavailable(reason)))
            }
        }
        if let validation = Self.validate(edit) {
            return urls.map { WriteOutcome(source: $0, result: .failure(validation)) }
        }

        let live: ExiftoolRunner
        if let runner {
            live = runner
        } else {
            live = ExiftoolRunner(executable: path)
            runner = live
        }

        return urls.map { url in
            do {
                let success = try writeOne(edit, to: url, options: options,
                                           runner: live, store: store)
                return WriteOutcome(source: url, result: .success(success))
            } catch let error as MetadataWriteError {
                return WriteOutcome(source: url, result: .failure(error))
            } catch {
                return WriteOutcome(source: url,
                                    result: .failure(.exiftoolFailed(String(describing: error))))
            }
        }
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
        var recordBefore: FileRecord?
        if let store { recordBefore = try? store.record(atPath: url.path) }

        // A sidecar write must leave the container byte-identical, so its stat
        // is captured to compare against; an in-place write needs the
        // pre-write image hash instead, to compare against after. Neither
        // path pays for the other's read.
        let containerBefore = isSidecar ? try? Self.stat(url) : nil
        let hashesBefore = isSidecar ? nil : try? hasher.hashes(for: url, mediaType: mediaType)

        let plan = Self.plan(edit, target: isSidecar ? .sidecar(destination) : .inPlace,
                             options: options)

        let run: ExiftoolRun
        do {
            run = try runner.run(arguments: plan.writeArguments, files: [destination.path])
        } catch {
            throw MetadataWriteError.exiftoolFailed(String(describing: error))
        }
        guard run.ok else {
            throw MetadataWriteError.exiftoolFailed(Self.diagnostic(run))
        }

        let backup = URL(fileURLWithPath: destination.path + "_original")
        let hasBackup = FileManager.default.fileExists(atPath: backup.path)

        // Verify.
        let mismatched: [String]
        do {
            if let verificationOverride {
                mismatched = verificationOverride(destination)
            } else {
                mismatched = try Self.verify(plan.expectations, at: destination, runner: runner)
            }
        } catch {
            try Self.restore(backup: hasBackup ? backup : nil, to: destination,
                             created: !sidecarExistedBefore && isSidecar,
                             tags: ["<read-back failed>"])
            throw MetadataWriteError.exiftoolFailed(String(describing: error))
        }
        guard mismatched.isEmpty else {
            try Self.restore(backup: hasBackup ? backup : nil, to: destination,
                             created: !sidecarExistedBefore && isSidecar,
                             tags: mismatched)
            throw MetadataWriteError.verificationFailed(mismatched)
        }

        // Commit: the backup only goes away once the tags have been read back.
        if hasBackup { try? FileManager.default.removeItem(at: backup) }

        var warnings: [WriteWarning] = []
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
        let hashesAfter: FileHashes
        do {
            hashesAfter = try hasher.hashes(for: url, mediaType: mediaType)
        } catch {
            throw MetadataWriteError.exiftoolFailed("rehash after write failed: \(error)")
        }

        // The tripwire. `image_hash` is defined to survive a metadata edit; if
        // it moved, the format's rule in `Hashing/` is wrong. Reported, never
        // repaired here — HANDOFF §6 makes those rules binding.
        if let before = hashesBefore?.imageHash, let now = hashesAfter.imageHash,
           before != now {
            warnings.append(.imageHashChanged(kind: hashesAfter.imageHashKind ?? mediaType.ext,
                                              before: before, after: now))
        }

        let rehash = RehashResult(size: after.size, mtime: after.mtime,
                                  contentHash: hashesAfter.contentHash,
                                  imageHash: hashesAfter.imageHash,
                                  imageHashKind: hashesAfter.imageHashKind)

        if let store, let record = recordBefore {
            let landed = (try? store.recordMetadataWrite(
                for: record, size: rehash.size, mtime: rehash.mtime,
                content: rehash.contentHash, image: rehash.imageHash,
                imageKind: rehash.imageHashKind,
                hashedAt: Date().timeIntervalSince1970)) ?? false
            if !landed { warnings.append(.indexRowNotUpdated) }
        }

        return WriteSuccess(written: url, target: .inPlace, rehash: rehash, warnings: warnings)
    }

    /// `IMG_0001.CR2` → `IMG_0001.xmp`, the convention Lightroom and Bridge use.
    static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: - Backup and restore

    static func restore(backup: URL?, to destination: URL, created: Bool,
                                tags: [String]) throws {
        if let backup, FileManager.default.fileExists(atPath: backup.path) {
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: backup)
            } catch {
                throw MetadataWriteError.restoreFailed(tags: tags,
                                                       reason: String(describing: error))
            }
            return
        }
        if created {
            // A sidecar exiftool had to create has no `_original`; undoing the
            // write means removing the file it made.
            do { try FileManager.default.removeItem(at: destination) } catch {
                throw MetadataWriteError.restoreFailed(tags: tags,
                                                       reason: String(describing: error))
            }
        }
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
