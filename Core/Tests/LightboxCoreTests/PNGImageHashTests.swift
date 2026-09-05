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

    @Test func pngExcludesTextAndTimeAndPhysicalChunks() throws {
        let url = try Fixtures.writeImage(to: tree.root.appendingPathComponent("a.png"), format: .png)
        let data = try Data(contentsOf: url)
        let types: [String] = try data.withUnsafeBytes { bytes in
            try PNGImageHash.includedRanges(bytes).map { range in
                String(decoding: (0..<4).map { bytes[range.lowerBound + 4 + $0] }, as: UTF8.self)
            }
        }
        #expect(types.contains("IHDR"))
        #expect(types.contains("IDAT"))
        #expect(types.contains("IEND"))
        #expect(!types.contains("eXIf"))
        #expect(!types.contains("iTXt"))
        #expect(!types.contains("tEXt"))
        #expect(!types.contains("pHYs"))
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
        // 0xFFFFFFFF is above the spec's 2^31 - 1 cap. Adding it to an offset
        // must fail a guard rather than wrap an Int and produce a valid-looking
        // range that walks off the buffer.
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
}
