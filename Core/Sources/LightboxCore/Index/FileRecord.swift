import Foundation
import GRDB

/// One indexed image. Timestamps are epoch seconds as `Double` rather than
/// `Date`: `mtime` is compared for exact equality to decide whether a file
/// needs re-reading, and GRDB's default millisecond-rounded text timestamps
/// would report every file stale on every scan.
public struct FileRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "files"

    public var id: Int64?
    public var path: String
    public var parentDir: String
    public var name: String
    public var ext: String
    public var size: Int64
    public var mtime: Double
    public var device: Int64
    public var inode: Int64
    /// The volume this file was seen on, or nil for a row written before
    /// schema v2 or walked on a filesystem that publishes no UUID. Stable
    /// across the replug that renumbers `device`; see `VolumeIdentity`.
    public var volumeUUID: String?
    public var width: Int?
    public var height: Int?
    public var captureTime: Double?
    public var captureOffset: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var orientation: Int?
    public var contentHash: String?
    public var imageHash: String?
    public var imageHashKind: String?
    public var phash: String?
    public var hashedAt: Double?
    public var indexedAt: Double

    public enum CodingKeys: String, CodingKey {
        case id, path, name, ext, size, mtime, device, inode, width, height, orientation, phash
        case parentDir = "parent_dir"
        case volumeUUID = "volume_uuid"
        case captureTime = "capture_time"
        case captureOffset = "capture_offset"
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case contentHash = "content_hash"
        case imageHash = "image_hash"
        case imageHashKind = "image_hash_kind"
        case hashedAt = "hashed_at"
        case indexedAt = "indexed_at"
    }

    public var modifiedDate: Date { Date(timeIntervalSince1970: mtime) }
    public var captureDate: Date? { captureTime.map(Date.init(timeIntervalSince1970:)) }

    /// The record for a freshly walked file, before metadata or hashes are read.
    ///
    /// `volume` is read once per pass from the scan's root rather than per
    /// entry: every file the walk produced is by construction on the volume
    /// answering there, and `volumeUUIDString` is a resource-value read this
    /// has no reason to pay 50,000 times.
    public init(entry: WalkEntry, volume: VolumeIdentity, indexedAt: Double) {
        self.id = nil
        self.path = entry.url.path
        self.parentDir = entry.url.deletingLastPathComponent().path
        self.name = entry.url.lastPathComponent
        self.ext = entry.mediaType.ext
        self.size = entry.size
        self.mtime = entry.mtime.timeIntervalSince1970
        self.device = entry.device
        self.inode = entry.inode
        self.volumeUUID = volume.uuid
        self.indexedAt = indexedAt
    }

    public init(id: Int64?, path: String, parentDir: String, name: String, ext: String,
                size: Int64, mtime: Double, device: Int64, inode: Int64,
                volumeUUID: String? = nil, width: Int?, height: Int?,
                captureTime: Double?, captureOffset: String?, cameraMake: String?,
                cameraModel: String?, orientation: Int?, contentHash: String?,
                imageHash: String?, imageHashKind: String?, phash: String?,
                hashedAt: Double?, indexedAt: Double) {
        self.id = id; self.path = path; self.parentDir = parentDir; self.name = name
        self.ext = ext; self.size = size; self.mtime = mtime; self.device = device
        self.inode = inode; self.volumeUUID = volumeUUID
        self.width = width; self.height = height; self.captureTime = captureTime
        self.captureOffset = captureOffset; self.cameraMake = cameraMake
        self.cameraModel = cameraModel; self.orientation = orientation
        self.contentHash = contentHash; self.imageHash = imageHash
        self.imageHashKind = imageHashKind; self.phash = phash
        self.hashedAt = hashedAt; self.indexedAt = indexedAt
    }
}
