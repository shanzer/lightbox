import Testing
import Foundation
@testable import LightboxCore

private func jpegHash(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return try data.withUnsafeBytes { bytes in
        try ImageDataDigest.digest(bytes, ranges: JPEGImageHash.includedRanges(bytes))
    }
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
        let markers: [UInt8] = try data.withUnsafeBytes { bytes in
            try JPEGImageHash.includedRanges(bytes).map { bytes.load(fromByteOffset: $0.lowerBound + 1, as: UInt8.self) }
        }
        #expect(!markers.contains(0xE0))
        #expect(!markers.contains(0xE1))
        #expect(!markers.contains(0xED))
        #expect(!markers.contains(0xFE))
        #expect(markers.contains(0xC0) || markers.contains(0xC2))   // SOF
        #expect(markers.contains(0xDA))                             // SOS
        #expect(markers.contains(0xD9))                             // EOI
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
}
