import Testing
import Foundation
@testable import LightboxCore

private func jpegHash(_ data: Data) throws -> String {
    try data.withUnsafeBytes { bytes in
        try ImageDataDigest.digest(bytes, ranges: JPEGImageHash.includedRanges(bytes))
    }
}

private func jpegHash(_ url: URL) throws -> String {
    try jpegHash(Data(contentsOf: url))
}

/// Walks the header segments independently of the parser and reports, per
/// marker, whether the returned ranges cover that segment. Every segment before
/// SOS is length-prefixed, so this walk terminates without having to reproduce
/// the entropy-data scan.
///
/// Needed because ranges are coalesced: one range no longer corresponds to one
/// segment, so their start offsets can no longer be read as a list of included
/// markers.
private func jpegHeaderCoverage(_ data: Data) throws -> [UInt8: Bool] {
    let ranges = try data.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
    var covered: [UInt8: Bool] = [:]
    var i = 2
    while i + 3 < data.count, data[i] == 0xFF {
        let marker = data[i + 1]
        covered[marker] = ranges.contains { $0.contains(i) }
        if marker == 0xDA { break }                 // SOS: entropy data follows
        i += 2 + (Int(data[i + 2]) << 8 | Int(data[i + 3]))
    }
    return covered
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards: teardown of `tree` is then the framework's
/// contract rather than an ARC ordering inferred from where it was last used.
struct JPEGImageHashTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func imageHashSurvivesAnEXIFEditWhileContentHashDoesNot() throws {
        let a = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let b = tree.root.appendingPathComponent("b.jpg")
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

        #expect(try jpegHash(a) == jpegHash(b))                       // the warranty
        #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
    }

    @Test func excludesOnlyTheMetadataSegments() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let data = try Data(contentsOf: url)
        let covered = try jpegHeaderCoverage(data)
        let ranges = try data.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }

        // A missing key reads as nil, which fails these comparisons, so each
        // assertion also proves the segment is present: an exclusion assertion
        // about a segment the fixture does not contain would prove nothing.
        #expect(covered[0xE0] == false)                             // APP0 / JFIF
        #expect(covered[0xE1] == false)                             // APP1 / EXIF
        #expect(covered[0xED] == false)                             // APP13 / Photoshop
        #expect(covered[0xC0] == true)                              // SOF0
        #expect(covered[0xC4] == true)                              // DHT
        #expect(covered[0xDB] == true)                              // DQT
        #expect(covered[0xDA] == true)                              // SOS
        #expect(ranges.contains { $0.contains(data.count - 2) })    // EOI
    }

    @Test func anInjectedCommentSegmentLeavesTheHashUnchanged() throws {
        // COM is on the denylist but ImageIO never writes one, so the exclusion
        // test above cannot exercise it. Inject one rather than leave the
        // denylist entry untested.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.jpg")))
        let text = Array("a comment nobody should hash".utf8)
        var withCOM = Data(base.prefix(2))                          // SOI
        withCOM.append(contentsOf: [0xFF, 0xFE,
                                    UInt8((text.count + 2) >> 8),
                                    UInt8((text.count + 2) & 0xFF)])
        withCOM.append(contentsOf: text)
        withCOM.append(base.dropFirst(2))

        #expect(withCOM.count > base.count)                         // it really landed
        #expect(try jpegHash(base) == jpegHash(withCOM))
    }

    @Test func aSegmentFloodedFileCollapsesToOneRange() throws {
        // RST markers are the smallest legal segment at two bytes each, so they
        // are the worst case for one-range-per-segment: a 256 MB file of them
        // needed 134 million ranges and 5.7 GB of RSS to describe a byte
        // sequence that a single range covers.
        var flood = Data([0xFF, 0xD8])                              // SOI
        for _ in 0..<200_000 { flood.append(contentsOf: [0xFF, 0xD0]) }
        flood.append(contentsOf: [0xFF, 0xD9])                      // EOI

        let ranges = try flood.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
        // Everything after SOI, which the parser never hashes, in one range.
        #expect(ranges == [2..<flood.count])
    }

    @Test func aDifferenceInAPP14ChangesTheHash() throws {
        // APP14 decides YCbCr vs YCCK, so it is image data, not metadata.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.jpg")))
        var withAPP14 = Data(base.prefix(2))                        // SOI
        withAPP14.append(contentsOf: [0xFF, 0xEE, 0x00, 0x0E])      // APP14, length 14
        withAPP14.append(contentsOf: Array("Adobe".utf8))
        withAPP14.append(contentsOf: [0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x02])
        withAPP14.append(base.dropFirst(2))

        let one = try base.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        let two = try withAPP14.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        #expect(one != two)
    }

    @Test func rejectsFilesThatAreNotJPEG() throws {
        let junk = Data("not a jpeg at all".utf8)
        #expect(throws: (any Error).self) {
            try junk.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
        }
    }

    @Test func rejectsATruncatedJPEG() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.jpg"))
        let truncated = try Data(contentsOf: url).prefix(20)
        #expect(throws: (any Error).self) {
            try truncated.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
        }
    }

    @Test func rejectsAnEmptyBuffer() throws {
        let empty = Data()
        #expect(throws: (any Error).self) {
            try empty.withUnsafeBytes { try JPEGImageHash.includedRanges($0) }
        }
    }

    @Test func appendedTrailingDataChangesTheHash() throws {
        // Motion photos append a complete MP4 after EOI; MPF files carry a
        // second image there. Payload, not metadata: it must change the hash,
        // or the duplicate view would offer to delete the file with the video.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.jpg")))
        var withTrailer = base
        withTrailer.append(contentsOf: Array("ftypmp42 fake appended video payload".utf8))

        let one = try base.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        let two = try withTrailer.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        #expect(one != two)
    }

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func imageHashSurvivesAnEXIFEditOnAFileWithTrailingData() throws {
        // The warranty must hold now that trailing bytes are hashed: exiftool
        // rewrites the metadata segments but preserves an unknown trailer.
        let a = tree.root.appendingPathComponent("a.jpg")
        try Fixtures.writeImage(to: a)
        var withTrailer = try Data(contentsOf: a)
        withTrailer.append(contentsOf: Array("ftypmp42 fake appended video payload".utf8))
        try withTrailer.write(to: a)
        let b = tree.root.appendingPathComponent("b.jpg")
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

        #expect(try jpegHash(a) == jpegHash(b))
        #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
    }

    @Test func aDifferenceInAPP2ChangesTheHash() throws {
        // APP2 carries the ICC profile, which changes how the scan data
        // decodes into colours: image data, not metadata. Guards the denylist
        // against a future edit adding 0xE2.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.jpg")))
        var withAPP2 = Data(base.prefix(2))                         // SOI
        withAPP2.append(contentsOf: [0xFF, 0xE2, 0x00, 0x10])      // APP2, length 16
        withAPP2.append(contentsOf: Array("ICC_PROFILE\u{00}".utf8))
        withAPP2.append(contentsOf: [0x01, 0x01])
        withAPP2.append(base.dropFirst(2))

        let one = try base.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        let two = try withAPP2.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        #expect(one != two)
    }

    @Test func aStandaloneMarkerOutsideTheScanChangesTheHash() throws {
        // TEM (0xFF01) is recognised and standalone; it must be hashed, not
        // silently skipped — the one place a recognised marker was dropped.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.jpg")))
        var withTEM = Data(base.prefix(2))                          // SOI
        withTEM.append(contentsOf: [0xFF, 0x01])                    // TEM
        withTEM.append(base.dropFirst(2))

        let one = try base.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        let two = try withTEM.withUnsafeBytes { try ImageDataDigest.digest($0, ranges: JPEGImageHash.includedRanges($0)) }
        #expect(one != two)
    }

    @Test func kindAgreesWithTheMediaTypeColumnValue() throws {
        // `image_hash_kind` is persisted; the recorded kind and the parser
        // that produced it must not be able to drift apart.
        #expect(MediaType.forExtension("jpg")?.imageHashKind == JPEGImageHash.kind)
        #expect(JPEGImageHash.kind == "jpeg-scan-v1")
    }
}
