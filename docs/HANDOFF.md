# Lightbox — handoff to the Mac mini

Written 2026-09-06, on the Intel iMac, immediately before copying the tree to
the M4 mini. Phase 1 is complete and merged to `main` (55 commits, clean tree,
single branch, **no git remote**). Everything below is what the next session on
the mini needs and cannot recover from the code alone.

---

## 1. Move it

The tree is fully relocatable — the Xcode project references the Swift package
as `relativePath = ../Core`, and nothing in tracked source hardcodes a machine
path. Copy anywhere.

**Do not `cp -a` the whole directory.** `Core/.build` is 645 MB of *x86_64*
objects (`Core/.build/x86_64-apple-macosx/…`) plus GRDB's checkout. It is
git-ignored, useless on arm64, and SwiftPM will not always notice it is stale.

```bash
# from the source machine
rsync -a --exclude='.build/' --exclude='DerivedData/' --exclude='.superpowers/' \
      "/Volumes/Seagate Desktop/Pictures/tools/lightbox/" \
      /path/on/mini/lightbox/
```

That moves ~336 MB, essentially all of it `.git` (see §2). Xcode's DerivedData
lives outside the repo (`~/Library/Developer/Xcode/DerivedData/Lightbox-*`,
919 MB here) and must not be copied.

If you copy by another route and `.build` comes along: `rm -rf Core/.build`
before the first build.

## 2. Read this before you push it anywhere

**The first commit accidentally committed `Core/.build`.** 3,421 objects,
~330 MB of Intel `.o` files, module caches, and a vendored GRDB pack, in
`5ad0724 feat: scaffold LightboxCore package`. The next commit,
`10ca995 chore: ignore Swift build artifacts`, added the ignore and removed
them — so they are absent from `HEAD` but permanent in history. Working tree
source is ~500 KB; `.git` is 335 MB. Objects are all loose; it has never been
gc'd.

Right now this is free to fix: no remote, one branch, nobody else has a clone.
The moment you push it to a forge it becomes expensive and rude to fix.

```bash
git filter-repo --path Core/.build --invert-paths   # rewrites all 55 commits
git reflog expire --expire=now --all && git gc --prune=now --aggressive
```

I did not run this — it rewrites every commit hash, and that is your call.
Doing it on the mini after the copy is fine; doing it before saves 330 MB of
transfer. If you skip it, at minimum `git gc` — loose objects pack down hard.

## 3. Environment

| | Intel iMac (built here) | Mac mini (verify) |
|---|---|---|
| macOS | 26.6.2 (25G83) | ≥ 26.0 — `MACOSX_DEPLOYMENT_TARGET = 26.0` |
| Xcode | 26.5 (17F42), SDK 26.5 | ≥ 26.0 |
| Swift | 6.3.2 | ≥ 6.2 — `Package.swift` is `swift-tools-version: 6.2` (needed for `.macOS(.v26)`) |
| arch | x86_64 | arm64 |
| exiftool | 13.55 at `/usr/local/bin/exiftool` | **will be `/opt/homebrew/bin/exiftool`** |

The exiftool path change bites in **phase 2**, not now — phase 1 shells out to
it nowhere. It was used during design to empirically verify the image-hash
denylists survive metadata edits. When phase 2 adds EXIF writing, resolve the
binary via `PATH` or a configurable setting; do not hardcode either prefix.

Sole dependency: **GRDB.swift 7.11.1**, pinned in
`App/Lightbox.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
(revision `b83108d`). First build needs network to fetch it.

The app is built with `CODE_SIGNING_ALLOWED = NO`, `ENABLE_HARDENED_RUNTIME =
NO`, no entitlements, no sandbox. On a new machine macOS will re-prompt for
access to Desktop/Documents/Photos the first time you open a folder there, and
because the binary is unsigned its TCC identity can reset across rebuilds — a
repeat prompt is expected, not a bug.

## 4. Bootstrap and verify

```bash
cd lightbox

# Core: 299 tests, 20 suites. Takes a few minutes — HashingPassTests alone
# runs ~69s on Intel with no output. Silence is normal; do not kill it.
cd Core && swift test

# App: builds the SwiftUI target and runs its 57 tests.
cd ../App && xcodebuild -scheme Lightbox -destination 'platform=macOS' test
```

Last verified on the merged `main` on Intel: **299 Core tests pass, 57 app
tests pass, build succeeded.** Not yet verified on arm64 — that is the
first thing to do on the mini, and a genuine test of the code, since several
guards concern concurrency and one concerns `st_dev`.

Runtime state is **not** in the repo and should not be copied:
`~/Library/Application Support/Lightbox/index.sqlite`. Deleting it is always
safe — the app detects a corrupt or missing index at launch and rebuilds.

## 5. What exists

`Core/` — `LightboxCore`, a headless package with no AppKit/SwiftUI dependency,
where all the logic and all 299 tests live. `App/` only wires it to views.

| Area | Files | What it does |
|---|---|---|
| Walk | `Walker.swift`, `MediaType.swift` | Recursive enumeration; extension + UTI classification (RAW, HEIC, JPEG, PNG, WebP) |
| Index | `Index/{FileRecord,IndexStore}.swift` | SQLite via GRDB, schema + migrations, FTS5, path scoping |
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
  denylist**, and WebP an **allowlist** — because exiftool inserts a VP8X chunk
  that a denylist would not know to exclude. This asymmetry is deliberate;
  don't "fix" it into symmetry.
- **`phash`** — 64-bit DCT perceptual hash, for near-duplicates. Golden vectors
  in `PerceptualHashTests` were produced by running photolib's real
  `lib/phash.js`, so the two tools agree. Measured cross-tool divergence over
  36 real photos: 0–4 bits, mean 1.22, against a match threshold of 12.

Two traps found the hard way, both now guarded and tested:
- **Motion photos** (Pixel/Samsung append an MP4 after JPEG EOI) hash identically
  to their stripped stills under `image_hash`.
- **Chunk-flood amplification**: a hostile 256 MB PNG drove 4.37 GB RSS; JPEG was
  22× worse. Fixed by coalescing ranges. Any new format parser needs the same.

Hashes are written through `setHashes(for:)`, which **refuses** a write whose
row no longer carries the path/size/mtime that was hashed. That guard is not
optional: `files.id` is `INTEGER PRIMARY KEY` without `AUTOINCREMENT`, so
SQLite reuses rowids, and without it one photo's hash lands on another photo's
row — which duplicate detection then deletes on.

## 7. Verify by hand on the mini

Five things automated tests could not cover. In rough priority:

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
   window builds its own `IndexStore` on the same `index.sqlite`, and GRDB's
   default busy mode is `.immediateError` — so two windows scanning at once can
   take `SQLITE_BUSY` mid-pass. Nothing is lost when it happens (the guards in
   §6 and a single-transaction delete see to that), but it fails visibly. The
   real fix is `DatabasePool` + WAL — see §8.
3. **Unplug the Seagate mid-hash.** The unreachable-root guards were only ever
   tested against *simulated* unmounts. This is the one that lost the whole
   index twice during development, so it is worth doing for real.
4. **⌘A with the search field focused.** Should select the field's text, not the
   grid. Tests could only warn, never assert.
5. **Cold folder open shows an empty grid** for the entire first index pass
   (~180 s at 50k). Known, ugly, deferred — the grid has no "indexing…" state.

## 8. Deferred, and what I'd do first in phase 2

Phase 2 per the spec: file operations (move/copy/delete with an undo journal),
EXIF editing via exiftool, and the duplicate view built on the three hashes
already being computed.

Two things belong at the *front* of phase 2 rather than in a backlog:

- **`DatabasePool` + WAL.** Fixes item 7.2, and removes read-behind-write stalls
  generally. A busy timeout alone bounds `SQLITE_BUSY` but does not eliminate
  it. All configuration goes in `IndexStore.makeConfiguration()` and nowhere
  else.
- **A volume-UUID column.** `st_dev` is currently used as the device identity,
  but it is a *mount-time* id — it changes across reboots and replugs, which
  matters a great deal for a library that lives on an external Seagate. This is
  a schema migration, and phase 2 is the last cheap moment to add one.

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
