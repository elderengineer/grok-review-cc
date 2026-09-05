---
name: simplicity
summary: Could this be materially less code, fewer concepts, better layered? Quality only.
require: settled decisions
---

<!--
Shipped lens. Fill every <TODO: …>, delete what does not apply, delete this comment.
To keep a repo-specific version: run-review.sh new-lens simplicity

This lens is QUALITY ONLY — it does not hunt for bugs. Run the `code` or `adversarial` lens for
that. It must not churn risky code for style: every proposal states what it deletes and why that is
safe.
-->

# Simplicity review — <TODO: what changed, in a few words>

Review this change for **reuse, simplification, efficiency and altitude**. The question is not "is
it correct" — assume it is, and that the `code` lens covers correctness. The question is whether the
same behaviour could be delivered with materially less code, fewer concepts, or at a better layer.

You run headless under a **read-only sandbox**: read any file and run read-only git commands
(`git diff`, `git log`, `git show`) freely. You cannot write, and builds and tests will not run — do
not attempt them. **Print the review to stdout**; the harness captures it.

## The artifact

- **Branch / PR:** <TODO: branch name and head SHA, and the PR link if there is one>
- **Spec:** <TODO: the design doc, issue or PR description that is the authority for intent>
- **Canon:** <TODO: the files that state this repo's style and architecture conventions. Read them;
  they are the standard, not your priors.>

The diff range is under *Reading assignment* below.

## Scope

1. **Reuse** — does the diff hand-roll something the repo already has? Search before concluding it
   does not: a helper, an extension, a repository method, a codec, a test fixture. Name the existing
   one by `file:line`.
2. **Simplification** — a wrapper that only forwards; an abstraction with exactly one caller; a
   config knob nothing varies; a state or flag derivable from another; a branch that cannot be
   taken; two code paths that could be one.
3. **Altitude** — is each piece at the right layer? Domain logic leaking into a transport handler, a
   transport concern pushed into the domain, storage shape decided in the caller, a pure function
   trapped inside a stateful component where it cannot be tested.
4. **Duplication** — near-identical blocks introduced by this diff. Pre-existing duplication the
   diff merely touches is out of scope.
5. <TODO: this repo's idiom — the language and framework patterns it has already settled on, and
   the hand-rolled shapes that should be replaced by them. Name the existing users so the finding
   is a reuse finding rather than a rewrite.>

**Out of scope:** correctness and security findings (a different lens owns those — mention a blocker
in one line and move on); formatting and whitespace <TODO: say whether this repo runs a formatter;
if it does not, formatting notes are unactionable churn>; naming preferences, unless a name is
hiding the abstraction problem you are reporting; anything under "settled decisions" below; and any
file the diff does not touch.

## Settled decisions — do not re-litigate

Decided by the owner. A simpler variant WITHIN a settled decision is welcome; replacing the decision
is not.

1. <TODO: decision — and the reason it was made>

## The bar — a proposal that does not clear it is churn

Every finding must state:

- **what gets deleted or merged**, concretely, and roughly how many lines it removes;
- **why it is safe** — what preserves the behaviour the deleted code was carrying;
- **why it is worth it now**, given the change is already written and reviewed.

Reject your own finding if it trades one concept for another of the same weight, if it is a rewrite
wearing a cleanup's clothes, or if it churns <TODO: the code in this repo that is allowed to be more
explicit than elsewhere — the money path, the crypto, the migration> for a stylistic gain.

## Required output

Findings ranked by **value removed per unit of risk** — the biggest safe deletion first. Each
heading is `### F<n> — <short title>` (`F1`, `F2`, …). The disposition file and the next round cite
these ids. For each:

- **Location** — `file:line`.
- **What to remove or merge**, and the approximate line delta.
- **Why it is safe.**
- **Existing thing to use instead**, by `file:line`, where the finding is a reuse finding.

Then an explicit **verdict**: the change is as simple as it needs to be / the listed simplifications
are worth taking / the change carries structural excess that should be addressed before merge.

## Claim table

One row per load-bearing claim from the brief, in brief order (if the brief listed none, one row for
whether the change is as simple as it needs to be). **No extra rows** — the next round is seeded
with this table, and extras are billed on every later turn. Cap: 15.

- HOLDS — the claim, verbatim from the brief
- BROKEN Fn — the claim
- UNVERIFIED — the claim

End the response with this exact line, on its own, and nothing after it:

<!-- END OF REVIEW -->
