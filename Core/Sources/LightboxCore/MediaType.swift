import Foundation

public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case jpeg, png, webp, gif, heic, tiff, raw, psd
}

/// A supported still-image type, identified by file extension.
///
/// Extension-based rather than content-sniffed: the walker must decide whether
/// to index a file without opening it, and at 50k files the difference between
/// a string comparison and a read is the difference between instant and slow.
public struct MediaType: Sendable, Hashable {
    public let kind: MediaKind
    public let ext: String

    private static let table: [String: MediaKind] = [
        "jpg": .jpeg, "jpeg": .jpeg, "jpe": .jpeg,
        "png": .png,
        "webp": .webp,
        "gif": .gif,
        "heic": .heic, "heif": .heic,
        "tif": .tiff, "tiff": .tiff,
        "psd": .psd,
        "cr2": .raw, "cr3": .raw, "nef": .raw, "nrw": .raw, "arw": .raw,
        "srf": .raw, "sr2": .raw, "raf": .raw, "orf": .raw, "rw2": .raw,
        "pef": .raw, "dng": .raw, "raw": .raw, "3fr": .raw, "erf": .raw,
    ]

    public static func forExtension(_ ext: String) -> MediaType? {
        let key = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let normalized = key.lowercased()
        guard let kind = table[normalized] else { return nil }
        return MediaType(kind: kind, ext: normalized)
    }

    /// The `image_hash_kind` recorded alongside a computed image hash, or nil
    /// when this format has no stable image-data hash in version 1.
    public var imageHashKind: String? {
        switch kind {
        case .jpeg: JPEGImageHash.kind
        case .png: PNGImageHash.kind
        case .webp: WebPImageHash.kind
        case .gif, .heic, .tiff, .raw, .psd: nil
        }
    }
}
