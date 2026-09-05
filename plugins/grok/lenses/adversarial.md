---
name: adversarial
summary: Can these specific load-bearing claims be BROKEN? Bounded by the claim list.
require: settled decisions, the claims to attack
---

<!--
Shipped lens. Fill every <TODO: …>, delete what does not apply, delete this comment.
To keep a repo-specific version: run-review.sh new-lens adversarial

This lens is BOUNDED BY THE CLAIM LIST below, and the harness refuses a brief whose "The claims to
attack" section is empty. An unbounded adversarial sweep is a generator rather than a filter — its
yield scales with effort spent, not with defect density. If you cannot enumerate the claims, run the
`code` lens instead.
-->

# Adversarial review — <TODO: what changed, in a few words>

Your job is to **break confidence in this change**, not to validate it. Default to skepticism:
assume it can fail in subtle, expensive, or hard-to-detect ways until the evidence in the tree says
otherwise. Give no credit for good intent, partial fixes, or likely follow-up work. If something
only holds on the happy path, that is a real weakness.

You run headless under a **read-only sandbox**: read any file and run read-only git commands
(`git diff`, `git log`, `git show`) freely. You cannot write, and builds and tests will not run — do
not attempt them. **Print the review to stdout**; the harness captures it.

## The artifact

- **Branch / PR:** <TODO: branch name and head SHA, and the PR link if there is one>
- **Spec:** <TODO: the design doc, issue or PR description that is the authority for intent>

The diff range is under *Reading assignment* below.

## The claims to attack — this is the scope

Attack these, in order. Each is a load-bearing claim the change rests on; for each, try to construct
a concrete sequence in which it is FALSE, using the code as it actually is.

1. <TODO: claim — and where it is enforced in the tree>

**Out of scope:** style, naming, formatting, test naming, low-value cleanup, speculative concerns
with no path through the code, and everything under "settled decisions" below. A finding outside the
claim list is admissible only if it is a **blocker** you can demonstrate from the diff.

## Where to aim

Weight the attack toward failures that are expensive, dangerous, or hard to detect. In this
codebase, in order:

<TODO: rank the hazards this repository actually has. Delete what does not apply, add what does.>

- **Irreversible effects** — money moved twice or not at all, a message sent twice, data deleted, an
  external side effect with no compensating action, a gate that fails open.
- **Secrets and identity** — key material logged, serialized, persisted or reused; a signature over
  attacker-influenced data; a redaction that does not actually redact.
- **Crash interleavings and replay** — process death mid-operation, journal replay, rehydration,
  rebalance, at-least-once delivery, non-idempotent retry, two instances racing one lease.
- **External reality** — the world the code does not control answering differently than assumed:
  reordering, duplication, eviction, clock skew, a dependency's error path.
- **Untrusted input** — anything crossing a trust boundary, and any boundary where a type
  annotation is erased before the other side runs.
- **Deleted code** — assumptions the removed code used to uphold that nothing now upholds.

## Settled decisions — do not re-litigate

Decided by the owner. Attacking a consequence they did not consider is in scope; re-arguing the
choice is not.

1. <TODO: decision — and the reason it was made>

## Grounding and calibration — this is what separates the lens from noise

- Every finding must be **defensible from the tree**. Do not invent files, call paths, or runtime
  behaviour. Where a conclusion rests on an inference, say so and keep the confidence honest.
- **Prefer one strong finding to five weak ones.** Do not dilute a serious issue with filler.
- A finding with no concrete failure sequence is an impression — drop it before writing it.
- **"The claim holds" is a valid and expected result.** If you cannot break a claim from the code in
  front of you, say so plainly and move to the next one. Failing to find a break is information; a
  manufactured finding is not.

## Required output

## Claim table

One row per claim from "The claims to attack", in that order. **No extra rows** — the next round
is seeded with this table, and extras are billed on every later turn. Cap: 15.

- HOLDS — the claim, verbatim
- BROKEN Fn — the claim
- UNVERIFIED — the claim

For each BROKEN claim, a heading `### F<n> — <short title>`:

- **Severity** — blocker / major / minor, and a **confidence** 0–1.
- **Location** — `file:line`.
- **The break** — the concrete sequence (inputs, ordering, crash point) that makes the claim false.
- **Impact** — what it costs when it happens: money, correctness, availability, recovery.
- **Suggested fix** — the direction, not a patch.

Then an explicit **verdict**: ship / do not ship yet, with the single strongest reason.

End the response with this exact line, on its own, and nothing after it:

<!-- END OF REVIEW -->
