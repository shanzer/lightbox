# CLAUDE.md

Guidance for Claude Code (and any agent) working in this repo.

---

## Working conventions (READ FIRST)

**Git workflow:** no direct commits to `main`. Every change is a feature branch → PR →
merge back, with CI green before merge. See **`CONTRIBUTING.md`**. (Phase 1 was committed
straight to `main` with subagent-driven development; that ended with the template
adoption. `docs/HANDOFF.md` §9 describes the old process as history, not instruction.)

### GitHub issue per change (required)

1. **Create a GitHub issue before starting.** Document *what* is being changed and *why*
   (the problem/root cause, the intended fix, and how it'll be verified). Title prefixes,
   labels, the ready-for-agent bar, and the body shape live in
   **`docs/agents/issue-conventions.md`**; the `gh` invocations are in
   `docs/agents/issue-tracker.md`.
   ```bash
   gh issue create --title "<concise summary>" --body-file <path>
   ```
2. **Reference the issue in the commit or PR** (`Fixes #<n>` / `Refs #<n>`).
3. **Close the issue when the work is complete and verified**, with a comment stating what
   was done and the verification result.
   ```bash
   gh issue close <n> --comment "<what shipped + verification>"
   ```

Two skills work from the conventions doc: **`/issue`** (a subject in, a fully-specified
issue out) and **`/intent`** (an issue number in, an implementable issue out). Both
confirm before writing to GitHub.

### Verify before claiming done

Run the project's checks and report what they actually said. For anything the test suite
cannot prove — index writes, volume unplugs, multi-window concurrency, exiftool calls —
exercise the real thing and say so. The concrete list is the **Verification** section of
`docs/agents/issue-conventions.md`. A green unit-test run is not evidence about a code
path it never entered; that is how the index got lost twice in phase 1.

### CI

`.github/workflows/ci.yml` runs both suites on every PR and push to `main`, on a clean
`macos-26` runner with no fixture library, no `index.sqlite`, and no photos. A test that
depends on local data must **skip cleanly**, and its skip guard must consult the same path
the code under test reads — the `LIGHTBOX_BENCH` gate is the model.

### Other conventions

- Labels are managed in `.github/labels.json` via `scripts/sync-labels.sh` — not by hand.
- Keep documentation in step with behavior changes, in the same PR. The spec in
  `docs/superpowers/specs/` is binding: amend it or don't merge.
- Commit/push only when the user asks.

---

## The project

**Lightbox** is a native macOS photo-library browser and deduplicator (SwiftUI, GRDB,
ImageIO, QuickLookThumbnailing), replacing Bridge for browsing and dimension search over a
large library on an external drive. Phase 1 (browse + structural search) is complete;
phase 2 (file operations, EXIF editing, duplicate view) is next. The spec's §13 has the
four-phase breakdown.

### Read these first

- `docs/HANDOFF.md` — the state of the project and the traps. §5 is the module map, §6
  the hash invariants that must not be "fixed", §7 the manual checks still owed, §8 what
  phase 2 should do first.
- `docs/superpowers/specs/2026-09-05-lightbox-design.md` — **the binding spec**, 14
  sections, amended three times during phase 1.
- `docs/superpowers/plans/2026-09-05-lightbox-phase-1.md` — the executed plan. Historical,
  but it holds the reasoning behind each decision.
- `docs/superpowers/notes/2026-09-05-grid-measurement.md` — the 50k benchmark numbers and
  thresholds. All Intel; the arm64 re-run is owed.

### Layout and commands

```
Core/     LightboxCore — headless SwiftPM package; all logic, all 613 tests. No AppKit/SwiftUI.
App/      Lightbox.xcodeproj — SwiftUI shell over Core; 141 tests. Depends on Core as ../Core.
docs/     spec, plan, notes, HANDOFF.md, and docs/agents/ (issue conventions).
scripts/  make-fixture-library.swift (50k benchmark library), sync-labels.sh.
```

```bash
cd Core && swift test                                                     # ~15 s on M4
cd App  && xcodebuild -scheme Lightbox -destination 'platform=macOS' test  # ~3 s after build
cd Core && LIGHTBOX_BENCH=1 swift test --filter Benchmark --no-parallel   # needs ~/lightbox-bench
cd Core && LIGHTBOX_POOL_LIMITS=1 swift test --filter BlockingWorkFanOut  # queue geometry; needs cores (#49)
```

Toolchain: Xcode 26.x, Swift ≥ 6.2 (`swift-tools-version: 6.2`, `.macOS(.v26)`). Sole
dependency GRDB.swift 7.11.1, pinned in both `Core/Package.resolved` and the xcodeproj's
`Package.resolved` — bump both together. exiftool is resolved via `PATH`, never a
hardcoded prefix (it's `/opt/homebrew/bin` on Apple silicon, `/usr/local/bin` on Intel).

### Gotchas that cost a debug session

- **`App/Lightbox.xcodeproj/project.pbxproj` is hand-written** (objectVersion 77,
  `PBXFileSystemSynchronizedRootGroup`). New `.swift` files under `App/Lightbox/` need no
  project edit. Do not regenerate it through Xcode's GUI; it churns badly.
- **The three hashes are deliberately asymmetric.** JPEG uses a segment denylist, PNG a
  chunk denylist, WebP an allowlist — verified against exiftool. Don't "fix" it into
  symmetry. `HANDOFF.md` §6.
- **`setHashes(for:)` refuses a write whose row no longer matches the path/size/mtime
  that was hashed.** `files.id` is a reused rowid; without the guard one photo's hash
  lands on another photo's row, and duplicate detection deletes on it. Not optional.
  **`FileOperator`'s two unlinks are guarded the same way (#33)** — the permanent
  `delete` against the row it read, the cross-volume move against the `stat`
  `verifyCopyLength` took of the source — because those are the only places where a
  file that arrived in the plan/execute gap is destroyed rather than displaced. The
  delete deliberately does not compare `inode`: `recordMetadataWrite` leaves it stale.
  A refusal on the *selected* file refuses the whole item — a companion is a companion
  only by basename, so it belongs to whatever is at that path now — and a row the plan
  read that has since been pruned is disagreement, not absence of evidence; a companion
  that never had a row of its own still deletes.
- **Motion photos and chunk-flood files are guarded and tested.** Any new format parser
  needs both: strip trailing data past EOI/IEND, and coalesce ranges before reading.
- **`st_dev` is a mount-time id**, not a volume identity — it changes on replug. Since
  schema v2 the identity is `files.volume_uuid` (`VolumeIdentity`), and `device` is kept
  only for inode uniqueness and for rows written before v2. The reconcile's matching rule
  is on `IndexStore.deleteRows`: **a row is prunable if its `volume_uuid` equals the
  root's, or its `volume_uuid` is NULL and its `device` equals the root's `st_dev`.** A
  root with no UUID therefore prunes only the NULL rows; a stamped row is never matched by
  a nameless root, and `volume_uuid` is written only through `COALESCE` so a nil read can
  never erase one. `indexTier0` reads the identity **twice** — before the walk and after —
  and gates both the stamp and the delete on them matching; collapsing that to a single
  post-walk read lets a mid-walk swap brand real rows with an impostor's UUID, which no
  later pass can undo. Don't reintroduce a device-only comparison as "simpler", don't
  "simplify" the COALESCE away, and don't drop either read; all three are the ghost-rows
  bug.
- **GRDB is on a `DatabasePool` in WAL mode, with a 5 s busy timeout.** Readers take a
  snapshot and never wait for a writer; the timeout is there for writer-versus-writer,
  which SQLite serialises whatever the journal mode. All DB configuration goes in
  `IndexStore.makeConfiguration()` and nowhere else. Two consequences: the index is
  three files (`index.sqlite`, `-wal`, `-shm`) and they are deleted together, and
  `IndexStore.inMemory()` is a private temporary file — a pool cannot be in-memory —
  removed when the store is released. `IndexStore.close()` now checkpoints before it
  closes — `Database.checkpoint(.truncate)` on the writer, via
  `pool.barrierWriteWithoutTransaction`, then `pool.close()` (#40): GRDB's
  `DatabasePool.close()` closes the writer before the read-only readers, so SQLite's
  checkpoint-on-last-close never runs once a reader connection has ever existed, and
  `close()` used to leave `-wal` on disk unchanged despite promising a file safe to
  hand off (#39). It's idempotent — a second call is detected from GRDB's own
  `DatabaseError.connectionIsClosed()`, not a flag this type tracks — and reports
  rather than throws when the checkpoint can't fully complete — a second store's
  reader still holding a snapshot on the same file, surfaced as `SQLITE_BUSY` —
  because that describes the checkpoint, not the close: `pool.close()` still runs
  either way. That test rule still stands for anything that bypasses
  `close()`: a test that mutates the file underneath a URL-backed store — corrupting
  it, replacing its sidecars, anything done to the bytes on disk rather than through
  the store's own API — must still call `close()` on that store first, because relying
  on `deinit` (not synchronous enough, and doesn't checkpoint on purpose — see
  `IndexStore.close()`'s doc comment) or reaching the pool some other way gets none of
  the fix: the pages about to be corrupted can still be served out of `-wal` to
  whatever reopens the file next, and the test never proves what it claims to (#39,
  #40).
- **Blocking work never runs on the cooperative pool.** That pool is exactly
  `activeProcessorCount` threads wide and never grows, so a thread parked in file IO,
  in SQLite's busy wait, or in a pipe read from exiftool is a thread the process has
  lost. Three of those stalled the CI job about one run in two (#28). `IndexCoordinator`,
  `MetadataWriter`, `FileOperator` and `ThumbnailCache` therefore run their bodies on
  their own `DispatchSerialQueue` through `unownedExecutor`; blocking work that is *not*
  actor-isolated hops through `BlockingWork.run` — the hashing pass's task-group
  children, `ThumbnailCache.generate`'s encode (the QuickLook render stays async and
  parks nothing), `MetadataWriter.recheckAvailability`, and, since `BlockingWork` went
  `public` in #30, the App target's two blocking sites: `BrowserModel`'s search and
  `FolderTreeView`'s directory reads — `BlockingWork.run` is the only thing in that
  enum that is `public`, its labels stay internal and the App tests reach them with
  `@testable import LightboxCore`. The rule now holds **everywhere**, not just in
  Core; anything new that blocks belongs behind one of those two.
  `CooperativePoolTests` — one suite in Core, one in `App/LightboxTests` — pins each
  site with a queue-label assertion and fails if it moves back, **except**
  `FolderTreeView`'s two hops, which have no label test: `FolderNode.children` has no
  injection seam and `FolderItem` is a view-tree helper with nowhere to read a queue
  label from. Those two are held by the standing `grep` instead, which is the check
  for the whole rule: `grep -rn 'Task.detached\|@concurrent' Core/Sources App/Lightbox`
  must turn up nothing doing synchronous IO or SQLite outside a hop. Today its only
  non-comment hit is `ThumbnailCache.generate`, whose `@concurrent` carries the async
  render and whose blocking half is hopped. `BlockingWork.run`'s
  queue admits **at most 64** concurrently-blocked closures and queues the surplus, so
  every caller's fan-out *and how long it holds a slot* is written down in the table on
  `BlockingWork.queue`. **64 is libdispatch's cap, not a number every machine reaches**
  — a 3-core CI runner tops out around 3 or 4, and the two tests that measure this
  geometry are therefore opt-in behind `LIGHTBOX_POOL_LIMITS=1` and skip on CI (#49).
  Don't quote the 64 as though CI had checked it. Two callers scale with the window
  rather than a constant: the grid's cells and the sidebar's rows. The grid is the one
  that has been measured — it peaks at 10 at worst on a 10-core M4 — but in slot-seconds `FolderTreeView` is the heavier of the two, and
  the one with no test: a `contentsOfDirectory` plus an `lstat` per entry can hold a
  slot for seconds on a spun-down volume against the encode's 0.6 ms. Reproduce a
  narrowed pool with
  `env LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test`, and `sample <pid> 5` if it
  hangs — the sample *is* the diagnosis.
- **Never zip or index a pre-filter list against a post-filter one.** Both of the
  photo-losing bugs in `FileOperator` were this: journal rows written one per planned
  replacement, then paired by position against the *staged* subset, so every row past
  the first skipped entry described the wrong file. Carry the id in the element
  (`StagedReplacement`) rather than trusting two lists to stay the same length.
- **`failed` means nothing changed, so a path that cannot promise that leaves its rows
  `in_flight`.** The reconcile is defined never to re-examine a `failed` row, so
  reporting `failed` over a file still sitting at the destination strands it for good.
  `FileOperationFailure` names the four cases that cannot make the promise. The same
  rule kills `try?` on any cleanup: a swallowed rollback is exactly how a row comes to
  claim `failed` over a filesystem that moved.
- **A `FileOperator` test that reaches the real `~/.Trash` must mint its own fixture
  name.** `swift test` runs suites in parallel, and Finder's Trash is one shared
  directory keyed by name — two tests trashing an `IMG_0001.CR2` at once either collide
  on the same slot or one test's journal-driven cleanup empties the other's item out
  from under it (#35). `TempTree.uniqueName(_:ext:)` mints `<stem>-<tag>.<ext>` once per
  `TempTree` instance, so every test gets its own name; a RAW and its sidecar keep
  pairing up by sharing a stem. Only a test whose batch genuinely calls `trashItem` needs
  it — kind `.trash` that survives long enough to trash something, or a `.replace`
  collision whose occupant's disposal actually succeeds. A test that fails *before*
  reaching `trashItem` (a vanished source, a locked folder, a disposal deliberately made
  to fail so the stash is never disposed of) never touches the real Trash and may keep
  the literal name — do not rename it "for consistency"; that is churn on a test the bug
  never reached.
- **A `move` journal row plus a destination that exists is not permission to unlink the
  source.** That shape is a cross-volume move whose copy landed and whose delete leg did
  not, and the launch-time reconcile (`IndexStore+Reconcile.swift`, run inside
  `IndexStore.init` and never throwing out of it) treats it as a *copy*: both files stay,
  the destination gains a row **without hashes**. Three rules govern every correction —
  never remove a file, never remove a row whose path still holds the file it describes
  (stale = nothing there, or a different inode/size/mtime), never carry hashes across a
  crash. `IndexStore.decide`'s doc comment is the whole decision table.
- **"Something is at `dst`" is never "the file that moved is at `dst`".** Every reconcile
  branch that writes to a destination first checks `destinationMatches` (the file's size
  and mtime against the source's row) — `rename(2)`, `copyfile` with `COPYFILE_ALL` and
  `clonefile` all preserve both, so it only rejects a stranger that arrived in the
  plan/execute gap or a copy the crash left short. Without it a 999-byte stranger inherits
  a 64-byte photo's `content_hash`. A destination that fails gets **no row at all**, not a
  NULL-dimensioned one: `needsReindex` keys on size and mtime, so a row matching its file
  is never re-read and its nulls would be permanent. Retention floors the age rule at one
  batch (`rn > 1`) for the same reason ⌘Z exists — 31 idle days must not eat the last
  batch. And the reconcile's `stat`s run off the calling thread on a bounded wait, because
  the app opens its store on the main actor before the first window draws — with the
  abandon flag read **inside** the write transaction and left by throwing, since a check
  merely before `pool.write` still commits after `init` has returned saying it did not.
  The mtime half of the identity check carries a 2 s tolerance: "`copyfile` carries the
  times across" is APFS-only, and exFAT/FAT/SMB quantise — which is every drive this app
  is actually for. Size stays exact.
- **`reconciled` is not `complete`, and undo knows the difference.** A `reconciled` row's
  outcome was reconstructed from two `stat`s after a crash, so `undoability(of:)` refuses
  the batch — as it refuses `in_flight` and `failed`. Only `skipped` is harmless enough to
  ignore. A permanent delete is refused **before** it runs, which is the only moment the
  answer is any use, and undo trashes a copy rather than unlinking it (spec §8 amended).
- **Swift 6.3.3 times out on dense bit-twiddling one-liners** that 6.3.2 accepted. Split
  into named steps; don't fight the type checker.
- **`width>=1920` costs 474 ms at 50k.** That is row materialisation, not a missing index.
  Don't add one.
- **Ids are rowids; the grid sorts by name.** Anything that "re-anchors to the lowest
  surviving id" is wrong. Measure before prescribing.
- **A test that passes without exercising the code is worse than none.** Five were caught
  in phase 1. Make it fail first.
- **The App tests run inside the real app** (`TEST_HOST` in `project.pbxproj`), so
  `xcodebuild test` executes `LightboxApp.main()` before any test does.
  `App/Lightbox/LaunchEnvironment.swift` is the guard: under XCTest's environment — or an
  explicit `LIGHTBOX_TEST_HOST=1`, the opt-in for a harness that sets none of XCTest's
  variables — it hands `BrowserView` no index at all, and `BrowserModel.init(at:)` has
  **no default argument**, so `IndexStore.defaultURL` is unreachable except through that
  one function. Don't reintroduce the default, and don't hardcode
  `BrowserView.launchIndexURL`: that is how a test run came to create, migrate and
  WAL-switch the user's real `~/Library/Application Support/Lightbox/index.sqlite` (#15).
- **The test suites build Debug only, and since #30 that is a requirement, not a
  habit.** `App/LightboxTests/CooperativePoolTests.swift` uses `@testable import
  LightboxCore`, which needs `ENABLE_TESTABILITY`, and that is set on the **Debug**
  configuration alone (`project.pbxproj`, one occurrence). So
  `xcodebuild test -configuration Release` does not compile, and neither does
  `swift test -c release` for the same reason on the Core side. Nothing runs either
  today — the scheme's TestAction is Debug and CI passes no `-configuration` — so this
  is a constraint to know, not a breakage. It was left this way deliberately rather
  than adding `ENABLE_TESTABILITY = YES` to Release: testability in Release costs
  cross-module optimization and adds symbols to the shipping binary, which is a poor
  trade for a test-only import. If Release testing is ever wanted, add the setting to
  the Release config then — and expect the pbxproj to be edited by hand.
