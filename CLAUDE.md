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
Core/     LightboxCore — headless SwiftPM package; all logic, all 477 tests. No AppKit/SwiftUI.
App/      Lightbox.xcodeproj — SwiftUI shell over Core; 63 tests. Depends on Core as ../Core.
docs/     spec, plan, notes, HANDOFF.md, and docs/agents/ (issue conventions).
scripts/  make-fixture-library.swift (50k benchmark library), sync-labels.sh.
```

```bash
cd Core && swift test                                                     # ~15 s on M4
cd App  && xcodebuild -scheme Lightbox -destination 'platform=macOS' test  # ~3 s after build
cd Core && LIGHTBOX_BENCH=1 swift test --filter Benchmark --no-parallel   # needs ~/lightbox-bench
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
  removed when the store is released.
- **Blocking work never runs on the cooperative pool.** That pool is exactly
  `activeProcessorCount` threads wide and never grows, so a thread parked in file IO,
  in SQLite's busy wait, or in a pipe read from exiftool is a thread the process has
  lost. Three of those stalled the CI job about one run in two (#28). `IndexCoordinator`
  and `MetadataWriter` therefore run their bodies on their own `DispatchSerialQueue`
  through `unownedExecutor`; blocking work that is *not* actor-isolated — the hashing
  pass's task-group children — hops through `BlockingWork.run`. Anything new in Core
  that blocks belongs behind one of those two, and `CooperativePoolTests` fails if it
  does not. Reproduce a narrowed pool with
  `env LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test`, and `sample <pid> 5` if it
  hangs — the sample *is* the diagnosis.
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
