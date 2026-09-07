# Does HEIC `mdat` survive an exiftool metadata round-trip?

2026-09-07 · issue #12 · resolves the spec's §14 open item

## Answer

**No, and yes — and the distinction is the whole result.**

- The **whole `mdat` box changes on every write** (5 of 5 files). Its digest
  changes because the `Exif` and XMP items live *inside* `mdat`, and in 2 of 5
  files the box also **moves** because `meta` grew ahead of it.
- The **primary item's coded extents, resolved through `pitm` → `dimg` → `iloc`,
  survive byte-for-byte** (5 of 5 files). So does `ipco`, where HEIF keeps the
  decode properties.

So HEIC *does* get an `image_hash` in version 1, but the rule is **"the primary
item's coded extents"**, not **"the `mdat` payload"**. A rule written against
`mdat` — the shape §11 speculated about — would have been wrong on every file
tested.

## Method

exiftool **13.55** (`/opt/homebrew/bin/exiftool`), macOS 26 / arm64 (M4 mini).

Five iPhone/iPad HEICs were copied out of the read-only archive at
`/Volumes/rockit88/03_DEDUPED_ARCHIVE/photos/high_confidence/` into a scratch
directory. The originals were never opened for writing. Each copy got one
metadata write:

```
exiftool -overwrite_original \
  -Description=lightbox-experiment \
  -Keywords=heic-roundtrip \
  '-DateTimeOriginal=2021:07:08 09:10:11' \
  '-OffsetTimeOriginal=-04:00' \
  <file>.heic
```

`mp4dump` (Bento4) is not installed, so the box structure was read with
`scripts/heic-box-walk.swift`, written for this experiment. It walks ISOBMFF
boxes (handling `meta` as a FullBox, 64-bit `largesize`, and the `iprp`/`ipco`
nesting), parses `pitm`, `iinf`/`infe` (v0–v3), `iref` and `iloc` (v0/1/2 with
`construction_method` and `base_offset`), and prints a SHA-256 of exactly the
bytes each item's extents cover.

The five were chosen to span the shapes the constraint section of #12 worried
about: a plain single capture, an HDR gain map, two Live Photo stills, and a
Portrait frame carrying a real depth map. Selection scanned all 1238 genuine
HEICs in the archive (12 of the 1250 `.heic`-named files are actually JPEGs) for
`ContentIdentifier` and for `urn:com:apple:photo:*` / `urn:mpeg:*` auxiliary
image types.

## The structural finding that mattered

**Every one of the 1238 HEICs in the archive has a `grid` primary item.** The
`pitm` box names a derived item whose own `iloc` entry is an 8-byte grid
descriptor stored in `idat` with `construction_method == 1`; the pixels live in
the `hvc1` tile items its `dimg` reference names — 6 tiles on the iPad file, 48
on every iPhone file.

Two traps follow from that, both of which a naive reading of `iloc` walks into:

1. **`construction_method == 1` offsets are relative to the `idat` payload, not
   to the file.** A parser that ignores the construction method hashes the
   first eight bytes of the file (`ftyp`'s header) and calls it the image.
2. **The primary item's own extent is 8 bytes of layout metadata, not image
   data.** The rule has to follow `dimg` to the tiles.

## Per-file results

Every file: primary extents identical, `ipco` identical, whole `mdat` changed.

| file | device / iOS | shape | items before→after | primary extents | `ipco` | whole `mdat` |
|---|---|---|---|---|---|---|
| 1 | iPad 6, 13.7 | plain, 6 tiles | 9 → 10 (XMP added) | **identical** | identical | changed + **moved** |
| 2 | iPhone 13 Pro, 17.4.1 | HDR gain map, 48 tiles | 53 → 54 (XMP added) | **identical** | identical | changed + **moved** |
| 3 | iPhone 8, 11.2.2 | Live Photo still, 48 tiles | 52 → 52 | **identical** | identical | changed |
| 4 | iPhone 13 Pro, 18.0.1 | Live Photo + gain map, 48 tiles | 66 → 66 | **identical** | identical | changed |
| 5 | iPhone XR, 14.4 | Portrait: depth + 3 mattes, 48 tiles | 62 → 62 | **identical** | identical | changed |

What exiftool did, consistently across all five:

- It rewrote the `Exif` item and the XMP (`mime`) item. Where no XMP item
  existed (files 1 and 2) it **inserted one**, appended an `infe` entry to
  `iinf`, appended a `cdsc` reference to `iref` pointing at the primary, and
  appended an `iloc` entry. `iinf`, `iref` and `iloc` therefore all grew.
- It **never renumbered an existing item id**, and never reordered `dimg`.
- It **never added or removed a box type**. Only `meta`, `iinf`, `iref`, `iloc`
  and `mdat` changed size.
- It **relocated the coded tiles within the file** in all five cases — every
  tile's `iloc` offset shifted (by +2952 on file 1, for instance) — while
  leaving every tile's *bytes* untouched. This is why the rule must read the
  offsets out of `iloc` rather than assume anything about layout.
- It left every auxiliary image (gain map, depth map, portrait-effects matte,
  semantic mattes) and the `thmb` thumbnail byte-identical.

The only items whose bytes changed in any file were `Exif` and `mime`.

## What the rule hashes, and why

`HEICImageHash` hashes **the primary item's coded extents, in `dimg` order and
then `iloc` extent order**, and nothing else.

**Auxiliaries are excluded** — the gain map, the depth map, the mattes, the
`thmb` thumbnail, `Exif`, and XMP. #12's constraint states the reason: two files
that are the same photograph with different auxiliaries must group together. A
gain map that Photos regenerates, or a Portrait matte a round-trip through
another tool drops, would otherwise split a duplicate group.

**`ipco` is excluded** even though it was byte-identical in all five files. Two
reasons. First, it is the WebP `VP8X` trap in a different costume: a writer that
adds an auxiliary image adds properties to `ipco`, and a rule that hashed the
whole box would change its answer because of a *sibling* image. Second, the one
property it would buy — `irot` — is one §11 already rules on: "an
orientation-only difference hashes as identical … this is correct." Including
`ipco` would contradict that. `hvcC` (the HEVC parameter sets) is the argument
for the other side and is noted here so a version 2 has the measurement to hand:
`ipco` survived the round-trip unchanged on all five files, so including it
would not have broken the warranty against *this* writer.

**Trailing bytes past the last box are hashed**, matching JPEG after EOI, PNG
after IEND and WebP past the declared RIFF size. An appended payload is content,
not metadata; dropping it would make a file carrying one hash identically to a
file without it, and the duplicate view would then offer to delete the copy with
the extra content.

**The rule fails closed.** If the primary item cannot be identified — no `iinf`
box, or no `infe` entry naming it — or if a derived primary does not resolve to
coded items that are distinct from it and not themselves derived, the file gets
no `image_hash` at all. The tempting fallback is to hash the primary item's own
extent, and that is a bug rather than a default: a `grid` descriptor is eight
bytes of rows, columns and output size, so two unrelated photographs of the same
dimensions would land in one duplicate group. Those files fall back to
`content_hash` and `phash`, which is less useful rather than wrong.

`image_hash_kind` is **`heic-item-v1`**.

## Box listings

Offsets and sizes in bytes, taken from `scripts/heic-box-walk.swift`. Only
`meta`'s children are recursed into; `mdat` is opaque here by design, since the
whole point is that its interior is addressed through `iloc`.

### `1-plain.heic` — iPad (6th gen), iOS 13.7 — plain single capture, no auxiliary images

| box | before offset | before size | after offset | after size | |
|---|---:|---:|---:|---:|---|
| `ftyp` | 0 | 24 | 0 | 24 | unchanged |
| `meta` | 24 | 1856 | 24 | 1927 | **resized 1856→1927** |
| `hdlr` | 36 | 34 | 36 | 34 | unchanged |
| `dinf` | 70 | 36 | 70 | 36 | unchanged |
| `pitm` | 106 | 14 | 106 | 14 | unchanged |
| `iinf` | 120 | 203 | 120 | 244 | **resized 203→244** |
| `iref` | 323 | 64 | 364 | 78 | **resized 64→78** |
| `iprp` | 387 | 1317 | 442 | 1317 | moved 387→442 |
| `ipco` | 395 | 1250 | 450 | 1250 | moved 395→450 |
| `hvcC` | 403 | 579 | 458 | 579 | moved 403→458 |
| `ispe` | 982 | 20 | 1037 | 20 | moved 982→1037 |
| `ispe` | 1002 | 20 | 1057 | 20 | moved 1002→1057 |
| `irot` | 1022 | 9 | 1077 | 9 | moved 1022→1077 |
| `pixi` | 1031 | 16 | 1086 | 16 | moved 1031→1086 |
| `hvcC` | 1047 | 578 | 1102 | 578 | moved 1047→1102 |
| `ispe` | 1625 | 20 | 1680 | 20 | moved 1625→1680 |
| `ipma` | 1645 | 59 | 1700 | 59 | moved 1645→1700 |
| `idat` | 1704 | 16 | 1759 | 16 | moved 1704→1759 |
| `iloc` | 1720 | 160 | 1775 | 176 | **resized 160→176** |
| `mdat` | 1880 | 97895 | 1951 | 100776 | **resized 97895→100776** |

- primary item: 7 grid; coded items via `dimg`: `1,2,3,4,5,6` (unchanged after)
- items in `iinf`: 9 → 10
- primary coded bytes: 89575 → 89575
- **primary extent SHA-256 before:** `325def2797da43152ec2f8d5f693d3352c81c6b3954f1083f9d873cbb0a20b7a`
- **primary extent SHA-256 after: ** `325def2797da43152ec2f8d5f693d3352c81c6b3954f1083f9d873cbb0a20b7a` — **IDENTICAL**
- `ipco` SHA-256: `96e4ef6e9be2740fa55c364f4715c595…` → `96e4ef6e9be2740fa55c364f4715c595…` — identical
- whole `mdat`: offset 1880→1951, size 97895→100776, sha `a8c8fe2aa188bb2d…`→`91dad089d3d45426…` — **CHANGED**

### `2-hdrgainmap.heic` — iPhone 13 Pro, iOS 17.4.1 — HDR gain-map auxiliary

| box | before offset | before size | after offset | after size | |
|---|---:|---:|---:|---:|---|
| `ftyp` | 0 | 40 | 0 | 40 | unchanged |
| `meta` | 40 | 3696 | 40 | 3767 | **resized 3696→3767** |
| `hdlr` | 52 | 33 | 52 | 33 | unchanged |
| `dinf` | 85 | 36 | 85 | 36 | unchanged |
| `pitm` | 121 | 14 | 121 | 14 | unchanged |
| `iinf` | 135 | 1147 | 135 | 1188 | **resized 1147→1188** |
| `iref` | 1282 | 176 | 1323 | 190 | **resized 176→190** |
| `iprp` | 1458 | 1398 | 1513 | 1398 | moved 1458→1513 |
| `ipco` | 1466 | 1063 | 1521 | 1063 | moved 1466→1521 |
| `colr` | 1474 | 548 | 1529 | 548 | moved 1474→1529 |
| `hvcC` | 2022 | 112 | 2077 | 112 | moved 2022→2077 |
| `ispe` | 2134 | 20 | 2189 | 20 | moved 2134→2189 |
| `ispe` | 2154 | 20 | 2209 | 20 | moved 2154→2209 |
| `irot` | 2174 | 9 | 2229 | 9 | moved 2174→2229 |
| `pixi` | 2183 | 16 | 2238 | 16 | moved 2183→2238 |
| `hvcC` | 2199 | 111 | 2254 | 111 | moved 2199→2254 |
| `ispe` | 2310 | 20 | 2365 | 20 | moved 2310→2365 |
| `hvcC` | 2330 | 113 | 2385 | 113 | moved 2330→2385 |
| `ispe` | 2443 | 20 | 2498 | 20 | moved 2443→2498 |
| `pixi` | 2463 | 14 | 2518 | 14 | moved 2463→2518 |
| `auxC` | 2477 | 52 | 2532 | 52 | moved 2477→2532 |
| `ipma` | 2529 | 327 | 2584 | 327 | moved 2529→2584 |
| `idat` | 2856 | 16 | 2911 | 16 | moved 2856→2911 |
| `iloc` | 2872 | 864 | 2927 | 880 | **resized 864→880** |
| `mdat` | 3736 | 307155 | 3807 | 310042 | **resized 307155→310042** |

- primary item: 49 grid; coded items via `dimg`: `1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48` (unchanged after)
- items in `iinf`: 53 → 54
- primary coded bytes: 281208 → 281208
- **primary extent SHA-256 before:** `1e987abbefaa6dec7fa15699cef4ea09fcdcd78905b4d7482d0599db5f3c738f`
- **primary extent SHA-256 after: ** `1e987abbefaa6dec7fa15699cef4ea09fcdcd78905b4d7482d0599db5f3c738f` — **IDENTICAL**
- `ipco` SHA-256: `1183c341640db5843428607184451e61…` → `1183c341640db5843428607184451e61…` — identical
- whole `mdat`: offset 3736→3807, size 307155→310042, sha `6fa19359da8f7480…`→`40a1638a89e3ae74…` — **CHANGED**

### `3-livephoto.heic` — iPhone 8, iOS 11.2.2 — Live Photo still (ContentIdentifier)

| box | before offset | before size | after offset | after size | |
|---|---:|---:|---:|---:|---|
| `ftyp` | 0 | 24 | 0 | 24 | unchanged |
| `meta` | 24 | 4027 | 24 | 4027 | unchanged |
| `hdlr` | 36 | 34 | 36 | 34 | unchanged |
| `dinf` | 70 | 36 | 70 | 36 | unchanged |
| `pitm` | 106 | 14 | 106 | 14 | unchanged |
| `iinf` | 120 | 1126 | 120 | 1126 | unchanged |
| `iref` | 1246 | 162 | 1246 | 162 | unchanged |
| `iprp` | 1408 | 1779 | 1408 | 1779 | unchanged |
| `ipco` | 1416 | 1453 | 1416 | 1453 | unchanged |
| `colr` | 1424 | 560 | 1424 | 560 | unchanged |
| `hvcC` | 1984 | 112 | 1984 | 112 | unchanged |
| `ispe` | 2096 | 20 | 2096 | 20 | unchanged |
| `ispe` | 2116 | 20 | 2116 | 20 | unchanged |
| `irot` | 2136 | 9 | 2136 | 9 | unchanged |
| `pixi` | 2145 | 16 | 2145 | 16 | unchanged |
| `colr` | 2161 | 560 | 2161 | 560 | unchanged |
| `hvcC` | 2721 | 112 | 2721 | 112 | unchanged |
| `ispe` | 2833 | 20 | 2833 | 20 | unchanged |
| `pixi` | 2853 | 16 | 2853 | 16 | unchanged |
| `ipma` | 2869 | 318 | 2869 | 318 | unchanged |
| `idat` | 3187 | 16 | 3187 | 16 | unchanged |
| `iloc` | 3203 | 848 | 3203 | 848 | unchanged |
| `mdat` | 4051 | 346191 | 4051 | 345741 | **resized 346191→345741** |

- primary item: 49 grid; coded items via `dimg`: `1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48` (unchanged after)
- items in `iinf`: 52 → 52
- primary coded bytes: 328365 → 328365
- **primary extent SHA-256 before:** `b615cd3c83ca735d6b9b02f84914aacd9a0ca8c88a5e9c484bba79cdac5681b4`
- **primary extent SHA-256 after: ** `b615cd3c83ca735d6b9b02f84914aacd9a0ca8c88a5e9c484bba79cdac5681b4` — **IDENTICAL**
- `ipco` SHA-256: `90b39f1d6ad0ee2326225053f89c1380…` → `90b39f1d6ad0ee2326225053f89c1380…` — identical
- whole `mdat`: offset 4051→4051, size 346191→345741, sha `d0e203620dda4a79…`→`353f401343b10cda…` — **CHANGED**

### `4-livephoto-hdr.heic` — iPhone 13 Pro, iOS 18.0.1 — Live Photo still + HDR gain map

| box | before offset | before size | after offset | after size | |
|---|---:|---:|---:|---:|---|
| `ftyp` | 0 | 40 | 0 | 40 | unchanged |
| `meta` | 40 | 5246 | 40 | 5246 | unchanged |
| `hdlr` | 52 | 33 | 52 | 33 | unchanged |
| `dinf` | 85 | 36 | 85 | 36 | unchanged |
| `pitm` | 121 | 14 | 121 | 14 | unchanged |
| `iinf` | 135 | 1440 | 135 | 1440 | unchanged |
| `iref` | 1575 | 226 | 1575 | 226 | unchanged |
| `iprp` | 1801 | 2389 | 1801 | 2389 | unchanged |
| `ipco` | 1809 | 1995 | 1809 | 1995 | unchanged |
| `colr` | 1817 | 548 | 1817 | 548 | unchanged |
| `ispe` | 2365 | 20 | 2365 | 20 | unchanged |
| `ispe` | 2385 | 20 | 2385 | 20 | unchanged |
| `irot` | 2405 | 9 | 2405 | 9 | unchanged |
| `pixi` | 2414 | 16 | 2414 | 16 | unchanged |
| `ispe` | 2430 | 20 | 2430 | 20 | unchanged |
| `ispe` | 2450 | 20 | 2450 | 20 | unchanged |
| `pixi` | 2470 | 14 | 2470 | 14 | unchanged |
| `auxC` | 2484 | 52 | 2484 | 52 | unchanged |
| `hvcC` | 2536 | 578 | 2536 | 578 | unchanged |
| `hvcC` | 3114 | 579 | 3114 | 579 | unchanged |
| `hvcC` | 3693 | 111 | 3693 | 111 | unchanged |
| `ipma` | 3804 | 386 | 3804 | 386 | unchanged |
| `idat` | 4190 | 24 | 4190 | 24 | unchanged |
| `iloc` | 4214 | 1072 | 4214 | 1072 | unchanged |
| `mdat` | 5286 | 485922 | 5286 | 485804 | **resized 485922→485804** |

- primary item: 49 grid; coded items via `dimg`: `1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48` (unchanged after)
- items in `iinf`: 66 → 66
- primary coded bytes: 446940 → 446940
- **primary extent SHA-256 before:** `13f6dbbc748e679c26b3a9d0fe67d66f411b08e83dc88399072f1eb3b3a9791a`
- **primary extent SHA-256 after: ** `13f6dbbc748e679c26b3a9d0fe67d66f411b08e83dc88399072f1eb3b3a9791a` — **IDENTICAL**
- `ipco` SHA-256: `84a0a3bb8d67174f5a9550ba2c33453c…` → `84a0a3bb8d67174f5a9550ba2c33453c…` — identical
- whole `mdat`: offset 5286→5286, size 485922→485804, sha `2eb5e477e13a1270…`→`10a477be68c87957…` — **CHANGED**

### `5-portrait-depth.heic` — iPhone XR, iOS 14.4 — Portrait: depth map + effects/semantic mattes

| box | before offset | before size | after offset | after size | |
|---|---:|---:|---:|---:|---|
| `ftyp` | 0 | 40 | 0 | 40 | unchanged |
| `meta` | 40 | 5390 | 40 | 5390 | unchanged |
| `hdlr` | 52 | 34 | 52 | 34 | unchanged |
| `dinf` | 86 | 36 | 86 | 36 | unchanged |
| `pitm` | 122 | 14 | 122 | 14 | unchanged |
| `iinf` | 136 | 1436 | 136 | 1436 | unchanged |
| `iref` | 1572 | 302 | 1572 | 302 | unchanged |
| `iprp` | 1874 | 2532 | 1874 | 2532 | unchanged |
| `ipco` | 1882 | 2161 | 1882 | 2161 | unchanged |
| `colr` | 1890 | 560 | 1890 | 560 | unchanged |
| `hvcC` | 2450 | 112 | 2450 | 112 | unchanged |
| `ispe` | 2562 | 20 | 2562 | 20 | unchanged |
| `ispe` | 2582 | 20 | 2582 | 20 | unchanged |
| `irot` | 2602 | 9 | 2602 | 9 | unchanged |
| `pixi` | 2611 | 16 | 2611 | 16 | unchanged |
| `hvcC` | 2627 | 111 | 2627 | 111 | unchanged |
| `ispe` | 2738 | 20 | 2738 | 20 | unchanged |
| `hvcC` | 2758 | 111 | 2758 | 111 | unchanged |
| `ispe` | 2869 | 20 | 2869 | 20 | unchanged |
| `pixi` | 2889 | 14 | 2889 | 14 | unchanged |
| `auxC` | 2903 | 60 | 2903 | 60 | unchanged |
| `colr` | 2963 | 368 | 2963 | 368 | unchanged |
| `hvcC` | 3331 | 113 | 3331 | 113 | unchanged |
| `ispe` | 3444 | 20 | 3444 | 20 | unchanged |
| `auxC` | 3464 | 62 | 3464 | 62 | unchanged |
| `hvcC` | 3526 | 113 | 3526 | 113 | unchanged |
| `auxC` | 3639 | 59 | 3639 | 59 | unchanged |
| `hvcC` | 3698 | 113 | 3698 | 113 | unchanged |
| `auxC` | 3811 | 59 | 3811 | 59 | unchanged |
| `hvcC` | 3870 | 113 | 3870 | 113 | unchanged |
| `auxC` | 3983 | 60 | 3983 | 60 | unchanged |
| `ipma` | 4043 | 363 | 4043 | 363 | unchanged |
| `idat` | 4406 | 16 | 4406 | 16 | unchanged |
| `iloc` | 4422 | 1008 | 4422 | 1008 | unchanged |
| `mdat` | 5430 | 1749135 | 5430 | 1748782 | **resized 1749135→1748782** |

- primary item: 49 grid; coded items via `dimg`: `1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48` (unchanged after)
- items in `iinf`: 62 → 62
- primary coded bytes: 1581837 → 1581837
- **primary extent SHA-256 before:** `e717653b567d4aa7be89fb2afc73538560707129f2b803cd6be6dab5c8685863`
- **primary extent SHA-256 after: ** `e717653b567d4aa7be89fb2afc73538560707129f2b803cd6be6dab5c8685863` — **IDENTICAL**
- `ipco` SHA-256: `0e70dc8185b92e4282044b953dbd1a6f…` → `0e70dc8185b92e4282044b953dbd1a6f…` — identical
- whole `mdat`: offset 5430→5430, size 1749135→1748782, sha `8e5bfd4a8263a07e…`→`db22f1720632a18b…` — **CHANGED**

## Sweep over the whole archive

After the rule was implemented, `HEICImageHash.includedRanges` was run over all
1238 genuine HEICs in the archive:

```
ok=1238  failed=0  maxRanges=1  distinct=1238
```

Every file parsed. Every file's primary extents **coalesced to exactly one
range** — the tiles abut in `mdat`, so the 48 `dimg` extents merge into a single
span, which is what keeps the flood guard from ever mattering on real input. And
all 1238 digests are distinct, which is the expected answer for an archive that
has already been deduplicated: the rule is not collapsing different photographs
into one group.

## The fixture the tests use

The round-trip above runs on files far too large to check in. macOS's own HEIF
encoder turns out to produce the same structure, though: `CGImageDestination`
writing a 1024×768 image emits a `grid` primary of four `hvc1` tiles with the
grid descriptor in `idat` under `construction_method == 1` — the real shape, in
17,268 bytes and with no photograph in it. That file is
`Core/Tests/LightboxCoreTests/Fixtures/grid.heic`, and it round-trips exactly
like the captures above: primary extents identical, `mdat` both grown and moved
(669 → 791).

Below 1024×768 the encoder stops tiling and writes a single `hvc1` item, so the
fixture is checked in rather than generated: a future macOS raising that
threshold would otherwise turn the grid test back into the single-item case
without anything failing. `theCheckedInFixtureIsATiledGridHEIC` pins its size
and extents so that cannot pass unnoticed.

## Reproducing

```bash
swift scripts/heic-box-walk.swift <file.heic>
```

Copy a HEIC, run the walker, run the exiftool command above on the copy, run the
walker again, and diff. The line to compare is `PRIMARY-SHA256`.
