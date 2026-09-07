import Foundation

/// The byte ranges of a HEIC that constitute image data.
///
/// An allowlist, like WebP and for the same reason: writing metadata to a HEIC
/// *adds structure*. Measured against exiftool 13.55 over five real iPhone and
/// iPad captures (`docs/superpowers/notes/2026-09-07-heic-mdat-roundtrip.md`),
/// a `-Description=`/`-Keywords=`/`-DateTimeOriginal=` write rewrites the `Exif`
/// item, inserts an XMP item where none existed, appends entries to `iinf`,
/// `iref` and `iloc`, and relocates every coded tile within the file. A denylist
/// would see all of that and hash differently.
///
/// What it does *not* touch is the coded image data. The spec's §11 guessed the
/// rule would be "the `mdat` box", and that guess was wrong on all five files:
/// `mdat` holds the `Exif` and XMP items too, so its digest changed every time,
/// and in two of the five it moved as well. The stable unit is one level down —
/// the byte extents `iloc` assigns to the *primary item*, which came through
/// byte-for-byte identical on all five.
///
/// Resolving the primary item is where the real work is. Every HEIC in the
/// library (1238 of them, 2017–2024) has a `grid` primary: `pitm` names a
/// derived item whose own extent is an eight-byte layout descriptor stored in
/// `idat`, and the pixels live in the `hvc1` tiles its `dimg` reference names —
/// six of them on an iPad file, forty-eight on every iPhone one. So the rule
/// follows `pitm` → `dimg` → `iloc`, hashes the tiles in `dimg` order, and
/// honours `construction_method`: a parser that ignored it would hash the first
/// eight bytes of the file and call every HEIC a duplicate of every other.
///
/// Auxiliary images are deliberately excluded — the HDR gain map, the Portrait
/// depth map and effects mattes, and the `thmb` thumbnail. Two files that are
/// the same photograph with different auxiliaries must group together, and a
/// gain map that Photos regenerates would otherwise split the group. `ipco`,
/// which carries `hvcC`/`ispe`/`irot`/`colr`, is excluded for the same reason a
/// sibling image must not move this hash — and because §11 has already ruled
/// that an orientation-only difference hashes as identical.
enum HEICImageHash {
    static let kind = "heic-item-v1"

    /// The most extents this parser will read for one image before giving up.
    ///
    /// `extent_count` is sixteen bits and `iloc` may declare `offset_size == 0`,
    /// so a few hundred kilobytes of `iloc` can name millions of extents that
    /// cost nothing on disk, land on the same offset, and therefore never
    /// coalesce. That is the PNG chunk flood in a new container — 4.37 GB of RSS
    /// at 256 MB of input — so the count is capped rather than trusted. A real
    /// primary item has tens of extents; this leaves four orders of magnitude of
    /// headroom, and exceeding it costs only the image hash, since `FileHasher`
    /// treats a parse failure as "no image hash" and still records the content
    /// hash.
    static let maxExtents = 1 << 20

    /// Brands that mark an ISOBMFF file as a HEIF image rather than, say, an
    /// MP4 with a `.heic` extension. Matched against the major brand and every
    /// compatible brand.
    static let heifBrandNames = ["heic", "heix", "heim", "heis", "hevc", "hevx",
                                 "hevm", "hevs", "mif1", "msf1", "miaf", "mif2"]

    private static let heifBrands: Set<UInt32> = Set(heifBrandNames.map(fourCC))

    /// Item types whose own extent is a layout descriptor rather than image
    /// data; the pixels are in the items their `dimg` reference names.
    private static let derivedItemTypes: Set<UInt32> =
        Set(["grid", "iovl", "iden"].map(fourCC))

    private static let ftypCode = fourCC("ftyp")
    private static let metaCode = fourCC("meta")
    private static let pitmCode = fourCC("pitm")
    private static let iinfCode = fourCC("iinf")
    private static let infeCode = fourCC("infe")
    private static let irefCode = fourCC("iref")
    private static let ilocCode = fourCC("iloc")
    private static let idatCode = fourCC("idat")
    private static let dimgCode = fourCC("dimg")

    /// A four-character code packed big-endian, in the byte order it appears in
    /// on disk. ISOBMFF is a big-endian format throughout, so unlike RIFF there
    /// is no mixed-endianness trap here.
    static func fourCC(_ name: String) -> UInt32 {
        let bytes = Array(name.utf8)
        precondition(bytes.count == 4, "a box type is exactly four bytes")
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
             | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    // MARK: - Bounds-checked reading

    /// Every multi-byte read goes through here, so a forged length can only
    /// produce `HashError.truncated` and never an out-of-bounds access.
    private struct Cursor {
        let bytes: UnsafeRawBufferPointer
        var offset: Int

        init(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
            self.bytes = bytes
            self.offset = offset
        }

        /// Reads `width` bytes big-endian. `width == 0` yields 0 without
        /// advancing, which is what `iloc`'s zero-width size fields mean.
        mutating func read(_ width: Int) throws -> Int {
            guard width >= 0, width <= 8 else {
                throw HashError.malformed("field width \(width) is not addressable")
            }
            guard offset >= 0, offset <= bytes.count - width else { throw HashError.truncated }
            // Accumulated as `UInt64`: a 64-bit `largesize` or `base_offset`
            // with the high bit set overflows the shift on a signed `Int` and
            // traps, which a hostile file must not be able to cause.
            var value: UInt64 = 0
            for i in 0..<width {
                value = value << 8 | UInt64(bytes[offset + i])
            }
            guard value <= UInt64(Int.max) else {
                throw HashError.malformed("field value \(value) is not addressable")
            }
            offset += width
            return Int(value)
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, offset <= bytes.count - count else { throw HashError.truncated }
            offset += count
        }
    }

    /// One box: its type, where its content begins, and where it ends.
    private struct BoxSpan {
        let type: UInt32
        let contentStart: Int
        let end: Int
    }

    /// Reads the box header at `offset`. Returns nil when fewer than eight bytes
    /// remain — the caller decides whether that is a trailer or a truncation.
    private static func readBox(_ bytes: UnsafeRawBufferPointer,
                                at offset: Int, limit: Int) throws -> BoxSpan? {
        guard offset >= 0, offset + 8 <= limit else { return nil }
        var cursor = Cursor(bytes, at: offset)
        var size = try cursor.read(4)
        let type = UInt32(try cursor.read(4))
        var headerLength = 8

        if size == 1 {
            // `largesize`: a 64-bit size, for a box over 4 GB.
            guard offset + 16 <= limit else { throw HashError.truncated }
            size = try cursor.read(8)
            headerLength = 16
        } else if size == 0 {
            // "To the end of the enclosing container", which for a top-level
            // box means the end of the file.
            size = limit - offset
        }

        guard size >= headerLength else {
            throw HashError.malformed("box size \(size) is smaller than its header")
        }
        guard size <= limit - offset else { throw HashError.truncated }
        return BoxSpan(type: type, contentStart: offset + headerLength, end: offset + size)
    }

    /// The children of a FullBox container: four bytes of version and flags,
    /// then boxes. Used for `meta`.
    private static func children(of box: BoxSpan) -> Range<Int> {
        min(box.contentStart + 4, box.end)..<box.end
    }

    private static func findBox(_ bytes: UnsafeRawBufferPointer,
                                type: UInt32, in span: Range<Int>) throws -> BoxSpan? {
        var i = span.lowerBound
        while let box = try readBox(bytes, at: i, limit: span.upperBound) {
            if box.type == type { return box }
            guard box.end > i else { throw HashError.malformed("zero-length box at \(i)") }
            i = box.end
        }
        return nil
    }

    // MARK: - The rule

    static func includedRanges(_ bytes: UnsafeRawBufferPointer) throws -> [Range<Int>] {
        guard bytes.count >= 8 else { throw HashError.truncated }

        // 1. Walk the top level. ISOBMFF has no end marker: the box sequence is
        //    expected to tile the file exactly, so the first box that does not
        //    fit ends the sequence and whatever follows is an appended payload.
        var meta: BoxSpan?
        var i = 0
        var sawFtyp = false
        var stoppedEarly = false

        while i < bytes.count {
            var box: BoxSpan?
            do {
                box = try readBox(bytes, at: i, limit: bytes.count)
            } catch is HashError {
                // A header that reads but does not describe a box that fits.
                // Whether that is a truncation or an appended payload depends on
                // whether the structure was ever found, which is decided below —
                // and an appended payload is arbitrary bytes, so it must not
                // matter whether they happen to look like an over-long box or an
                // under-short one.
                box = nil
            }
            guard let box else { stoppedEarly = true; break }

            if !sawFtyp {
                guard box.type == ftypCode else {
                    throw HashError.malformed("first box is not ftyp")
                }
                try checkBrands(bytes, ftyp: box)
                sawFtyp = true
            }
            if box.type == metaCode, meta == nil { meta = box }
            guard box.end > i else { throw HashError.malformed("zero-length box at \(i)") }
            i = box.end
        }
        let trailerStart = i

        guard let meta else {
            // Cut short before the structure could be read, versus a complete
            // file that simply is not a HEIF item file.
            throw stoppedEarly ? HashError.truncated
                               : HashError.malformed("no meta box")
        }

        // 2. Resolve which items carry the primary image's coded data.
        let metaSpan = children(of: meta)
        let primary = try readPrimaryItemID(bytes, in: metaSpan)
        let primaryType = try itemType(bytes, in: metaSpan, id: primary)
        let codedIDs = try codedItemIDs(bytes, in: metaSpan,
                                        primary: primary, primaryType: primaryType)

        // 3. Read their extents out of `iloc`, in `dimg` order.
        let idatPayloadStart = try findBox(bytes, type: idatCode, in: metaSpan)?.contentStart
        var ranges = try extents(bytes, in: metaSpan,
                                 for: codedIDs, idatPayloadStart: idatPayloadStart)

        // Checked before the trailer is appended: a file whose primary item has
        // no locatable data has no image to hash, and an appended payload must
        // not disguise that. Hashing nothing would make every such file a
        // duplicate of every other one.
        guard !ranges.isEmpty else { throw HashError.malformed("no image extents found") }

        // 4. Bytes past the last box are an appended payload, not metadata — the
        //    same rule JPEG applies after EOI, PNG after IEND and WebP past the
        //    declared RIFF size. Dropping them would let a file carrying a
        //    payload hash identically to one without, and the duplicate view
        //    would then offer to delete the copy with the extra content.
        if trailerStart < bytes.count {
            ranges.appendCoalescing(trailerStart..<bytes.count)
        }
        return ranges
    }

    private static func checkBrands(_ bytes: UnsafeRawBufferPointer, ftyp: BoxSpan) throws {
        guard ftyp.end - ftyp.contentStart >= 8 else { throw HashError.truncated }
        var cursor = Cursor(bytes, at: ftyp.contentStart)
        let major = UInt32(try cursor.read(4))
        _ = try cursor.read(4)                              // minor version
        if heifBrands.contains(major) { return }
        while cursor.offset + 4 <= ftyp.end {
            if heifBrands.contains(UInt32(try cursor.read(4))) { return }
        }
        throw HashError.malformed("no HEIF brand in ftyp")
    }

    /// `pitm`, ISO/IEC 14496-12 §8.11.4.
    private static func readPrimaryItemID(_ bytes: UnsafeRawBufferPointer,
                                          in span: Range<Int>) throws -> Int {
        guard let pitm = try findBox(bytes, type: pitmCode, in: span) else {
            throw HashError.malformed("no pitm box")
        }
        var cursor = Cursor(bytes, at: pitm.contentStart)
        let version = try cursor.read(1)
        try cursor.skip(3)                                  // flags
        return try cursor.read(version == 0 ? 2 : 4)
    }

    /// The `item_type` of one item, from the matching `infe` entry in `iinf`
    /// (§8.11.6). Versions 0 and 1 of `infe` carry no item type at all — they
    /// predate HEIF — so they report zero and are treated as non-derived.
    private static func itemType(_ bytes: UnsafeRawBufferPointer,
                                 in span: Range<Int>, id: Int) throws -> UInt32 {
        guard let iinf = try findBox(bytes, type: iinfCode, in: span) else { return 0 }
        var cursor = Cursor(bytes, at: iinf.contentStart)
        let version = try cursor.read(1)
        try cursor.skip(3)
        _ = try cursor.read(version == 0 ? 2 : 4)           // entry_count

        var i = cursor.offset
        while let entry = try readBox(bytes, at: i, limit: iinf.end) {
            if entry.type == infeCode {
                var e = Cursor(bytes, at: entry.contentStart)
                let entryVersion = try e.read(1)
                try e.skip(3)
                if entryVersion >= 2 {
                    let entryID = try e.read(entryVersion == 2 ? 2 : 4)
                    try e.skip(2)                           // item_protection_index
                    if entryID == id { return UInt32(try e.read(4)) }
                }
            }
            guard entry.end > i else { throw HashError.malformed("zero-length infe at \(i)") }
            i = entry.end
        }
        return 0
    }

    /// The items whose extents make up the primary image. A `grid`, `iovl` or
    /// `iden` primary is a derived item: its own extent is a layout descriptor,
    /// and its `dimg` reference names the coded items in assembly order.
    private static func codedItemIDs(_ bytes: UnsafeRawBufferPointer,
                                     in span: Range<Int>,
                                     primary: Int, primaryType: UInt32) throws -> [Int] {
        guard derivedItemTypes.contains(primaryType) else { return [primary] }
        guard let iref = try findBox(bytes, type: irefCode, in: span) else { return [primary] }

        var cursor = Cursor(bytes, at: iref.contentStart)
        let version = try cursor.read(1)
        try cursor.skip(3)
        let idWidth = version == 0 ? 2 : 4

        var i = cursor.offset
        while let entry = try readBox(bytes, at: i, limit: iref.end) {
            if entry.type == dimgCode {
                var e = Cursor(bytes, at: entry.contentStart)
                let from = try e.read(idWidth)
                let count = try e.read(2)
                if from == primary {
                    var ids: [Int] = []
                    ids.reserveCapacity(min(count, 4096))
                    for _ in 0..<count { ids.append(try e.read(idWidth)) }
                    // A derived item that references nothing describes no image.
                    // Falling back to its own extent would hash eight bytes of
                    // layout metadata as though they were pixels.
                    return ids
                }
            }
            guard entry.end > i else { throw HashError.malformed("zero-length iref at \(i)") }
            i = entry.end
        }
        return [primary]
    }

    /// `iloc`, §8.11.3, read in one pass. Versions 0, 1 and 2 differ in the
    /// width of the item id and whether a `construction_method` is present.
    ///
    /// Only the wanted items' extents are materialised; every other entry is
    /// stepped over arithmetically, so an `iloc` describing a million auxiliary
    /// items costs no allocation.
    private static func extents(_ bytes: UnsafeRawBufferPointer,
                                in span: Range<Int>,
                                for wantedIDs: [Int],
                                idatPayloadStart: Int?) throws -> [Range<Int>] {
        guard !wantedIDs.isEmpty else { return [] }
        guard let iloc = try findBox(bytes, type: ilocCode, in: span) else {
            throw HashError.malformed("no iloc box")
        }

        var cursor = Cursor(bytes, at: iloc.contentStart)
        let version = try cursor.read(1)
        try cursor.skip(3)
        let sizes = try cursor.read(1)
        let offsetSize = sizes >> 4
        let lengthSize = sizes & 0x0F
        let sizes2 = try cursor.read(1)
        let baseOffsetSize = sizes2 >> 4
        // `index_size` occupies the low nibble only from version 1 on; in
        // version 0 those bits are reserved and there is no extent index.
        let indexSize = version == 0 ? 0 : sizes2 & 0x0F
        let idWidth = version < 2 ? 2 : 4
        let itemCount = try cursor.read(version < 2 ? 2 : 4)

        // Split into named steps: Swift 6.3.3's type checker times out on the
        // one-line sum.
        let indexAndOffset = indexSize + offsetSize
        let extentWidth = indexAndOffset + lengthSize

        let wanted = Set(wantedIDs)
        var found: [Int: [Range<Int>]] = [:]
        var inspected = 0

        for _ in 0..<itemCount {
            if cursor.offset >= iloc.end { break }
            let id = try cursor.read(idWidth)
            var construction = 0
            if version >= 1 { construction = try cursor.read(2) & 0x0F }
            try cursor.skip(2)                              // data_reference_index
            let declaredBase = try cursor.read(baseOffsetSize)
            let extentCount = try cursor.read(2)

            guard wanted.contains(id), found[id] == nil else {
                try cursor.skip(extentWidth * extentCount)
                continue
            }

            // Reading a wanted item's extents is the only unbounded work here,
            // so the budget is charged before the loop runs rather than after.
            inspected += extentCount
            guard inspected <= maxExtents else {
                throw HashError.malformed("more than \(maxExtents) image extents")
            }

            // `construction_method`: 0 means the offset is a file offset, 1 that
            // it is relative to the `idat` payload in this `meta`. Method 2
            // (relative to another item) is produced by no writer this has been
            // measured against, and guessing at it would be a way to hash the
            // wrong bytes silently.
            let base: Int
            switch construction {
            case 0:
                base = declaredBase
            case 1:
                guard let idatPayloadStart else {
                    throw HashError.malformed("construction_method 1 without an idat box")
                }
                // Two fields that each fit in an `Int` can still overflow when
                // added, and an overflowing `+` traps rather than throwing.
                let (sum, overflowed) = idatPayloadStart.addingReportingOverflow(declaredBase)
                guard !overflowed else { throw HashError.truncated }
                base = sum
            default:
                throw HashError.malformed("unsupported construction_method \(construction)")
            }

            var itemRanges: [Range<Int>] = []
            for _ in 0..<extentCount {
                try cursor.skip(indexSize)
                let extentOffset = try cursor.read(offsetSize)
                let extentLength = try cursor.read(lengthSize)
                // An empty extent contributes no bytes, and skipping it keeps a
                // zero-length flood from costing one `Range` each.
                if extentLength == 0 { continue }
                let (start, overflowed) = base.addingReportingOverflow(extentOffset)
                guard !overflowed, start >= 0, start <= bytes.count - extentLength else {
                    throw HashError.truncated
                }
                itemRanges.appendCoalescing(start..<(start + extentLength))
            }
            found[id] = itemRanges
        }

        // Emitted in `dimg` order — the order the tiles assemble into the
        // picture — not in the order `iloc` happens to list them.
        var ranges: [Range<Int>] = []
        for id in wantedIDs {
            for range in found[id] ?? [] { ranges.appendCoalescing(range) }
        }
        return ranges
    }
}
