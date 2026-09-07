---
name: issue
description: Turn a rough subject into a fully-specified GitHub issue for this repo — research the code, ask the questions that matter, draft it to the repo's conventions, apply labels, and file it. Use this whenever the user wants to file, create, open, raise, or write up an issue, bug, feature request, PRD, or epic, or says "/issue", or describes something broken or missing and wants it tracked — even when they phrase it as "we should probably log this somewhere" rather than asking for an issue by name.
---

# Filing an issue

The point of this skill is that a filed issue should be worth implementing from, not just
worth reading. Most of the value comes from the research step: an issue that quotes the
three lines causing the bug is actionable, and one that describes the symptom in prose is
a request for someone else to do the investigation.

Read `docs/agents/issue-conventions.md` first — it holds the title prefixes, label policy,
the ready-for-agent bar, and the body shape, and it is shared with `/intent`.
`docs/agents/issue-tracker.md` has the `gh` invocations.

## 1. Research before asking

Go find the code. You will ask better questions afterwards, and half of what you were
going to ask you'll answer yourself.

- Locate the behaviour in the source. Get to a file and line number.
- Check for an existing issue covering it: `gh issue list --state all --search`. Filing a
  duplicate wastes the triager's time; linking to the original doesn't.
- If it's a bug, understand *why* the code does the wrong thing. "The button is in the
  wrong place" becomes "`align-items: flex-end` bottom-aligns the row and the hint element
  adds height inside the field" — the second one tells the implementer where to fix it and
  stops them fixing the symptom.
- **Check the project's own gotcha documentation before concluding.** Most codebases have
  a file recording the traps that make the obvious diagnosis wrong. A symptom matching one
  of them is usually that one, and rediscovering it costs an afternoon.
- Notice what the code implies but the reporter didn't mention. A form field with no
  `aria-describedby`, an unbounded read, a switch with no default, an unsanitized render
  path. These are worth a line in the issue even when nobody asked.

## 2. Ask only what research can't settle

Ask about intent, priority, and scope — the things the code cannot tell you. Don't ask
what you can read.

Worth asking:

- Ambiguity where readings diverge into materially different work.
- Whether an adjacent problem you found belongs in this issue or its own.
- Anything where guessing would bake a decision the user should make.

Not worth asking: which file it's in, what the current behaviour is, whether a test
exists. Go look.

Ask in prose, as few questions as the work needs. If nothing genuinely blocks, say what
you're assuming and carry on.

## 3. Draft, then confirm

Write the body to the shape in the conventions doc. State how the fix will be verified —
and where the test suite can't prove it, name the live check that can.

Then **show the user the title, labels, and body and wait for a yes before creating
anything.** Filing is outward-facing and awkward to unwind — a wrong issue can only be
closed, never un-filed, and it stays in the tracker's history either way.

Pick labels yourself rather than defaulting everything to `needs-triage`; the conventions
doc defines the ready-for-agent bar and you're better placed to judge it than a later
reader who lacks the research you just did. State your reasoning in one line when you
present the draft, so the user can overrule it.

Use a heredoc to a file and `--body-file`; markdown in `--body` gets mangled.

```bash
gh issue create --title "..." --body-file <path> \
  --label <type> --label <priority> --label <triage>
```

## Doing several at once

When the user dumps a list, file them separately rather than as one issue with sections.
Separate issues get separate labels, separate priorities, and separate PRs. Do the
research for all of them before drafting any, so cross-references between them are real.

Where one clearly contains the others, propose an `[EPIC]` and link the children to it —
but only when the children are genuinely separable work, not when it's one job described
in several sentences.
