# Issue conventions

How issues in this repo are titled, labelled, and written. The `/issue` and `/intent`
skills both work from this file — change it here and both follow.

For the `gh` commands themselves see `issue-tracker.md`. For what the triage labels mean
see `triage-labels.md`.

## Title prefixes

A prefix is a scanning aid, not a taxonomy to be satisfied. Use one when it tells a reader
something the title alone doesn't; leave it off when the issue spans areas or none of them
fits. Never stack two.

**Area prefixes** — what part of the system the work lands in. These follow the module
layout in `Core/Sources/LightboxCore/` and the phase plan in the spec (§13):

| Prefix    | Covers                                                                                   |
| --------- | ---------------------------------------------------------------------------------------- |
| `UI:`     | `App/` — SwiftUI views, the grid, folder tree, menus, selection, windows, thumbnails     |
| `INDEX:`  | `Walker`, `MediaType`, `Index/`, `Coordinator/` — enumeration, schema and migrations, the two-tier pass, integrity and rebuild |
| `HASH:`   | `Hashing/` — `content_hash`, `image_hash`, `phash`, the per-format parsers, duplicate detection |
| `SEARCH:` | `Search/` — the query compiler, FTS5, facets, predicates, saved searches                 |
| `FILES:`  | Phase 2 file operations — move/copy/delete, the undo journal, companion files, EXIF writing via exiftool |
| `SEC:`    | Untrusted input — hostile image files (chunk-flood, oversized headers), the query compiler's injection surface, anything that shells out |
| `DOC:`    | Documentation — the spec, `HANDOFF.md`, and code comments that have drifted             |

Phase 3 (Vision) and phase 4 (embeddings) will earn prefixes when they are planned; don't
pre-invent them.

**Document-type prefixes** — what kind of issue this is, rather than where it lands. These
outrank an area prefix: a PRD about the grid is `PRD:`, not `UI:`, because how a reader
should treat it matters more than which files it touches.

| Prefix   | Means                                                                      |
| -------- | -------------------------------------------------------------------------- |
| `PRD:`   | A design document. The deliverable is a decision, not a patch.              |
| `[EPIC]` | A tracking issue. The work lives in its children; this one holds the shape. |

## Labels

The canonical set lives in `.github/labels.json` and is applied with
`scripts/sync-labels.sh`. Edit the file, re-run the script — don't create labels by hand,
or the tracker drifts from what the skills expect to find.

**Type** — `bug` when something is broken against its own stated intent, `enhancement`
when it works as designed and the design should change, `documentation` for docs-only
work.

**Priority** — the ladder ranks by harm to the user's photo library, not by effort.
Lightbox indexes, deduplicates, and (from phase 2) moves and deletes files that often
have no other copy. Calibrate against that:

| Label | Means                                                                   |
| ----- | ----------------------------------------------------------------------- |
| `P0`  | **A photo can be lost, overwritten, or misattributed.** A hash landing on another file's row; a duplicate view that would delete a non-duplicate; a move or delete with no journal entry; an EXIF write that corrupts the file. Fix before shipping anything. |
| `P1`  | High — the index is corrupted and does not self-heal, the app cannot open a library, a search silently returns the wrong set, an unreachable volume takes the index down. |
| `P2`  | Medium — worth doing, not urgent. A visible defect with a workaround; a measured performance regression. |
| `P3`  | Low — polish, papercuts, small correctness nits.                        |
| `P4`  | A note. Informational, or a latent footgun with no live symptom.         |

A defect that is invisible to users is not therefore low priority. Silent breakage —
a hashing pass that skips files without saying so, a guard that swallows `SQLITE_BUSY`,
a staleness check that stops firing — ranks by what broke, not by how loudly. The index
is rebuildable; the photos are not. Anything on the wrong side of that line is `P0`.

**Triage** — see `triage-labels.md` for the full table. In practice the choice is between
two:

- `ready-for-agent` — an AFK agent could pick this up and finish it without asking anyone
  a question.
- `needs-triage` — anything else.

Be honest about which. `ready-for-agent` on an underspecified issue produces an agent that
guesses, and a guessed decision is worse than a blocked one because it arrives looking
finished. The bar is below.

## The ready-for-agent bar

All four, or it isn't ready:

1. **Located.** The relevant code is identified by path and line, or the change is
   somewhere no reasonable implementer could misplace.
2. **Decided.** No open design question. If the issue contains the words "should we" or
   "we could either", it is not ready. If it contradicts the spec, the spec amendment is
   part of the decision.
3. **Testable.** Acceptance criteria state observable outcomes, not intentions. "Grid
   feels faster" is not testable; "the 50k cold open renders the first row in under
   2 s" is.
4. **Bounded.** What's explicitly *not* in scope is stated, so an agent doesn't annex
   adjacent work while it's in there.

And a fifth, for any change the test suite cannot prove: **say what live check would
prove it.** See the next section for what that means here.

## Verification

The automated checks, in the order to run them:

```bash
cd Core && swift test                                             # 469 tests, ~15 s on M4
cd App  && xcodebuild -scheme Lightbox -destination 'platform=macOS' test   # 63 tests
cd Core && LIGHTBOX_BENCH=1 swift test --filter Benchmark --no-parallel     # needs ~/lightbox-bench
```

The benchmark line needs the 50k fixture library
(`swift scripts/make-fixture-library.swift ~/lightbox-bench 50000`, ~14 GB, exclude it
from backup first). Any change to the grid, the index passes, or the query compiler
should quote before/after numbers from it; thresholds are in
`docs/superpowers/notes/2026-09-05-grid-measurement.md`.

Things the suites structurally cannot prove, and the live check that does. An issue
touching one of these must name it in **Acceptance**:

| Change touches                              | Live check                                                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Index writes, `setHashes`, migrations       | Open a real folder, then `sqlite3 ~/Library/Application\ Support/Lightbox/index.sqlite` and inspect the rows you expect changed — and the ones you don't |
| Volume / unreachable-root handling          | Physically unplug the external drive mid-hash. Simulated unmounts passed twice while the real one lost the index |
| Concurrency across windows                  | ⌘N with a folder already scanning; watch for `SQLITE_BUSY` in the log                            |
| Menu commands, focus, selection             | Run the app; ⌘A with the search field focused must select text, not the grid (the test can only warn) |
| Anything that shells out to exiftool        | Run it against a copy of a real file and diff `exiftool -a -G1` before and after; then confirm `image_hash` did not change |
| A new image-format parser                   | Feed it a 256 MB chunk-flood file and watch RSS; phase 1 found 4.37 GB before coalescing        |

Generic "verify manually" gets ignored; a named command gets run.

## Body shape

Adapt to the issue — a one-line papercut doesn't need six headings. These are the sections
that tend to earn their place:

- **Current behaviour** — what happens now, with the code that causes it quoted by path
  and line. This is the section that makes an issue actionable, and the one most often
  skipped.
- **Why it matters** — only when the harm isn't self-evident from the symptom.
- **Ask** — the change requested. Prescribe the outcome; leave the implementer room on
  approach unless the approach is the point.
- **Constraints and risks** — the hash invariants in `HANDOFF.md` §6 that must survive,
  schema migration, backward compatibility with an existing `index.sqlite`, anything
  that makes the obvious implementation wrong. If the work parses untrusted bytes, say
  so explicitly; the obvious parser is the unsafe one.
- **Acceptance** — testable outcomes, including the failure cases worth covering, and the
  live check from the table above where one applies.
- **Out of scope** — deliberate exclusions, and follow-up issues if they exist.

Quote real code rather than describing it. A reader who can see the three lines that cause
the bug doesn't have to trust the description. And check `docs/HANDOFF.md` §6 and §8
before diagnosing — most of the traps that make the obvious diagnosis wrong are already
written down there.
