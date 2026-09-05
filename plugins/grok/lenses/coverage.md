---
name: coverage
summary: Does the test suite cover what it claims to? Finds the missing cases and the ones that prove nothing.
require: settled decisions, what the suite claims
---

<!--
Shipped lens, for a change that ships tests — especially one that ships NO production code, which
gives the `code` lens nothing to grade but test style, the lowest-yield review there is.
Fill every <TODO: …>, delete what does not apply, delete this comment.
To keep a repo-specific version: run-review.sh new-lens coverage
-->

# Coverage review — <TODO: what the suite covers, in a few words>

You are reviewing this independently. You have the repository and this brief; you were not part of
the work, and should not assume anything the brief does not state.

Do not review test style, naming, helper structure or language idiom — those are out of scope and
another lens owns them. You are here for one question:

> **Does this test suite cover what it claims to cover, and what could still break without any
> test catching it?**

A suite that goes green while proving less than its acceptance line says is worse than no suite,
because it retires the suspicion that would otherwise have found the bug. Hunt for that.

You run headless under a **read-only sandbox**: read any file and run read-only git commands
(`git diff`, `git log`, `git show`) freely. You cannot write, and builds and tests will not run — do
not attempt them. **Print the review to stdout**; the harness captures it.

## The artifact

- **Branch / PR:** <TODO: branch name and head SHA, and the PR link if there is one>
- **Design doc:** <TODO: the authority for what the suite was supposed to cover>
- **The coverage table:** <TODO: where the design pins its cases — the matrix rows, the drill table,
  the TODO list this closes>

The diff range is under *Reading assignment* below.

## What the suite claims

The acceptance line is the sentence this review is testing. If the PR body claims "the money path is
proven", that claim is the thing to attack.

- <TODO: the acceptance line, quoted verbatim from the design doc or the PR body>

## Scope — the six questions

1. **What is reachable and untested?** Walk the state machine, the interface contract and the error
   paths for states, transitions and refusals with no case. Name each one and say what it would cost
   to lose. Prefer the ones where the loss is money, data, or a silent wrong answer.
2. **Which case is weaker than it reads?** Find the case whose assertion would still pass with the
   thing it names removed. That case is decorative: it contributes a green tick and no information.
   This is the highest-value finding in this lens — a suite's credibility is set by its weakest
   passing case, not its strongest.
3. **What does a stub or a fake decide that the real thing would not?** Every double on the asserted
   path narrows what the case proves. For each, say which case's conclusion silently depends on it,
   and whether the real component would have answered differently.
4. **What did the suite stop short of?** Cases that assert an intermediate state and stop, cases
   that assert a call was made rather than an outcome reached, cases that prove construction rather
   than acceptance. Say what the missing half was worth.
5. **Positive controls.** Does anything prove the suite can FAIL? A suite with no case that goes red
   when the system is broken is untested itself. If the design claims mutations were run, check the
   claims against what the assertions could actually detect.
6. **Honest gaps.** Where the design or the PR says a thing is NOT covered, is that statement
   accurate and complete — or does the surrounding prose still imply more coverage than exists?

**Out of scope:** test code style, naming, duplication, helper design, language idiom, formatting,
performance of the suite, and everything under "settled decisions". Do not propose refactors.

## Settled decisions — do not re-litigate

Decided by the owner. Report a coverage consequence they did not consider; do not re-argue the
choice.

1. <TODO: decision — and the reason it was made>

## Known gaps — already named, do not re-report as findings

These are recorded as debt with an owner. Report only if the stated scope is WRONG, or if the gap is
larger than the record admits.

1. <TODO: gap — and the ticket that owns it. Write "none" if there are none.>

## Required output

**1. Ranked findings**, most severe first. Each heading is `### F<n> — <short title>` (`F1`,
`F2`, …). The disposition file and the next round cite these ids. For each:

- **Severity** — blocker / major / minor. A blocker is a claim in the acceptance line that the suite
  does not support.
- **The claim it undermines** — quote the sentence this finding falsifies.
- **What is not covered** — the specific state, transition, input or failure, and the `file:line` of
  the case that was supposed to cover it (or "none exists").
- **What breaks in production if it is wrong** — concrete. A gap with no consequence is not a
  finding.
- **The case that would close it** — the shape, not the code.

**2. The decorative-case list.** Every case you believe would pass with its own named guard removed,
with the reasoning. Empty is a valid answer and worth saying explicitly.

**3. Coverage verdict** — does the suite support its acceptance line? One of: supports it / supports
it with the listed gaps / does not support it, with the single strongest reason.

## Claim table

One row per claim the suite's acceptance line (and the brief) rests on, in brief order. **No extra
rows** — the next round is seeded with this table, and extras are billed on every later turn.
Cap: 15.

- HOLDS — the claim, verbatim
- BROKEN Fn — the claim
- UNVERIFIED — the claim

End the response with this exact line, on its own, and nothing after it:

<!-- END OF REVIEW -->
