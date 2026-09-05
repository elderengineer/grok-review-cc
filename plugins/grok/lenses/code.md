---
name: code
summary: Does the diff implement the design correctly? The scoped correctness pass.
require: settled decisions, load-bearing claims
---

<!--
Shipped lens. `run-review.sh init code` copies it to the brief path; fill every <TODO: …>, delete
what does not apply, delete this comment.

The four judgment sections — the artifact, the scope, the settled decisions and the load-bearing
claims — are what turn a general impression into a verifiable review. The harness refuses a brief
that has lost its "out of scope", "settled decisions" or "END OF REVIEW" section, and one that still
carries a <TODO: …>.

To keep a repo-specific version of this lens: run-review.sh new-lens code
-->

# Code review — <TODO: what changed, in a few words>

You are reviewing this independently. You have the repository and this brief; you were not part of
the work, and should not assume anything the brief does not state.

You run headless under a **read-only sandbox**: read any file and run read-only git commands
(`git diff`, `git log`, `git show`) freely. You cannot write, and builds and tests will not run — do
not attempt them. **Print the review to stdout**; the harness captures it.

## The artifact

- **Branch / PR:** <TODO: branch name and head SHA, and the PR link if there is one>
- **Diff:** the exact range is under *Reading assignment* below. Run it yourself.
- **Spec:** <TODO: the design doc, issue or PR description that is the authority for INTENT — a
  committed path or a URL, never "the doc we discussed">
- **Canon:** <TODO: the files that state this repo's conventions, e.g. AGENTS.md, CONTRIBUTING.md,
  CODING_GUIDELINE.md. Read them; they are the standard, not your priors.>

## Scope — this is a scoped review, not an open-ended pass

Review these dimensions and no others. An open-ended sweep is a generator rather than a filter: its
yield scales with effort spent rather than with defect density.

1. **Design fidelity** — does the code implement the spec, and where it deviates, is the deviation
   right? Are the new seams at the correct boundaries, or does one leak a concern?
2. <TODO: the correctness dimension this change actually risks — protocol/wire contract, error
   codes, API compatibility. Say which surface, and name the file that pins it.>
3. <TODO: the failure dimension — concurrency, crash and restart, retries and idempotency,
   persistence and recovery, ordering, partial failure.>
4. <TODO: the data dimension — schema and migration correctness, transaction scoping,
   read-then-write races, query shape.>

**Out of scope:** naming, formatting, comment prose style, test naming, and everything under
"settled decisions" below.

<!--
Touching money, keys, or user data? Do not bolt a section on here — run the dedicated lenses, which
get their own filter and their own claim table:
  run-review.sh review security     (attacker input, authz, secrets, exhaustion)
  run-review.sh review adversarial  (break the enumerated load-bearing claims)
One brief asking for everything is a brief that filters nothing.
-->

## Settled decisions — do not re-litigate

Decided by the owner. Report a consequence you think was missed, but do not re-argue the choice.

1. <TODO: decision — and the reason it was made>

## Load-bearing claims — check each against the code

The diff rests on these. Each is phrased to be checkable; a claim you cannot verify from the tree is
itself a finding.

1. <TODO: claim — and where to check it>

## Required output

Ranked findings, most severe first. Each heading is `### F<n> — <short title>` (`F1`, `F2`, …).
The disposition file and the next round cite these ids. For each:

- **Severity** — blocker / major / minor.
- **Location** — `file:line`.
- **Failure scenario** — concrete inputs or interleaving → the wrong outcome. A finding without one
  is an impression; drop it.
- **Suggested fix** — the direction, not a patch.

Then an explicit **verdict**: mergeable as is / mergeable with the listed changes / not mergeable,
with the reason.

## Claim table

One row per load-bearing claim from the brief, in brief order. **No extra rows** — the next round
is seeded with this table, and extras are billed on every later turn. Cap: 15.

- HOLDS — the claim, verbatim from the brief
- BROKEN Fn — the claim
- UNVERIFIED — the claim

End the response with this exact line, on its own, and nothing after it:

<!-- END OF REVIEW -->
