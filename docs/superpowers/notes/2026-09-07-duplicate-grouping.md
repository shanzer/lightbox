# Duplicate grouping — the near tier's ceiling

Issue #10. The exact tier needed a number to confirm it was not a problem; the
near tier needed one to choose `DuplicateFinder.nearTierCeiling`. These are
those numbers.

**Headline: brute force wins against the proposed prefix filter, and 100,000
rows is as far as the 5 s budget reaches.** The pairwise scan is `n(n-1)/2` XOR +
popcount over 64-bit values, and at 50,000 rows it costs about 1 s — a fifth of
the budget the issue sets. The proposed 16-bit-prefix bucketing is not
implemented, and
[the arithmetic says it should not be](#why-there-is-no-bucketed-fast-path).
This is not a claim that brute force beats every alternative; if the ceiling
ever binds, [there is a right thing to reach for](#if-the-ceiling-ever-binds).

**These numbers are synthetic.** They were taken over generated index rows, not
over the 50,000-image fixture library, which does not exist on this machine.
See [What is still owed](#what-is-still-owed) before treating the exact tier's
number as settled.

## Hardware and software

| | |
|---|---|
| CPU | Apple M4 (Mac mini) |
| Memory | 32 GB |
| Storage | Internal APFS SSD (index on it; no photo files involved) |
| OS | macOS 26.5.2 (25F84) |
| Toolchain | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), arm64 |
| Build | **release** — see [Debug is not a factor away](#debug-is-not-a-factor-away) |
| Date | 2026-09-07 |

## What was measured

`measureDuplicateGroupingScaling` in `Core/Tests/LightboxCoreTests/BenchmarkTests.swift`,
run as:

```bash
cd Core && LIGHTBOX_BENCH=1 swift test -c release \
    --filter measureDuplicateGroupingScaling --no-parallel
```

It builds a temporary `IndexStore` of `n` synthetic rows and times
`DuplicateFinder.exactGroups(for:)` and `nearGroups(for:excluding:)` separately
over `SearchQuery(scope: .everywhere)`, with the ceiling lifted so the large
sizes report the cost the ceiling exists to refuse rather than reporting the
refusal.

Each row carries a unique `content_hash`, a unique `image_hash` except every
hundredth row, which repeats its predecessor's (so `n/100 - 1` planted exact
groups of two, each with two content sub-groups — the metadata-edit shape), and
a uniformly random 64-bit `phash`, except a planted cluster of twenty within 12
bits of one base.

**Where synthetic hashes are and are not a fair stand-in.** The near tier's
*scan* compares every pair whatever the data, so its cost is a function of `n`
alone and uniform hashes measure it exactly. What they under-state is the
*result*: a real library of one person's photographs clusters, so there are
more matches to assemble afterwards. Uniform 64-bit hashes still produce chance
matches at these sizes. P(distance ≤ 12) = Σ_{k≤12} C(64,k) / 2⁶⁴ = 2.283e-7
per pair, so `n(n-1)/2 × p` gives 11 expected pairs at 10,000, 285 at 50,000
and 4,567 at 200,000 — against 6, 276 and 4,303 *groups* observed. Groups are
the lower number because the star cover folds a record that matches two seeds
into one group; the agreement is close enough to confirm the scan is examining
every pair. This is why the near-group counts below are not zero.

## The numbers

Four runs, all reported, because a single run over-states the precision of
every one of these figures. Group counts were identical in all three, which is
the check that each run examined the same pairs.

| rows | exact tier | exact groups | near tier (r1 / r2 / r3 / r4) | near groups |
|---:|---:|---:|---:|---:|
| 10,000 | 0.002–0.003 s | 99 | 0.059 / 0.042 / 0.044 / 0.043 s | 6 |
| 25,000 | 0.004–0.015 s | 249 | 0.407 / 0.225 / 0.230 / 0.227 s | 85 |
| 50,000 | 0.008–0.014 s | 499 | 1.315 / 0.857 / 1.391 / 0.862 s | 276 |
| 100,000 | 0.016–0.027 s | 999 | 3.365 / 3.395 / 4.127 / 3.379 s | 1,080 |
| 200,000 | 0.033–0.055 s | 1,999 | 13.652 / 13.656 / 15.788 / 13.649 s | 4,303 |

Run 4 is post-rebase onto `main` at 8208abd (HEIC image hashing merged) and is
the run the committed code was measured on.

Run-to-run spread is up to 62% at 50,000 and 22% at 100,000 — enough that the
ceiling must be read off the measurements rather than off a fitted curve. Run 3
included the `COUNT(*)` pre-check added for the ceiling, which is a small part
of the difference; the rest is scheduling and thermal noise on a machine doing
other things.

Against the issue's budgets of **500 ms** for the exact tier and **5 s** for the
near tier at 50,000 rows: the exact tier clears by a factor of at least 35, the
near tier by a factor of at least 3.6 on the worst run.

The near tier's growth is quadratic — 100k→200k is 3.8–4.1×, 50k→100k is
2.6–3.0× (under 4× because the smaller sizes still carry fixed setup). A fit
would put the 5 s budget somewhere around 110,000–120,000 rows, but the
100,000 point alone moved 22% between runs, so the ceiling is set to the
largest size that came in under budget on **every** run rather than to the
first size the curve says should:

`DuplicateFinder.nearTierCeiling = 100_000`. Round down, and raise it only when
there is a measurement at the higher size. Choosing a user-visible multi-second
stall on the strength of an extrapolation is not a trade worth making for 20%
more headroom. Past it the near tier
returns nothing and sets `DuplicateReport.nearTierSkipped` to the scope size, so
the view can say "too many files to compare here" rather than "no
near-duplicates" — a distinction that matters when the answer is used to delete
photographs. The exact tier has no ceiling; it does not need one.

The exact tier's numbers barely move with `n` because they are an indexed
`GROUP BY` plus row materialisation for the *matched* rows only, and the
planted matches grow linearly. This is the opposite of the phase-1 finding that
`width>=1920` costs 474 ms at 50k: that query materialises 30,000 rows, this one
materialises about 1,000.

## Why there is no bucketed fast path

The issue proposed "bucketing by the first 16 bits" above the ceiling. That
would be a *filter*, and it is not a sound one at this threshold.

Split 64 bits into `B` bands. Two hashes at distance ≤ `T` must agree exactly on
at least one band only if `B > T` — otherwise the differing bits can be spread
one per band with none left over. At `T = 12` that needs **13 bands**, so bands
of 4–5 bits, and 13 passes over buckets averaging `n/32` entries each:

    13 × 32 × C(n/32, 2) ≈ 13 × n²/64   against   n²/2 for brute force

about a 2.5× saving, before the cost of deduplicating candidate pairs across 13
passes and before the loss of the tight contiguous scan. Bucketing on a single
16-bit prefix, as proposed, is 1 band of 16 bits, which finds only pairs that
agree exactly on the top quarter of the hash — it would silently miss the
majority of genuine near-duplicates.

An approximate filter is the wrong trade for a view whose output is a deletion.
So the near tier is exhaustive up to the ceiling and refuses past it, and the
refusal is reported rather than disguised as an empty result.

### If the ceiling ever binds

The thing to reach for is **multi-index hashing**, not a prefix filter: split
the 64 bits into 4 bands of 16 and index each band separately, then for each
probe enumerate every band value within radius 3 of the probe's band and look
it up. Pigeonhole again — 12 differing bits over 4 bands puts at most 3 in some
band — but this time it is *exact*, because the radius is searched rather than
assumed to be zero. The cost is Σ_{k≤3} C(16,k) = 697 lookups per band per row,
so ~2,800 hash-table probes per row instead of `n` comparisons; it overtakes
brute force somewhere above a few hundred thousand rows, and it returns exactly
the same pairs. Worth building when a real library reaches the ceiling, and not
before — the 120,000-row ceiling is well past the library this app was written
for.

## Debug is not a factor away

The near tier is a tight scalar loop over an unsafe buffer, and the two build
configurations are not comparable:

| rows | debug | release | ratio |
|---:|---:|---:|---:|
| 10,000 | 4.007 s | 0.059 s | 68× |
| 25,000 | 24.819 s | 0.407 s | 61× |
| 50,000 | 111.401 s | 1.315 s | 85× |

(Release column from run 1, for comparability with the debug run taken beside
it.)

A ceiling chosen from a debug build would have been about 12,000 rather than
100,000 — an order of magnitude of usable library size thrown away. Both
duplicate benchmarks therefore refuse to run in a debug build (`isDebugBuild` in
`BenchmarkTests.swift`) rather than print a number somebody might act on, which
also keeps the documented `LIGHTBOX_BENCH=1 swift test --filter Benchmark`
invocation to a visible skip instead of a forty-minute scan.

## Fixture distances, measured

The acceptance test's fixtures, verified before the assertions were written
rather than after — all four written by ImageIO, so CI runs them:

| copy | `content_hash` | `image_hash` | phash distance from the original |
|---|---|---|---|
| byte-identical copy | same | same | 0 |
| EXIF rewritten (different make, model, capture time) | **differs** | **same** | 0 |
| re-encoded at quality 0.25 | differs | **differs** | **8** |

The middle row is the whole reason `image_hash` exists, and it is reproducible
without exiftool: writing the same `CGImage` through
`CGImageDestinationAddImage` with different metadata leaves the JPEG scan data
byte-identical, and the JPEG segment denylist excludes the APP1 that changed.
The last row is the whole reason the near tier exists: 8 bits, inside the
threshold of 12, invisible to both exact hashes.

## What is still owed

1. **The 50,000-image fixture library run.** `measureDuplicateGroupingOverTheFixtureLibrary`
   is written and skips visibly; `~/lightbox-bench` does not exist on this
   machine (14 GB, `scripts/make-fixture-library.swift`). Only that run
   measures the exact tier over *real* hash distributions and a real
   `image_hash` index rather than synthetic rows. Until it runs, the exact
   tier's 500 ms budget is confirmed only against generated data.
2. ~~The live check over the real library.~~ Done the same day; see
   [Live run over the real archive](#live-run-over-the-real-archive) below.
3. **The near tier's result cost at a realistic clustering.** Synthetic uniform
   hashes produce few matches. A library with a thousand near-identical burst
   frames produces a large match set, and the fetch-and-assemble step after the
   scan is linear in that set, not in `n`.

## Live run over the real archive

Run on 2026-09-07 on the M4 mini against the whole of
`/Volumes/rockit88/03_DEDUPED_ARCHIVE/photos` (an external drive, read-only),
into a throwaway index under the scratchpad, with the PR #20 code. The
grouping algorithm is unchanged on `main`; the later single-snapshot read and
the 100,000 ceiling do not change the output at this size.

| | |
|---|---|
| rows | 26,372 (tier 0: 323.8 s, 5 corrupt files failed the metadata read; tier 1: 1,383 s, 0 failures, ~19 files/s over 136 GB) |
| `report(for:)` | **0.32 s** |
| exact groups | 106, of which 80 have more than one `content_hash` sub-group |
| near groups | 5,078 (8,499 matches) |
| `nearTierSkipped` | nil |

`image_hash` was NULL on 4,345 rows: 4,323 by rule (NEF, TIF, DNG, PSD have
none) and 18 that have a rule but refused — 16 extension-misnamed files
(`.HEIC` that is JPEG, `.jpg` that is JPEG 2000 or PNG) and 2 JPEGs with no
EOI marker. All safe refusals; #26 decides whether to sniff magic bytes.

Near-tier distance histogram over all 8,499 matches:

| d | 0 | 2 | 4 | 6 | 8 | 10 | 12 |
|---|---|---|---|---|---|---|---|
| matches | 2,728 | 1,279 | 677 | 705 | 768 | 893 | 1,449 |

Only even distances occur, and that is arithmetic, not a bug: a
median-threshold 64-bit pHash has exactly 32 bits set, so two of them differ by
`64 - 2·|A ∩ B|` bits. 73.6 % of near groups lie entirely inside one
`YYYY-MM-DD` folder; 26 % span dates, 1,228 of them across years.

Four groups were inspected by eye, by the coordinating agent and not only the
one that ran the harness:

- **An exact group** with one `image_hash` and three `content_hash`es
  (`low_confidence/2025-11-24`): the same photograph three times. The byte
  differences are exactly the sizes of the embedded EXIF thumbnails
  (278,079 − 276,680 = 15,292 − 13,893). True positive, and the case
  `image_hash` exists for.
- **Near, d = 2**: a vintage scan and its retouched restoration. True positive.
- **Near, d = 12, one day-folder**: three different frames of one parrot on
  one perch. Same session, not duplicates; the visible distance is what tells
  the user.
- **Near, d = 12, across 2011/2017/2020 and NEF/JPEG/PNG**: the seed matched
  three unrelated photographs. Two of the three matches are a genuine
  JPEG/PNG duplicate of each other (identical `phash`, d = 0), which no exact
  group can ever contain because the two rules hash different bytes. A
  transitive cluster would have fused all four into one "duplicate set"; the
  star shape keeps each match against the seed with its own distance.

No exact group contained two visibly different photographs. The 12-bit bucket
does admit unrelated photographs, and it is the second-largest bucket. Whether
the threshold stays at 12 (HANDOFF §6, set against a measured 0–4 bit
cross-tool divergence), drops, or becomes adjustable in the duplicate view
(#11) is an open product decision recorded on #10; the view should at least
sort by distance ascending and show it as a first-class column.

Still owed after this run: item 1 above (the 50k fixture library) and item 3
(result cost under realistic clustering — this archive is already deduplicated,
so its match set is small).
