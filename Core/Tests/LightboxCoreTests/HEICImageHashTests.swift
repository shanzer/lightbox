import Testing
import Foundation
@testable import LightboxCore

private func heicHash(_ data: Data) throws -> String {
    try data.withUnsafeBytes { bytes in
        try ImageDataDigest.digest(bytes, ranges: HEICImageHash.includedRanges(bytes))
    }
}

private func heicHash(_ url: URL) throws -> String {
    try heicHash(Data(contentsOf: url))
}

private func heicRanges(_ data: Data) throws -> [Range<Int>] {
    try data.withUnsafeBytes { try HEICImageHash.includedRanges($0) }
}

// MARK: - A hand-built HEIF item file
//
// ImageIO writes a single-`hvc1` HEIC, which exercises only the simplest shape.
// Every HEIC in the real library is a *tiled* file whose primary item is a
// `grid` — so the grid path, the `idat` construction method, and the hostile
// extent counts all need a container this test file builds itself, the way
// `WebPImageHashTests` builds RIFF containers.

private func be(_ value: Int, _ width: Int) -> [UInt8] {
    var out = [UInt8]()
    for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
        out.append(UInt8(truncatingIfNeeded: value >> shift))
    }
    return out
}

/// A plain box: a four-byte big-endian size, a four-character type, a payload.
private func box(_ type: String, _ payload: Data) -> Data {
    var out = Data(be(8 + payload.count, 4))
    out.append(contentsOf: Array(type.utf8))
    out.append(payload)
    return out
}

/// A FullBox: a box whose payload begins with a one-byte version and three
/// bytes of flags.
private func fullBox(_ type: String, version: Int, _ payload: Data) -> Data {
    var body = Data([UInt8(version), 0, 0, 0])
    body.append(payload)
    return box(type, body)
}

private struct HEIFItem {
    var id: Int
    var type: String            // "hvc1", "grid", "Exif", "mime", …
    /// The item's bytes. A `grid` item's descriptor goes in `idat` instead, so
    /// this is empty for one.
    var payload: [UInt8] = []
    /// `construction_method`: 0 = file offset, 1 = relative to `idat`.
    var construction: Int = 0
}

/// Assembles a minimal but structurally valid HEIF item file.
///
/// `mdat` is laid out in item order, so tiles abut — which is what real files
/// look like and what makes the coalescing assertions meaningful.
private struct HEIFBuilder {
    var items: [HEIFItem] = []
    var primary: Int = 1
    /// `iref` entries, as (type, fromID, toIDs).
    var references: [(String, Int, [Int])] = []
    /// The `idat` payload, holding any `construction_method == 1` item's bytes.
    var idat: [UInt8] = []
    /// Bytes appended after the last box.
    var trailer: [UInt8] = []
    var majorBrand = "heic"
    var compatibleBrands = ["mif1", "heic"]

    func build() -> Data {
        var ftypBody = Data(Array(majorBrand.utf8))
        ftypBody.append(contentsOf: be(0, 4))
        for brand in compatibleBrands { ftypBody.append(contentsOf: Array(brand.utf8)) }
        let ftyp = box("ftyp", ftypBody)

        let hdlr = fullBox("hdlr", version: 0,
                           Data(be(0, 4) + Array("pict".utf8) + [UInt8](repeating: 0, count: 13)))
        let pitm = fullBox("pitm", version: 0, Data(be(primary, 2)))

        var infes = Data()
        for item in items {
            var body = Data(be(item.id, 2))
            body.append(contentsOf: be(0, 2))               // protection index
            body.append(contentsOf: Array(item.type.utf8))
            body.append(0)                                  // empty item_name
            infes.append(fullBox("infe", version: 2, body))
        }
        var iinfBody = Data(be(items.count, 2))
        iinfBody.append(infes)
        let iinf = fullBox("iinf", version: 0, iinfBody)

        var irefBody = Data()
        for (type, from, tos) in references {
            var body = Data(be(from, 2))
            body.append(contentsOf: be(tos.count, 2))
            for to in tos { body.append(contentsOf: be(to, 2)) }
            irefBody.append(box(type, body))
        }
        let iref = references.isEmpty ? Data() : fullBox("iref", version: 0, irefBody)

        let idatBox = idat.isEmpty ? Data() : box("idat", Data(idat))

        // `iloc` must name absolute file offsets, which depend on how large
        // `iloc` itself is — so it is built once with placeholder offsets to
        // learn its length, then rebuilt with the real ones.
        func makeILOC(mdatStart: Int) -> Data {
            var body = Data([0x44, 0x00])                   // offset_size 4, length_size 4,
                                                            // base_offset_size 0, index_size 0
            body.append(contentsOf: be(items.count, 2))
            var cursor = mdatStart
            var idatCursor = 0
            for item in items {
                body.append(contentsOf: be(item.id, 2))
                body.append(contentsOf: be(item.construction, 2))
                body.append(contentsOf: be(0, 2))           // data_reference_index
                body.append(contentsOf: be(1, 2))           // extent_count
                if item.construction == 1 {
                    body.append(contentsOf: be(idatCursor, 4))
                    body.append(contentsOf: be(item.payload.count, 4))
                    idatCursor += item.payload.count
                } else {
                    body.append(contentsOf: be(cursor, 4))
                    body.append(contentsOf: be(item.payload.count, 4))
                    cursor += item.payload.count
                }
            }
            return fullBox("iloc", version: 1, body)
        }

        var metaFixed = Data()
        metaFixed.append(hdlr)
        metaFixed.append(pitm)
        metaFixed.append(iinf)
        metaFixed.append(iref)
        metaFixed.append(idatBox)

        let ilocLength = makeILOC(mdatStart: 0).count
        // ftyp + meta header (8) + version/flags (4) + fixed children + iloc,
        // then mdat's own eight-byte header.
        let mdatStart = ftyp.count + 12 + metaFixed.count + ilocLength + 8
        var metaBody = metaFixed
        metaBody.append(makeILOC(mdatStart: mdatStart))
        let meta = fullBox("meta", version: 0, metaBody)

        var mdatPayload = Data()
        for item in items where item.construction == 0 {
            mdatPayload.append(contentsOf: item.payload)
        }
        let mdat = box("mdat", mdatPayload)

        var out = ftyp
        out.append(meta)
        out.append(mdat)
        #expect(out.count - mdat.count + 8 == mdatStart,
                "the builder mis-predicted where mdat's payload starts")
        out.append(contentsOf: trailer)
        return out
    }
}

/// Tile bytes that differ per tile, so a rule that hashed the wrong tiles, or
/// hashed them in the wrong order, produces a different digest.
private func tileBytes(_ index: Int, count: Int = 32) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0) }
}

/// A three-tile grid: primary `grid` item 4 whose descriptor lives in `idat`,
/// tiles 1–3 in `mdat`, plus an `Exif` item.
private func gridFixture(tileCount: Int = 3, seed: Int = 0) -> HEIFBuilder {
    var b = HEIFBuilder()
    for i in 1...tileCount {
        b.items.append(HEIFItem(id: i, type: "hvc1", payload: tileBytes(i &+ seed)))
    }
    let gridID = tileCount + 1
    b.items.append(HEIFItem(id: gridID, type: "grid",
                            payload: [0, 0, 0, 0, 0, 0, 0, 0], construction: 1))
    b.idat = [0, 0, 0, 0, 0, 0, 0, 0]
    b.items.append(HEIFItem(id: gridID + 1, type: "Exif",
                            payload: Array("EXIF-payload-goes-here".utf8)))
    b.primary = gridID
    b.references = [("dimg", gridID, Array(1...tileCount)),
                    ("cdsc", gridID + 1, [gridID])]
    return b
}

struct HEICImageHashTests {
    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    // MARK: - The warranty, against a real writer

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func heicImageHashSurvivesAnExiftoolMetadataRoundTrip() throws {
        // The experiment recorded in docs/superpowers/notes/2026-09-07-heic-
        // mdat-roundtrip.md, reduced to a fixture the suite can run everywhere:
        // exiftool rewrites the Exif item, inserts an XMP item, grows iinf/iref/
        // iloc and relocates the coded item — and the primary item's bytes come
        // through untouched.
        let a = tree.root.appendingPathComponent("a.heic")
        let b = tree.root.appendingPathComponent("b.heic")
        try Fixtures.writeImage(to: a, format: .heic)
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-Description=lightbox-experiment",
                          "-Keywords=heic-roundtrip",
                          "-DateTimeOriginal=2021:07:08 09:10:11",
                          "-OffsetTimeOriginal=-04:00", b.path]))

        // The write really did restructure the file rather than rewrite bytes
        // in place — otherwise this test would prove nothing.
        let before = try Data(contentsOf: a)
        let after = try Data(contentsOf: b)
        #expect(before.count != after.count)
        #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))

        #expect(try heicHash(a) == heicHash(b))                        // the warranty
    }

    @Test func aDifferentImageChangesTheHash() throws {
        let a = tree.root.appendingPathComponent("seed0.heic")
        let b = tree.root.appendingPathComponent("seed7.heic")
        try Fixtures.writeImage(to: a, format: .heic, seed: 0)
        try Fixtures.writeImage(to: b, format: .heic, seed: 7)

        #expect(try heicHash(a) != heicHash(b))
    }

    @Test func aByteChangedInsideACodedTileChangesTheHash() throws {
        // Guards against a rule that names the right extents but hashes only
        // their offsets: the coded bytes have to be in the digest.
        let base = gridFixture().build()
        let baseline = try heicHash(base)
        let ranges = try heicRanges(base)
        var edited = base
        edited[ranges[0].lowerBound + 1] ^= 0xFF

        #expect(try heicHash(edited) != baseline)
    }

    // MARK: - The grid, and what it must and must not include

    @Test func theGridPrimaryHashesItsTilesAndNothingElse() throws {
        // `pitm` names a derived item whose own extent is an eight-byte
        // descriptor in `idat`. A parser that hashed the primary item's own
        // extent would hash eight bytes of layout; one that ignored
        // construction_method 1 would hash the file's first eight bytes —
        // `ftyp`'s header — and call every HEIC a duplicate of every other.
        let data = gridFixture(tileCount: 3).build()
        let ranges = try heicRanges(data)

        // Three 32-byte tiles laid out consecutively at the head of mdat:
        // one coalesced range of 96 bytes, and nothing from idat or ftyp.
        #expect(ranges.count == 1)
        #expect(ranges[0].count == 96)
        #expect(ranges[0].lowerBound > 8)

        var expected = Data()
        for i in 1...3 { expected.append(contentsOf: tileBytes(i)) }
        #expect(Data(data[ranges[0]]) == expected)
    }

    @Test func theExifItemDoesNotContributeToTheHash() throws {
        var withExif = gridFixture()
        var withBiggerExif = gridFixture()
        withBiggerExif.items[withBiggerExif.items.count - 1].payload =
            Array("a completely different and much longer EXIF payload".utf8)

        #expect(try heicHash(withExif.build()) == heicHash(withBiggerExif.build()))
        #expect(withExif.build().count != withBiggerExif.build().count)
    }

    @Test func anAuxiliaryImageDoesNotContributeToTheHash() throws {
        // The gain map, the depth map and the portrait mattes are `auxl` items
        // that hang off the primary. Two files that are the same photograph
        // with different auxiliaries must group together, so they are excluded.
        let plain = gridFixture()
        var withAux = gridFixture()
        let auxID = 99
        withAux.items.append(HEIFItem(id: auxID, type: "hvc1",
                                      payload: Array(repeating: 0xAB, count: 64)))
        withAux.references.append(("auxl", auxID, [withAux.primary]))

        #expect(try heicHash(plain.build()) == heicHash(withAux.build()))
    }

    @Test func aThumbnailItemDoesNotContributeToTheHash() throws {
        let plain = gridFixture()
        var withThumb = gridFixture()
        withThumb.items.append(HEIFItem(id: 98, type: "hvc1",
                                        payload: Array(repeating: 0xCD, count: 48)))
        withThumb.references.append(("thmb", 98, [withThumb.primary]))

        #expect(try heicHash(plain.build()) == heicHash(withThumb.build()))
    }

    @Test func reorderingTheGridTilesChangesTheHash() throws {
        // The tiles are hashed in `dimg` order. Two files holding the same tile
        // bytes assembled into a different picture are different images.
        let normal = gridFixture(tileCount: 3)
        var reversed = gridFixture(tileCount: 3)
        reversed.references[0] = ("dimg", reversed.primary, [3, 2, 1])

        #expect(try heicHash(normal.build()) != heicHash(reversed.build()))
    }

    @Test func aSingleCodedItemPrimaryIsHashedDirectly() throws {
        // ImageIO writes this shape: `pitm` names an `hvc1` item outright, with
        // no `grid` and no `dimg`.
        var b = HEIFBuilder()
        b.items = [HEIFItem(id: 1, type: "hvc1", payload: tileBytes(1)),
                   HEIFItem(id: 2, type: "Exif", payload: Array("exif".utf8))]
        b.primary = 1
        b.references = [("cdsc", 2, [1])]
        let data = b.build()

        let ranges = try heicRanges(data)
        #expect(ranges.count == 1)
        #expect(Data(data[ranges[0]]) == Data(tileBytes(1)))
    }

    @Test func appendedTrailingDataChangesTheHash() throws {
        // Bytes past the last box are an appended payload, not metadata — the
        // rule JPEG applies after EOI, PNG after IEND and WebP past the
        // declared RIFF size. Discarding them would let a file carrying a
        // payload hash identically to one without, and the duplicate view would
        // then offer to delete the copy with the extra content.
        var withTrailer = gridFixture()
        withTrailer.trailer = Array("ftypmp42 fake appended video payload".utf8)

        #expect(try heicHash(gridFixture().build()) != heicHash(withTrailer.build()))
    }

    // MARK: - Amplification

    @Test func aGridOfManyAbuttingTilesCollapsesToOneRange() throws {
        // 30,000 one-byte tiles. Uncoalesced this is one `Range` per tile, and
        // Task 9's 256 MB in-memory limit admits a file of this shape — at that
        // size the PNG equivalent cost 1.2 GB of RSS, and the indexer hashes
        // several files at once.
        var b = HEIFBuilder()
        let tiles = 30_000
        for i in 1...tiles { b.items.append(HEIFItem(id: i, type: "hvc1", payload: [UInt8(i & 0xFF)])) }
        b.items.append(HEIFItem(id: tiles + 1, type: "grid",
                                payload: [0, 0, 0, 0, 0, 0, 0, 0], construction: 1))
        b.idat = [0, 0, 0, 0, 0, 0, 0, 0]
        b.primary = tiles + 1
        b.references = [("dimg", tiles + 1, Array(1...tiles))]

        let ranges = try heicRanges(b.build())
        #expect(ranges.count == 1)
        #expect(ranges[0].count == tiles)
    }

    @Test func aHostileExtentCountIsRefusedRatherThanAmplified() throws {
        // `extent_count` is sixteen bits and `offset_size` may be zero, so a
        // few hundred kilobytes of `iloc` can declare millions of extents that
        // cost nothing on disk and do not coalesce. The parser refuses past its
        // cap rather than materialising a `Range` for each.
        let data = hostileExtentFile(items: 20, extentsPerItem: 65_535)
        #expect(data.count < 2 << 20)                       // the file really is small

        let error = #expect(throws: HashError.self) { try heicRanges(data) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("extent"))
    }

    /// An `iloc` with `offset_size == 0` and `length_size == 1`: every extent
    /// costs one byte on disk, starts at the same place and has a different
    /// length, so none of them merge into its neighbour.
    private func hostileExtentFile(items: Int, extentsPerItem: Int) -> Data {
        let ftyp = box("ftyp", Data(Array("heic".utf8) + be(0, 4) + Array("mif1".utf8)))
        let hdlr = fullBox("hdlr", version: 0,
                           Data(be(0, 4) + Array("pict".utf8) + [UInt8](repeating: 0, count: 13)))
        // The primary is the `grid`, so every one of the tile items below is a
        // *wanted* item and its extents are charged against the budget.
        let pitm = fullBox("pitm", version: 0, Data(be(items + 1, 2)))

        var infes = Data()
        for i in 1...items {
            var body = Data(be(i, 2))
            body.append(contentsOf: be(0, 2))
            body.append(contentsOf: Array("hvc1".utf8))
            body.append(0)
            infes.append(fullBox("infe", version: 2, body))
        }
        infes.append(fullBox("infe", version: 2,
                             Data(be(items + 1, 2) + be(0, 2) + Array("grid".utf8) + [0])))
        var iinfBody = Data(be(items + 1, 2))
        iinfBody.append(infes)
        let iinf = fullBox("iinf", version: 0, iinfBody)

        var irefBody = Data(be(items + 1, 2))
        irefBody.append(contentsOf: be(items, 2))
        for i in 1...items { irefBody.append(contentsOf: be(i, 2)) }
        let iref = fullBox("iref", version: 0, box("dimg", irefBody))

        var ilocBody = Data([0x01, 0x40])            // offset_size 0, length_size 1,
                                                     // base_offset_size 4, index_size 0
        ilocBody.append(contentsOf: be(items + 1, 2))
        for i in 1...(items + 1) {
            ilocBody.append(contentsOf: be(i, 2))
            ilocBody.append(contentsOf: be(0, 2))    // construction_method 0
            ilocBody.append(contentsOf: be(0, 2))    // data_reference_index
            ilocBody.append(contentsOf: be(0, 4))    // base_offset
            let count = i > items ? 1 : extentsPerItem
            ilocBody.append(contentsOf: be(count, 2))
            for e in 0..<count { ilocBody.append(UInt8(truncatingIfNeeded: e &+ 1)) }
        }
        let iloc = fullBox("iloc", version: 1, ilocBody)

        var metaBody = Data()
        metaBody.append(hdlr); metaBody.append(pitm); metaBody.append(iinf)
        metaBody.append(iref); metaBody.append(iloc)
        let meta = fullBox("meta", version: 0, metaBody)

        var out = ftyp
        out.append(meta)
        out.append(box("mdat", Data(repeating: 0x5A, count: 1024)))
        return out
    }

    // MARK: - Malformed input

    @Test func heicRejectsAnEmptyBuffer() throws {
        let error = #expect(throws: HashError.self) { try heicRanges(Data()) }
        #expect(error == .truncated)
    }

    @Test func heicRejectsABufferWithNoFtyp() throws {
        var forged = Data(be(16, 4))
        forged.append(contentsOf: Array("moov".utf8))
        forged.append(contentsOf: [UInt8](repeating: 0, count: 8))
        let error = #expect(throws: HashError.self) { try heicRanges(forged) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("ftyp"))
    }

    @Test func heicRejectsANonHEIFBrand() throws {
        // An MP4 with a .heic extension is exactly the "the extension lies"
        // case that `FileHasher` must survive.
        var b = gridFixture()
        b.majorBrand = "isom"
        b.compatibleBrands = ["isom", "mp42"]
        let error = #expect(throws: HashError.self) { try heicRanges(b.build()) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("brand"))
    }

    @Test func heicRejectsAFileWithNoMetaBox() throws {
        var forged = box("ftyp", Data(Array("heic".utf8) + be(0, 4) + Array("mif1".utf8)))
        forged.append(box("mdat", Data(repeating: 0x11, count: 32)))
        let error = #expect(throws: HashError.self) { try heicRanges(forged) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("meta"))
    }

    @Test func heicRejectsAPrimaryItemWithNoLocation() throws {
        // A well-formed container whose `pitm` names an item `iloc` does not
        // describe has no image data to hash. Hashing nothing would make every
        // such file a duplicate of every other one.
        var b = gridFixture()
        b.primary = 4242
        let error = #expect(throws: HashError.self) { try heicRanges(b.build()) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("no image"))
    }

    @Test func heicRejectsAnExtentPastTheEndOfTheBuffer() throws {
        var data = gridFixture().build()
        data = data.prefix(data.count - 40)               // lop off most of mdat
        let error = #expect(throws: HashError.self) { try heicRanges(data) }
        #expect(error == .truncated)
    }

    @Test func heicRejectsABoxThatOverrunsTheBuffer() throws {
        var forged = box("ftyp", Data(Array("heic".utf8) + be(0, 4) + Array("mif1".utf8)))
        forged.append(contentsOf: be(1 << 20, 4))
        forged.append(contentsOf: Array("meta".utf8))
        let error = #expect(throws: HashError.self) { try heicRanges(forged) }
        #expect(error == .truncated)
    }

    // MARK: - Wiring

    @Test func kindAgreesWithTheMediaTypeColumnValue() throws {
        // `image_hash_kind` is persisted; the recorded kind and the parser that
        // produced it must not be able to drift apart.
        #expect(MediaType.forExtension("heic")?.imageHashKind == HEICImageHash.kind)
        #expect(MediaType.forExtension("heif")?.imageHashKind == HEICImageHash.kind)
        #expect(HEICImageHash.kind == "heic-item-v1")
    }

    @Test func fileHasherRoutesHEICThroughTheItemRule() throws {
        let url = tree.root.appendingPathComponent("routed.heic")
        try Fixtures.writeImage(to: url, format: .heic)
        let hashes = try FileHasher().hashes(for: url, mediaType: MediaType.forExtension("heic")!)

        #expect(hashes.imageHashKind == HEICImageHash.kind)
        #expect(hashes.imageHash == (try heicHash(url)))
        #expect(hashes.imageHash != hashes.contentHash)
    }
}
