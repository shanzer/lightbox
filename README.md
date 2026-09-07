# Lightbox

A native macOS photo-library browser and deduplicator. It walks a folder tree on any
volume, indexes every image into SQLite with its dimensions, camera, capture time, and
three hashes — whole-file, metadata-independent pixel data, and a perceptual DCT hash —
and puts a fast grid, a folder tree, and a structural search over the result. It exists to
replace Bridge for browsing and dimension search over a large library on an external
drive, and then to act on what it finds: exact and near duplicates, moves and deletes with
an undo journal, EXIF editing.

**Status:** phase 1 (browse and structural search) is complete and verified on Apple
silicon. Phase 2 (file operations, EXIF editing, the duplicate view) is next. The spec's
§13 lays out all four phases.

## Layout

| | |
| --- | --- |
| `Core/` | `LightboxCore` — a headless SwiftPM package with no AppKit/SwiftUI dependency. All the logic and all the tests live here. |
| `App/` | `Lightbox.xcodeproj` — the SwiftUI shell. Wires `Core` to views and nothing more. |
| `docs/` | The binding spec, the executed phase-1 plan, benchmark notes, `HANDOFF.md`, and `agents/` (issue conventions). |
| `scripts/` | `make-fixture-library.swift` generates the 50k-image benchmark library; `sync-labels.sh` applies `.github/labels.json`. |

## Building and testing

Requires Xcode 26 (Swift ≥ 6.2, macOS 26 SDK). The only dependency is GRDB.swift,
fetched on first build.

```bash
cd Core && swift test                                                     # 469 tests
cd App  && xcodebuild -scheme Lightbox -destination 'platform=macOS' test  # 61 tests
```

The app is unsigned and unsandboxed by design; macOS will ask for folder access the first
time you open a library and may ask again after a rebuild.

Benchmarks are off unless `LIGHTBOX_BENCH=1` and need the fixture library:

```bash
swift scripts/make-fixture-library.swift ~/lightbox-bench 50000   # ~14 GB — exclude from backup first
cd Core && LIGHTBOX_BENCH=1 swift test --filter Benchmark --no-parallel
```

## Working on it

Start with **`docs/HANDOFF.md`** — it is the map, the list of traps, and the list of what
is still owed. Then **`CONTRIBUTING.md`** for the branch → PR flow and
**`docs/agents/issue-conventions.md`** for how issues are written and prioritised here.
`CLAUDE.md` carries the same for agents.

Every change lands through a PR with `.github/workflows/ci.yml` green: both test suites on
a GitHub-hosted Apple-silicon runner.
