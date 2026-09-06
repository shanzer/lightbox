# The 50,000-image measurement

Task 18. The spec refused to spend the `NSCollectionView` complexity budget
before there was a number. These are the numbers.

**Headline: `LazyVGrid` survives. Keep it.** The two thresholds that failed are
not the grid — one is the indexing pipeline and one is row decoding in the
search path. Both were already named as suspects, and neither is fixed here.

**These numbers are a lower bound taken on the wrong machine.** They were
measured on an Intel Mac; the app targets an M4 Mac mini. See
[What must be re-measured on the M4](#what-must-be-re-measured-on-the-m4)
before treating the decision as final.

## Hardware and software

| | |
|---|---|
| CPU | Intel Core i9-10910 @ 3.60 GHz, 10 cores / 20 threads |
| Memory | 72 GB |
| Storage | Internal APFS SSD (fixture library and index both on it) |
| OS | macOS 26.6.2 (25G83) |
| Toolchain | Apple Swift 6.3.2 (swiftlang-6.3.2.1.108) |
| Date | 2026-09-06 |

The plan's platform decision assumed Apple Silicon. Every figure below is from
an x86 machine with no unified memory, no AMX, and a different media engine.
Where an Intel result is *worse* than the threshold, the M4 may well clear it;
where it is *better*, the M4 will almost certainly also be better. That
asymmetry is what makes the grid decision safe to take here and the pipeline
decisions unsafe to take here.

## The fixture library

`scripts/make-fixture-library.swift` writes 50,000 JPEGs into
`~/lightbox-bench/2019/01…12` — on the internal disk, so the measurement is not
really a measurement of the external drive the repo lives on.

- 50,000 files, **14 GB**, generated in **355 s**.
- Five dimension classes cycled per index: 640×480, 1920×1080, 4032×3024,
  200×200, 3000×2000. So exactly 30,000 files have `width >= 1920`.
- EXIF `DateTimeOriginal` per file, twelve month folders, so date sort and the
  recursive walk are both exercised.

The script departs from the brief's draft in one way that matters: each image
gets a deterministic 40×40 block mosaic rather than two flat rectangles. A
flat-filled JPEG compresses to a few kilobytes and decodes almost for free,
which would have made file size, QuickLook cost and scroll smoothness
optimistic by an order of magnitude. With the mosaic a 12 MP frame lands around
720 KB — still smaller than a real photo, but the same order of magnitude
rather than three below it.

Generation is parallel (`DispatchQueue.concurrentPerform`) because 50,000
serial encodes is half an hour of wall clock that measures nothing.

## Results

| Measure | Threshold | Measured (Intel) | |
|---|---|---|---|
| Tier 0 over 50k files | under 3 min | **179–182 s** | ✗ *at the line* |
| Folder open → first thumbnails, warm index | under 1.5 s | **≈1.2–1.4 s** | ✓ *barely* |
| Folder open → first thumbnails, cold index | under 1.5 s | **≈180 s** | ✗ |
| Median scroll frame time | ≤ 16.7 ms | **12.1 ms** | ✓ |
| 99th-percentile scroll frame time | ≤ 33 ms | **19.9 ms** | ✓ |
| Peak resident memory while scrolling | under 2 GB | **724 MB** | ✓ |
| `width >= 1920` over 50k rows | under 100 ms | **474 ms** | ✗ |

Scroll and memory figures are from a headless harness, not a human scrolling a
window — see [What a human still has to measure](#what-a-human-still-has-to-measure).

### Indexing, in detail

`Benchmark.indexingPass`, run twice against the same tree:

| Stage | Time |
|---|---|
| Walk only (50,000 entries) | 1.85 s |
| Tier 0, cold (empty database) | 182.27 s / 179.37 s |
| Tier 0, warm rescan (nothing changed) | 20.66 s |
| `width >= 1920` (30,000 rows returned) | 0.474 s |
| Every row in the tree (50,000 rows) | 0.808 s |
| Peak RSS of the indexing process | 244 MB |

The warm rescan is the interesting decomposition. It walks all 50,000 files and
does one `needsReindex` read per file, skipping every one — 20.66 s, of which
1.85 s is the walk. So **the read round trips alone cost ≈0.38 ms per file**,
and the remaining ≈160 s of the cold pass is the ImageIO header read plus one
write transaction per file, ≈3.2 ms each.

That is the serial-loop cost flagged in Task 10 and it is now a number rather
than a worry: 50,000 files is 50,000 round trips, and at 3 min it is exactly on
the threshold on this hardware. **Not fixed here** — the brief is explicit that
Task 18 measures and does not repair. The obvious lever is batching the
`needsReindex` reads and the upserts into transactions of a few hundred rows.

### The `width >= 1920` query is not missing an index

The threshold table says a failure here means "an index is missing". It does
not. `files_on_dimensions ON files(width, height)` exists, and the plan for the
compiled query is:

```
MULTI-INDEX OR
  INDEX 1  SEARCH files USING INDEX sqlite_autoindex_files_1 (path=?)
  INDEX 2  SEARCH files USING INDEX sqlite_autoindex_files_1 (path>? AND path<?)
USE TEMP B-TREE FOR ORDER BY
```

Timed against the persisted 50,000-row index with the `sqlite3` CLI (each
figure includes ~15 ms of process start):

| | Time |
|---|---|
| `SELECT id`, scope + `width >= 1920`, no `ORDER BY` | 51 ms |
| `SELECT id`, same, with the compiled `ORDER BY` | 59 ms |
| `SELECT *`, same, 30,000 rows | 176 ms |
| `SELECT *`, scope only, 50,000 rows | 465 ms |

So the scan and the filter cost ~35 ms, the temp-B-tree sort costs ~8 ms, and
everything else is **materialising and decoding rows**. In Swift the same query
takes 474 ms against sqlite3's 176 ms, so GRDB is decoding 30,000 22-column
`FileRecord` structs at ≈13–16 µs each — roughly 300 ms of the 474 ms.

Adding an index would buy nothing. The fixes that would are all in the shape of
the query, not the schema: fetch the columns the grid actually renders rather
than `SELECT *`, or page the result rather than materialising the whole answer
before the first cell is drawn. Left for a later task.

### Thumbnails

`ThumbnailCache` at 512 px — what a cell asks for at the default 256 pt
thumbnail side on a Retina display, after `ThumbnailCell`'s 256 px
quantisation — 40 at a time, which is roughly one screenful and is how the grid
issues them (one `.task` per visible cell, all at once):

| | Time |
|---|---|
| First screenful, QuickLook agent cold | 0.400 s |
| Second screenful, different files, steady state | 0.555 s |
| First screenful again, cache hit | 0.002 s |

≈14 ms per thumbnail at 40-way concurrency, and essentially free once cached.

**Watch out for Spotlight.** The same measurement taken minutes after
generating the library read **22.589 s** for the first screenful, 56× worse,
because `mds` was importing 50,000 brand-new JPEGs at the time. Let the machine
settle before believing any thumbnail number.

### Folder open

The 1.5 s threshold has two answers, because `BrowserModel.reloadThenRescan`
queries the index first and rescans second.

**Warm** (folder already indexed) — the query returns immediately from the
index and the grid paints:

```
0.808 s  query every row in the tree
0.020 s  LazyVGrid first layout
0.4–0.55 s  first screenful of thumbnails
≈1.2–1.4 s
```

Inside the threshold, with no margin worth relying on. Note that the largest
term is the row decoding from the previous section, not the grid.

**Cold** (first ever open of the folder) — the query returns zero rows because
nothing is indexed yet, and `rescan` only reloads the grid *after* `indexTier0`
returns. So the window shows an empty grid for the entire tier 0 pass:
**≈180 s to first thumbnail**. This is a real product problem, it is a
consequence of the same serial pipeline, and it is not something the grid can
fix. Recorded here rather than repaired.

### The grid itself

`GridBenchmarkTests.measureGridAtFiftyThousandRecords` hosts the real
`PhotoGridView` over 50,000 records in a real 1440×900 `NSWindow`, forces a
layout, then walks the scroll offset down the document in 152 pt steps (about
one row at a time — the worst case for cell realisation) and times each step.

| | Debug | Release |
|---|---|---|
| Records handed to the grid | 50,000 | 50,000 |
| Document height | 872,304 pt | 872,304 pt |
| First layout | 18 ms | 20 ms |
| Scroll steps timed | 3,000 | 3,000 |
| Median step | 12.69 ms | 12.12 ms |
| p99 step | 20.17 ms | 19.91 ms |
| Worst step | 27.61 ms | 26.74 ms |
| Peak RSS | 772 MB | 724 MB |

Two things stand out.

**`LazyVGrid` is genuinely lazy at this size.** An 872,304 pt document lays out
in 18 ms, which is only possible if it is realising a screenful and not 50,000
cells. There is no cliff.

**Debug and Release are the same.** That is the strongest signal in the whole
measurement: the cost is inside AppKit and SwiftUI layout, which is already
optimised in both configurations, and essentially none of it is our Swift. No
amount of tuning `PhotoGridView` would move these numbers — and equally, the
grid is not carrying any accidental per-record work.

## Decision

**Keep `LazyVGrid`. Do not build the `NSCollectionView` bridge.**

Both grid thresholds pass with roughly 25–40% of headroom on hardware that is
slower than the target, in a harness that is biased pessimistic in the ways
that matter (layout forced synchronously per step, one row per step, no
coalescing). The complexity budget the spec reserved for an `NSCollectionView`
bridge stays unspent, and phases 2–4 build on `LazyVGrid`.

The measurement did *not* clear the pipeline. Two follow-ups are owed, neither
in scope here:

1. **Tier 0 is at its threshold** — 180 s for 50k, one read and one write
   transaction per file. Batch the transactions.
2. **A cold folder open shows an empty grid for the whole tier 0 pass.** The
   grid should be fed incrementally from progress, or the query re-run
   periodically during the pass.
3. **Searches decode every matching row before the first cell draws** — 474 ms
   for 30,000 matches, 300 ms of it GRDB decoding. Page the query or narrow the
   columns.

## What must be re-measured on the M4

The decision above is provisional until these are re-taken on the target
machine. Every one of them is a `swift test` or an `xcodebuild test` away.

- [ ] **Scroll frame times and memory** (`GridBenchmarkTests`). The M4 should be
      faster, so this is confirmation rather than a real risk — but the M4 mini
      has far less RAM than this machine's 72 GB, and the 724 MB peak was
      measured where memory pressure was zero. **Memory is the one grid number
      that could plausibly go the wrong way**, because eviction behaviour under
      pressure is not exercised here at all.
- [ ] **Tier 0 over 50k.** Sitting on the threshold on Intel; single-threaded
      and I/O-bound, so the M4's faster cores and much faster SSD should clear
      it. If it does, the batching work drops in priority. If it does not, it
      is the top of the phase 2 list.
- [ ] **The `width >= 1920` query.** 474 ms here, of which ~300 ms is row
      decoding — pure single-thread CPU, which is where the M4 gains most. It
      will improve, but 4.7× is a lot to make up; expect this still to fail.
- [ ] **Real scroll frame times with a human** (below). Nothing headless
      substitutes for this, on either machine.
- [ ] Re-run on a **quiet** machine: no Spotlight import of the fixture library
      in flight, and no backup client uploading it.

## What a human still has to measure

Two of the six thresholds cannot be taken without someone driving the window,
and the numbers in the table above are proxies for them.

**Scroll frame times.** `PhotoGridView` carries a `--measure-frames` overlay:

```bash
open -a Lightbox --args --measure-frames
# ⌘O → ~/lightbox-bench, turn on Include Subfolders,
# then scroll continuously from top to bottom at speed.
```

It samples the interval between scroll geometry changes, which during a
continuous scroll is one sample per presented frame, and shows a running median
and p99. It says nothing while the view is still, so the samples are only
meaningful for a scroll that never stops.

The headless harness is not the same thing: it forces layout synchronously and
never presents to a display, and its cells are mostly placeholders because
thumbnails resolve asynchronously. A step longer than 16.7 ms could not have
been a 60 Hz frame, so the harness numbers are a floor on frame cost — the
overlay can only report worse, never better.

**Peak resident memory while scrolling.** Read the real `Lightbox` process in
Activity Monitor during that same scroll. The 724 MB above is the *test host*
after 3,000 layout steps, with the thumbnail pipeline only partially exercised.

There is also no way to open a folder from the command line — the app takes its
root from `NSOpenPanel` only — so even the folder-open timing above is
reconstructed from its parts rather than measured end to end in the app. A
`--open <path>` launch argument would make the whole measurement scriptable and
is worth adding before the M4 re-run.

## Re-running the whole thing

```bash
# 1. Fixtures (~6 min, 14 GB, on the internal disk).
swift scripts/make-fixture-library.swift ~/lightbox-bench 50000

# 2. Let the machine settle — Spotlight will be importing 50,000 new files,
#    and a backup client may start uploading 14 GB. Exclude ~/lightbox-bench
#    from both if you can. Wait for `mds` to go quiet.

# 3. Indexing and thumbnails (~4 min).
cd Core && LIGHTBOX_BENCH=1 swift test --filter Benchmark --no-parallel

# 4. The grid (~1 min).
TEST_RUNNER_LIGHTBOX_BENCH=1 xcodebuild -project App/Lightbox.xcodeproj \
  -scheme Lightbox -destination 'platform=macOS' \
  -only-testing:LightboxTests/GridBenchmarkTests test

# 5. Frame times, by hand.
open -a Lightbox --args --measure-frames
```

Every benchmark is `.disabled` unless `LIGHTBOX_BENCH=1` is set, so a normal
`swift test` never spends minutes on any of this — and re-running the
measurement on new hardware needs an environment variable rather than an edit
to the test traits and a promise to put them back.

The fixture library is 14 GB and is not deleted by anything here. Remove it
with `rm -rf ~/lightbox-bench` when you no longer need to re-run.
