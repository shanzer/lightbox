# Lightbox — design

**Date:** 2026-09-05
**Status:** approved, ready for implementation planning

A native macOS image browser in the spirit of Adobe Bridge: browse a directory
tree, search it by metadata and by content, act on selections in bulk, and edit
EXIF in place.

## 1. Goals

1. Browse any directory as a thumbnail grid, optionally including every
   subdirectory.
2. Search by structural metadata — dimensions, file size, date, camera,
   extension.
3. Search by content, using on-device models: text in the image, faces,
   subject labels, and free-text semantic queries.
4. Select many images and move, copy, or delete them, recoverably.
5. Read and write EXIF, including capture time, for one image or a selection.
6. Identify duplicates — byte-identical files, the same image carrying different
   metadata, and visually near-identical photos.

### Non-goals

Image editing. Version control of images. Cloud sync. Publishing. Multi-user
anything. Video, for now — the schema does not preclude it, but nothing in this
spec supports it.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Platform | Native macOS, SwiftUI, arm64 only, macOS 26 minimum | Neural Engine access for Vision and CLIP; QuickLook thumbnails for RAW/HEIC/PSD for free; modern Swift-native Vision API |
| Persistence | SQLite via GRDB.swift, FTS5 for text | Only practical way to make OCR text search instant across 50k+ images |
| Index location | One global database in Application Support | Keeps the photo tree clean; enables cross-directory search |
| Metadata read | ImageIO (`CGImageSource`) | In-process, no subprocess on the hot indexing path |
| Metadata write | exiftool subprocess | No re-encode, unlike ImageIO; broad format coverage |
| Delete | Trash by default, permanent behind explicit confirmation | Recoverable by default on 50k-file batches |
| Sandbox | None; local unsigned development build | Security-scoped bookmarks for arbitrary browsing is disproportionate machinery for a personal tool |
| "Meme" detection | A user-editable saved search over Vision signals, plus a CLIP semantic query | Explainable and tunable, rather than an opaque classifier |
| Hash function | SHA-256 via CryptoKit | Hardware-accelerated on Apple Silicon; collision resistance removes the need for a byte-for-byte confirmation |
| Duplicate detection | Three hashes at different levels: whole file, image data, perceptual | Metadata edits must not destroy duplicate groupings |

Development happens on the M4 Mac mini. The Intel machine is being retired
within three weeks and is not a support target.

## 3. Architecture

One app target for the UI, one `Core` framework target holding everything else
so the whole system is testable without launching the app.

| Module | Responsibility | Depends on |
|---|---|---|
| `Walker` | Enumerate a root, filter by extension, handle symlink loops and junk files | — |
| `IndexStore` | Schema, migrations, upsert, query | GRDB |
| `MetadataReader` | Read EXIF/TIFF/GPS dictionaries | ImageIO |
| `MetadataWriter` | Apply EXIF edits with backup and verification | exiftool |
| `ThumbnailCache` | Generate and cache thumbnails, evict by LRU | QuickLookThumbnailing |
| `Hasher` | Whole-file, image-data, and perceptual hashes | CryptoKit |
| `VisionAnalyzer` | OCR, classification labels, feature print, face rectangles | Vision |
| `EmbeddingAnalyzer` | CLIP image and text embeddings | Core ML |
| `QueryCompiler` | `SearchQuery` value type to SQL, FTS5, and vector scan | IndexStore |
| `FileOperator` | Move, copy, trash; undo journal | — |
| `IndexCoordinator` | Pipeline orchestration, priority, cancellation, progress | all of the above |

`VisionAnalyzer` and `EmbeddingAnalyzer` both satisfy a single protocol:

    protocol Analyzer {
        var version: Int { get }
        func analyze(_ batch: [ImageRef]) async throws -> [Analysis]
    }

A third analyzer — a local VLM, or a cloud model — can be added later without
changing `IndexCoordinator`.

Each module exposes a protocol at its boundary, and each has a test double, so
`IndexCoordinator` can be tested without touching a filesystem, a subprocess, or
a model.

## 4. Data model

Database at `~/Library/Application Support/Lightbox/index.sqlite`, in WAL mode
through a GRDB `DatabasePool`, so a window's reads never wait for its own or
another window's writes. WAL keeps two sidecars — `index.sqlite-wal` and
`index.sqlite-shm` — beside it; the three are one database and are deleted
together.

**`files`** — `id`, `path` (unique), `parent_dir`, `name`, `ext`, `size`,
`mtime`, `device`, `inode`, `volume_uuid`, `width`, `height`, `capture_time`,
`capture_offset`, `camera_make`, `camera_model`, `orientation`, `content_hash`,
`image_hash`, `image_hash_kind`, `phash`, `hashed_at`, `indexed_at`.

**`files_fts`** — a standalone FTS5 table over `name` and `ocr_text`, not an
external-content one: it stores its own copy of the text, keyed by `rowid` =
`files.id`, and is kept in step by `upsert` and by the `files_ad` trigger.

**`analysis`** — `file_id`, `ocr_text`, `text_coverage` (union area of OCR
bounding boxes as a fraction of the frame), `top_labels` (JSON),
`has_faces`, `feature_print` BLOB, `clip_embedding` BLOB, `analyzer_versions`
(JSON), `analyzed_at`.

**`saved_searches`** — `id`, `name`, `query` (JSON-encoded `SearchQuery`),
`is_builtin`.

**`op_journal`** — `op_id`, `batch_id`, `kind`, `src`, `dst`, `trash_url`,
`timestamp`, `state`.

### Volume identity

*(Amended: schema v2.)* A row records which volume it was seen on, so a walk of
a path is never taken as evidence about rows that came from a different
filesystem — a stale mount point, a share that mounts empty, or a drive back
with a fresh filesystem otherwise reads as "every file here was deleted" from a
clean, complete, zero-entry pass.

Two columns, because neither id is sufficient alone:

- **`volume_uuid`** — `URLResourceValues.volumeUUIDString`, read from the scan's
  root once *before* the walk and once *after*, with the two required to agree
  before anything is written. It is a property of the filesystem, assigned when
  it is created, and it survives unmounts, reboots and replugs. This is the
  identity.
- **`device`** — `st_dev`, assigned at *mount* time and renumbered when a drive
  comes back. It cannot be the identity, and is kept because an inode is unique
  only within a volume and because rows written before v2 have nothing else.

**The matching rule for the reconcile's delete: a row is prunable if its
`volume_uuid` equals the root's, or its `volume_uuid` is NULL and its `device`
equals the root's `st_dev`.** The second clause is the pre-migration case.

A filesystem that publishes no UUID (SMB, some FAT) binds NULL, so the first
clause cannot hold and the rule collapses to the `st_dev` comparison **for rows
that carry no UUID; a row already stamped with one is never matched by a
nameless root.** That asymmetry is the safe direction — a row naming a volume is
making a claim a nameless root cannot answer — and it is why `volume_uuid` is
only ever written through `COALESCE`, by both the stamp and the upsert: a pass
whose UUID read came back nil refreshes `device` but must not erase an identity
an earlier pass established, which would demote the row into the weaker case.

**Both reads are load-bearing, and neither may be dropped for the other.** The
pre-walk read is what makes the walk's results attributable — read the volume
only afterwards and a drive swapped out mid-walk hands the *impostor's*
identity to rows that came off the real one, which is unrecoverable: a later
pass on the real volume would match them by neither UUID nor device and could
never prune them. The post-walk read is what makes those results trustworthy.
So the identity is captured before the walk, re-read after it, and the stamp
and the delete are both gated on the two matching. The per-entry upserts run
before that gate and are deliberately not covered: rows written from an
impostor describe paths the real volume does not have, so the next clean pass
reconciles or re-stamps them.

The tier 1 hashing pass guards its writes with the same identity, comparing the
UUID where one exists and `st_dev` where it does not — so a root that has become
a *different* volume aborts the pass, not merely one that has gone away. That
distinction matters because `hashed_at` records an attempt: a pass that kept
going against an impostor would mark the whole library attempted and no later
pass would revisit it.

v2 adds the column nullable and backfills nothing: no row can name a UUID for a
volume that may not be mounted. Each tier 0 pass instead stamps the rows whose
files it actually walked — not the whole path scope, because a row the walk
could not look at is not evidence of anything. A volume whose UUID *changes* (a
reformat) is out of scope; that is a new library.

### Staleness

The freshness key is `(size, mtime)`. Rescanning an unchanged tree costs one
`stat` per file and no re-analysis. Changing either re-reads the file.
`analyzer_versions` is compared per analyzer, so improving OCR forces
re-analysis of OCR alone rather than of everything.

### Vector search

Brute force, deliberately. 50k embeddings at 512 float32 dimensions is 100 MB;
a full cosine scan is one `cblas_sgemv` call and completes in single-digit
milliseconds. An approximate-nearest-neighbour index would be complexity without
a problem to solve at this scale.

## 5. Hashing and duplicate detection

Three hashes, because there are three different questions.

| Field | What it covers | Answers |
|---|---|---|
| `content_hash` | SHA-256 of the whole file | Are these the same file? |
| `image_hash` | SHA-256 of the format-stripped image data | Are these the same image carrying different metadata? |
| `phash` | 64-bit DCT perceptual hash of a 32x32 render | Are these the same photo, re-encoded or resized? |

`image_hash` is the one that survives Lightbox's own EXIF edits. Without it,
setting a capture time across 500 files silently destroys 500 duplicate
groupings. `phash` is cheap, because it is computed from a small ImageIO downsample rather
than a full decode, and it catches what neither exact hash can: the same photo
at a different JPEG quality, or a HEIC converted to JPEG.

The perceptual hash is deliberately *not* computed from the cached QuickLook
thumbnail. QuickLook fits to aspect and may pad, and for RAW it may return the
embedded camera preview rather than a render of the image data — all of which
would make the hash depend on QuickLook's behaviour rather than on the image.
It is computed instead from a dedicated ImageIO downsample squashed to exactly
32x32.

SHA-256 rather than `photolib`'s MD5. `photolib` follows its MD5 with a
byte-for-byte confirmation precisely because MD5 is collision-broken; with
SHA-256 that confirmation is unnecessary and is not carried over.

### Computing `image_hash`

There is no generic way to skip a header, so each container gets its own rule.
Where a container's metadata segments are additive, the rule is a denylist,
because several segments that look like metadata determine how pixels decode
and an allowlist would silently drop them. Where writing metadata restructures
the container, a denylist cannot work and the rule is an allowlist of the
image-bearing segments instead. Every rule below was verified empirically
against an exiftool round-trip before being written down.

**JPEG** — exclude APP0 (JFIF), APP1 (EXIF and XMP), APP13 (Photoshop and
IPTC), and COM. Retain APP2 and APP14: APP2 carries the ICC profile, and APP14
carries Adobe's colour transform marker, which determines whether the data is
YCbCr or YCCK. Dropping APP14 would make two genuinely different images hash
identically. Everything from SOF, DQT, DHT, and DRI through the entropy-coded
scan to EOI is hashed.

**PNG** — exclude `tEXt`, `zTXt`, `iTXt`, `eXIf`, `tIME`, and `pHYs`. Retain
IHDR, PLTE, tRNS, IDAT, and the colour chunks `gAMA`, `cHRM`, `iCCP`, `sRGB`.

**WebP** — an allowlist, not a denylist: hash only `VP8 `, `VP8L`, `ALPH`,
`ANIM`, `ANMF`, and `ICCP`. A denylist of `EXIF` and `XMP ` does not work,
because writing EXIF to a simple-format WebP promotes it to extended format and
inserts a `VP8X` header chunk that was not previously present. A denylist sees
a new chunk and hashes differently; the allowlist ignores it.

**GIF** — `image_hash` is NULL in version 1. GIF metadata lives in Comment and
Application extension blocks, but the NETSCAPE Application extension carries the
loop count, which affects playback — so neither a denylist nor an allowlist is
unambiguous, and GIFs rarely carry EXIF worth editing. The cost of getting this
wrong exceeds the value of getting it right.

**HEIC** — an allowlist, and not over `mdat`. Hash the byte extents `iloc`
assigns to the **primary item**, resolved through `pitm` and — when the primary
is a `grid`, `iovl` or `iden` derived item, which every capture in the library
is — through its `dimg` reference to the coded tiles, hashed in `dimg` order.
`construction_method` is honoured, so a `grid` descriptor in `idat` is not
mistaken for a file offset. Auxiliary images (HDR gain map, Portrait depth map
and mattes), the `thmb` thumbnail, `Exif`, XMP and `ipco` are all excluded: two
files that are the same photograph with different auxiliaries must group
together. The measurement behind this — five real captures through an exiftool
round-trip — is
`docs/superpowers/notes/2026-09-07-heic-mdat-roundtrip.md`. The whole `mdat`
box changed on every one of them, so the obvious rule would have been wrong.
A HEIC whose primary item cannot be identified — no `iinf` box, or no `infe`
entry for it — or whose derived primary does not resolve to distinct,
non-derived coded items gets **no `image_hash` at all** rather than a hash of
its layout descriptor: a `grid` descriptor is eight bytes of rows, columns and
output size, identical for any two photographs of the same dimensions, so
hashing it would group unrelated pictures as duplicates. Such files fall back to
`content_hash` and `phash` like the formats below.

**RAW, TIFF, PSD, GIF** — `image_hash` is NULL in version 1. TIFF and RAW are
IFD-based with byte offsets that shift when metadata is written, so a stable
hash means a parser per vendor container. For these formats duplicate detection
falls back to `content_hash` and `phash`.

`image_hash_kind` records which rule produced the value — `jpeg-scan-v1`,
`png-idat-v1`, `webp-chunk-v1`, `heic-item-v1`, or NULL — so a rule can be
revised and only the affected rows recomputed.

### Two consequences

**An orientation-only difference hashes as identical.** Two files that display
rotated ninety degrees apart but share scan data receive the same `image_hash`.
This is correct — the image data is the same — but the duplicate view must
surface orientation so the right-side-up copy is not the one discarded.

**The size-bucket optimization does not transfer.** `photolib` skips most I/O by
hashing only files whose size is shared by two or more, which works because
exact duplicates have identical sizes. Files holding the same image with
different metadata have different sizes, so `image_hash` requires reading every
file in full.

### Perceptual hash

`photolib`'s DCT perceptual hash is ported directly, retaining its
`phash-dct-64-nodc` identifier: the same 32x32 luminance grid at Rec. 709
weights, the same separable DCT-II, the same 8x8 coefficient block with DC
dropped and F(0,8) substituted, the same six-decimal quantization, and the same
bit order.

The two tools will not produce bit-identical hashes, and the spec does not claim
they will. `photolib` resamples with `sips` and Lightbox resamples with
CoreGraphics; different kernels yield slightly different luminance grids and
therefore a few differing bits. What is guaranteed is that the hashes occupy the
same space and that Hamming distances between them are meaningful.

That distribution has now been measured rather than assumed. Across 36 real
photographs spanning HEIC, JPEG and PNG at orientations 1, 3 and 6, the
cross-tool distance was 0 on 16 files, 2 on 18, and 4 on 2 — mean 1.22, maximum
4, against `photolib`'s similarity threshold of 12. The hash function itself is
bit-exact with the original; the divergence comes entirely from the file-to-grid
stage, where `sips` and ImageIO resample differently.

Two consequences follow. Comparing a Lightbox hash against a `photolib` hash for
the same pair of images spends up to 8 of the 12-bit budget on pipeline
disagreement alone, so cross-tool comparison is meaningful but not free. And the
intermediate downsample size is part of the hash definition, not a performance
knob: at 256 pixels the mean divergence is 1.22, at full image size 0.67, and at
a single step straight to 32 it is 2.94 — so changing it silently invalidates
every stored hash. It is fixed at 256 and commented accordingly.

### Duplicate view

A view that groups the current scope by `image_hash`, then by `content_hash`
within each group, then offers `phash` neighbours within a Hamming threshold as
a separate, clearly-labelled tier of confidence. Each group shows every copy
with its path, size, dimensions, orientation, and capture time, and supports
keeping one and acting on the rest through the ordinary `FileOperator` path, so
duplicate removal is journalled and undoable like any other operation.

The grouping itself is `DuplicateFinder`, and the scope is the *same compiled
`WHERE` the grid uses*, so "duplicates in this folder" and "duplicates in the
whole library" are one code path. A group spanning two volumes is legitimate —
a backup copy is a duplicate, and the view shows both rather than hiding one.

Three semantics the threshold alone does not fix:

- **A row is in at most one group, in either tier.** "Which group is this file
  in?" has to have one answer, because the answer is what the user acts on.
- **The near tier is star-shaped, not a transitive cluster.** Every match is
  stated as a distance from one seed, and seeds are taken in the grid's order
  (name, then path — never row id, which SQLite reuses). Chaining A–B–C would
  put two files 24 bits apart into one set of "duplicates", which is how a
  near-duplicate view starts recommending the deletion of a different
  photograph.
- **The near tier never repeats a pair the exact tier already reported**, or
  every metadata-edited copy would appear as two findings.

The near tier compares every pair in the scope — `n(n-1)/2` XOR + popcount, no
index — so it is bounded by `DuplicateFinder.nearTierCeiling`, above which it
reports that it was *skipped* rather than returning an empty result. There is
deliberately no approximate prefix-bucketing fast path: it would silently drop
real near-duplicates from a view whose output is a deletion. See
`docs/superpowers/notes/2026-09-07-duplicate-grouping.md` for the measurement
behind the ceiling and the pigeonhole argument against bucketing.

## 6. Indexing pipeline

    walk -> stat/diff -> ImageIO metadata          (tier 0, on folder open)
    content hash + image hash + perceptual hash    (tier 1, explicitly started)
    Vision                                          (tier 2)
    CLIP                                            (tier 3)

    thumbnails                                      (on demand, driven by the grid)

A bounded structured-concurrency pipeline inside an actor. Three required
properties:

**Viewport priority, by construction.** Thumbnails are not generated by the
indexer at all; the grid requests them for the cells it is actually showing and
cancels the request when a cell scrolls away. Pre-generating thumbnails for
50,000 images on folder open would be minutes of work for images the user may
never reach, and requesting them from the visible cells makes viewport priority
a property of the UI rather than a queue the coordinator has to model. This is
the difference between an app that feels like Bridge and one that feels like a
batch job.

**Tiered commitment.** Tier 0 — stat and the ImageIO property dictionary —
runs on folder open and is fast because it decodes nothing: reading image
properties is a header read, not a render. It is what powers dimension, date,
and camera search.

Tier 1 is `content_hash`, `image_hash`, and the perceptual hash together. All
three require reading the file's bytes, and the perceptual hash additionally
requires a decode, so they belong in the same explicitly started, resumable
background pass rather than on the folder-open path. Both SHA-256 hashes are
computed from a single read through `ContentHasher`, so the file is read once —
a format with an image-hash rule is read whole and both digests come off that
buffer, and one without a rule is streamed for its content hash alone.

That read is deliberately *not* a memory mapping, which an earlier draft of this
spec called for: on a failing external volume — exactly the hardware tier 1 is
built to grind through — a mid-read I/O error reaches a mapped buffer as
`SIGBUS`, an uncatchable fault that takes the whole app down, where the same
error on a `read(2)` comes back as `EIO` for the pass to record and move past.

Tier 2 (Vision) and tier 3 (CLIP) are likewise explicitly started, with visible
progress and a pause control. The user is never surprised by an hour of CPU or
by tens of minutes of reads from an external drive.

**Resumability.** Pipeline progress is database state, not memory: the tier 1
work queue is literally the set of rows whose `hashed_at` is NULL. Quitting
mid-pass loses nothing, and no separate progress record can drift out of sync
with the work. `hashed_at` is set even when hashing fails, so an unreadable file
records that it was attempted rather than being retried on every pass forever.

## 7. Search

One `SearchQuery` value type, compiled by `QueryCompiler` into SQL, an optional
FTS5 match, and an optional vector scan.

- **Structural** — width, height, exact dimensions (`200x200`), thresholds
  (`>= 2000px`), megapixels, aspect ratio, file size, extension, capture and
  modification date ranges, camera make and model.
- **Text** — FTS5 over filename and OCR text.
- **Semantic** — free-text CLIP query, ranked by cosine similarity with an
  adjustable threshold.
- **Duplicate** — `has_duplicates` (shares an `image_hash` or `content_hash`
  with at least one other indexed file), and `is_duplicate_of` for a specific
  file.
- **Derived** — `has_text` (OCR returned any string above the confidence
  floor), `has_faces` (Vision returned at least one face rectangle), label
  match, `is_screenshot` (no camera make/model in EXIF and dimensions match a
  known display or device resolution), and `is_meme`.

Predicates compose with AND, OR, and NOT. Any query is scopable to the current
folder or to the entire index, and any query is savable.

`is_meme` ships as a built-in saved search — OCR text present, text coverage
above roughly 8%, aspect ratio within a range, and low colour complexity —
editable
in the same editor as a user's own searches. Colour complexity is measured as
the count of distinct quantized colours in the cached thumbnail, which
distinguishes flat graphics and screenshots from photographs cheaply and without
a second decode. When the search is wrong, it is tuned, not retrained.

### Injection surface

FTS5 query syntax is an injection surface. User text containing `"`, `*`,
`NEAR`, or unbalanced quotes either throws or matches wrongly. All search input
is tokenized and re-quoted before reaching SQLite. Every SQL statement is
parameterized; no query is assembled by string interpolation. This path has its
own test file with hostile fixtures.

## 8. File operations

Move, copy, and delete over a multi-selection, each a single cancellable job
with progress.

- **Delete goes to the Trash.** `trashItem` returns the resulting Trash URL,
  which is recorded — that is what makes deletion undoable. Permanent delete is
  a separate command behind a confirmation naming the file count.
- **Undo journal.** Every operation is written to `op_journal` before it runs
  and marked complete after. Undo reverses moves, **sends copies to the Trash**,
  and restores from the Trash by recorded URL. The journal survives quitting.
  *(Amended: this bullet said undo "removes copies". It trashes them. `delete`
  is the only operation in this app that destroys a file, it lives behind its
  own confirmation, and an undo that unlinked would be a destructive operation
  reachable from ⌘Z with no confirmation at all. The Trash also keeps the
  reversal reversible, which is what makes redo undo-of-the-undo.)*
  *(Amended: undo reverses **the last batch** and only an all-`complete` one. A
  batch with `in_flight`, `reconciled` or `failed` rows is refused with a reason
  — `FileOperator.undoability(of:)` reports it, and reports a permanent delete
  as un-undoable **before** the operation rather than after. Reversing a row
  whose outcome the launch-time reconcile had to infer from two `stat`s is how a
  half-finished cross-volume move becomes a lost photo.)*
- **Collisions are resolved before anything moves.** A pre-flight pass checks
  the destination and presents skip / rename / replace, per item or applied to
  all. No batch discovers a collision at file 300.
- **Companion files travel with the image** — same basename `.xmp`, `.aae`,
  `.thm`, and RAW+JPEG pairs. Not doing this silently orphans edits. Default on,
  toggleable.
- **Copy clones on APFS** via `copyfile` with `COPYFILE_CLONE` when source and
  destination share a volume.
- **An unlink is decided by file identity, not by the path.** *(Amended: added
  for #33.)* Every index write in `FileOperator` is already guarded on identity
  — `setHashes(for:)`'s rule, matching the id and the `size`/`mtime` the row was
  written with. The two paths that *unlink* now read the same way. A permanent
  `delete` re-reads the row for each file and refuses when it no longer
  describes what is on disk, or when the row the plan read has been pruned —
  a missing row is disagreement, not an absence of evidence. **A refusal on the
  selected file refuses the whole item, companions included**: a sidecar travels
  with a photo because it shares its basename, so once the file at the source
  path is not the planned one, its companions belong to that file and unlinking
  them destroys a stranger's edits. A cross-volume move keeps the `stat` its
  copy was verified against and refuses to remove a source that no longer
  matches it, naming which sources went and which did not. A source that has
  vanished is not a mismatch on either path — something else unlinked it, which
  is where a finished move leaves it anyway. "There is a file here now" is not
  "this is the file we were asked to act on", and these are the only two places
  in the app where a file that arrived in the plan/execute gap would be
  destroyed rather than displaced —
  `replace` moves such a file to the Trash under its own journal row. The delete
  refusal changed nothing, so its rows are `failed`; the move's copy is already
  at the destination, so its rows stay `in_flight` carrying both paths.
- **Index and filesystem are reconciled, not transacted.** The filesystem is
  not transactional, so the order is: journal the intent, perform the
  filesystem operation, then update the index in a single database transaction.
  A crash between steps two and three leaves a journal entry in `state =
  in_flight`; on next launch every such entry is reconciled by re-`stat`ing both
  paths and believing the filesystem. An FSEvents watcher on open roots catches
  changes made outside the app.

Explicitly handled failures: source vanished mid-operation, destination
read-only, disk full, permission denied, and volume unmounted mid-operation —
the last of which matters because libraries live on external drives. Batch jobs
return a per-item result list; a summary sheet lists failures with reasons and
offers retry-failed.

## 9. EXIF editing

Single-file and batch editing from the inspector. Supported fields: capture time
(with `SubSec` and `OffsetTime` variants), Artist, Copyright, Description,
Keywords, GPS, Rating, Label.

Batch time operations: set to a fixed value; shift by an offset, for the case
where the camera clock was wrong; and assign a sequence from a start time at a
fixed interval.

Each logical field maps to a defined set of EXIF, IPTC, and XMP tags, and the
mapping is documented in the code. Writing "description" to only one of the
three produces a file that different readers disagree about. The sets are not
hand-assembled: exiftool's **MWG composite tags** are its own implementation of
the Metadata Working Group rules and already know which tags belong together,
so the mapping delegates to them and hand-maps only what MWG does not cover —
Label (`XMP-xmp:Label`, which has no MWG composite) and GPS (`GPS:*` plus
`XMP-exif:*`, which disagree on representation: EXIF stores an unsigned
magnitude and a hemisphere reference, XMP a signed decimal).

Four deliberate constraints:

1. **Timezones are explicit.** `DateTimeOriginal` carries no zone. Setting a
   capture time without also writing `OffsetTimeOriginal` yields a timestamp
   that means something different on every machine. The editor requires the
   zone rather than assuming wall-clock is sufficient.
2. **RAW gets a sidecar, not an in-place write.** Everything else — JPEG, HEIC,
   TIFF, PNG, WebP, GIF, PSD — is edited in place. RAW gets a `<basename>.xmp`
   sidecar, as Lightroom and Bridge do, and its container is never opened for
   writing. Writing into proprietary RAW containers is where files get
   corrupted. GIF is the one in-place format with no EXIF block, so its fields
   are written to XMP alone; a GIF's capture time and position live there and
   nowhere else.
3. **Write, verify, then commit.** exiftool writes with its `_original` backup;
   the tag is re-read to confirm it took, and the image hash is re-run and shown
   to have survived; only then is the backup removed. Any failure restores from
   the backup. exiftool *declines to overwrite an existing* `_original` while
   still reporting success, so a file already at that path is moved aside before
   the write and put back after: it is neither this write's rollback nor this
   write's to delete.
4. **The `-stay_open` argument protocol is newline-delimited.** A filename or
   tag value containing `\n` or `\r` breaks it, and in the general case that is
   argument injection, not merely a bug. Filenames beginning with `-` are the
   other case. Both are detected and routed to a per-file invocation with `--`
   separation, and both have tests with hostile fixtures.

Optionally, the file's modification time is preserved across a metadata edit.

## 10. User interface

Three panes. Left: folder tree, saved searches, and faceted filters with counts.
Centre: thumbnail grid. Right: metadata inspector.

Above the grid: path bar, an **include-subfolders** toggle, search field, sort
control, and a thumbnail size slider.

Selection follows Finder conventions — click, shift-click for range, command-click
to toggle, marquee, command-A, arrow-key navigation, and space for QuickLook.
With several images selected, the inspector shows shared values and
`(multiple values)` elsewhere; editing a field applies it across the selection.

*(Amended: how "editing a field applies it across the selection" works, for #9.)*
A commit is **one `MetadataWriter` batch over the whole selection**, run off the
main thread behind the same progress sheet, the same Stop-after-this-item button
and the same per-item summary a move gets — §11's rule that batches never fail
as a unit applies unchanged. Six things the editor commits to:

- **Return applies; blur does not.** A field that committed on focus change
  would write to every selected file the moment the user clicked elsewhere.
- **The time zone is a control, never a default.** It opens on the selection's
  own `OffsetTimeOriginal` when they agree and on the machine's zone when they
  do not, it is always visible, and a capture time with no zone is refused
  *before* a batch starts (§9, constraint 1) rather than once per file
  afterwards.
- **Batch time operations are a sheet**: set to a fixed value; shift by an
  offset, which keeps each file's own zone because it is fixing a clock rather
  than moving photos between zones; and assign a sequence from a start time at a
  fixed interval, numbered in the grid's current sort order. A sequence gives
  every file a different instant, so it is one writer call per file rather than
  one call over all of them.
- **A RAW selection says "writes to an `.xmp` sidecar"** beside the fields, so
  §9's second constraint is visible rather than merely true.
- **Metadata edits are not ⌘Z-able in this phase, and the panel says so.**
  `MetadataWriter` writes no `op_journal` rows, so there is nothing to reverse;
  the last file operation stays ⌘Z's subject rather than being displaced by a
  write that cannot be undone.
- **Only capture time and time zone are seeded from the index.** `FileRecord`
  has no columns for Artist, Copyright, Description, Keywords, Rating, Label or
  GPS, so those boxes are blank-meaning-unchanged rather than showing a current
  value that would cost one exiftool fork per selected file on every selection
  change. Showing them is a later change to the schema, not to the inspector.

With exiftool absent the fields render read-only with §11's explanation and the
install command, plus a *Try Again* that re-runs the lookup — a cached answer
under an instruction reading "install it, then try again" is how a user who has
just installed it concludes the app is broken.

After a successful write the grid is refreshed **from the index, never by a
rescan**: `MetadataWriter` is handed the store and rewrites each edited row's
size, mtime and hashes as part of the write, so the index already describes the
files on disk by the time the batch returns.

### Grid implementation

`LazyVGrid` is far less code than `NSCollectionView`, and at 50k items with fast
scrolling and rich selection it is the part of this app most likely to
disappoint. The grid is therefore built behind a `PhotoGrid` view protocol and
**measured at 50k items early in implementation**. If it fails, the swap to
`NSCollectionView` is contained to one file by construction. The complexity
budget is spent after a measurement, not before one.

## 11. Failure behaviour

No optional dependency renders the app unusable.

| Condition | Behaviour |
|---|---|
| exiftool absent | Editing disabled with an explanation; browsing and search unaffected |
| CLIP model absent | Semantic search offers to download the model; everything else works |
| Index corrupt | Integrity check at launch, offer to rebuild |
| Volume unmounted | Scanning pauses, resumes on remount |
| Analysis or hashing pass interrupted | Resumes from database state |
| Unsupported format for `image_hash` | Row stores NULL; duplicate detection falls back to `content_hash` and `phash` |

Batch operations never fail as a unit. They return per-item results, and the
summary sheet reports what failed and why.

## 12. Testing

The `Core` framework is tested headless with swift-testing.

- **Walker** — symlink loops, permission-denied directories, emoji and RTL
  filenames, names containing newlines, APFS case-collisions.
- **QueryCompiler** — FTS5 escaping against unbalanced quotes, `*`, `NEAR`, and
  empty input; numeric boundary conditions; contradictory predicates.
- **IndexStore** — migrations, staleness detection at mtime granularity,
  concurrent writes.
- **MetadataWriter** — golden-file round-trip; assertion that image data is
  byte-identical before and after a tag edit, which is what catches an
  accidental re-encode; backup restoration on simulated failure; hostile
  filenames.
- **Hashers** — the warranty test, once per format: take a fixture, change
  `DateTimeOriginal` with exiftool, then assert `image_hash` is unchanged and
  `content_hash` changed. Additionally: truncated and malformed files must fail
  cleanly rather than hash garbage; a JPEG differing only in APP14 must hash
  differently; a JPEG differing only in APP1 must hash identically; a WebP that
  exiftool has promoted from simple to extended format must hash identically to
  the original; and `phash` output must land within a measured Hamming distance
  of `photolib`'s for shared fixtures, not equal it.
- **FileOperator** — every collision policy, cross-volume moves, source vanished
  mid-operation, undo correctness, companion-file handling.
- **Analyzers** — fixture images with known text; assertions on recognized
  content, never on confidence values.

Tests make no network calls. Tests requiring exiftool skip cleanly when it is
absent.

## 13. Implementation phases

This is more than one implementation plan's worth of work. It decomposes into
four phases, each independently useful and independently shippable:

**Phase 1 — browse and structural search.** `Walker`, `IndexStore`,
`MetadataReader`, `ThumbnailCache`, the hashers, `IndexCoordinator` tiers 0 and
1, index integrity checking, the grid, the folder tree, include-subfolders, and
structural predicates. At the end of this
phase the app replaces Bridge for browsing and dimension search. This phase also
carries the `PhotoGrid` performance measurement, because the answer changes what
the remaining phases are built on.

**Phase 2 — acting on selections.** `FileOperator`, the undo journal,
collision pre-flight, companion files, `MetadataWriter` with the EXIF inspector,
and the duplicate view built on phase 1's hashes. Depends on phase 1's selection
model.

**Phase 3 — Vision analysis.** `VisionAnalyzer`, the `analysis` table, FTS5 over
OCR text, `has_text` / `has_faces` / label predicates, `is_screenshot` and
`is_meme` as saved searches, and the background pass with pause and progress.

**Phase 4 — semantic search.** `EmbeddingAnalyzer`, CLIP embeddings, the vector
scan, and free-text semantic queries. Carries the model-availability risk noted
below, and is the phase most likely to change shape before it is built.

Each phase gets its own implementation plan. This document is the spec for all
four; only phase 1 should be planned in detail now.

## 14. Open items for implementation planning

- The exact CLIP model and its Core ML packaging must be confirmed against what
  Apple currently publishes before Tier 2 is built. If no suitable Core ML
  package exists, the fallback is conversion from the published PyTorch
  checkpoints, and that conversion step belongs in the plan.
- The `is_meme` threshold values in this document are a starting point, to be
  calibrated against a sample of the real library.
- ~~Whether HEIC `mdat` survives an exiftool metadata round-trip unchanged
  decides whether HEIC gains an `image_hash` in version 1.~~ **Settled** by the
  experiment in `docs/superpowers/notes/2026-09-07-heic-mdat-roundtrip.md`
  (issue #12): the whole `mdat` box does *not* survive — it carries the `Exif`
  and XMP items, and it moves when `meta` grows — but the primary item's coded
  extents do, byte-for-byte, on all five files tested. HEIC therefore has an
  `image_hash` in version 1, under the `heic-item-v1` rule in §11.
- The `PhotoGrid` performance measurement needs a 50k-item fixture. Generating
  synthetic images is cheap; deciding whether to measure against synthetic or
  against the real library belongs in the plan.
