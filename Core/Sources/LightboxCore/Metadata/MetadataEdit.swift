import Foundation

/// A capture instant together with the zone it was captured in.
///
/// `offset` is optional in the *type* only so that "no zone" is a value the
/// caller can hand over and have refused, rather than one that cannot be
/// spelled at all. `MetadataWriter` rejects an edit whose capture time has no
/// zone, or whose zone is not the EXIF `±HH:MM` form — spec §9, constraint 1.
/// A `DateTimeOriginal` with no `OffsetTimeOriginal` means a different instant
/// on every machine that reads it, and that is worse than not writing it.
public struct CaptureTime: Sendable, Hashable {
    /// The absolute instant. The wall-clock written to EXIF is this instant
    /// rendered in `offset`, so the two always agree by construction.
    public var date: Date
    /// EXIF `OffsetTimeOriginal`, e.g. `-05:00`. Zero-padded `±HH:MM`, the only
    /// form `MetadataReader.timeZone(fromOffset:)` accepts on the read side.
    public var offset: String?
    /// EXIF `SubSecTimeOriginal`: the digits *after* the decimal point, e.g.
    /// `250` for .250 s. Nil clears any existing sub-second value rather than
    /// leaving a stale one attached to a new capture time.
    public var subSeconds: String?

    public init(date: Date, offset: String?, subSeconds: String? = nil) {
        self.date = date
        self.offset = offset
        self.subSeconds = subSeconds
    }
}

/// A WGS-84 position in signed decimal degrees.
public struct GPSCoordinate: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The logical fields of spec §9. A nil field is left alone; a non-nil field is
/// written across every tag family the mapping in `MetadataWriter` names.
public struct MetadataEdit: Sendable, Hashable {
    public var captureTime: CaptureTime?
    public var artist: String?
    public var copyright: String?
    public var description: String?
    /// Replaces the existing keyword set wholesale. An empty array clears it.
    public var keywords: [String]?
    public var gps: GPSCoordinate?
    /// 0...5, the range XMP `Rating` and the MWG rules share.
    public var rating: Int?
    public var label: String?

    public init(captureTime: CaptureTime? = nil, artist: String? = nil,
                copyright: String? = nil, description: String? = nil,
                keywords: [String]? = nil, gps: GPSCoordinate? = nil,
                rating: Int? = nil, label: String? = nil) {
        self.captureTime = captureTime
        self.artist = artist
        self.copyright = copyright
        self.description = description
        self.keywords = keywords
        self.gps = gps
        self.rating = rating
        self.label = label
    }

    public var isEmpty: Bool {
        captureTime == nil && artist == nil && copyright == nil && description == nil
            && keywords == nil && gps == nil && rating == nil && label == nil
    }
}

/// Where a write landed.
public enum WriteTarget: Sendable, Hashable {
    /// The container itself was rewritten (JPEG, PNG, WebP, HEIC, TIFF, …).
    case inPlace
    /// A RAW container was left untouched and this `.xmp` sidecar carries the
    /// edit — spec §9, constraint 2.
    case sidecar(URL)
}

/// The container's post-write facts, recomputed from the file on disk.
///
/// Present only for an in-place write. A sidecar write does not touch the
/// container, so the container's index row still stands and there is nothing
/// to recompute.
public struct RehashResult: Sendable, Hashable {
    public let size: Int64
    public let mtime: Double
    public let contentHash: String
    public let imageHash: String?
    public let imageHashKind: String?

    public init(size: Int64, mtime: Double, contentHash: String,
                imageHash: String?, imageHashKind: String?) {
        self.size = size
        self.mtime = mtime
        self.contentHash = contentHash
        self.imageHash = imageHash
        self.imageHashKind = imageHashKind
    }
}

/// Something that happened during a *successful* write and that a summary sheet
/// should still show. Warnings never fail the write; a failure is an error.
public enum WriteWarning: Sendable, Hashable {
    /// The format has no `image_hash` rule (HEIC, TIFF, GIF, PSD — spec §11's
    /// last row), so duplicate grouping for this file rests on `content_hash`
    /// and `phash`, and this write just invalidated the `content_hash`. The
    /// file is written correctly; what changes is that it is temporarily
    /// ungrouped from its exact copies. The inspector should say so rather
    /// than pretend a HEIC edit is as cheap as a JPEG one.
    case imageHashUnavailable(kind: String)
    /// The container was expected to be byte-identical after a sidecar write
    /// and was not.
    case containerModifiedBySidecarWrite
    /// `IndexStore.recordMetadataWrite` refused the write because the row no
    /// longer describes the file that was edited. Safe — the row keeps NULL
    /// hashes and gets re-read — but worth reporting.
    case indexRowNotUpdated
    /// An orphaned `…_original.lightbox-stash-*` left beside the destination by
    /// a run that was killed between stashing and restoring. Swept, and named
    /// so the sweep is visible rather than silent.
    case sweptOrphanedBackup(String)
    /// Text exiftool wrote to stderr while succeeding.
    case exiftool(String)
}

public struct WriteSuccess: Sendable, Hashable {
    /// The file exiftool actually modified: the container, or the sidecar.
    public let written: URL
    public let target: WriteTarget
    public let rehash: RehashResult?
    public let warnings: [WriteWarning]

    public init(written: URL, target: WriteTarget, rehash: RehashResult?,
                warnings: [WriteWarning]) {
        self.written = written
        self.target = target
        self.rehash = rehash
        self.warnings = warnings
    }
}

public enum MetadataWriteError: Error, Equatable, Sendable {
    /// exiftool is missing or too old. Carries the explanation the UI shows
    /// when it disables editing (spec §11).
    case exiftoolUnavailable(String)
    /// A capture time arrived with no `OffsetTimeOriginal`. Spec §9.1.
    case captureTimeRequiresTimeZone
    /// The offset was present but not zero-padded `±HH:MM`.
    case invalidTimeZoneOffset(String)
    /// `SubSecTimeOriginal` must be digits only.
    case invalidSubSeconds(String)
    case invalidRating(Int)
    case invalidCoordinate(latitude: Double, longitude: Double)
    case nothingToWrite
    /// The extension is not one `MediaType` recognises, so there is no rule for
    /// whether it is edited in place or through a sidecar.
    case unsupportedFormat(String)
    case fileMissing(String)
    /// exiftool ran and failed. Carries its stderr.
    case exiftoolFailed(String)
    /// The tags read back did not match what was written. Carries the tag names
    /// that disagreed. The file has been restored from exiftool's backup.
    case verificationFailed([String])
    /// Verification failed *and* the restore failed too, so the file on disk is
    /// the half-written one. The worst case, and the one that must be loudest.
    case restoreFailed(tags: [String], reason: String)
    /// The tags did not verify and there was no backup to restore from, so
    /// whatever exiftool left is what is on disk. Distinct from
    /// `verificationFailed`, which promises the file *was* put back — the
    /// caller must not be told a rollback happened when none could.
    case verificationFailedWithoutRollback(tags: [String])
    /// A file already occupied exiftool's `_original` backup path and could not
    /// be moved out of the way. exiftool declines to overwrite an existing
    /// `_original` and still reports success, so the write would have run with
    /// no rollback available; it is refused before it starts instead.
    case backupPathOccupied(String)
    /// **The tripwire.** `image_hash` is defined to survive a metadata edit
    /// (HANDOFF §6). It moved, so the format's segment/chunk rule in `Hashing/`
    /// is wrong and duplicate grouping for that format is unreliable — and
    /// duplicate detection *deletes files* on the strength of those hashes.
    /// The edit is rolled back and reported as a failure rather than kept
    /// alongside a hash the app has just proved it cannot trust. A bug to file,
    /// not to paper over by loosening the rule.
    case imageHashChanged(kind: String, before: String, after: String)
    /// The image hash could not be read *before* the write, so there is nothing
    /// to check the post-write hash against. The write is refused rather than
    /// performed with the tripwire silently disabled: `image_hash` is what the
    /// duplicate view deletes on, and recording one that was never verified is
    /// worse than not editing the file. A mid-read I/O error on an external
    /// volume is the realistic cause.
    case imageHashUnreadable(String)
    /// The batch was cancelled before this item was reached. Items already
    /// written stay written — a metadata edit is not a transaction.
    case cancelled

    /// A sentence for the summary sheet (spec §11: "reports what failed and
    /// why"), in the same shape as `ExiftoolAvailability.explanation`.
    ///
    /// The three post-write cases keep their distinction deliberately, because
    /// they call for different actions: the file was put back, the file could
    /// not be put back, or there was never anything to put back. Collapsing
    /// them into "verification failed" tells a user their photo is fine when it
    /// may not be.
    public var explanation: String {
        switch self {
        case .exiftoolUnavailable(let why):
            why.hasSuffix(".") ? why : why + "."
        case .captureTimeRequiresTimeZone:
            """
            A capture time needs a time zone. Without one the timestamp means a \
            different moment on every machine that reads it.
            """
        case .invalidTimeZoneOffset(let offset):
            "\"\(offset)\" is not a time-zone offset. It must look like -05:00."
        case .invalidSubSeconds(let value):
            "\"\(value)\" is not a sub-second value. It must be digits only."
        case .invalidRating(let rating):
            "A rating of \(rating) is out of range. Ratings run from 0 to 5."
        case .invalidCoordinate(let latitude, let longitude):
            """
            \(latitude), \(longitude) is not a position on Earth. Latitude runs \
            -90 to 90 and longitude -180 to 180.
            """
        case .nothingToWrite:
            "Nothing to write: no field was changed."
        case .unsupportedFormat(let ext):
            "Lightbox does not edit .\(ext) files."
        case .fileMissing(let path):
            "\((path as NSString).lastPathComponent) is no longer there."
        case .exiftoolFailed(let detail):
            "exiftool could not write the file: \(detail.oneLine)."
        case .verificationFailed(let tags):
            """
            \(tags.tagList) did not read back correctly, so nothing was changed \
            — the file was restored from its backup.
            """
        case .restoreFailed(let tags, let reason):
            """
            \(tags.tagList) did not read back correctly and the file could not be \
            restored from its backup (\(reason.oneLine)). It may be half-written; \
            check it before using it.
            """
        case .verificationFailedWithoutRollback(let tags):
            """
            \(tags.tagList) did not read back correctly and there was no backup to \
            restore from, so the file is as exiftool left it. Check it before \
            using it.
            """
        case .backupPathOccupied(let path):
            """
            Another file is already at \((path as NSString).lastPathComponent) and \
            could not be moved aside, so this edit would have had no way back. \
            Nothing was changed.
            """
        case .imageHashChanged(let kind, _, _):
            """
            The image data changed when only the metadata should have \
            (\(kind)). The edit was rolled back; please report this, because \
            duplicate detection depends on that hash.
            """
        case .imageHashUnreadable(let path):
            """
            \((path as NSString).lastPathComponent) could not be read for hashing, \
            so the edit could not be verified. Nothing was changed.
            """
        case .cancelled:
            "Cancelled before this file was reached."
        }
    }
}

private extension String {
    /// Collapses a multi-line diagnostic so it fits one row of a summary sheet.
    var oneLine: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "; ")
    }
}

private extension [String] {
    var tagList: String {
        switch count {
        case 0: "The metadata"
        case 1: self[0]
        default: dropLast().joined(separator: ", ") + " and " + self[count - 1]
        }
    }
}

/// Knobs for one batch.
public struct WriteOptions: Sendable, Hashable {
    /// exiftool `-P`: leave the file's modification time as it was. Spec §9's
    /// closing line. Off by default, because a changed file usually should
    /// look changed.
    public var preserveModificationTime: Bool

    public init(preserveModificationTime: Bool = false) {
        self.preserveModificationTime = preserveModificationTime
    }
}

/// One item's result. Batches never fail as a unit — spec §11.
public struct WriteOutcome: Sendable {
    /// The file the caller asked about, which for a RAW is the container even
    /// though the sidecar is what was written.
    public let source: URL
    public let result: Result<WriteSuccess, MetadataWriteError>

    public init(source: URL, result: Result<WriteSuccess, MetadataWriteError>) {
        self.source = source
        self.result = result
    }

    public var success: WriteSuccess? { try? result.get() }
    public var error: MetadataWriteError? {
        if case .failure(let e) = result { return e }
        return nil
    }
}
