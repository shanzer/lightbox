import Foundation

/// The byte ranges of a PNG that constitute image data.
///
/// A denylist, not an allowlist: an ancillary chunk this parser has never
/// heard of is hashed, because a chunk it does not recognise may well affect
/// rendering. Guessing wrong in that direction changes a hash; guessing wrong
/// the other way would silently call two different images identical.
///
/// A denylist works for PNG because writing metadata rewrites existing chunks
/// in place rather than restructuring the file; verified against an exiftool
/// round-trip.
enum PNGImageHash {
    static let kind = "png-idat-v1"

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Text, timestamps, EXIF, and physical pixel dimensions. `pHYs` is print
    /// density, not pixels, and exiftool rewrites it.
    ///
    /// The colour chunks `gAMA`, `cHRM`, `iCCP` and `sRGB` are deliberately
    /// absent: all of them change how the samples decode into pixels.
    static let excludedTypeNames = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME", "pHYs"]

    /// The denylist as packed type codes. The walk compares one integer per
    /// chunk rather than building a `String`: a 256 MB file of minimum-size
    /// chunks holds 22 million of them, and this loop runs on every PNG the
    /// indexer touches.
    private static let excludedTypes: Set<UInt32> = Set(excludedTypeNames.map(typeCode))

    private static let iendType = typeCode("IEND")

    /// The PNG spec caps a chunk's data length at 2^31 - 1.
    private static let maxChunkDataLength = 0x7FFF_FFFF

    /// The length (4), type (4) and CRC (4) fields wrapped around chunk data.
    private static let chunkOverhead = 12

    /// A four-character chunk type packed big-endian, in the byte order it
    /// appears in on disk.
    static func typeCode(_ name: String) -> UInt32 {
        let bytes = Array(name.utf8)
        precondition(bytes.count == 4, "a PNG chunk type is exactly four bytes")
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
             | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] {
        guard bytes.count >= signature.count else { throw HashError.truncated }
        for (offset, expected) in signature.enumerated() where bytes[offset] != expected {
            throw HashError.malformed("bad PNG signature")
        }

        var ranges: [Range<Int>] = []
        var i = signature.count

        // A chunk header is the 4 length bytes plus the 4 type bytes. Reading
        // the byte at index i + 7 needs i + 7 < count, i.e. i + 8 <= count.
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16
                       | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            // Four big-endian bytes widened into an Int are never negative, so
            // a sign test would be dead code. Lengths above the spec's cap are
            // already unreachable in practice — nothing that large fits a real
            // buffer, so the fit guard below would reject them anyway. Checking
            // the cap here classifies them as malformed, which is what they
            // are, instead of blaming a truncated file for a forged length.
            guard length <= maxChunkDataLength else {
                throw HashError.malformed("chunk length \(length) at \(i) exceeds the PNG maximum")
            }
            // With the cap above, this sum cannot overflow a 64-bit Int short
            // of a buffer of roughly 9.2 exabytes, so the guard never fires
            // today. It is kept because it costs nothing and states the
            // invariant the fit check below depends on.
            let (end, overflowed) = i.addingReportingOverflow(chunkOverhead + length)
            guard !overflowed, end <= bytes.count else { throw HashError.truncated }

            let type = UInt32(bytes[i + 4]) << 24 | UInt32(bytes[i + 5]) << 16
                     | UInt32(bytes[i + 6]) << 8 | UInt32(bytes[i + 7])

            if type == iendType {
                // Everything from IEND to the end of the buffer is hashed.
                // A trailing payload is image content, not metadata: dropping
                // it would make a file with an appended payload hash
                // identically to one without, and the duplicate view would
                // then offer to delete the copy carrying the extra content.
                ranges.appendCoalescing(i..<bytes.count)
                return ranges
            }

            if !excludedTypes.contains(type) { ranges.appendCoalescing(i..<end) }
            i = end
        }

        // Reaching here means the walk ran off the end without an IEND.
        throw HashError.truncated
    }
}
