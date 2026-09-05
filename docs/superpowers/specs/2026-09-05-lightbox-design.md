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

Database at `~/Library/Application Support/Lightbox/index.sqlite`.

**`files`** — `id`, `path` (unique), `parent_dir`, `name`, `ext`, `size`,
`mtime`, `inode`, `width`, `height`, `capture_time`, `capture_offset`,
`camera_make`, `camera_model`, `orientation`, `indexed_at`.

**`files_fts`** — FTS5 external-content table over `name` and `ocr_text`.

**`analysis`** — `file_id`, `ocr_text`, `text_coverage` (union area of OCR
bounding boxes as a fraction of the frame), `top_labels` (JSON),
`has_faces`, `feature_print` BLOB, `clip_embedding` BLOB, `analyzer_versions`
(JSON), `analyzed_at`.

**`saved_searches`** — `id`, `name`, `query` (JSON-encoded `SearchQuery`),
`is_builtin`.

**`op_journal`** — `op_id`, `batch_id`, `kind`, `src`, `dst`, `trash_url`,
`timestamp`, `state`.

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

## 5. Indexing pipeline

    walk -> stat/diff -> ImageIO metadata -> thumbnail -> Vision -> CLIP

A bounded structured-concurrency pipeline inside an actor. Three required
properties:

**Viewport priority.** Files scrolled into view jump the thumbnail queue. This
is the difference between an app that feels like Bridge and one that feels like
a batch job.

**Tiered commitment.** Tier 0 — stat, ImageIO metadata, thumbnail — runs on
folder open and is fast. Tier 1 (Vision) and Tier 2 (CLIP) run as an explicitly
started background pass with visible progress and a pause control. The user is
never surprised by an hour of CPU.

**Resumability.** Pipeline progress is database state, not memory. Quitting
mid-pass loses nothing.

## 6. Search

One `SearchQuery` value type, compiled by `QueryCompiler` into SQL, an optional
FTS5 match, and an optional vector scan.

- **Structural** — width, height, exact dimensions (`200x200`), thresholds
  (`>= 2000px`), megapixels, aspect ratio, file size, extension, capture and
  modification date ranges, camera make and model.
- **Text** — FTS5 over filename and OCR text.
- **Semantic** — free-text CLIP query, ranked by cosine similarity with an
  adjustable threshold.
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

## 7. File operations

Move, copy, and delete over a multi-selection, each a single cancellable job
with progress.

- **Delete goes to the Trash.** `trashItem` returns the resulting Trash URL,
  which is recorded — that is what makes deletion undoable. Permanent delete is
  a separate command behind a confirmation naming the file count.
- **Undo journal.** Every operation is written to `op_journal` before it runs
  and marked complete after. Undo reverses moves, removes copies, and restores
  from the Trash by recorded URL. The journal survives quitting.
- **Collisions are resolved before anything moves.** A pre-flight pass checks
  the destination and presents skip / rename / replace, per item or applied to
  all. No batch discovers a collision at file 300.
- **Companion files travel with the image** — same basename `.xmp`, `.aae`,
  `.thm`, and RAW+JPEG pairs. Not doing this silently orphans edits. Default on,
  toggleable.
- **Copy clones on APFS** via `copyfile` with `COPYFILE_CLONE` when source and
  destination share a volume.
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

## 8. EXIF editing

Single-file and batch editing from the inspector. Supported fields: capture time
(with `SubSec` and `OffsetTime` variants), Artist, Copyright, Description,
Keywords, GPS, Rating, Label.

Batch time operations: set to a fixed value; shift by an offset, for the case
where the camera clock was wrong; and assign a sequence from a start time at a
fixed interval.

Each logical field maps to a defined set of EXIF, IPTC, and XMP tags, and the
mapping is documented in the code. Writing "description" to only one of the
three produces a file that different readers disagree about.

Four deliberate constraints:

1. **Timezones are explicit.** `DateTimeOriginal` carries no zone. Setting a
   capture time without also writing `OffsetTimeOriginal` yields a timestamp
   that means something different on every machine. The editor requires the
   zone rather than assuming wall-clock is sufficient.
2. **RAW gets a sidecar, not an in-place write.** JPEG, HEIC, TIFF, and PNG are
   edited in place. RAW gets an `.xmp` sidecar, as Lightroom and Bridge do.
   Writing into proprietary RAW containers is where files get corrupted.
3. **Write, verify, then commit.** exiftool writes with its `_original` backup;
   the tag is re-read to confirm it took; only then is the backup removed. Any
   failure restores from the backup.
4. **The `-stay_open` argument protocol is newline-delimited.** A filename or
   tag value containing `\n` or `\r` breaks it, and in the general case that is
   argument injection, not merely a bug. Filenames beginning with `-` are the
   other case. Both are detected and routed to a per-file invocation with `--`
   separation, and both have tests with hostile fixtures.

Optionally, the file's modification time is preserved across a metadata edit.

## 9. User interface

Three panes. Left: folder tree, saved searches, and faceted filters with counts.
Centre: thumbnail grid. Right: metadata inspector.

Above the grid: path bar, an **include-subfolders** toggle, search field, sort
control, and a thumbnail size slider.

Selection follows Finder conventions — click, shift-click for range, command-click
to toggle, marquee, command-A, arrow-key navigation, and space for QuickLook.
With several images selected, the inspector shows shared values and
`(multiple values)` elsewhere; editing a field applies it across the selection.

### Grid implementation

`LazyVGrid` is far less code than `NSCollectionView`, and at 50k items with fast
scrolling and rich selection it is the part of this app most likely to
disappoint. The grid is therefore built behind a `PhotoGrid` view protocol and
**measured at 50k items early in implementation**. If it fails, the swap to
`NSCollectionView` is contained to one file by construction. The complexity
budget is spent after a measurement, not before one.

## 10. Failure behaviour

No optional dependency renders the app unusable.

| Condition | Behaviour |
|---|---|
| exiftool absent | Editing disabled with an explanation; browsing and search unaffected |
| CLIP model absent | Semantic search offers to download the model; everything else works |
| Index corrupt | Integrity check at launch, offer to rebuild |
| Volume unmounted | Scanning pauses, resumes on remount |
| Analysis pass interrupted | Resumes from database state |

Batch operations never fail as a unit. They return per-item results, and the
summary sheet reports what failed and why.

## 11. Testing

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
- **FileOperator** — every collision policy, cross-volume moves, source vanished
  mid-operation, undo correctness, companion-file handling.
- **Analyzers** — fixture images with known text; assertions on recognized
  content, never on confidence values.

Tests make no network calls. Tests requiring exiftool skip cleanly when it is
absent.

## 12. Implementation phases

This is more than one implementation plan's worth of work. It decomposes into
four phases, each independently useful and independently shippable:

**Phase 1 — browse and structural search.** `Walker`, `IndexStore`,
`MetadataReader`, `ThumbnailCache`, `IndexCoordinator` tiers 0, the grid, the
folder tree, include-subfolders, and structural predicates. At the end of this
phase the app replaces Bridge for browsing and dimension search. This phase also
carries the `PhotoGrid` performance measurement, because the answer changes what
the remaining phases are built on.

**Phase 2 — acting on selections.** `FileOperator`, the undo journal,
collision pre-flight, companion files, and `MetadataWriter` with the EXIF
inspector. Depends on phase 1's selection model.

**Phase 3 — Vision analysis.** `VisionAnalyzer`, the `analysis` table, FTS5 over
OCR text, `has_text` / `has_faces` / label predicates, `is_screenshot` and
`is_meme` as saved searches, and the background pass with pause and progress.

**Phase 4 — semantic search.** `EmbeddingAnalyzer`, CLIP embeddings, the vector
scan, and free-text semantic queries. Carries the model-availability risk noted
below, and is the phase most likely to change shape before it is built.

Each phase gets its own implementation plan. This document is the spec for all
four; only phase 1 should be planned in detail now.

## 13. Open items for implementation planning

- The exact CLIP model and its Core ML packaging must be confirmed against what
  Apple currently publishes before Tier 2 is built. If no suitable Core ML
  package exists, the fallback is conversion from the published PyTorch
  checkpoints, and that conversion step belongs in the plan.
- The `is_meme` threshold values in this document are a starting point, to be
  calibrated against a sample of the real library.
- The `PhotoGrid` performance measurement needs a 50k-item fixture. Generating
  synthetic images is cheap; deciding whether to measure against synthetic or
  against the real library belongs in the plan.
