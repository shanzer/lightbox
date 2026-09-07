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
    /// The item's bytes. They are laid out in `mdat` for a `construction_method`
    /// of 0 and in `idat` for one of 1.
    var payload: [UInt8] = []
    /// `construction_method`: 0 = file offset, 1 = relative to `idat`,
    /// 2 = relative to another item (which this parser refuses).
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
    /// Writes the `iloc` entries with `construction_method == 1` but leaves the
    /// `idat` box out, so there is nothing for them to be relative to.
    var omitIdat = false
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

        // `idat` is derived rather than set by hand, and in the same item order
        // `makeILOC` walks — so a construction-1 item's declared offset and the
        // bytes actually sitting there cannot drift apart.
        var idat: [UInt8] = []
        for item in items where item.construction == 1 { idat.append(contentsOf: item.payload) }
        let idatBox = (idat.isEmpty || omitIdat) ? Data() : box("idat", Data(idat))

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

/// A `grid` item's own extent: version, flags, rows-1, columns-1 and the output
/// dimensions. Eight bytes that say nothing about the picture — which is why
/// hashing them instead of the tiles would collapse every same-sized photograph
/// into one duplicate group.
private let gridDescriptor: [UInt8] = [0, 0, 0, 2, 0x04, 0x00, 0x03, 0x00]

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
                            payload: gridDescriptor, construction: 1))
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

    @Test(.enabled(if: exiftoolAvailable, "exiftool not installed"))
    func aRealGridHEICSurvivesAnExiftoolMetadataRoundTrip() throws {
        // The test above uses what `Fixtures.writeImage` produces at 64×48: a
        // single `hvc1` primary, no `grid`, no `idat`. Every HEIC in a real
        // library is tiled, so the shape that actually ships needs a fixture of
        // its own — a checked-in file rather than a generated one, so that a
        // future macOS changing its tiling threshold cannot quietly turn this
        // back into the single-item case.
        let a = tree.root.appendingPathComponent("grid-a.heic")
        let b = tree.root.appendingPathComponent("grid-b.heic")
        try FileManager.default.copyItem(at: Fixtures.url("grid.heic"), to: a)
        try FileManager.default.copyItem(at: a, to: b)
        #expect(exiftool(["-q", "-overwrite_original",
                          "-Description=lightbox-experiment",
                          "-Keywords=heic-roundtrip",
                          "-DateTimeOriginal=2021:07:08 09:10:11",
                          "-OffsetTimeOriginal=-04:00", b.path]))

        // The write restructured the file the way it does on real captures:
        // `mdat` both grew and moved, because exiftool inserted an XMP item and
        // `meta` grew ahead of it.
        let before = try Data(contentsOf: a)
        let after = try Data(contentsOf: b)
        #expect(after.count > before.count)
        #expect(try ContentHasher().hash(a) != ContentHasher().hash(b))

        #expect(try heicHash(a) == heicHash(b))                        // the warranty
    }

    @Test func theCheckedInFixtureIsATiledGridHEIC() throws {
        // Pins what the fixture is. If it were a single-item file the
        // round-trip above would prove nothing about the shape that ships.
        let data = try Data(contentsOf: Fixtures.url("grid.heic"))
        #expect(data.count == 17_268)

        // A `grid` primary of four `hvc1` tiles. The tiles abut in `mdat`, so
        // the four `dimg` extents coalesce into a single range — which is what
        // every real capture does too, and why the flood guard never fires on
        // honest input. The span starts at 685, well past `ftyp` and `meta`, so
        // this cannot be passing by hashing the head of the file.
        let ranges = try heicRanges(data)
        #expect(ranges == [685..<17_268])
        #expect(ranges[0].count == 16_583)
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

    // MARK: - construction_method

    /// A grid whose *middle tile* is stored in `idat` rather than `mdat`. Only
    /// the grid item itself normally uses `construction_method == 1`, and the
    /// grid item's own extent is never hashed — so without a coded item using
    /// method 1 the whole branch is unreachable from the tests, and a mutation
    /// that replaced it with a throw would go unnoticed.
    private func gridWithATileInIdat() -> HEIFBuilder {
        var b = HEIFBuilder()
        b.items = [
            HEIFItem(id: 1, type: "hvc1", payload: tileBytes(1)),
            HEIFItem(id: 2, type: "hvc1", payload: tileBytes(2), construction: 1),
            HEIFItem(id: 3, type: "hvc1", payload: tileBytes(3)),
            HEIFItem(id: 4, type: "grid", payload: gridDescriptor, construction: 1),
            HEIFItem(id: 5, type: "Exif", payload: Array("exif".utf8)),
        ]
        b.primary = 4
        b.references = [("dimg", 4, [1, 2, 3]), ("cdsc", 5, [4])]
        return b
    }

    @Test func aCodedItemInIdatIsResolvedAgainstTheIdatBox() throws {
        // `construction_method == 1` makes an extent offset relative to the
        // payload of `idat`, not to the file. A parser that ignored it would
        // read tile 2 from offset 32 of the *file* — inside `ftyp` and `meta` —
        // and hash structure as though it were pixels.
        let data = gridWithATileInIdat().build()
        let ranges = try heicRanges(data)

        var hashed = Data()
        for range in ranges { hashed.append(contentsOf: data[range]) }
        var expected = Data()
        for i in 1...3 { expected.append(contentsOf: tileBytes(i)) }
        #expect(hashed == expected)

        // Tile 2 really is somewhere other than the two mdat tiles, so the three
        // extents cannot have coalesced into one contiguous run.
        #expect(ranges.count == 3)
        // And it is earlier in the file than the mdat tiles: `idat` lives inside
        // `meta`, which precedes `mdat`.
        #expect(ranges[1].lowerBound < ranges[0].lowerBound)
    }

    @Test func aCodedItemInIdatWithoutAnIdatBoxIsRefused() throws {
        var b = gridWithATileInIdat()
        b.omitIdat = true
        let error = #expect(throws: HashError.self) { try heicRanges(b.build()) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("idat"))
    }

    @Test func anUnsupportedConstructionMethodIsRefused() throws {
        // Method 2 makes an offset relative to another *item*. No writer
        // measured here produces it, and guessing at it would be a way to hash
        // the wrong bytes silently, so it is refused rather than approximated.
        var b = gridWithATileInIdat()
        b.items[1].construction = 2
        let error = #expect(throws: HashError.self) { try heicRanges(b.build()) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("construction_method"))
    }

    // MARK: - A derived primary that does not resolve

    /// The failure these three guard against is the worst one this file can
    /// produce. A `grid` item's own extent is eight bytes of rows, columns and
    /// output size, so falling back to it makes every photograph of a given
    /// dimension hash identically — and the duplicate view would then offer to
    /// delete all but one of them.
    @Test func aGridPrimaryWithNoDimgReferenceIsRefused() throws {
        var b = gridFixture()
        b.references = [("cdsc", b.primary + 1, [b.primary])]     // no dimg at all
        try expectUnresolvedDerivedPrimary(b, containing: "no coded items")
    }

    @Test func aGridPrimaryThatReferencesItselfIsRefused() throws {
        var b = gridFixture()
        b.references[0] = ("dimg", b.primary, [b.primary])
        try expectUnresolvedDerivedPrimary(b, containing: "references itself")
    }

    @Test func aGridPrimaryThatReferencesAnotherGridIsRefused() throws {
        var b = gridFixture()
        let inner = 90
        b.items.append(HEIFItem(id: inner, type: "grid", payload: gridDescriptor))
        b.references[0] = ("dimg", b.primary, [inner])
        try expectUnresolvedDerivedPrimary(b, containing: "derived item")
    }

    @Test func twoDifferentPhotographsWithUnresolvableGridsDoNotCollide() throws {
        // The bug in its original form. These two files hold different pictures
        // — different tile bytes, so different hashes when their grids resolve —
        // but identical eight-byte grid descriptors, because the descriptor
        // says only "two by two, 1024 by 768". Hashing the primary item's own
        // extent as a fallback therefore made them a duplicate pair.
        var a = gridFixture(tileCount: 3, seed: 0)
        var c = gridFixture(tileCount: 3, seed: 40)
        #expect(try heicHash(a.build()) != heicHash(c.build()))      // they are different pictures

        a.references = []
        c.references = []
        let dataA = a.build(), dataC = c.build()
        let descriptorA = try heicRanges(gridFixture().build())      // resolvable, for contrast
        #expect(!descriptorA.isEmpty)

        // Neither has an image hash now, so neither can equal the other.
        #expect(throws: HashError.self) { try heicRanges(dataA) }
        #expect(throws: HashError.self) { try heicRanges(dataC) }
    }

    /// Asserts the parser refuses, and that `FileHasher` turns that refusal into
    /// `imageHash == nil` with a content hash still recorded.
    private func expectUnresolvedDerivedPrimary(_ builder: HEIFBuilder,
                                                containing fragment: String) throws {
        let data = builder.build()
        let error = #expect(throws: HashError.self) { try heicRanges(data) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains(fragment), "got: \(message)")

        let url = tree.root.appendingPathComponent("unresolved-\(UUID().uuidString).heic")
        try data.write(to: url)
        let hashes = try FileHasher().hashes(for: url, mediaType: MediaType.forExtension("heic")!)
        #expect(hashes.imageHash == nil)
        #expect(hashes.imageHashKind == nil)
        #expect(hashes.contentHash == (try ContentHasher().hash(url)))
    }

    // MARK: - Amplification

    @Test func aGridOfManyAbuttingTilesCollapsesToOneRange() throws {
        // 60,000 one-byte tiles — just under `maxExtents`, so this is the
        // largest legitimate shape the parser accepts. Uncoalesced it is one
        // `Range` per tile, and Task 9's 256 MB in-memory limit admits a file of
        // this shape: at that size the PNG equivalent cost 1.2 GB of RSS, and
        // the indexer hashes several files at once.
        var b = HEIFBuilder()
        let tiles = 60_000
        #expect(tiles < HEICImageHash.maxExtents)
        for i in 1...tiles { b.items.append(HEIFItem(id: i, type: "hvc1", payload: [UInt8(i & 0xFF)])) }
        b.items.append(HEIFItem(id: tiles + 1, type: "grid",
                                payload: gridDescriptor, construction: 1))
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
        let data = hostileExtentFile(items: 2, extentsPerItem: 65_535)
        #expect(2 * 65_535 > HEICImageHash.maxExtents)
        #expect(data.count < 2 << 20)                       // the file really is small

        let error = #expect(throws: HashError.self) { try heicRanges(data) }
        guard case .malformed(let message)? = error else {
            Issue.record("expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("extent"))
    }

    /// An `iloc` with `offset_size == 0`: every extent starts at the same place
    /// and has a different length, so none of them merge into its neighbour,
    /// and four bytes of `iloc` buys a sixteen-byte `Range`.
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

        var ilocBody = Data([0x04, 0x40])            // offset_size 0, length_size 4,
                                                     // base_offset_size 4, index_size 0
        ilocBody.append(contentsOf: be(items + 1, 2))
        for i in 1...(items + 1) {
            ilocBody.append(contentsOf: be(i, 2))
            ilocBody.append(contentsOf: be(0, 2))    // construction_method 0
            ilocBody.append(contentsOf: be(0, 2))    // data_reference_index
            ilocBody.append(contentsOf: be(0, 4))    // base_offset
            let count = i > items ? 1 : extentsPerItem
            ilocBody.append(contentsOf: be(count, 2))
            for e in 0..<count {
                ilocBody.append(contentsOf: be(Int(UInt8(truncatingIfNeeded: e &+ 1)), 4))
            }
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
