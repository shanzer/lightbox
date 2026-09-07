#!/usr/bin/env swift
//
// heic-box-walk.swift — an ISOBMFF/HEIF box walker for the HEIC image-hash
// experiment (issue #12).
//
// Prints the top-level (and `meta`-nested) box tree of a HEIC with type, file
// offset and size, then resolves the primary item through `pitm` → `iloc` and
// prints its extents plus a SHA-256 of exactly those bytes. Diffing two runs —
// before and after an exiftool metadata write — answers the question the spec's
// §14 asks: does the primary item's coded image data survive a metadata
// round-trip byte-for-byte.
//
// Usage:  swift scripts/heic-box-walk.swift <file.heic> [--json]
//
// Not part of the shipped package; it exists so the note's box tables are
// reproducible.

import Foundation
import CryptoKit

// MARK: - Reading

struct Reader {
    let bytes: [UInt8]

    func u8(_ o: Int) -> UInt64 { UInt64(bytes[o]) }

    func be(_ o: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n { v = (v << 8) | UInt64(bytes[o + i]) }
        return v
    }

    func fourCC(_ o: Int) -> String {
        String(decoding: bytes[o..<(o + 4)], as: UTF8.self)
    }
}

struct Box {
    let type: String
    let offset: Int          // offset of the box header in the file
    let size: Int            // total box size including the header
    let payload: Range<Int>  // the box's content, after type/size/version
    let depth: Int
    var children: [Box] = []
}

/// Boxes whose payload is a list of child boxes. `meta`, `iinf` and `ipco` are
/// FullBoxes (4 bytes of version+flags before the children); `iinf` also has an
/// entry count that is 2 bytes in version 0 and 4 in version 1, which is why it
/// is not recursed into structurally here — `infe` entries are parsed directly.
let containerBoxes: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "iprp", "ipco"]
let fullBoxContainers: Set<String> = ["meta"]

func walk(_ r: Reader, from start: Int, to end: Int, depth: Int) -> [Box] {
    var boxes: [Box] = []
    var i = start
    while i + 8 <= end {
        var size = Int(r.be(i, 4))
        let type = r.fourCC(i + 4)
        var headerLength = 8
        if size == 1 {
            guard i + 16 <= end else { break }
            size = Int(r.be(i + 8, 8))
            headerLength = 16
        } else if size == 0 {
            size = end - i          // "to end of file"
        }
        guard size >= headerLength, i + size <= end else {
            // A box that overruns its parent: stop rather than misread.
            boxes.append(Box(type: type + "!truncated", offset: i,
                             size: end - i, payload: (i + headerLength)..<end, depth: depth))
            break
        }

        var contentStart = i + headerLength
        if fullBoxContainers.contains(type) { contentStart += 4 }
        var box = Box(type: type, offset: i, size: size,
                      payload: contentStart..<(i + size), depth: depth)
        if containerBoxes.contains(type) || fullBoxContainers.contains(type) {
            box.children = walk(r, from: contentStart, to: i + size, depth: depth + 1)
        }
        boxes.append(box)
        i += size
    }
    return boxes
}

func flatten(_ boxes: [Box]) -> [Box] {
    boxes.flatMap { [$0] + flatten($0.children) }
}

func find(_ boxes: [Box], _ type: String) -> Box? {
    flatten(boxes).first { $0.type == type }
}

// MARK: - HEIF item structures

struct Extent {
    let offset: Int
    let length: Int
}

struct ItemLocation {
    let itemID: Int
    let constructionMethod: Int
    let baseOffset: Int
    let extents: [Extent]
}

/// `iloc`, ISO/IEC 14496-12 §8.11.3. Versions 0, 1 and 2 differ in the width of
/// the item id and whether a construction method is present.
func parseILOC(_ r: Reader, _ box: Box) -> [ItemLocation] {
    var p = box.offset + 8
    let version = Int(r.u8(p))
    p += 4                                   // version + flags
    let sizes = Int(r.u8(p)); p += 1
    let offsetSize = sizes >> 4
    let lengthSize = sizes & 0x0F
    let sizes2 = Int(r.u8(p)); p += 1
    let baseOffsetSize = sizes2 >> 4
    let indexSize = sizes2 & 0x0F

    var itemCount = 0
    if version < 2 {
        itemCount = Int(r.be(p, 2)); p += 2
    } else {
        itemCount = Int(r.be(p, 4)); p += 4
    }

    var out: [ItemLocation] = []
    for _ in 0..<itemCount {
        guard p < box.offset + box.size else { break }
        var itemID = 0
        if version < 2 {
            itemID = Int(r.be(p, 2)); p += 2
        } else {
            itemID = Int(r.be(p, 4)); p += 4
        }
        var construction = 0
        if version == 1 || version == 2 {
            construction = Int(r.be(p, 2)) & 0x0F; p += 2
        }
        p += 2                                // data_reference_index
        var baseOffset = 0
        if baseOffsetSize > 0 { baseOffset = Int(r.be(p, baseOffsetSize)); p += baseOffsetSize }
        let extentCount = Int(r.be(p, 2)); p += 2
        var extents: [Extent] = []
        for _ in 0..<extentCount {
            if (version == 1 || version == 2), indexSize > 0 { p += indexSize }
            var eOffset = 0
            if offsetSize > 0 { eOffset = Int(r.be(p, offsetSize)); p += offsetSize }
            var eLength = 0
            if lengthSize > 0 { eLength = Int(r.be(p, lengthSize)); p += lengthSize }
            extents.append(Extent(offset: eOffset, length: eLength))
        }
        out.append(ItemLocation(itemID: itemID, constructionMethod: construction,
                                baseOffset: baseOffset, extents: extents))
    }
    return out
}

/// `pitm`, §8.11.4.
func parsePITM(_ r: Reader, _ box: Box) -> Int {
    let p = box.offset + 8
    let version = Int(r.u8(p))
    return version == 0 ? Int(r.be(p + 4, 2)) : Int(r.be(p + 4, 4))
}

struct ItemInfo {
    let itemID: Int
    let type: String
    let name: String
}

/// `iinf` → `infe` entries, §8.11.6.
func parseIINF(_ r: Reader, _ box: Box) -> [ItemInfo] {
    var p = box.offset + 8
    let version = Int(r.u8(p))
    p += 4
    if version == 0 { p += 2 } else { p += 4 }

    var out: [ItemInfo] = []
    let end = box.offset + box.size
    while p + 8 <= end {
        let size = Int(r.be(p, 4))
        let type = r.fourCC(p + 4)
        guard size >= 8, p + size <= end else { break }
        if type == "infe" {
            var q = p + 8
            let v = Int(r.u8(q))
            q += 4
            if v < 2 {
                // v0/v1 carry no item_type; the name follows the protection index.
                let id = Int(r.be(q, 2))
                out.append(ItemInfo(itemID: id, type: "(v\(v))", name: ""))
            } else {
                // v2 has a 16-bit item_ID, v3 a 32-bit one; both then carry a
                // 16-bit protection index and a four-character item_type.
                let idWidth = (v == 2) ? 2 : 4
                let id = Int(r.be(q, idWidth)); q += idWidth
                q += 2                        // protection index
                let itemType = r.fourCC(q); q += 4
                var name = ""
                var k = q
                while k < p + size, r.bytes[k] != 0 {
                    name.append(Character(UnicodeScalar(r.bytes[k])))
                    k += 1
                }
                out.append(ItemInfo(itemID: id, type: itemType, name: name))
            }
        }
        p += size
    }
    return out
}

struct ItemReference {
    let type: String     // "dimg", "cdsc", "auxl", "thmb", …
    let fromID: Int
    let toIDs: [Int]
}

/// `iref`, §8.11.12. A FullBox whose payload is a list of `SingleItemTypeReference`
/// boxes; item ids are 16-bit in version 0 and 32-bit in version 1.
func parseIREF(_ r: Reader, _ box: Box) -> [ItemReference] {
    var p = box.offset + 8
    let version = Int(r.u8(p))
    p += 4
    let idWidth = version == 0 ? 2 : 4
    let end = box.offset + box.size

    var out: [ItemReference] = []
    while p + 8 <= end {
        let size = Int(r.be(p, 4))
        let type = r.fourCC(p + 4)
        guard size >= 8, p + size <= end else { break }
        var q = p + 8
        let from = Int(r.be(q, idWidth)); q += idWidth
        let count = Int(r.be(q, 2)); q += 2
        var tos: [Int] = []
        for _ in 0..<count {
            guard q + idWidth <= p + size else { break }
            tos.append(Int(r.be(q, idWidth)))
            q += idWidth
        }
        out.append(ItemReference(type: type, fromID: from, toIDs: tos))
        p += size
    }
    return out
}

// MARK: - Report

func sha256(_ slice: ArraySlice<UInt8>) -> String {
    var h = SHA256()
    slice.withUnsafeBufferPointer { h.update(bufferPointer: UnsafeRawBufferPointer($0)) }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: heic-box-walk.swift <file.heic>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let data = try Data(contentsOf: url)
let reader = Reader(bytes: [UInt8](data))
let top = walk(reader, from: 0, to: reader.bytes.count, depth: 0)

print("file: \(url.lastPathComponent)   size: \(reader.bytes.count)")
print("")
print("  offset       size  box")
for box in flatten(top) {
    let indent = String(repeating: "  ", count: box.depth)
    let o = String(format: "%8d", box.offset)
    let s = String(format: "%10d", box.size)
    print("\(o) \(s)  \(indent)\(box.type)")
}

guard let meta = find(top, "meta") else {
    print("\nno meta box — not a HEIF item file")
    exit(0)
}
let metaChildren = meta.children
let primary = find(metaChildren, "pitm").map { parsePITM(reader, $0) } ?? -1
let infos = find(metaChildren, "iinf").map { parseIINF(reader, $0) } ?? []
let locations = find(metaChildren, "iloc").map { parseILOC(reader, $0) } ?? []
let references = find(metaChildren, "iref").map { parseIREF(reader, $0) } ?? []

// `construction_method == 1` makes an extent offset relative to the payload of
// the `idat` box inside this `meta`, not to the file. iPhone tiled HEICs put
// the primary `grid` item's 8-byte descriptor there, so getting this wrong
// hashes the file's first eight bytes instead.
let idatPayloadStart = find(metaChildren, "idat").map { $0.offset + 8 }

func absoluteRanges(_ loc: ItemLocation) -> [Range<Int>]? {
    var out: [Range<Int>] = []
    for e in loc.extents {
        var base = loc.baseOffset
        switch loc.constructionMethod {
        case 0: break                                  // file offset
        case 1:
            guard let idat = idatPayloadStart else { return nil }
            base += idat
        default: return nil                            // 2 = item offset, unused here
        }
        let start = base + e.offset
        let end = start + e.length
        guard start >= 0, end <= reader.bytes.count, start <= end else { return nil }
        out.append(start..<end)
    }
    return out
}

func digest(_ ranges: [Range<Int>]) -> String {
    var acc = SHA256()
    for r in ranges {
        reader.bytes[r].withUnsafeBufferPointer {
            acc.update(bufferPointer: UnsafeRawBufferPointer($0))
        }
    }
    return acc.finalize().map { String(format: "%02x", $0) }.joined()
}

func itemType(_ id: Int) -> String { infos.first { $0.itemID == id }?.type ?? "?" }

print("\nprimary item id: \(primary)  type: \(itemType(primary))")
let itemSummary = infos.sorted { $0.itemID < $1.itemID }.map { info -> String in
    let suffix = info.name.isEmpty ? "" : "(\(info.name))"
    return "\(info.itemID):\(info.type)\(suffix)"
}
print("items (\(infos.count)): " + itemSummary.joined(separator: " "))
for ref in references {
    print("iref \(ref.type): \(ref.fromID) -> \(ref.toIDs.map(String.init).joined(separator: ","))")
}

// The rule under test: the primary item's coded image data. A `grid` (or
// `iovl`) primary is a derived item whose own extent is a tiny descriptor in
// `idat`; the pixels live in the tile items its `dimg` reference names, and
// those are hashed in `dimg` order.
func codedItemIDs(forPrimary id: Int) -> [Int] {
    let derived = ["grid", "iovl", "iden"]
    guard derived.contains(itemType(id)) else { return [id] }
    let dimg = references.first { $0.type == "dimg" && $0.fromID == id }
    return dimg?.toIDs ?? [id]
}

let codedIDs = codedItemIDs(forPrimary: primary)
print("coded item ids for the primary: \(codedIDs.map(String.init).joined(separator: ","))")

var primaryRanges: [Range<Int>] = []
var resolved = true
for id in codedIDs {
    guard let loc = locations.first(where: { $0.itemID == id }),
          let ranges = absoluteRanges(loc) else { resolved = false; break }
    primaryRanges.append(contentsOf: ranges)
}
if resolved {
    let total = primaryRanges.reduce(0) { $0 + $1.count }
    let spans = primaryRanges.map { "\($0.lowerBound)+\($0.count)" }
    print("primary coded extents (\(primaryRanges.count)): \(spans.prefix(6).joined(separator: " "))"
        + (primaryRanges.count > 6 ? " …" : ""))
    print("primary coded bytes: \(total)")
    print("PRIMARY-SHA256 \(digest(primaryRanges))")
} else {
    print("PRIMARY-SHA256 unresolved")
}

// Every item, so a multi-image file's auxiliaries can be compared too.
print("\nall items:")
for loc in locations.sorted(by: { $0.itemID < $1.itemID }) {
    guard let ranges = absoluteRanges(loc) else {
        print("  id=\(loc.itemID) type=\(itemType(loc.itemID)) unresolved "
            + "(construction=\(loc.constructionMethod))")
        continue
    }
    let total = ranges.reduce(0) { $0 + $1.count }
    let at = ranges.map { String($0.lowerBound) }.prefix(3).joined(separator: ",")
    print("  id=\(loc.itemID) type=\(itemType(loc.itemID)) c=\(loc.constructionMethod) "
        + "bytes=\(total) at=[\(at)\(ranges.count > 3 ? ",…" : "")] "
        + "sha256=\(digest(ranges).prefix(16))")
}

// The `ipco` property container, where HEIF keeps image properties (`hvcC`,
// `ispe`, `colr`, `pixi`, `irot`, `auxC`). A metadata write that rewrote these
// would change what the file decodes to.
if let iprp = find(metaChildren, "iprp"), let ipco = find([iprp], "ipco") {
    let slice = reader.bytes[ipco.offset..<(ipco.offset + ipco.size)]
    print("\nIPCO-SHA256 \(sha256(slice))  offset=\(ipco.offset) size=\(ipco.size)")
    let props = ipco.children.map { "\($0.type)@\($0.offset)+\($0.size)" }
    print("ipco properties: \(props.joined(separator: " "))")
}

// The whole `mdat`, for the coarser question of whether the media box moved or
// was rewritten wholesale.
for box in top where box.type == "mdat" {
    let slice = reader.bytes[box.offset..<(box.offset + box.size)]
    print("MDAT offset=\(box.offset) size=\(box.size) sha256=\(sha256(slice))")
}
