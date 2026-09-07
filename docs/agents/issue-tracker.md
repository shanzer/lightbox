# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for all operations.
`gh` infers the repo from `git remote -v` when run inside a clone.

## Issues

- **Create**: `gh issue create --title "..." --body-file <path>`. Write the body to a file
  first — markdown passed inline through `--body` gets mangled.
- **Read**: `gh issue view <number> --comments`
- **List**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with `--label` / `--state` filters.
- **Comment**: `gh issue comment <number> --body "..."`
- **Label**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "<what shipped + verification result>"`

## Pull requests

Every change reaches `main` through a PR (see `CONTRIBUTING.md`). The issue is linked from
the PR body or a commit trailer:

- `Fixes #<n>` — the PR closes the issue. GitHub auto-closes it on merge to `main`.
- `Refs #<n>` — the PR advances the issue but doesn't finish it. Close it by hand when the
  last piece lands.

- **Open**: `gh pr create --title "..." --body-file <path>`
- **Read**: `gh pr view <number> --comments`, `gh pr diff <number>` for the diff.
- **Watch CI**: `gh pr checks <number> --watch`

GitHub shares one number space across issues and PRs, so a bare `#42` may be either —
resolve with `gh pr view 42` and fall back to `gh issue view 42`.

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as
feature requests, in which case they run through the same labels and states as issues,
using `gh pr view`, `gh pr edit --add-label`, and `gh pr close`. To find them:
`gh pr list --state open --json number,title,body,labels,author,authorAssociation` then
keep only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE`.)_

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.
