import Testing
import Foundation
@testable import LightboxCore

private func webpHash(_ data: Data) throws -> String {
    try data.withUnsafeBytes { bytes in
        try ImageDataDigest.digest(bytes, ranges: WebPImageHash.includedRanges(bytes))
    }
}

private func webpHash(_ url: URL) throws -> String {
    try webpHash(Data(contentsOf: url))
}

/// A RIFF chunk: a four-byte name, a little-endian payload length, the payload,
/// and a pad byte when that length is odd.
private func webpChunk(_ name: String, _ payload: [UInt8]) -> Data {
    var out = Data(name.utf8)
    let n = UInt32(payload.count)
    out.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
                            UInt8((n >> 16) & 0xFF), UInt8(n >> 24)])
    out.append(contentsOf: payload)
    if payload.count & 1 == 1 { out.append(0x00) }
    return out
}

/// Wraps chunk bytes in a RIFF/WEBP header with a correct declared size.
private func riffContainer(_ chunks: Data) -> Data {
    var out = Data("RIFF".utf8)
    let n = UInt32(4 + chunks.count)
    out.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
                            UInt8((n >> 16) & 0xFF), UInt8(n >> 24)])
    out.append(contentsOf: Array("WEBP".utf8))
    out.append(chunks)
    return out
}

/// Splices a chunk in immediately after the 12-byte RIFF header and grows the
/// declared container size to match, exactly as a real writer would.
private func inserting(_ chunk: Data, afterHeaderIn base: Data) -> Data {
    var out = Data(base.prefix(12))
    out.append(chunk)
    out.append(base.dropFirst(12))
    let grown = UInt32(Int(base[4]) | Int(base[5]) << 8 | Int(base[6]) << 16
                       | Int(base[7]) << 24) + UInt32(chunk.count)
    out.replaceSubrange(4..<8, with: [UInt8(grown & 0xFF), UInt8((grown >> 8) & 0xFF),
                                      UInt8((grown >> 16) & 0xFF), UInt8(grown >> 24)])
    return out
}

/// Walks the container's chunks independently of the parser and reports, per
/// name, whether the returned ranges cover that chunk. Ranges are coalesced, so
/// one range no longer corresponds to one chunk and their start offsets can no
/// longer be read as a list of included names.
private func webpChunkCoverage(_ data: Data) throws -> [String: Bool] {
    let ranges = try data.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
    let riffEnd = 8 + (Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24)
    var covered: [String: Bool] = [:]
    var i = 12
    while i + 8 <= riffEnd {
        let name = String(decoding: data[i..<(i + 4)], as: UTF8.self)
        let length = Int(data[i + 4]) | Int(data[i + 5]) << 8
                   | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
        covered[name] = ranges.contains { $0.contains(i) }
        i += 8 + length + (length & 1)
    }
    return covered
}

/// A `struct` suite so swift-testing builds a fresh instance per test and
/// releases it afterwards, matching the other hashing suites.
struct WebPImageHashTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    /// The names the allowlist is expected to contain, written out here rather
    /// than read from `WebPImageHash.includedChunkNames`. A typo in the
    /// implementation's set (`"VP8"` for `"VP8 "`) has to fail these tests, and
    /// it would not if the test injected whatever that set happens to say.
    static let allowlisted = ["VP8 ", "VP8L", "ALPH", "ANIM", "ANMF", "ICCP"]

    /// Chunks that must not contribute to the hash: the two metadata chunks
    /// WebP defines, the extended-format header exiftool inserts, and names
    /// this parser has never heard of — including near-misses of allowlisted
    /// names, which must not be matched loosely.
    static let notAllowlisted = ["EXIF", "XMP ", "VP8X", "unKn", "VP8l", "ICCp", "ANMx"]

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func webpImageHashSurvivesPromotionToExtendedFormat() throws {
        // The reason WebP uses an allowlist. Writing EXIF to a simple-format
        // WebP promotes it to extended format: exiftool inserts a VP8X header
        // chunk that was not there before. A denylist of EXIF/XMP would see a
        // brand-new chunk and hash the file differently.
        let a = tree.root.appendingPathComponent("a.webp")
        let b = tree.root.appendingPathComponent("b.webp")
        try FileManager.default.copyItem(at: Fixtures.url("simple.webp"), to: a)
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-DateTimeOriginal=2021:07:08 09:10:11", b.path]))

        // The edit really did restructure the file, not merely rewrite bytes.
        let promoted = try Data(contentsOf: b)
        let coverage = try webpChunkCoverage(promoted)
        #expect(coverage["VP8X"] == false)
        #expect(coverage["EXIF"] == false)
        #expect(coverage["VP8L"] == true)

        #expect(try webpHash(a) == webpHash(b))                       // the warranty
        #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))
    }

    @Test func theFixtureIsASimpleFormatLosslessWebP() throws {
        // Pins what the checked-in fixture is: if it were an extended-format
        // file the promotion test above would prove nothing.
        let data = try Data(contentsOf: Fixtures.url("simple.webp"))
        #expect(data.count == 248)
        #expect(try webpChunkCoverage(data) == ["VP8L": true])
    }

    @Test func theFixtureHashesAsOneRangeCoveringItsOnlyChunk() throws {
        let data = try Data(contentsOf: Fixtures.url("simple.webp"))
        let ranges = try data.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        #expect(ranges == [12..<248])
    }

    @Test func everyAllowlistedChunkNameChangesTheHash() throws {
        // The allowlist's warranty in the direction that matters for
        // correctness: a chunk that carries or governs image data must move the
        // hash, or two different images could be called identical.
        let base = try Data(contentsOf: Fixtures.url("simple.webp"))
        let baseline = try webpHash(base)

        for name in Self.allowlisted {
            let injected = inserting(webpChunk(name, Array("payload-\(name)".utf8)),
                                     afterHeaderIn: base)
            #expect(injected.count > base.count)            // the chunk really landed
            #expect(try webpHash(injected) != baseline,
                    "\(name) is on the allowlist and must change the hash")
        }
    }

    @Test func everyNonAllowlistedChunkNameLeavesTheHashUnchanged() throws {
        let base = try Data(contentsOf: Fixtures.url("simple.webp"))
        let baseline = try webpHash(base)

        for name in Self.notAllowlisted {
            let injected = inserting(webpChunk(name, Array("payload-\(name)".utf8)),
                                     afterHeaderIn: base)
            #expect(injected.count > base.count)
            #expect(try webpHash(injected) == baseline,
                    "\(name) is not on the allowlist and must not change the hash")
        }
    }

    @Test func aByteChangedInsideAnAllowlistedChunkChangesTheHash() throws {
        // Guards against an allowlist that names the right chunks but hashes
        // only their headers: the payload has to be in the digest too.
        var edited = try Data(contentsOf: Fixtures.url("simple.webp"))
        let baseline = try webpHash(edited)
        let payloadStart = 20                               // 12 header + 8 chunk header
        edited[payloadStart + 40] ^= 0xFF

        #expect(try webpHash(edited) != baseline)
    }

    @Test func webpRejectsANonRIFFBuffer() throws {
        let junk = Data("JUNK\u{08}\u{00}\u{00}\u{00}WEBP".utf8)
        let error = #expect(throws: HashError.self) {
            try junk.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        #expect(error == .malformed("not a RIFF/WEBP container"))
    }

    @Test func webpRejectsARIFFContainerThatIsNotWEBP() throws {
        // A .webp extension on an AVI is exactly the "the extension lies" case.
        var forged = Data("RIFF".utf8)
        forged.append(contentsOf: [0x04, 0x00, 0x00, 0x00])
        forged.append(contentsOf: Array("AVI ".utf8))
        let error = #expect(throws: HashError.self) {
            try forged.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        #expect(error == .malformed("not a RIFF/WEBP container"))
    }

    @Test func webpRejectsAnEmptyBuffer() throws {
        let error = #expect(throws: HashError.self) {
            try Data().withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func webpRejectsABufferShorterThanTheRIFFHeader() throws {
        let short = try Data(contentsOf: Fixtures.url("simple.webp")).prefix(11)
        let error = #expect(throws: HashError.self) {
            try short.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func webpRejectsADeclaredContainerSizePastTheEnd() throws {
        let truncated = try Data(contentsOf: Fixtures.url("simple.webp")).prefix(100)
        let error = #expect(throws: HashError.self) {
            try truncated.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func webpRejectsADeclaredSizeTooSmallForTheFormType() throws {
        var forged = Data("RIFF".utf8)
        forged.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
        forged.append(contentsOf: Array("WEBP".utf8))
        let error = #expect(throws: HashError.self) {
            try forged.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("RIFF size"))
    }

    @Test func webpRejectsAChunkLengthPastTheEnd() throws {
        // The declared container size is honest here — 12 bytes of payload
        // after the size field, so the container ends exactly at the buffer's
        // end. Only the chunk length is forged, so this exercises the chunk-fit
        // guard rather than being caught earlier by the container-fit guard.
        var forged = Data("RIFF".utf8)
        forged.append(contentsOf: [0x0C, 0x00, 0x00, 0x00])
        forged.append(contentsOf: Array("WEBP".utf8))
        forged.append(contentsOf: Array("VP8L".utf8))
        forged.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x7F])          // enormous length
        #expect(forged.count == 20)
        let error = #expect(throws: HashError.self) {
            try forged.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        #expect(error == .truncated)
    }

    @Test func webpRejectsStrayBytesInsideTheContainer() throws {
        // Bytes the container's own declared size accounts for, but that are
        // too few to be a chunk header. The file is not short — its contents
        // are wrong — so this must not be reported as truncation.
        var body = webpChunk("VP8L", Array(repeating: 0x11, count: 8))
        body.append(contentsOf: [0x01, 0x02, 0x03])
        let error = #expect(throws: HashError.self) {
            try riffContainer(body).withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("stray"))
    }

    @Test func webpRejectsAContainerWithNoImageChunks() throws {
        // A well-formed RIFF/WEBP carrying only metadata has no image data to
        // hash. Returning an empty digest would make every such file a
        // duplicate of every other one.
        let body = webpChunk("EXIF", Array(repeating: 0x22, count: 16))
        let error = #expect(throws: HashError.self) {
            try riffContainer(body).withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("no image"))
    }

    @Test func metadataOnlyContainerIsRejectedEvenWithATrailer() throws {
        // The trailing-byte range must not rescue a file that has no image
        // chunk at all: the emptiness check runs on the chunks, before the
        // trailer is appended.
        var forged = riffContainer(webpChunk("EXIF", Array(repeating: 0x22, count: 16)))
        forged.append(contentsOf: Array("appended payload".utf8))
        let error = #expect(throws: HashError.self) {
            try forged.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("no image"))
    }

    @Test func anOddLengthChunkPayloadIsPaddedToAnEvenBoundary() throws {
        // A parser that ignored the RIFF pad byte would read the next chunk's
        // header one byte early and reject a perfectly legal file.
        let body = webpChunk("VP8L", Array(repeating: 0x11, count: 7))
                 + webpChunk("EXIF", Array(repeating: 0x22, count: 3))
                 + webpChunk("ALPH", Array(repeating: 0x33, count: 5))
        let data = riffContainer(body)
        #expect(try webpChunkCoverage(data) == ["VP8L": true, "EXIF": false, "ALPH": true])
    }

    @Test func appendedTrailingDataChangesTheHash() throws {
        // Bytes past the size the RIFF header declares are payload, not
        // metadata — the same rule JPEG applies after EOI and PNG after IEND.
        // Discarding them would make a file with an appended payload hash
        // identically to one without, and the duplicate view would then offer
        // to delete the copy carrying the extra content.
        let base = try Data(contentsOf: Fixtures.url("simple.webp"))
        var withTrailer = base
        withTrailer.append(contentsOf: Array("ftypmp42 fake appended video payload".utf8))

        #expect(try webpHash(base) != webpHash(withTrailer))
        let ranges = try withTrailer.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        // The chunk range runs to the container's end and the trailer abuts it,
        // so coalescing leaves a single range covering both.
        #expect(ranges == [12..<withTrailer.count])
    }

    @Test func kindAgreesWithTheMediaTypeColumnValue() throws {
        // `image_hash_kind` is persisted; the recorded kind and the parser that
        // produced it must not be able to drift apart.
        #expect(MediaType.forExtension("webp")?.imageHashKind == WebPImageHash.kind)
        #expect(WebPImageHash.kind == "webp-chunk-v1")
    }

    @Test func aChunkFloodedFileCollapsesToOneRange() throws {
        // 200k empty VP8L chunks: eight bytes of header each and nothing else.
        // Uncoalesced this is one `Range` per chunk, and Task 9's 256 MB
        // in-memory limit admits a file of this shape — at that size the PNG
        // equivalent cost 1.2 GB of RSS, and the indexer hashes several files
        // at once.
        var body = Data()
        body.reserveCapacity(200_000 * 8)
        for _ in 0..<200_000 { body.append(webpChunk("VP8L", [])) }
        let flood = riffContainer(body)

        let ranges = try flood.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        // Every byte after the RIFF header, described by a single range.
        #expect(ranges == [12..<flood.count])
    }

    @Test func alternatingIncludedAndExcludedChunksProduceSeparateRanges() throws {
        // Coalescing must not silently swallow an excluded chunk that sits
        // between two included ones: that would put the metadata back in the
        // digest and break the warranty.
        let body = webpChunk("VP8L", [0x11, 0x22])
                 + webpChunk("EXIF", [0x33, 0x44])
                 + webpChunk("ALPH", [0x55, 0x66])
        let data = riffContainer(body)
        let ranges = try data.withUnsafeBytes { try WebPImageHash.includedRanges($0) }
        #expect(ranges == [12..<22, 32..<42])
    }
}
