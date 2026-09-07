# Duplicate grouping — the near tier's ceiling

Issue #10. The exact tier needed a number to confirm it was not a problem; the
near tier needed one to choose `DuplicateFinder.nearTierCeiling`. These are
those numbers.

**Headline: brute force wins, and 120,000 rows is where the 5 s budget runs
out.** The pairwise scan is `n(n-1)/2` XOR + popcount over 64-bit values, and
at 50,000 rows it costs about 1 s — a fifth of the budget the issue sets. The
proposed 16-bit-prefix bucketing is not implemented, and
[the arithmetic says it should not be](#why-there-is-no-bucketed-fast-path).

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
matches at these sizes — P(distance ≤ 12) ≈ 1.1e-7 per pair, so ~140 expected
at 50,000 — which is why the near-group counts below are not zero.

## The numbers

Two runs, both reported, because the smaller sizes are noisy enough that one
run would over-state their precision. Group counts were identical in both.

| rows | exact tier | exact groups | near tier (run 1) | near tier (run 2) | near groups |
|---:|---:|---:|---:|---:|---:|
| 10,000 | 0.003 s | 99 | 0.059 s | 0.042 s | 6 |
| 25,000 | 0.006–0.015 s | 249 | 0.407 s | 0.225 s | 85 |
| 50,000 | 0.012–0.014 s | 499 | 1.315 s | 0.857 s | 276 |
| 100,000 | 0.024 s | 999 | 3.365 s | 3.395 s | 1,080 |
| 200,000 | 0.050 s | 1,999 | 13.652 s | 13.656 s | 4,303 |

The two large sizes agree to within 1%, which is what the ceiling is derived
from; the small ones scatter by up to 50% because they are short enough for
scheduling noise to matter, and they are not load-bearing.

Against the issue's budgets of **500 ms** for the exact tier and **5 s** for the
near tier at 50,000 rows: the exact tier clears by a factor of 35, the near
tier by a factor of about 4.

The near tier's growth is clean quadratic — 100k→200k is 4.06×, 50k→100k is
2.56× (a little under 4× because the smaller sizes still carry fixed setup) —
so the 5 s budget lands at roughly 120,000 rows:

    3.365 s × (120/100)² = 4.84 s

Hence `DuplicateFinder.nearTierCeiling = 120_000`. Past it the near tier
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

## Debug is not a factor away

The near tier is a tight scalar loop over an unsafe buffer, and the two build
configurations are not comparable:

| rows | debug | release | ratio |
|---:|---:|---:|---:|
| 10,000 | 4.007 s | 0.059 s | 68× |
| 25,000 | 24.819 s | 0.407 s | 61× |
| 50,000 | 111.401 s | 1.315 s | 85× |

A ceiling chosen from a debug build would have been about 12,000 rather than
120,000 — an order of magnitude of usable library size thrown away. Both
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
2. **The live check over the real library.** Spot-checking groups by eye is the
   only thing that catches a wrong row assignment, and a wrong row assignment
   here is a deleted photograph. Not done: the library on `/Volumes/rockit88`
   was deliberately not touched by this work.
3. **The near tier's result cost at a realistic clustering.** Synthetic uniform
   hashes produce few matches. A library with a thousand near-identical burst
   frames produces a large match set, and the fetch-and-assemble step after the
   scan is linear in that set, not in `n`.
