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

The exiftool path change bit in **phase 2**, and is handled:
`Metadata/ExiftoolLocator.swift` searches `PATH` at first use and hardcodes
neither prefix, with `LIGHTBOX_EXIFTOOL` as an override for a non-standard
install or a test stub. `MetadataWriter.availability` is the single answer to
"can we edit?", and the round-trip tests gate on that same property so a machine
without exiftool (every CI runner) skips them visibly instead of failing. It was
also used during design to empirically verify the image-hash rules survive
metadata edits; `postWriteImageHashEqualsPreWriteImageHash` now checks that
automatically for JPEG, PNG, WebP **and HEIC** — so §6's newest rule is held to
the same exiftool round-trip as the others — on every run **that has exiftool**.
On a runner without it, that test and the rest of the round-trip suite skip, so
the tripwire is only armed where the binary exists. Every exiftool-gated test now
consults that one property — the image-hash round-trips included, which used to
fork their own `/usr/bin/env exiftool -ver` and so held a second opinion about
`PATH` — and every child a test spawns is drained and reaped against a deadline
through `Core/Tests/LightboxCoreTests/Support/BoundedProcess.swift`. An unbounded
`waitUntilExit()` anywhere, test code included, is the fourteen-minute CI hang of
#18, not a style preference.

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

# Core: 616 tests, 77 suites.
cd Core && swift test

# App: builds the SwiftUI target and runs its 100 tests.
cd ../App && xcodebuild -scheme Lightbox -destination 'platform=macOS' test
```

Verified on the mini, 2026-09-06, on the rewritten `main`. **Pre-phase-2
counts** — this table is a record of that day's run and is deliberately not
updated; the live counts are in §4 and in `CLAUDE.md`:

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
where all the logic and all 616 tests live. `App/` only wires it to views.

| Area | Files | What it does |
|---|---|---|
| Walk | `Walker.swift`, `MediaType.swift` | Recursive enumeration; extension + UTI classification (RAW, HEIC, JPEG, PNG, WebP) |
| Index | `Index/{FileRecord,IndexStore,VolumeIdentity}.swift`, `Index/IndexStore+{FileOperations,Reconcile}.swift` | SQLite via GRDB, schema + migrations (v2 = `volume_uuid`), FTS5, path scoping, volume identity; the `op_journal` writes and the guarded row move/copy/remove; the launch-time reconcile of `in_flight` rows and journal retention |
| Metadata | `Metadata/{ImageMetadata,MetadataReader}.swift` | ImageIO `CGImageSource` reads — dimensions, camera, capture time |
| Hashing | `Hashing/*.swift` | Three hashes: `content_hash` (whole file), `image_hash` (format-stripped pixel data), `phash` (DCT perceptual) |
| Thumbnails | `Thumbnails/ThumbnailCache.swift` | QuickLookThumbnailing, on-demand, concurrent decode |
| Search | `Search/*.swift` | Structural query → SQL compiler, FTS5 text, facets, folder tree, Finder-style selection |
| Pipeline | `Coordinator/{IndexProgress,IndexCoordinator}.swift` | Two-tier pass (tier 0 = stat+metadata, tier 1 = hashes), progress, cancellation |
| Files | `Files/{FileOperation,FileOperationPlan,CompanionFiles,FileOperator,FileOperator+Transfer,FileOperator+Replacements,FileOperator+Undo}.swift` | Move/copy/trash/delete over a selection: pre-flight collision plan (with the claim's *kind*), companion files, `op_journal` ordering, rollback accounting, per-item results; both unlinks guarded on file identity (#33); undo of the last batch as a new batch, and `undoability(of:)` (§8) |
| Bench | `Diagnostics/Benchmark.swift` | The 50k measurement harness |
| Concurrency | `Concurrency/BlockingWork.swift` | Where Core's blocking sections run — off the cooperative pool (#28) |

**Blocking work is kept off the cooperative pool.** Swift's pool is exactly
`activeProcessorCount` threads wide and never grows, so a thread parked in file
IO, in SQLite's busy wait, or in a pipe read from exiftool is a thread the
process has lost — on the three-core CI runner three of those stalled the whole
job about one run in two (#28). `IndexCoordinator` and `MetadataWriter` run
their bodies on their own `DispatchSerialQueue` through `unownedExecutor`, which
moves *where* the body runs without adding a suspension point, and so without
changing what may interleave with what. The hashing pass's task-group children
are not actor-isolated, so they hop through `BlockingWork.run` instead.
`CooperativePoolTests` asserts both, and reproduces the stall itself with more
blocked hashes than the machine has cores. To see it by hand:
`env LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test` narrows the pool to one
thread; if it hangs, `sample <pid> 5` names the parked frame outright.

The App target is hosted in the app itself, so `xcodebuild test` runs
`LightboxApp.main()` before a single test does. `App/Lightbox/LaunchEnvironment.swift`
is what keeps that launch off the user's library: under XCTest's environment
(`XCTestConfigurationFilePath` / `XCTestBundlePath` / `XCTestSessionIdentifier`,
or an explicit `LIGHTBOX_TEST_HOST=1`) `launchIndexURL(in:)` returns nil and
`BrowserView` renders an inert scene instead of building a `BrowserModel`.
`BrowserModel.init(at:)` has no default argument, so `IndexStore.defaultURL` has
exactly one caller. Before that guard (#15) every App test run created, migrated
and WAL-switched the real `~/Library/Application Support/Lightbox/index.sqlite`.
The same argument now applies to `UserDefaults`: the companion-files preference
goes through a `PreferenceStore` the model is handed, `UserDefaults.standard` in
production and an in-memory double in every test, because `.standard` under a
test host is the *user's* preferences domain. A `UserDefaults(suiteName:)` was
tried first and is not enough — `removePersistentDomain` clears the values, but
`cfprefsd` writes the file out afterwards anyway, so the run left empty plists
in `~/Library/Preferences`.

The App side, file by file:

| File | What it does |
|---|---|
| `LightboxApp.swift` | The scene, the menu commands, and `FocusedValues.browserModel` — the key window the file commands act on |
| `LaunchEnvironment.swift` | Whether this launch may open the real index (#15) |
| `BrowserModel.swift` | The window's state: folder, records, selection, filters, progress; every async step carries a `Pass` |
| `BrowserModel+FileOperations.swift` | Spec §8's batches: plan, collision sheet, run off the main thread, put the window back together |
| `FileOperationState.swift` | `FileCommand`, `BatchProgress`, `CompletedBatch`, `OperationSummary`, `ActiveSheet`, `CollisionSheetModel` — the testable half of the sheets |
| `DestinationChooser.swift` | The `NSOpenPanel` behind Move/Copy To…, with the companion checkbox as its accessory view |
| `Views/` | Thin SwiftUI: grid, tree, filters, path bar, inspector, and the four file-operation sheets |

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

Eight things automated tests could not cover. **None done yet** as of the
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
3. **Move files off the Seagate and onto the boot volume, with a collision.**
   The whole `FileOperator` cross-volume path — copy, then unlink the sources —
   has only ever run against two *simulated* volumes over one real directory
   tree, because a test cannot mount a second drive. That path is the one where
   a photo has the fewest copies at any moment: between the copy landing and the
   source being unlinked there are two, and immediately after there is one. Do
   it for real, with a destination that already holds a same-named file so
   `replace` runs too, and check `op_journal` afterwards — every row `complete`,
   and every `trash_url` naming a file that is really in the Trash. Worth
   repeating once onto an exFAT or SMB destination, where `.Trashes` cannot be
   created and the disposal fails: nothing may be lost, and the rows should be
   `in_flight` naming both paths. Since #33 the source removal also refuses a
   source whose `stat` no longer matches the one its copy was verified against,
   so an ordinary move must not trip it: a batch that reports
   `modifiedSinceOperation` over files nothing touched means the reading taken
   at `verifyCopyLength` and the one taken at the unlink disagree on a real
   volume, which no simulated one would show.
4. **Unplug the Seagate mid-hash, and replug it.** The unreachable-root guards
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
5. **⌘A with the search field focused.** Should select the field's text, not the
   grid. Tests could only warn, never assert.
6. **The file-operation UI, against the real library** (#7). Automated tests
   cover the model and the sheets' logic; nothing automated can open a panel or
   click Rename. With the Seagate library open, select 30 files including a
   RAW+JPEG pair and Move To a folder that already holds one of them: the
   collision sheet should name that one file and nothing else, choosing Rename
   should run the batch, and the summary sheet should **not** appear. Then check
   the rest of the surface — the companion checkbox on the panel and whether it
   is remembered next time, ⌘⌫ with the grid focused, Delete Permanently naming
   the right count, and Stop After This Item on a batch long enough to catch it
   (the items already done stay done, and `op_journal` says so).

   **Two of these are sheet *swaps*, and they are the part no test can reach.**
   A `.sheet(item:)` asked for a new item while a sheet is up is the classic
   macOS way to end up with no sheet at all and a model that believes one is
   showing — here, a batch running with no progress indicator and no way to
   cancel it. `BrowserModel.present(_:)` nils, yields, then presents; nothing in
   an `xcodebuild test` run presents a real sheet, so collapsing that back to a
   direct assignment leaves the whole suite green (measured). Both swaps have to
   be watched by eye:
   - **confirm-delete → progress.** Delete Permanently…, then Delete
     Permanently in the sheet: the confirmation goes and the progress sheet
     arrives. (The same swap as collisions → progress, which the Rename step
     above already exercises.)
   - **progress → summary.** A batch with a guaranteed failure — move a
     selection into a folder you have `chmod -w`'d — so the progress sheet is
     replaced by the summary rather than by nothing.

   **And ⌘Z**, which is the live check the #6 entry in §8 was waiting on a UI
   for: move 20 files, quit, relaunch, ⌘Z — they come back, and the menu item
   then reads "Redo Move 20 Items"; and trash 5, empty the Trash, ⌘Z — five
   per-item failures in the summary sheet saying the files are no longer in the
   Trash, and nothing else claimed.

   **Three of these need a real key window**, which is where both of the first
   ⌘Z attempts shipped broken — see §8. The decision layer and the views' focus
   reporting are now both covered by the suite; what no test can reach is the
   menu bar delivering a keystroke to them.
   - ⌘Z with the grid focused and a batch behind it **actually reverses it**.
   - ⌘Z **while the search field or a size field is focused and has typing to
     undo** undoes the *typing*, not the batch — and the menu item is enabled
     while that field is focused, which is the regression the observable flag
     exists to prevent.
   - ⌘Z with nothing typed and nothing to reverse leaves the item greyed out
     rather than beeping.
7. **Cold folder open shows an empty grid** for the entire first index pass
   (~180 s at 50k). Known, ugly, deferred — the grid has no "indexing…" state.
8. **A real index pass over the Seagate, under the new executors.** #28 moved
   `IndexCoordinator` and `MetadataWriter` off the cooperative pool onto serial
   dispatch queues of their own. `CooperativePoolTests` proves *where* the work
   runs; it says nothing about the GUI path. Open a large folder on the external
   drive, watch progress advance, then pause and resume tier 1 mid-pass and
   confirm the counts pick up where they left off and the window stays
   responsive throughout. Executor changes are exactly the kind that a unit
   suite passes and a real window reveals.

## 8. Deferred, and what I'd do first in phase 2

Phase 2 per the spec: file operations (move/copy/delete with an undo journal),
EXIF editing via exiftool, and the duplicate view built on the three hashes
already being computed.

Three things belonged at the *front* of phase 2 rather than in a backlog, and
all three are now done:

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

- ~~**`FileOperator`.**~~ **Done** (issue #5). Move, copy, trash and permanent
  delete over a selection, spec §8. Five things worth carrying forward:

  **The order is the type.** Journal (`state = 'in_flight'`, one transaction,
  before a byte moves) → filesystem → index. The index write and the `complete`
  mark are the *same* transaction, so there is no window in which the index has
  moved on and the journal has not. `OpJournalState` documents the full state
  set, which is the contract #6's undo and launch-time reconcile read:
  `in_flight` (outcome unknown, ask the filesystem), `complete`, `failed`
  (attempted, nothing changed), `skipped` (journalled, deliberately not
  attempted — the volume went away), and `reconciled`, which only #6 writes.

  **One journal row per *file*, not per item.** Issue #5 asked for a row per
  item, and for a photo with no sidecar those are the same thing. They are not
  the same thing for a RAW with an `.xmp`: the schema has one `src`/`dst` per
  row and no way to name a companion, so a row per file is the only shape from
  which undo can put a sidecar back. One `batch_id` keeps them one undoable
  unit. The spec is untouched by this — §8 constrains the *ordering* ("every
  operation is written to `op_journal` before it runs and marked complete
  after"), not the row granularity.

  **Hash carry-over on copy is guarded twice**, and both guards matter. The
  destination's length must equal the source's (a `copyfile` that returns
  success can still leave a short file behind a full disk), and the source's
  `path`/`size`/`mtime` must still match the row that was hashed — the
  `setHashes(for:)` rule, read rather than written. Either doubt leaves the new
  row's hashes NULL and re-queues tier 1. A wrong carry-over is a permanent
  digest for bytes a file does not contain, on a row nothing will revisit, in
  the table duplicate deletion acts on.

  **A cross-volume move is written out as copy-then-delete** rather than left
  to `moveItem`, precisely so the intermediate state is reachable and
  describable: copy landed, source removal refused, both paths present. That is
  the one outcome the operator will not classify — `complete` and `failed` would
  both be lies — so the row stays `in_flight` and the reconcile settles it.
  `replace` likewise moves the existing file aside and removes it only once the
  item has succeeded; unlinking first has a window in which the user has
  neither file, reachable by something as ordinary as a full disk.

  **`FileManager.contentsOfDirectory(at:)` resolves symlinks.** A companion of
  a file under `/var/…` comes back under `/private/var/…`, and `files.path`
  holds whatever the walker was given. Companion URLs are therefore built by
  appending *names* to the source's own directory URL. The symptom of getting
  this wrong is quiet: the `.xmp` moves and its row stays behind.

  **Two things an adversarial review found, both of which lost a photo, and
  both of which the code now refuses.** First, a collision carries its *kind*:
  `occupied` (a real file is on disk) or `claimedInBatch` (an earlier item of
  this same batch is going there). `replace` is only meaningful against the
  first — against the second the "existing file" it would displace is a photo
  the batch itself moved there moments ago, and honouring it destroyed one of
  the user's own selected files while reporting `complete` for both. Two
  same-named photos from two folders, Move, Replace, apply to all, was enough.
  `replace` now degrades to `rename` wherever any claim is the batch's own, and
  `PlannedItem.effectiveResolution` records that so the sheet can stop saying
  "already exists at the destination" about a path nothing occupies. Second,
  the file `replace` displaces gets its **own journal row** — it is a mutation
  of a photo the user did not even select — written in the same up-front
  transaction, with both its path and its stash path decided at plan time so
  the row can exist before the file moves. It goes to the Trash rather than
  being unlinked, which makes `replace` as undoable as `trash` and lets #6
  reverse it by a rule it already needs.

  **`try?` on a rollback is not a rollback.** Every undo path now reports what
  it could not put back, and an item whose rollback was incomplete is
  `.rollbackIncomplete` with its rows left `in_flight`. Swallowing it produced
  the one genuinely unrecoverable record: a file at the destination under a row
  saying `failed`, which means "nothing changed" and which the reconcile is
  defined never to re-examine. Relatedly, putting a displaced file back never
  deletes what is at its original path — after a failed rollback that may be
  the user's own file, and clearing it to make room is the loss the guard
  exists to prevent.

  **`trashItem` reports OSStatus, never errno.** It is Carbon-backed and
  surfaces `NSCocoaErrorDomain` over `NSOSStatusErrorDomain` (`-43 fnfErr`,
  `-5000 afpAccessDenied`), so a failure taxonomy that reads only `errno`
  classified every trash failure as `.other` — on the operation users run most.
  errno is still consulted first; the Cocoa and OSStatus domains are walked
  after it.

  **Volume checks compare identity, not presence**, per distinct source
  directory as well as at the destination, and for `trash` and `delete` too —
  which had no check at all, so a permanent delete ran against whatever was
  mounted at the path.

  **Two more of the same class, found by a second review.** A `replace` whose
  occupant vanishes in the plan/execute gap made the staged list a *subset* of
  the replacements, while the aside rows had been written one per replacement —
  so from the first gap onwards every row was attributed to the wrong file: the
  row for a photo that was never trashed acquired another photo's Trash URL,
  and the one that really was trashed recorded nothing. `StagedReplacement`
  carries the `op_id` alongside the replacement now, paired before any
  filtering, so there is no offset left to get wrong. The same gap left the
  vanished occupant's *index* row in place, still naming the exact path the
  move was about to write, which turned a move that fully succeeded on disk
  into `indexWriteFailed(UNIQUE files.path)`; removals are emitted for every
  replacement whose row exists, staged or not. The lesson both times: **a
  subset and a list written before it was known to be a subset must never be
  zipped by index.**

  `FileOperator` runs its body on its own `DispatchSerialQueue` through
  `unownedExecutor`, like `IndexCoordinator` and `MetadataWriter` (#28). A
  batch is the largest single lump of blocking work in Core — a `rename(2)` or
  a `copyfile(3)` per file, a `trashItem` that talks to another process, two
  `stat`s around each — and none of it may sit on a pool that is
  `activeProcessorCount` wide and never grows. An executor rather than hopping
  each call through `BlockingWork.run`, because hopping would add a suspension
  point per file and the item-level rollback argument is written in terms of
  what cannot interleave with what.

  **A third of the same class, and the worst: a cross-volume move that lost the
  photo outright.** A cross-volume move copies and then unlinks the sources, so
  from that moment the copies at the destination are the *only* copies — but the
  undo path was still a list of `(from, to)` pairs whose non-rename branch
  removed every `to`. A failed stash disposal after the unlink therefore deleted
  the destination copies with the sources already gone: both paths empty, the
  journal row `in_flight` naming two files that no longer exist, no `trash_url`,
  nothing to recover from. The shipped test for the disposal path drove exactly
  this and passed, because it only checked journal marks. Reachable on the app's
  most ordinary gesture — the library is on an external drive, so every move off
  it is cross-volume — whenever the destination cannot make a `.Trashes`
  (exFAT, SMB, an unwritable folder), `trashItem` returns no URL, or the journal
  write hits `SQLITE_BUSY`.

  Two guards now, in `FileOperator+Transfer.swift`, and they cover **different**
  paths rather than being redundant — the first draft of this claimed otherwise
  and was wrong. `rollbackMoves`' non-rename branch `stat`s the source before
  removing a copy and refuses when it is absent; that is what saves the photo
  when a *disposal* failure abandons the item, because that path reaches
  `abandon` directly. `TransferState.sourcesRemoved` governs the other path, a
  source-removal failure part way through the unlink loop: if nothing has been
  unlinked yet the copies are ordinary undoable work and come back off the
  destination, and once anything has been unlinked they are the only copies and
  the undo declines. Each has its own test and its own mutation. **The tests that
  matter assert the photo exists at its source *or* its destination** — not what
  the journal says, which is how the original bug shipped green.

  A third file-losing path in the same function: `copyfileCopy` passes
  `COPYFILE_EXCL`, so a destination occupied by a file that *arrived in the
  plan/execute gap* fails with `EEXIST` — and the cleanup, seeing a file at the
  destination, unlinked it. Not trashed, and under a row saying `failed`.
  Whether the destination pre-existed is now read **before** the attempt, and
  the gap arrival is reported as `destinationNotReplaceable` and left alone.
  "There is a file here now" never means "we created it".

  **The unlinks are guarded on identity too** (issue #33). Every index *write*
  in the type matched the row's id and its `size`/`mtime` before landing —
  `setHashes(for:)`'s rule — while the two `removeItem` calls still trusted the
  path alone. `performDelete` now re-reads each file's row and refuses when the
  row's id is not the one the plan read, when its `size`/`mtime` no longer match
  the disk, or when the row the plan read has been pruned — a missing row is
  disagreement, not an absence of evidence, and that is deliberately stricter
  than undo's identical-looking check, because undo displaces and `delete`
  destroys. **A refusal on the selected file refuses the whole item**: a
  companion rides along only because it shares the source's basename, so once
  the source is a stranger's file the `.xmp` beside it is the stranger's too,
  and it has no row of its own to be guarded by. `.modifiedSinceOperation`,
  every row of the item `failed`, nothing touched.

  The cross-volume source removal keeps the `stat` `verifyCopyLength` took of
  each source — carried on `TransferState.Landing`, in the element, never in a
  list paired by position — and refuses to unlink a source that no longer
  matches it; there the copy is already at the destination, so it goes through
  `abandon` and the rows stay `in_flight` naming both paths. **A source that has
  vanished is not a mismatch**, on either path: something else removed it
  between the copy and the unlink, "gone from the source, present at the
  destination" is the finished shape of a move, and there is nothing left to
  unlink — the loop marks `sourcesRemoved` and carries on, so an ordinary move
  still completes. And `abandon` now says *which* sources went and which did
  not, because the guard can stop the removal loop with the first source already
  unlinked, and "the originals are gone" would send the user to the wrong folder
  for the rest. `inode` is compared on the transfer's window and
  deliberately not on the delete's: `recordMetadataWrite` refreshes a row's
  `size`/`mtime` after an exiftool write but not its `inode`, so an inode read
  off a row is stale for every photo the app has ever edited, and comparing it
  would refuse to delete them. `replace` needs no such guard — a gap arrival at
  an occupant path is moved aside and trashed under its own row, displaced
  rather than destroyed.

  Owed: the Seagate live check. The batch was exercised over 50 real photos
  copied off `03_DEDUPED_ARCHIVE/2019` into a scratch directory on the boot
  volume — 53 journal rows, all `complete`, companions moved, `files_fts`
  following the rename — but that is one volume, so the same-volume `rename(2)`
  path and the `COPYFILE_CLONE` path are the only ones a real drive would add
  coverage for. The archive holds no RAW and no `.xmp`, so the pair in that
  check was named rather than found.

- ~~**The undo journal, read back.**~~ **Done** (issue #6). Two halves, both in
  Core, both over the rows `FileOperator` already wrote.

  **`FileOperator.undo(batch:)` reverses the last batch as a new batch.** Its
  own `batch_id`, its own `op_journal` rows, journalled up front like any other
  — which is what makes redo nothing but undo of the undo, with no history
  state anywhere. Reversal per kind: a move moves back; a copy's destination is
  **trashed, never unlinked** (`delete` is the only thing in this app that
  destroys a file, and undo is not it — spec §8 amended, see below); a `trash`
  row, plain or aside, is restored from `trash_url` to `src`; a `delete` is
  refused for the whole batch, before it runs, by `undoability(of:)`. Steps run
  in **descending `op_id`**, which is what puts a `replace`'s aside row after
  the item that displaced its occupant: the item's own reversal has to vacate
  the path before the displaced photo can come back to it.

  **Only an all-`complete` batch is undoable.** `in_flight` means the outcome
  was never written down; `reconciled` means it was reconstructed from two
  `stat`s after a crash, and reversing an inference is how a half-finished
  cross-volume move becomes a lost photo; `failed` means nothing changed but is
  something the user was shown. `skipped` is the one non-`complete` state that
  does *not* block — its contract is the strongest in the enumeration
  (journalled, deliberately not attempted, nothing changed), so a batch that
  lost its tail to an unplugged drive is still as undoable as the part that ran.

  **Nothing is skipped silently**, which is the same rule as everywhere else
  here. Three pre-checks, each a per-item failure that changes nothing: the file
  is not where the row says (`sourceVanished`, or `trashEmptied` when it is the
  Trash URL that is missing); the path it would return to is **occupied**
  (`destinationNotReplaceable` — this is what stops an undone trash overwriting
  the export the user saved there since); and its `files` row no longer
  describes it (`modifiedSinceOperation`). The reversal itself goes through
  `performTransfer` and `performTrash`, not a second copy of them, so the
  cross-volume legs and the "the copies are the only copies" guard are the ones
  already written and tested.

  **The reconcile runs inside `IndexStore.init`**, before the initializer
  returns, so no window can start a pass over rows a crash left describing files
  that have moved. One read (the `in_flight` rows plus the `files` rows for
  every path they name, chunked), every `stat` outside any transaction, then one
  write for the corrections, the `reconciled` marks and retention together. It
  **never throws out of `init`**: a store that will not open is an app that will
  not launch, over a repair whose worst case is "the rows are wrong until the
  next pass". The full decision table is the doc comment on
  `IndexStore.decide`; three rules govern all of it — **never remove a file**,
  **never remove a row whose file is there** (stale means the path holds nothing
  or holds something with a different inode/size/mtime), and **never carry
  hashes across a crash** (the one insert it makes has NULL hashes, because
  nothing verified those bytes).

  The row that matters is still `move` with **both** paths present: that is a
  cross-volume copy whose delete leg did not run, and a `move` row plus a
  destination that exists is exactly the inference that would unlink the source.
  It is treated as a copy — both files stay, the destination gains a row without
  hashes. Its test asserts both files are on disk, and the mutation that turns
  the branch back into "believe the row" fails it.

  **"Something is at `dst`" is not "the file that moved is at `dst`".** Every
  branch that would write to a destination first checks `destinationMatches` —
  the file's `size` and `mtime` against the source's row — and writes nothing
  when it fails. `rename(2)` preserves both, and so do `copyfile(3)` with
  `COPYFILE_ALL` and `clonefile`, so the check only rejects two things, and both
  are real: a **stranger** that arrived in the plan/execute gap (widened, after a
  crash, to however long the app was shut), and a **copy the crash left short**.
  Without it a 999-byte stranger inherited a 64-byte photo's `content_hash` — a
  digest describing bytes it does not contain, on a row nothing re-hashes, in
  the table the duplicate view deletes on. It is deliberately a *different* test
  from `removalIfStale`'s, which also requires the inode: there the path is
  unchanged so a new inode is evidence of a different file, while here the path
  changed by construction and a cross-volume copy lands on a new inode by
  definition. A destination that fails the check gets **no row at all** rather
  than a row with NULL dimensions: `needsReindex` keys on `size` and `mtime`
  alone, so a row whose facts match its file is never re-read and its nulls
  would be permanent, while an unindexed path is indexed completely by the next
  walk.

  **Every correction is one transaction, so one collision is not one bad row.**
  Two `in_flight` rows naming one destination — two copies of the same photo,
  two crashed batches, one name — used to raise `UNIQUE(files.path)`, roll the
  whole pass back and leave *everything* `in_flight` for a next open that failed
  identically, forever. Destination claims are now deduped: the first wins, the
  loser is marked `reconciled` with a conclusion naming the path and still gets
  the correction that cannot collide (retiring its own stale source row).

  **Retention:** `IndexStore.journalRetentionDays` (30) and
  `journalRetentionBatches` (200), an AND-keep — a row survives only if its
  batch is inside both — run in the reconcile's write transaction and never
  touching an `in_flight` row. A malformed row (a `move`/`copy` with a NULL
  `dst`, which no `FileOperator` path produces) is left `in_flight` deliberately
  and is therefore never retired: it is the only record that it exists.

  **The age rule is floored at one batch** (`rn > 1`). Thirty idle days is an
  ordinary holiday, and without the floor the last batch went with them: come
  back after 31 days and ⌘Z answers `noSuchBatch` for an operation the user
  still remembers doing. The count rule needs no such floor — at `rn > 200`
  there are by definition 200 newer batches to undo instead.

  **The reconcile's `stat`s do not run on the calling thread.** `init` is
  synchronous and the reconcile still finishes before it returns, but the app
  opens its store on the **main actor** (`BrowserView.start` →
  `BrowserModel(at:)`), the rows name whatever volume the library lives on, and
  one `stat` on a spun-down external drive parks its thread for seconds — before
  the first window draws. The work goes to a dispatch queue and `init` waits on
  it for `IndexStore.reconcileBudget` (3 s; five thousand rows reconcile in
  about 0.19 s warm, so this only bites on a drive that has to spin up). Past
  the budget the run is **abandoned, and the abandon is atomic with the write**:
  the flag is read inside the transaction — on acquiring the writer and again
  immediately before the commit — and leaves by throwing, which is the only
  thing GRDB treats as a rollback. Checking merely *before* `pool.write` was not
  enough, and was proven not to be: a deferred run still queued for the writer
  behind the 5 s busy timeout and committed after `init` had returned saying
  nothing landed, applying corrections from a snapshot up to `budget` old — and
  `.insertCopy` goes through `upsertRow`'s `ON CONFLICT`, so one of those late
  writes could overwrite a row a tier 0 pass had indexed properly in the
  interim. Now every row stays `in_flight`, the report says `.deferred`, and the
  next open finishes the job; that retry path has its own test.
  `JournalReconcileDisposition` also distinguishes a run that threw from an
  empty journal, which the counts alone could not.

  **`destinationMatches` compares the timestamp with a tolerance and the length
  without one**, because only one of the two is quantised by the filesystem.
  "`copyfile` carries the times across" is an APFS sentence: measured against a
  real `COPYFILE_ALL`, exFAT rounds a modification time to 10 ms and the FAT
  family to 2 s, and SMB rounds either way. **Those are the ordinary volumes
  here, not the exotic ones** — this app exists for a library on an external
  drive — and an exact comparison failed identity on the user's own good copy,
  retired the hashed source row, wrote no destination row, and reported
  `destinationDiffersFromTheSource` about it. `destinationMtimeTolerance` is
  2 s and symmetric; size stays exact, so a stranger still has to match byte for
  byte in length *and* land within two seconds to be mistaken for the original.

  **A missing `files` row for `src` is not a mismatched destination.** Both
  `move` branches folded "no row to compare against" into
  `destinationDiffersFromTheSource`, which is a claim *about the user's file*
  made on the strength of an index row a walk had pruned. A pruned source row
  now reports `happened` for the src-gone branch and `copyDoneDeleteNot` for the
  both-present one — deliberately not `happened` there, because the source is
  demonstrably still on disk — with no mutation either way.

  Two things worth knowing. **Undoing a trash leaves the restored photo without
  an index row** until the next tier 0 pass: the row was deleted when the file
  was trashed, its hashes with it, and inserting a `stat`-derived row would be
  worse than none — `needsReindex` compares size and mtime, so a row with NULL
  dimensions would be considered up to date forever. Same reasoning for the
  reconcile's copy insert when there is no source row to derive from. And
  **undo is per journal row, not per item**: `execute` reports per item because
  an image and its sidecar succeed together, but an undo has only rows, and a
  sidecar whose reversal fails is a fact rather than something to fold into its
  image's verdict.

  Owed: the ⌘Z live check (move 20, quit, relaunch, undo; trash 5, empty the
  Trash, undo). **It can be run now** — #7 shipped the menu item, so this is
  part of §7.6. The Core equivalents exist:
  `aBatchSurvivesQuittingAndIsUndoneAfterRelaunch` closes a file-backed store and
  undoes through a fresh one, and `anEmptiedTrashIsFivePerItemFailuresAndNothingElse`
  trashes five real files, empties them from the real Trash and asserts five
  `.trashEmptied` results with nothing else touched. Every Core test that trashes a
  file for real cleans it up afterwards from the journal's own `trash_url` rows —
  never by listing `~/.Trash` and matching on name — and, since #35, mints its
  fixture name unique to that test run (`TempTree.uniqueName(_:ext:)`) rather than
  reusing a literal like `IMG_0001.CR2`: `swift test` runs suites in parallel, and
  two tests trashing the same name at once collide in that one shared directory.
  Also owed: a genuinely cross-volume undo. `performTransfer` is shared with the
  forward path, which is where the cross-volume legs are tested, but no test
  drives an undo across two real volumes.

- ~~**The file-operation UI.**~~ **Done** (issue #7). Move To…, Copy To…, Move
  to Trash (⌘⌫) and Delete Permanently… in the File menu, ⌘Z in the Edit menu,
  with the collision, progress, summary and confirmation sheets behind them. All of it in `App/`; the only `Core` change was
  `FileOperationFailure.explanation`, the sentence a summary row shows.
  Five things worth carrying forward:

  **The commands are wired through `@FocusedValue`, not a notification.** ⌘O,
  ⌘R and ⌘A post to `NotificationCenter` and every open window responds, which
  is harmless for "reload yourself" and wrong for "move these 300 files" — a
  broadcast would start one batch per window. `FocusedValues.browserModel` is
  set by `BrowserView` with `.focusedSceneValue`, so the command acts in the
  key window and, as a bonus, gets its enabled state from that window's
  selection.

  **A disabled `CommandGroup` item has a nil `action`.** Measured, and it is
  what makes the menu half of the enabled-state assertion possible: SwiftUI
  strips the action off a disabled command item entirely, so `action == nil`
  *is* "disabled" in `NSMenuItem` terms. The Cut/Copy/Paste note in
  `LightboxApp` still holds for items with no `.disabled` on them — those
  validate to enabled whatever the responder chain thinks.

  **The grid updates with `reload()`, never `refresh()`.** `FileOperator`
  rewrites the index rows in the same transaction that marks the journal
  complete, so the index already describes the new world by the time a batch
  returns; a rescan would re-walk the folder — minutes on the Seagate — to
  learn it again. The test pins this by creating a file on disk the index has
  never seen and asserting it does *not* appear.

  **⌘Z replaces the stock `.undoRedo` group whole**, for the reason
  `.pasteboard` was replaced: SwiftUI's stock Undo already carries ⌘Z, and
  AppKit resolves two items sharing one key equivalent by stripping it off the
  *custom* one — the collision that left ⌘A mouse-only. One item, titled from
  `BrowserModel.undoMenuTitle`. **No Redo goes back**: `Core` journals a
  reversal as an ordinary batch, so undoing the undo *is* the redo, and the
  title flips to "Redo Move 12 Items" to say so. `CompletedBatch.isReversal` is
  the whole of that mechanism on this side, and the *original* operation's kind
  is carried through a reversal rather than read back off it — a copy's reversal
  is journalled as a trash, so reading it back titles the redo "Undo Trash 3
  Items", naming the machinery instead of what the user did.

  **The title only names a batch when the press would reverse one.** That is
  load-bearing rather than tidy: `undoMenuTitle` describes the last batch and
  knows nothing about focus, so a window with a batch behind it and the search
  field focused offered "Undo Move 3 Items" while ⌘Z undid typing — the single
  claim this whole design rests on ("the title says which of the two the next
  press will do"), false in exactly the state four review rounds were about.
  `UndoCommand` computes the destination once and uses it for the title, the
  enabled state and the action, so the three cannot disagree.

  **⌘Z cannot be routed the way ⌘A is, and the first attempt at it was dead on
  arrival.** ⌘A asks the responder chain and reads "nobody answered" as "the
  grid means it". That works for `selectAll:` because nothing outside a text
  view implements it. `undo:` is different: **`NSWindow` implements it**,
  through its own `NSUndoManager`. Measured in a standalone AppKit app with a
  real key window and a plain `NSView` focused:

  ```
  undo:       target=NSWindow    sendAction=true      ← always
  selectAll:  target=nil         sendAction=false
  copy:       target=nil         sendAction=false
  ```

  So `sendAction("undo:")` is true whenever *any* window is key, whatever is
  focused. The shipped-then-caught version guarded on exactly that and swallowed
  every ⌘Z while the menu item still read "Undo Move 12 Items" — and the App
  suite could not see it, because the test host never gets a key window, so the
  guard read false there and only there. **A test whose own failure message says
  it proves nothing is not covering the path it names.**

  **The first fix for that was right about focus and wrong about where to read
  it.** It asked `NSApp.keyWindow?.firstResponder` inside the command body,
  including in `.disabled`. That is an API property, not a measurement, and it
  is enough on its own: **an `NSApp` read is not observable state, so a body
  reading it acquires no SwiftUI dependency on it.** Such a body can only ever
  be re-evaluated when something *else* it does observe changes, so the enabled
  state was decided by whatever happened to invalidate the command last rather
  than by where the focus actually was.

  What that looked like on screen is deliberately *not* claimed here. The
  obvious symptom — the item stuck greyed out, ⌘Z in the search field doing
  nothing — could not be separated from SwiftUI refreshing command items lazily:
  three probe shapes (an `@Observable` flag read directly by a command body,
  `NSMenu.update()`, `performKeyEquivalent`) produced no observable refresh
  signal at all, so the harness cannot distinguish "never re-evaluated" from
  "re-evaluated somewhere the probe could not see". Whether the item re-enables
  in a running app is §7.6's second and third ⌘Z checks, which is what they are
  for. The fix does not rest on the answer: reading observed model state instead
  removes the dependency question entirely, and it is the same mechanism the
  four file commands already rely on.

  So the flag is observable state the views publish. `BrowserModel.editingFields`
  is a `Set<TextField>` written through `setEditing(_:_:)` by
  `View.reportingTextFocus(_:isFocused:to:)`, which every text field in the app
  must call — `PathBarView`'s search and `FilterPanelView`'s exact-size pair
  today, and `BrowserModel.TextField` is the checklist for the next one. A set
  rather than a `Bool` because focus moving between two fields produces two
  reports in an order SwiftUI does not promise, and a single flag lets the field
  that just lost focus clear what the field that gained it had already set.
  There is no `NSApp` read left anywhere in the routing: one source of truth.

  The decision is `UndoCommandAction.destination(for:)` over that state, and
  `destination(isEditingText:canUndo:)` under it is a pure function of two
  booleans — so the menu's real decision is testable with no key window, which
  neither earlier version was. Text being edited wins even when the grid also
  has a batch: ⌘Z belongs to the thing being typed in.

  The item still may not simply be disabled on the grid's state, because it
  replaces the stock group and is therefore the app's only ⌘Z; it greys out only
  when the decision is `.nowhere` — nothing being edited *and* nothing to
  reverse.

  **The views' half is tested, and nearly was not.** `NSHostingView` renders the
  real view and `makeFirstResponder` engages `@FocusState` *without* a key
  window — measured, `isKey=false foundField=true isEditingText=true
  fields=[.search]` — so `TextFocusReportingTests` drives both views for real. A
  field that stops calling `reportingTextFocus` reddens it.

  **A refusal is shown, never swallowed.** `undoability(of:)` is consulted
  before `undo(batch:)`, and its `UndoRefusal` becomes the summary sheet's
  headline through `BrowserModel.describe(refusal:)` — App copy, like
  `FileOperatorError`'s and unlike `FileOperationFailure.explanation`, because a
  refusal is a pre-flight answer to a caller rather than a row in a list. The
  permanent-delete case is the one that has to arrive before the operation, and
  `Core` reports it first whatever else the batch holds.

  **The selection follows the files for a move and empties for trash/delete —
  and empties after an undo.** A move out of the folder on screen has nothing to
  follow, so it empties too; a copy leaves the selection alone, because the
  sources did not go anywhere. An undo empties because it is the one run whose
  items do not share a direction: undoing a copy trashes while undoing a move
  restores, and a reversal can put photos back into folders that are not on
  screen. A selection right for some of them and wrong for the rest is worse
  than none.

  Owed: the GUI live check, §7.6 — which now includes the ⌘Z pair the #6 entry
  above lists (move 20, quit, relaunch, undo; trash 5, empty the Trash, undo),
  because #7 is the UI that entry was waiting for.

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
