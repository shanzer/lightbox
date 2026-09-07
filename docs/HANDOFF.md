# Lightbox — handoff to the Mac mini

Written 2026-09-06 on the Intel iMac immediately before the move, and updated
the same evening on the M4 mini after the move was verified. Phase 1 is
complete and on `main` (clean tree, single branch, remote `origin` =
`github.com/shanzer/lightbox`, pushed 2026-09-06). Everything below is what a session on the mini needs and cannot
recover from the code alone. §1–4 record the move and its verification; §5–9
are the durable part.

---

## 1. The move — done

The tree now lives at `~/src/lightbox` on the mini. The iMac copy at
`/Volumes/Seagate Desktop/Pictures/tools/lightbox/` is the stale one.

For the record: the tree is fully relocatable (the Xcode project references the
package as `relativePath = ../Core`; nothing hardcodes a machine path). The
first copy attempt landed one level too deep, next to a stale mid-phase-1 copy
that carried the 645 MB x86_64 `Core/.build`; that was deleted and the real
tree moved up. `.git` was copied separately. The phase-1 SDD ledger
(`.superpowers/sdd/2026-09-05-lightbox-phase-1/` — task briefs, reports,
review diffs) was rescued from the stale copy; it is git-ignored, so it exists
only on this machine.

Not copied, by design: `Core/.build`, Xcode's DerivedData, the
`~/lightbox-bench` fixture library (regenerate it, §7.1), and the runtime index
(`~/Library/Application Support/Lightbox/index.sqlite`).

## 2. Git history — rewritten and repacked

The first commit had accidentally committed `Core/.build` (~330 MB of Intel
objects); the next commit removed them from the tree but not from history. On
2026-09-06, before any remote existed, this was fixed on the mini:

```bash
git filter-repo --path Core/.build --invert-paths --force
git reflog expire --expire=now --all && git gc --prune=now --aggressive
```

Result: `.git` went from 323 MB of loose objects to ~540 KB in one pack; 57
commits, none touching `Core/.build`; working tree byte-identical to HEAD.
**Every commit hash changed.** Hashes quoted anywhere written before the
rewrite — the SDD ledger, the review-diff filenames under `.superpowers/sdd/`,
the phase-1 plan's progress notes — no longer resolve. Match by commit message
instead. The rewritten history is what was pushed to `origin`, so the remote
has never seen the Intel objects.

## 3. Environment

| | Intel iMac (phase 1 built here) | M4 mini (phase 2 lives here) |
|---|---|---|
| macOS | 26.6.2 (25G83) | 26.5.2 (25F84) — `MACOSX_DEPLOYMENT_TARGET = 26.0` |
| Xcode | 26.5 (17F42), SDK 26.5 | 26.6 (17F113) |
| Swift | 6.3.2 | 6.3.3 — `Package.swift` is `swift-tools-version: 6.2` (needed for `.macOS(.v26)`) |
| arch | x86_64 | arm64 |
| exiftool | 13.55 at `/usr/local/bin/exiftool` | 13.55 at `/opt/homebrew/bin/exiftool` |
| git-filter-repo | — | installed via Homebrew |

Three one-time setup steps were needed on the mini before anything would build,
all `sudo`, in this order:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # was pointing at CommandLineTools
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch     # otherwise xcodebuild cannot load its plug-ins (exit 70)
```

The Command Line Tools toolchain alone compiles `LightboxCore` but cannot build
the tests — it ships no `Testing` module.

**Swift 6.3.3 is stricter than 6.3.2 about expression complexity.** One test
helper (`inserting(_:afterHeaderIn:)` in `WebPImageHashTests`) that compiled on
the iMac failed with "unable to type-check this expression in reasonable time"
and was split into named steps. Expect the same from any other dense
bit-twiddling one-liner; the fix is always the same.

The exiftool path change bites in **phase 2**, not now — phase 1 shells out to
it nowhere. It was used during design to empirically verify the image-hash
denylists survive metadata edits. When phase 2 adds EXIF writing, resolve the
binary via `PATH` or a configurable setting; do not hardcode either prefix.

Sole dependency: **GRDB.swift 7.11.1**, pinned in
`App/Lightbox.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
(revision `b83108d`). Fetched fine on the mini; a fresh build needs network.

The app is built with `CODE_SIGNING_ALLOWED = NO`, `ENABLE_HARDENED_RUNTIME =
NO`, no entitlements, no sandbox. macOS will re-prompt for access to
Desktop/Documents/Photos the first time you open a folder there, and because
the binary is unsigned its TCC identity can reset across rebuilds — a repeat
prompt is expected, not a bug.

## 4. Bootstrap and verify

```bash
cd ~/src/lightbox

# Core: 389 tests, 23 suites.
cd Core && swift test

# App: builds the SwiftUI target and runs its 57 tests.
cd ../App && xcodebuild -scheme Lightbox -destination 'platform=macOS' test
```

Verified on the mini, 2026-09-06, on the rewritten `main`:

| | Intel iMac | M4 mini |
|---|---|---|
| Core | 299 pass, several minutes (`HashingPassTests` ~69 s silent) | **299 pass, 14.3 s** |
| App | 57 pass | **57 pass, 3.0 s**, 1 warning |

So the concurrency and `st_dev` guards now have a passing arm64 result. The one
App warning is `selectAllPrefersAFocusedTextFieldOverTheGrid` in
`MenuCommandTests` — the ⌘A test that can only warn, never assert (§7.4); same
on both machines. The `linkd.autoShortcut` XPC errors that spam the App test
log are macOS noise from the unsigned test host, not failures.

The 10-minute-silence concern in §9 is moot for the plain suites on this
hardware; it still applies to `LIGHTBOX_BENCH=1` runs.

Runtime state is **not** in the repo: `~/Library/Application
Support/Lightbox/index.sqlite`. Deleting it is always safe — the app detects a
corrupt or missing index at launch and rebuilds.

Since the move to WAL, the index is **three** files, not one:

```
~/Library/Application Support/Lightbox/index.sqlite
~/Library/Application Support/Lightbox/index.sqlite-wal
~/Library/Application Support/Lightbox/index.sqlite-shm
```

**Quit the app, then delete the whole set.** Deleting only `index.sqlite` is the
shape of mistake that silently corrupts a WAL database elsewhere. What has been
tested is the narrow case: the app quit, a crash-shaped `-wal`/`-shm` pair left
on disk, `index.sqlite` removed by hand. SQLite discards a log whose database is
missing or zero-length rather than replaying it into the replacement, so that
case rebuilds empty and clean — pinned, with a control leg showing the same log
does replay when its database is there, by
`aStaleWriteAheadLogBesideAMissingDatabaseIsDiscarded`.

Nothing has been tested about deleting any of it *while a window is open*, and
nothing should be: a live connection holds the file it is writing to. Quit
first. `IndexStore.rebuild(at:)`, the corrupt-index recovery path, removes all
three itself and does not depend on any of this.

## 5. What exists

`Core/` — `LightboxCore`, a headless package with no AppKit/SwiftUI dependency,
where all the logic and all 389 tests live. `App/` only wires it to views.

| Area | Files | What it does |
|---|---|---|
| Walk | `Walker.swift`, `MediaType.swift` | Recursive enumeration; extension + UTI classification (RAW, HEIC, JPEG, PNG, WebP) |
| Index | `Index/{FileRecord,IndexStore,VolumeIdentity}.swift` | SQLite via GRDB, schema + migrations (v2 = `volume_uuid`), FTS5, path scoping, volume identity |
| Metadata | `Metadata/{ImageMetadata,MetadataReader}.swift` | ImageIO `CGImageSource` reads — dimensions, camera, capture time |
| Hashing | `Hashing/*.swift` | Three hashes: `content_hash` (whole file), `image_hash` (format-stripped pixel data), `phash` (DCT perceptual) |
| Thumbnails | `Thumbnails/ThumbnailCache.swift` | QuickLookThumbnailing, on-demand, concurrent decode |
| Search | `Search/*.swift` | Structural query → SQL compiler, FTS5 text, facets, folder tree, Finder-style selection |
| Pipeline | `Coordinator/{IndexProgress,IndexCoordinator}.swift` | Two-tier pass (tier 0 = stat+metadata, tier 1 = hashes), progress, cancellation |
| Bench | `Diagnostics/Benchmark.swift` | The 50k measurement harness |

`App/Lightbox.xcodeproj/project.pbxproj` is **hand-written** (objectVersion 77,
`PBXFileSystemSynchronizedRootGroup`). Adding a `.swift` file under
`App/Lightbox/` needs no project edit — the group syncs from the filesystem.
Keep it that way; regenerating it through Xcode's GUI will churn the file
badly.

Docs, in dependency order:
- `docs/superpowers/specs/2026-09-05-lightbox-design.md` — **the binding spec**,
  14 sections. Amended three times during implementation (WebP allowlist,
  measured phash divergence, tiering correction + mmap removal). §13 has the
  phase breakdown.
- `docs/superpowers/plans/2026-09-05-lightbox-phase-1.md` — the executed
  20-task plan, ~5,700 lines. Historical now, but it is where the reasoning
  behind each design decision is written out.
- `docs/superpowers/notes/2026-09-05-grid-measurement.md` — the 50k benchmark,
  its thresholds, and its method.

## 6. The three hashes — the part worth not re-deriving

Duplicate detection needs a hash that survives a metadata edit, so there are
three, all computed in tier 1:

- **`content_hash`** — SHA-256 of the whole file. Changes on any edit. Exact-copy detection.
- **`image_hash`** — SHA-256 over image data with format containers stripped, so
  writing EXIF does not invalidate it. The per-format rules were verified
  empirically against exiftool: JPEG uses a **segment denylist**, PNG a **chunk
  denylist**, WebP an **allowlist** — because exiftool inserts a VP8X chunk that
  a denylist would not know to exclude — and HEIC an **allowlist over the
  primary item's `iloc` extents**, not over `mdat`. This asymmetry is
  deliberate; don't "fix" it into symmetry.
- **`phash`** — 64-bit DCT perceptual hash, for near-duplicates. Golden vectors
  in `PerceptualHashTests` were produced by running photolib's real
  `lib/phash.js`, so the two tools agree. Measured cross-tool divergence over
  36 real photos: 0–4 bits, mean 1.22, against a match threshold of 12.

HEIC's rule has a trap of its own, measured in
`docs/superpowers/notes/2026-09-07-heic-mdat-roundtrip.md` (issue #12). The
obvious rule — "hash the `mdat` box" — is wrong: `Exif` and XMP live inside
`mdat`, so its digest changed on all five files round-tripped through exiftool,
and in two of them the box moved as well. The stable unit is the *primary
item's* extents. Every HEIC in the library has a `grid` primary whose own
extent is an eight-byte descriptor in `idat` with `construction_method == 1`,
so the rule follows `pitm` → `dimg` → `iloc` and honours the construction
method; a parser that ignored it would hash the file's first eight bytes and
call every HEIC a duplicate of every other. Auxiliaries (gain map, depth map,
mattes, thumbnail) and `ipco` are excluded on purpose — the first three by
consequence, since the rule follows `dimg` and never looks at a sibling image.

The rule **fails closed**. If the primary item cannot be identified (no `iinf`,
or no `infe` entry for it) or a derived primary does not resolve to distinct,
non-derived coded items, HEIC gets no `image_hash` rather than a hash of the
eight-byte layout descriptor — which is the same eight bytes for any two photos
of a size, so the duplicate view would offer to delete unrelated pictures. Those
files fall back to `content_hash`. Do not "improve" any of those branches into a
default.

Two traps found the hard way, both now guarded and tested:
- **Motion photos** (Pixel/Samsung append an MP4 after JPEG EOI) *used to* hash
  identically to their stripped stills under `image_hash`, because the parser
  stopped at EOI. That was the bug, not the intent: the duplicate view would
  have offered to delete the copy carrying the video. `2f698b0` hashes
  everything after EOI, so the two now differ, and `JPEGImageHash` says why in
  the EOI case. PNG (after IEND), WebP (past the declared RIFF size) and HEIC
  (past the last box) all follow the same convention: an appended payload is
  content, not metadata.
- **Chunk-flood amplification**: a hostile 256 MB PNG drove 4.37 GB RSS; JPEG was
  22× worse. Fixed by coalescing ranges. Any new format parser needs the same.
  HEIC needs more than coalescing: `iloc` can declare `offset_size == 0` and
  65535 extents per item, so millions of non-coalescing ranges cost nothing on
  disk. `HEICImageHash.maxExtents` caps the count outright.

Hashes are written through `setHashes(for:)`, which **refuses** a write whose
row no longer carries the path/size/mtime that was hashed. That guard is not
optional: `files.id` is `INTEGER PRIMARY KEY` without `AUTOINCREMENT`, so
SQLite reuses rowids, and without it one photo's hash lands on another photo's
row — which duplicate detection then deletes on.

## 7. Verify by hand on the mini

Five things automated tests could not cover. **None done yet** as of the
2026-09-06 update. In rough priority:

1. **Re-run the 50k benchmark.** All current numbers are Intel, and the choice of
   `LazyVGrid` over an `NSCollectionView` bridge is provisional on them. The
   fixture library was deliberately left behind at `~/lightbox-bench` on the
   iMac — regenerate rather than copy:
   ```bash
   swift scripts/make-fixture-library.swift ~/lightbox-bench 50000   # ~14 GB
   cd Core && LIGHTBOX_BENCH=1 swift test --filter Benchmark --no-parallel
   ```
   **Exclude `~/lightbox-bench` from Backblaze before generating it** — on the
   iMac it silently started uploading 14 GB. Thresholds are in the note.
   Benchmarks are off unless `LIGHTBOX_BENCH=1`, so a normal `swift test`
   never pays for them.
2. **⌘N with a folder already scanning.** Least-tested path in the app. Each
   window builds its own `IndexStore` on the same `index.sqlite`. The fix
   landed — `DatabasePool` + WAL, so readers never wait for a writer, with the
   5 s busy timeout left covering writer-versus-writer only — and is covered by
   a two-store soak test and a read-during-write latency test in
   `IndexStoreTests`. What is still owed is the live check: open a large folder,
   ⌘N while tier 1 is hashing, open the same folder in the second window. Both
   windows should stay responsive, neither pass should fail, and
   `log stream --predicate 'process == "Lightbox"'` should show no `SQLITE_BUSY`.
3. **Unplug the Seagate mid-hash, and replug it.** The unreachable-root guards
   were only ever tested against *simulated* unmounts. This is the one that lost
   the whole index twice during development, so it is worth doing for real.
   Issue #4 (volume UUID) landed the replug half of it in code and in tests, but
   both live checks are still owed:
   - Delete a file in Finder, eject the drive, replug it, reopen the folder. The
     row should be gone — before #4 it survived forever, because the replug
     renumbered `st_dev` and the prune guard read every row as another volume's.
   - Unplug it *during* a hashing pass. The pass must abort (`rootUnreadable`)
     and the index must survive. One caveat on what "abort" means since #4: the
     guard compares volume *identity*, so an unplug aborts (nothing answers at
     the root, so there is no identity to match), but an unplug followed by a
     replug before the next batch does **not** — the UUID says it is the same
     volume, and continuing is correct. To see the abort, leave it unplugged.
4. **⌘A with the search field focused.** Should select the field's text, not the
   grid. Tests could only warn, never assert.
5. **Cold folder open shows an empty grid** for the entire first index pass
   (~180 s at 50k). Known, ugly, deferred — the grid has no "indexing…" state.

## 8. Deferred, and what I'd do first in phase 2

Phase 2 per the spec: file operations (move/copy/delete with an undo journal),
EXIF editing via exiftool, and the duplicate view built on the three hashes
already being computed.

Two things belong at the *front* of phase 2 rather than in a backlog:

- ~~**`DatabasePool` + WAL.**~~ **Done** (issue #3). Readers no longer block on
  the writer, in their own window or another's; the busy timeout stays for
  writer-versus-writer, which no journal mode avoids. All configuration is still
  in `IndexStore.makeConfiguration()` and nowhere else. Two consequences worth
  carrying forward: the index is now three files (§4), and `IndexStore.inMemory()`
  is a private temporary file rather than a true in-memory database, because a
  pool cannot be one.
- ~~**A volume-UUID column.**~~ **Done** (issue #4, schema v2). `files.volume_uuid`
  holds `URLResourceValues.volumeUUIDString`, which is a property of the
  filesystem and survives the replug that renumbers `st_dev`; `device` is kept
  for inode uniqueness and for rows written before v2. `VolumeIdentity` is the
  one place the two ids are compared, and the reconcile's matching rule is
  written out on `IndexStore.deleteRows`: a row is prunable if its `volume_uuid`
  equals the root's, or its `volume_uuid` is NULL and its `device` equals the
  root's `st_dev`. Three things worth carrying forward: the migration adds a
  nullable column and backfills nothing (no row can name a UUID for a volume
  that may not be mounted), so `IndexStore.setVolume(_:forPaths:)` stamps the
  rows each tier 0 pass actually walked — that is the backfill, and it is why it
  does not wait for a file's bytes to change; a filesystem that publishes no
  UUID (SMB, some FAT) collapses the rule to the `st_dev` comparison **for rows
  that carry no UUID**, while a row already stamped with one is never matched by
  a nameless root (so `volume_uuid` is written only through `COALESCE` — a nil
  read refreshes `device` but never erases an established identity); and a
  volume whose UUID *changes* (a reformat) is deliberately out of scope — that
  is a new library.

Also known and deferred: the `width>=1920` query takes 474 ms at 50k. That is
row materialisation, not a missing index — do not "fix" it by adding one. And
if the grid is ever moved to an `NSCollectionView` bridge, it will capture ⌘A
and needs a regression test for 7.4.

## 9. Process notes, if you continue with subagents

Phase 1 was built with superpowers subagent-driven-development: fresh
implementer per task, review after each, whole-branch review at the end. It
worked, and the reviews caught real bugs — a `LIKE` case-insensitivity that
deleted the wrong index rows on case-sensitive APFS, a `NOT` over a nullable
column that hid every screenshot, an actor-inherited `Task {}` that serialized
every thumbnail decode.

Two operational lessons worth carrying over:

- **A 10-minute-silence watchdog kills agents.** `HashingPassTests` alone runs
  69 s with no output; any soak on top of it guarantees a silent stretch.
  Chunk long-running verification so it prints progress, or run it outside the
  agent.
- **Four times a fix I prescribed was wrong and measurement corrected it** — most
  usefully, "re-anchor to the lowest surviving id" was wrong because ids are
  rowids while the grid sorts by name. Measure before prescribing; the tests in
  this repo are the record of what is actually true.

Five tests were caught being vacuous before shipping (a timezone test that
passed only because the machine wasn't UTC; an `EINTR` test whose signal was
blocked; denylist assertions that passed because the chunk was absent). If you
add tests here, check that they fail when they should.
