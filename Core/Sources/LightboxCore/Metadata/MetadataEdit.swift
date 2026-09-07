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
    /// **The tripwire.** `image_hash` is defined to survive a metadata edit
    /// (HANDOFF §6); if it moved, the format's segment/chunk rule is wrong and
    /// duplicate grouping for that format is now unreliable. The edit is kept
    /// and the index is updated with the hash the file actually has — losing
    /// the user's edit over a hashing bug would be the wrong trade — but this
    /// is a bug to file, not to swallow.
    case imageHashChanged(kind: String, before: String, after: String)
    /// The container was expected to be byte-identical after a sidecar write
    /// and was not.
    case containerModifiedBySidecarWrite
    /// `IndexStore.recordMetadataWrite` refused the write because the row no
    /// longer describes the file that was edited. Safe — the row keeps NULL
    /// hashes and gets re-read — but worth reporting.
    case indexRowNotUpdated
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
