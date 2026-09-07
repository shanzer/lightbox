---
name: intent
description: Take an existing GitHub issue by number and bake it until it's genuinely implementable — research the code, ask what's missing, rewrite the body to the repo's conventions, fix the labels, and move it out of needs-triage. Use this whenever the user gives an issue number and wants it triaged, specified, fleshed out, sharpened, unblocked, made ready for an agent, or asks "what's missing on #N" or "/intent N" — including when they just paste an issue number and ask whether it's ready to work on.
---

# Triaging an issue

An issue arrives as a note-to-self. It leaves as something an agent can finish without
asking a question. The work in between is mostly research, not editing: the gaps you can
close by reading the code are the ones the reporter didn't know were gaps.

Read `docs/agents/issue-conventions.md` first — title prefixes, label policy, the
ready-for-agent bar, and the body shape. `docs/agents/triage-labels.md` has the label
meanings; `docs/agents/issue-tracker.md` has the `gh` invocations.

## 1. Read the whole issue

```bash
gh issue view <N> --comments --json number,title,body,labels,state,comments
```

Comments often carry the real decision while the body still describes the original guess.
Where they disagree, the comments usually win — but say so rather than silently discarding
what the body claims.

## 2. Research the code

Same standard as filing: get to file and line, understand the mechanism, and verify the
issue's claims rather than inheriting them. Issues age badly. A claim that was true when
written may have been fixed, changed shape, or moved — and the git history will often tell
you which change moved it.

**Say so when the issue is wrong.** An issue describing a bug that no longer exists should
be closed, not specified. One whose premise is mistaken needs the premise corrected before
anything else is worth writing.

Look for what the reporter couldn't see: the same defect in three other call sites, a
security dimension in what was filed as a papercut, a dependency on work that hasn't
landed, or a documented gotcha that makes the filed diagnosis the wrong one.

## 3. Ask what's actually blocking

Work out what stands between this issue and the ready-for-agent bar, then ask only about
that. Usually it's one of:

- An open design decision — the issue offers two approaches and picks neither.
- Missing acceptance criteria — nobody has said what "done" looks like.
- Unstated scope — it's unclear whether an adjacent problem is included.
- No verification path — the change can't be proven by the test suite and nobody has said
  what live check would prove it.
- A priority call that depends on the user's plans, not on the code.

Ask in prose, and ask about the blockers only. If research settled everything, don't
manufacture questions — go straight to the rewrite.

## 4. Rewrite, then confirm

Rewrite the body to the conventions doc's shape, with the code you found quoted by path
and line.

**Preserve the reporter's intent.** You are sharpening a record someone else wrote, and
the original phrasing sometimes carries context the rewrite would flatten — a specific
scenario, a constraint mentioned in passing, why they cared. Keep what carries
information. Where the original states a decision that research contradicts, keep the
original claim visible and note what you found, rather than quietly replacing it: a triage
that erases the disagreement hides the fact that someone was working from a wrong
assumption.

**Show the rewritten body, the label changes, and your triage verdict, and wait for a
yes.** This overwrites someone's words in a shared tracker, which is not something to do
on inference.

```bash
gh issue edit <N> --body-file <path> \
  --add-label <...> --remove-label needs-triage
```

## 5. Land the verdict

Every intent ends in one of four states. Pick honestly:

- **`ready-for-agent`** — clears all the bars in the conventions doc, and the verification
  path is stated. If you're reaching to argue it does, it doesn't.
- **`needs-info`** — blocked on the reporter, not on you. Say precisely what you need;
  "please clarify" wastes a round trip.
- **`ready-for-human`** — specified, but needs judgment an agent shouldn't make alone (a
  product call, a security-sensitive design, a migration with no undo).
- **`wontfix`** and close — the premise is wrong, it's already fixed, or it's a duplicate.
  Say which, and link the issue that supersedes it.

Leaving `needs-triage` on and calling it triaged is not one of the options. If the issue is
genuinely blocked on something outside the tracker, record what, in a comment, so the next
reader doesn't re-derive it.

If the triage revealed separable work, file it as its own issue rather than growing this
one — an issue that accumulates scope during triage is one nobody will pick up.
