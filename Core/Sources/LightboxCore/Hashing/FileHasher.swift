import Foundation
import CryptoKit

/// The two hashes recorded for one file: the whole-file digest used for exact
/// duplicate detection, and the image-data digest that survives a metadata
/// edit, tagged with the rule that produced it.
public struct FileHashes: Sendable, Hashable {
    public let contentHash: String
    public let imageHash: String?
    public let imageHashKind: String?

    public init(contentHash: String, imageHash: String?, imageHashKind: String?) {
        self.contentHash = contentHash
        self.imageHash = imageHash
        self.imageHashKind = imageHashKind
    }
}

public protocol FileHashing: Sendable {
    func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes
}

/// Computes the whole-file and image-data hashes in a single read per file.
///
/// Deliberately NOT memory-mapped. `Data(contentsOf:, .mappedIfSafe)` would
/// turn a mid-read I/O error on a flaky external volume into `SIGBUS` — an
/// uncatchable fault rather than a `HashError` — on exactly the
/// multi-hundred-megabyte RAW and PSD files that motivated streaming in the
/// first place, silently bypassing `ContentHasher`'s error handling.
///
/// So the file is read once, by whichever of two routes fits it. A format with
/// an image-hash rule (JPEG, PNG, WebP) is read whole through
/// `ContentHasher.readWholeFile` and both hashes come from that buffer; a
/// format without one (RAW, PSD, HEIC, TIFF, GIF — which are the large ones) is
/// streamed for its content hash alone and gets `imageHash == nil`. Every
/// failure stays catchable, and buffering is bounded to the formats that are
/// small in practice, plus the `inMemoryLimit` backstop for the ones that
/// are not.
public struct FileHasher: FileHashing {
    /// Above this size an image-hashable file is streamed for its content hash
    /// only, and `imageHash` is left nil rather than buffering it whole.
    public static let defaultInMemoryLimit = 256 << 20

    public let inMemoryLimit: Int

    /// - Parameter inMemoryLimit: injectable so the streaming branch is
    ///   testable without writing a quarter-gigabyte file.
    public init(inMemoryLimit: Int = FileHasher.defaultInMemoryLimit) {
        precondition(inMemoryLimit > 0, "inMemoryLimit must be positive")
        self.inMemoryLimit = inMemoryLimit
    }

    public func hashes(for url: URL, mediaType: MediaType) throws -> FileHashes {
        let hasher = ContentHasher()

        // A failed size lookup falls through to the streaming branch rather
        // than throwing here: whatever is wrong with the path, `hash(_:)`
        // classifies it as `.unreadable` or `.truncated` for one consistent
        // set of errors across both branches.
        let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int

        guard mediaType.imageHashKind != nil, let size, size <= inMemoryLimit else {
            return FileHashes(contentHash: try hasher.hash(url),
                              imageHash: nil, imageHashKind: nil)
        }

        let data = try hasher.readWholeFile(url)

        return data.withUnsafeBytes { bytes -> FileHashes in
            var content = SHA256()
            // `update(bufferPointer:)` on an empty buffer is avoided: the
            // digest of no bytes is still the well-defined empty-input hash,
            // which is what an empty file must produce.
            if !bytes.isEmpty { content.update(bufferPointer: bytes) }
            let contentHash = content.finalize().hexEncoded

            // A parse failure is not an indexing failure. A file whose
            // extension lies about its contents still deserves a content hash,
            // and the image hash is simply unavailable for it. `imageHashKind`
            // goes nil with it, so a stored kind never describes a hash that
            // was not computed.
            guard let kind = mediaType.imageHashKind,
                  let ranges = try? Self.ranges(bytes, kind: mediaType.kind),
                  let imageHash = try? ImageDataDigest.digest(bytes, ranges: ranges)
            else {
                return FileHashes(contentHash: contentHash, imageHash: nil, imageHashKind: nil)
            }
            return FileHashes(contentHash: contentHash, imageHash: imageHash, imageHashKind: kind)
        }
    }

    private static func ranges(_ bytes: UnsafeRawBufferPointer,
                               kind: MediaKind) throws -> [Range<Int>] {
        switch kind {
        case .jpeg: try JPEGImageHash.includedRanges(bytes)
        case .png: try PNGImageHash.includedRanges(bytes)
        case .webp: try WebPImageHash.includedRanges(bytes)
        // Exhaustive rather than defaulted, so adding a `MediaKind` with an
        // image-hash rule fails to compile until it is routed here.
        case .gif, .heic, .tiff, .raw, .psd:
            throw HashError.malformed("no image-hash rule for \(kind)")
        }
    }
}
