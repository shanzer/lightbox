import Foundation

/// The byte ranges of a WebP that constitute image data.
///
/// An allowlist, unlike JPEG and PNG, and not as a matter of taste. Writing
/// EXIF to a *simple-format* WebP promotes it to *extended format*: the writer
/// inserts a `VP8X` header chunk that was not there before. A denylist of
/// `EXIF`/`XMP ` therefore sees a brand-new chunk and hashes the file
/// differently, which breaks the one warranty these parsers exist to provide.
/// Verified against an exiftool round-trip.
///
/// The cost of inverting the rule is that a chunk this parser has never heard
/// of is excluded, so a future WebP extension carrying real image data would
/// be missed until it is added here. That is the reason `ALPH`, `ANIM`, `ANMF`
/// and `ICCP` are on the list alongside the two bitstream chunks: alpha,
/// animation frames and the colour profile all change what the file decodes to.
/// `VP8X` is the only structural chunk deliberately left off — its canvas
/// dimensions and feature flags merely restate what the image-data chunks
/// already encode, which is exactly why promotion can be ignored.
enum WebPImageHash {
    static let kind = "webp-chunk-v1"

    /// The chunks that carry image data or govern how it decodes.
    static let includedChunkNames = ["VP8 ", "VP8L", "ALPH", "ANIM", "ANMF", "ICCP"]

    /// The allowlist as packed four-character codes. The walk compares one
    /// integer per chunk rather than building a `String`: a file at the
    /// indexer's 256 MB in-memory limit can hold 33 million eight-byte chunks,
    /// and this loop runs on every WebP the indexer touches.
    private static let includedChunks: Set<UInt32> = Set(includedChunkNames.map(fourCC))

    private static let riffCode = fourCC("RIFF")
    private static let webpCode = fourCC("WEBP")

    /// `RIFF`, the four-byte container size, and the `WEBP` form type.
    private static let headerLength = 12

    /// A chunk's four-byte name plus its four-byte payload length.
    private static let chunkHeaderLength = 8

    /// A four-character code packed big-endian, in the byte order it appears
    /// in on disk. (The *code* is byte order; only the length fields that
    /// follow it are little-endian, RIFF being a little-endian format.)
    static func fourCC(_ name: String) -> UInt32 {
        let bytes = Array(name.utf8)
        precondition(bytes.count == 4, "a RIFF four-character code is exactly four bytes")
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
             | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] {
        guard bytes.count >= headerLength else { throw HashError.truncated }

        func code(at offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
          | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        func littleEndianLength(at offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
          | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }

        guard code(at: 0) == riffCode, code(at: 8) == webpCode else {
            throw HashError.malformed("not a RIFF/WEBP container")
        }

        // RIFF declares its own size: the byte count following the size field,
        // which includes the four-byte form type. Four bytes widened into an
        // Int are never negative, so the only bad values are "too small to hold
        // the form type" and "larger than the buffer".
        let declared = littleEndianLength(at: 4)
        guard declared >= 4 else {
            throw HashError.malformed("RIFF size \(declared) does not cover the WEBP form type")
        }
        let riffEnd = 8 + declared
        guard riffEnd <= bytes.count else { throw HashError.truncated }

        var ranges: [Range<Int>] = []
        var i = headerLength

        while i + chunkHeaderLength <= riffEnd {
            let name = code(at: i)
            let length = littleEndianLength(at: i + 4)
            // RIFF pads an odd-length payload to an even boundary, and the pad
            // byte is part of the chunk. Skipping it would read the next
            // chunk's header one byte early.
            let end = i + chunkHeaderLength + length + (length & 1)
            guard end <= riffEnd else { throw HashError.truncated }

            if includedChunks.contains(name) { ranges.appendCoalescing(i..<end) }
            i = end
        }

        // Fewer than eight bytes left inside a container whose declared size
        // accounts for them: the contents are wrong rather than cut short, so
        // this is malformed and not truncation.
        guard i == riffEnd else {
            throw HashError.malformed("\(riffEnd - i) stray bytes at \(i) inside the RIFF container")
        }

        // Checked before the trailer is appended: a file carrying only metadata
        // has no image data to hash, and a trailing payload must not disguise
        // that. Hashing nothing would make every such file a duplicate of every
        // other one.
        guard !ranges.isEmpty else { throw HashError.malformed("no image chunks found") }

        // Bytes past the size the RIFF header declares are hashed, matching
        // JPEG after EOI and PNG after IEND. RIFF is the one of the three that
        // states its own extent, so "trailing" is unambiguous here: anything
        // the container does not account for. Such bytes are an appended
        // payload, not metadata — dropping them would make a file with a
        // payload hash identically to one without, and the duplicate view would
        // then offer to delete the copy carrying the extra content.
        if riffEnd < bytes.count { ranges.appendCoalescing(riffEnd..<bytes.count) }

        return ranges
    }
}
