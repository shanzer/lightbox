import Foundation
import CryptoKit

/// Hashes a set of byte ranges from one buffer. Shared by every format parser
/// so that all of them agree on digest construction.
enum ImageDataDigest {
    static func digest(_ bytes: UnsafeRawBufferPointer, ranges: [Range<Int>]) throws -> String {
        var sha = SHA256()
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
                throw HashError.malformed("range \(range) outside buffer of \(bytes.count)")
            }
            if range.isEmpty { continue }
            sha.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[range]))
        }
        return sha.finalize().hexEncoded
    }
}

extension Array where Element == Range<Int> {
    /// Appends `range`, merging it into the previous element when the two are
    /// exactly adjacent.
    ///
    /// The parsers walk a file segment by segment, and in a file with no
    /// metadata every segment abuts the last, so an uncoalesced walk stores one
    /// range per segment. A 256 MB file built from minimum-size segments then
    /// costs gigabytes of ranges to describe a byte sequence that a handful of
    /// them covers — and the indexer hashes several files at once, which turns
    /// that into an out-of-memory kill rather than a slow hash. Coalescing
    /// changes only the representation: the concatenation the digest sees is
    /// identical, because merging two adjacent ranges yields exactly the bytes
    /// the pair covered.
    mutating func appendCoalescing(_ range: Range<Int>) {
        if let last = self.last, last.upperBound == range.lowerBound {
            self[self.count - 1] = last.lowerBound..<range.upperBound
        } else {
            append(range)
        }
    }
}

/// The byte ranges of a JPEG that constitute image data.
///
/// A denylist, not an allowlist: markers this parser has never heard of are
/// hashed. Guessing wrong in that direction changes a hash; guessing wrong the
/// other way would silently call two different images identical.
enum JPEGImageHash {
    static let kind = "jpeg-scan-v1"

    /// APP0 (JFIF), APP1 (EXIF/XMP), APP13 (Photoshop/IPTC), COM.
    ///
    /// APP2 (ICC profile) and APP14 (Adobe colour transform) are deliberately
    /// absent: both change how the scan data decodes into pixels.
    static let excludedMarkers: Set<UInt8> = [0xE0, 0xE1, 0xED, 0xFE]

    static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] {
        guard bytes.count >= 4 else { throw HashError.truncated }
        guard bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw HashError.malformed("missing JPEG SOI marker")
        }

        var ranges: [Range<Int>] = []
        var i = 2

        while i < bytes.count {
            guard bytes[i] == 0xFF else { throw HashError.malformed("expected a marker at \(i)") }
            // Fill bytes: a run of 0xFF before the marker identifier is legal.
            var markerIndex = i + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < bytes.count else { throw HashError.truncated }
            let marker = bytes[markerIndex]

            switch marker {
            case 0xD9:                                   // EOI
                // Everything from EOI to the end of the buffer is hashed:
                // motion photos (Pixel/Samsung) append a complete MP4 after
                // EOI and MPF multi-picture files carry a second image there.
                // That is payload, not metadata — excluding it would call a
                // motion photo and its stripped-still twin identical.
                ranges.appendCoalescing(i..<bytes.count)
                return ranges

            case 0x01, 0xD0...0xD7:                      // standalone, no payload
                ranges.appendCoalescing(i..<(markerIndex + 1))
                i = markerIndex + 1

            case 0xDA:                                   // SOS: header, then entropy data
                guard markerIndex + 3 <= bytes.count else { throw HashError.truncated }
                let headerLength = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
                var scan = markerIndex + 1 + headerLength
                guard scan <= bytes.count else { throw HashError.truncated }
                // Entropy-coded data runs until a marker that is neither a
                // stuffed 0xFF00 nor a restart marker.
                while scan + 1 < bytes.count {
                    if bytes[scan] == 0xFF {
                        let next = bytes[scan + 1]
                        if next != 0x00, !(0xD0...0xD7).contains(next) { break }
                    }
                    scan += 1
                }
                if scan + 1 >= bytes.count { scan = bytes.count }
                ranges.appendCoalescing(i..<scan)
                i = scan

            default:                                     // length-prefixed segment
                guard markerIndex + 3 <= bytes.count else { throw HashError.truncated }
                let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
                guard length >= 2 else { throw HashError.malformed("segment length \(length) at \(i)") }
                let end = markerIndex + 1 + length
                guard end <= bytes.count else { throw HashError.truncated }
                if !excludedMarkers.contains(marker) { ranges.appendCoalescing(i..<end) }
                i = end
            }
        }

        // Reaching here means the scan ran off the end without an EOI.
        throw HashError.truncated
    }
}
