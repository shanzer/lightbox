# Contributing

Every change reaches `main` through a reviewable pull request with CI green behind it.
Not because the process is valuable in itself, but because the alternative — a change
that lands unreviewed and unverified — is only cheap until the first time it isn't.

## Trunk

**`main`** is the trunk. It is always releasable and is the base every change branches
from and merges back into.

## The flow: one branch per change

Direct commits to `main` are retired (phase 1 was built that way; from the template
adoption onward it isn't). Every change — a feature, a fix, even a docs edit like this
one — follows the same path:

1. **File the issue first** if one doesn't exist. Document *what* is changing and *why* —
   the problem, the intended fix, and how it will be verified. See
   `docs/agents/issue-conventions.md`.
2. **Branch off `main`.** Name it `<type>/<short-slug>`, using the same type prefixes as
   the commits: `feat/`, `fix/`, `docs/`, `chore/`, `refactor/`, `test/`, `perf/`.
   Example: `feat/database-pool-wal`.
3. **Make the change** on that branch, in focused commits.
4. **Push and open a PR** into `main` (`gh pr create`). Link the issue it closes or
   advances (`Fixes #6` / `Refs #6`).
5. **Merge back** once CI is green and the PR is approved. Delete the branch after merge.
6. **Close the issue** with a comment stating what shipped and the verification result.

Keep a branch scoped to one change. If it grows a second concern, branch again.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): a `type(scope): summary`
subject line, imperative mood, with the body explaining the *why* rather than restating
the diff. The history already uses `feat`, `fix`, `docs`, `chore`, `test`, and `perf`;
match it — `git log` is the style guide. A body that records what was *measured* is
worth more than one that restates the diff; several phase-1 fixes were reversed by
measurement, and the commit is where that gets remembered.

## Before you open a PR

- **Checks pass locally.** CI runs them anyway, but a red CI run is a slow way to learn
  something you could have caught in fifteen seconds on an M4:
  ```bash
  cd Core && swift test
  cd ../App && xcodebuild -scheme Lightbox -destination 'platform=macOS' test
  ```
- **The change is scoped** to what the PR title claims. Unrelated cleanups belong in their
  own branch.
- **Docs track reality.** If the change alters behavior that documentation describes,
  update it in the same PR. That includes `docs/HANDOFF.md` and the spec in
  `docs/superpowers/specs/` — the spec is binding, and a change that contradicts it
  either amends the spec or doesn't merge.
- **Anything the test suite can't prove is proven another way.** This project has a
  specific list — see "Verification" in `docs/agents/issue-conventions.md`. Say in the PR
  what you actually ran. A green unit-test suite is not evidence that a code path it
  never entered works; that is how an index got lost twice during phase 1.
- **New tests fail when they should.** Five phase-1 tests were caught passing vacuously
  (a timezone test that only passed off-UTC; a denylist assertion that passed because the
  chunk was absent). Break the code once and watch the test go red before trusting it.

## CI

`.github/workflows/ci.yml` runs on every PR and every push to `main`, on a clean
GitHub-hosted Apple-silicon runner (`macos-26`): no `~/lightbox-bench`, no
`~/Library/Application Support/Lightbox/index.sqlite`, none of this machine's photos.

That environment is the thing to hold in mind when writing tests. **A test that depends on
local data must skip cleanly rather than fail — and its skip guard must consult the same
path the code under test reads.** The benchmark suites are the model: they are gated on
`LIGHTBOX_BENCH=1` and on the fixture library existing, and they skip visibly otherwise.
A guard that checks a different path than the implementation produces a green run that
proves nothing, which is strictly worse than a red one: nobody investigates a passing
check.
