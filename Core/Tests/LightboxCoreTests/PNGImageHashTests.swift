import Testing
import Foundation
@testable import LightboxCore

private func pngHash(_ data: Data) throws -> String {
    try data.withUnsafeBytes { bytes in
        try ImageDataDigest.digest(bytes, ranges: PNGImageHash.includedRanges(bytes))
    }
}

private func pngHash(_ url: URL) throws -> String {
    try pngHash(Data(contentsOf: url))
}

/// A PNG chunk: length, type, data, CRC. The CRC bytes are arbitrary — this
/// parser hashes chunks rather than decoding them, and never validates one.
private func pngChunk(_ type: String, _ payload: [UInt8]) -> Data {
    var out = Data()
    let n = UInt32(payload.count)
    out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF),
                            UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    out.append(contentsOf: Array(type.utf8))
    out.append(contentsOf: payload)
    out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    return out
}

/// Splices a chunk in immediately after IHDR, which every other chunk but the
/// signature must follow.
private func inserting(_ chunk: Data, afterIHDRIn base: Data) -> Data {
    let ihdrLength = Int(base[8]) << 24 | Int(base[9]) << 16
                   | Int(base[10]) << 8 | Int(base[11])
    let at = 8 + 12 + ihdrLength
    var out = Data(base.prefix(at))
    out.append(chunk)
    out.append(base.dropFirst(at))
    return out
}

/// Walks the file's chunks independently of the parser and reports, per type,
/// whether the returned ranges cover that chunk. Ranges are coalesced, so one
/// range no longer corresponds to one chunk and their start offsets can no
/// longer be read as a list of included types.
private func pngChunkCoverage(_ data: Data) throws -> [String: Bool] {
    let ranges = try data.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
    var covered: [String: Bool] = [:]
    var i = 8
    while i + 8 <= data.count {
        let length = Int(data[i]) << 24 | Int(data[i + 1]) << 16
                   | Int(data[i + 2]) << 8 | Int(data[i + 3])
        let type = String(decoding: data[(i + 4)..<(i + 8)], as: UTF8.self)
        covered[type] = ranges.contains { $0.contains(i) }
        if type == "IEND" { break }
        i += 12 + length
    }
    return covered
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards, matching the other hashing suites.
struct PNGImageHashTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func pngImageHashSurvivesAnEXIFEdit() throws {
        let a = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
        let b = tree.root.appendingPathComponent("b.png")
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

        #expect(try pngHash(a) == pngHash(b))                         // the warranty
        #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
    }

    @Test func pngExcludesTheMetadataChunksThatTheFixtureActuallyContains() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
        let covered = try pngChunkCoverage(Data(contentsOf: url))

        // Presence checks first. An assertion that a chunk is not covered is
        // vacuous when the chunk is not in the file at all, so only the two
        // metadata chunks ImageIO actually writes are asserted on here; the
        // rest of the denylist is exercised by injection below.
        #expect(covered["eXIf"] != nil)
        #expect(covered["iTXt"] != nil)

        #expect(covered["eXIf"] == false)
        #expect(covered["iTXt"] == false)
        #expect(covered["IHDR"] == true)
        #expect(covered["IDAT"] == true)
        #expect(covered["IEND"] == true)
        #expect(covered["sRGB"] == true)                    // a retained colour chunk
    }

    @Test func everyExcludedChunkTypeLeavesTheHashUnchanged() throws {
        // The types are written out here rather than read from
        // `PNGImageHash.excludedTypeNames`: a typo in the denylist (`pHYS` for
        // `pHYs`) has to fail this test, and it would not if the test injected
        // whatever the denylist happens to say. This is also the only coverage
        // `zTXt`, `tIME`, `tEXt` and `pHYs` get — ImageIO writes none of them.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.png"), format: .png))
        let baseline = try pngHash(base)

        for type in ["tEXt", "zTXt", "iTXt", "eXIf", "tIME", "pHYs"] {
            let injected = inserting(pngChunk(type, Array("payload-\(type)".utf8)),
                                     afterIHDRIn: base)
            #expect(injected.count > base.count)            // the chunk really landed
            #expect(try pngHash(injected) == baseline,
                    "\(type) is on the denylist and must not change the hash")
        }
    }

    @Test func pngWithDifferentPixelsHashesDifferently() throws {
        let a = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"),
                                        format: .png, seed: 0)
        let b = try Fixtures.writeImage(to: tree.root.appendingPathComponent("b.png"),
                                        format: .png, seed: 7)
        #expect(try pngHash(a) != pngHash(b))
    }

    @Test func pngRejectsABadSignature() throws {
        let junk = Data(repeating: 0x00, count: 64)
        let error = #expect(throws: HashError.self) {
            try junk.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
        }
        #expect(error == .malformed("bad PNG signature"))
    }

    @Test func pngRejectsAnEmptyBuffer() throws {
        let empty = Data()
        let error = #expect(throws: HashError.self) {
            try empty.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func pngRejectsATruncatedChunk() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
        let truncated = try Data(contentsOf: url).prefix(30)
        let error = #expect(throws: HashError.self) {
            try truncated.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func pngRejectsAFileWithNoIEND() throws {
        // A well-formed prefix that ends exactly on a chunk boundary must not
        // be accepted: without IEND the file is truncated, not complete.
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
        let data = try Data(contentsOf: url)
        let ihdrLength = Int(data[8]) << 24 | Int(data[9]) << 16
                       | Int(data[10]) << 8 | Int(data[11])
        let throughIHDR = data.prefix(8 + 12 + ihdrLength)
        let error = #expect(throws: HashError.self) {
            try throughIHDR.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func pngRejectsAnAbsurdChunkLength() throws {
        var forged = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        forged.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])          // length ~2GB
        forged.append(contentsOf: Array("IHDR".utf8))
        forged.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // It is within the spec's cap, so it must be rejected for not fitting
        // the buffer — not by accident through some other guard.
        let error = #expect(throws: HashError.self) {
            try forged.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func pngRejectsAChunkLengthAboveTheSpecMaximum() throws {
        // 0xFFFFFFFF is above the spec's 2^31 - 1 cap. Such a length is
        // rejected either way — nothing that large fits a real buffer, so the
        // fit guard would catch it — so this pins the classification, not the
        // memory safety: a forged length must report `.malformed` rather than
        // blame a truncated file.
        var forged = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        forged.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        forged.append(contentsOf: Array("IDAT".utf8))
        let error = #expect(throws: HashError.self) {
            try forged.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
        }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("exceeds the PNG maximum"))
    }

    @Test func appendedTrailingDataChangesTheHash() throws {
        // Bytes after IEND are payload, not metadata. Discarding them would
        // make a file with an appended payload hash identically to one without,
        // and the duplicate view would offer to delete the one with the extra
        // content.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.png"), format: .png))
        var withTrailer = base
        withTrailer.append(contentsOf: Array("ftypmp42 fake appended video payload".utf8))

        #expect(try pngHash(base) != pngHash(withTrailer))
    }

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func pngImageHashSurvivesAnEXIFEditOnAFileWithTrailingData() throws {
        // The warranty must still hold now that trailing bytes are hashed:
        // exiftool rewrites the eXIf and iTXt chunks but preserves the trailer.
        let a = tree.root.appendingPathComponent("a.png")
        try Fixtures.writeImage(to: a, format: .png)
        var withTrailer = try Data(contentsOf: a)
        withTrailer.append(contentsOf: Array("ftypmp42 fake appended video payload".utf8))
        try withTrailer.write(to: a)
        let b = tree.root.appendingPathComponent("b.png")
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

        #expect(try pngHash(a) == pngHash(b))
        #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
    }

    @Test func aColourChunkChangesTheHash() throws {
        // gAMA changes how the samples decode into colours, so it is image
        // data. Guards the denylist against a future edit adding it.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.png"), format: .png))
        let withGAMA = inserting(pngChunk("gAMA", [0x00, 0x00, 0xB1, 0x8F]), afterIHDRIn: base)

        #expect(try pngHash(base) != pngHash(withGAMA))
    }

    @Test func anUnrecognisedAncillaryChunkChangesTheHash() throws {
        // The denylist's whole point: a chunk this parser has never heard of
        // is hashed, because it may well affect what the file decodes to.
        let base = try Data(contentsOf: Fixtures.writeImage(
            to: tree.root.appendingPathComponent("a.png"), format: .png))
        let withUnknown = inserting(pngChunk("unKn", [0x01, 0x02, 0x03]), afterIHDRIn: base)

        #expect(try pngHash(base) != pngHash(withUnknown))
    }

    @Test func kindAgreesWithTheMediaTypeColumnValue() throws {
        // `image_hash_kind` is persisted; the recorded kind and the parser
        // that produced it must not be able to drift apart.
        #expect(MediaType.forExtension("png")?.imageHashKind == PNGImageHash.kind)
        #expect(PNGImageHash.kind == "png-idat-v1")
    }

    @Test func aChunkFloodedFileCollapsesToOneRange() throws {
        // 200k minimum-size IDAT chunks. Uncoalesced this is one range per
        // chunk; at Task 9's 256 MB in-memory limit that shape cost 1.2 GB of
        // RSS for PNG and 5.7 GB for the JPEG equivalent, and the indexer
        // hashes several files at once.
        var flood = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        flood.append(pngChunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]))
        for _ in 0..<200_000 { flood.append(pngChunk("IDAT", [])) }
        flood.append(pngChunk("IEND", []))

        let ranges = try flood.withUnsafeBytes { try PNGImageHash.includedRanges($0) }
        // Every byte after the signature, described by a single range.
        #expect(ranges == [8..<flood.count])
    }
}
