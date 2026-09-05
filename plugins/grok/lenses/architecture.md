---
name: architecture
summary: Is this the design to build? Alternatives and excess machinery, before any code exists.
require: settled decisions, load-bearing claims
---

<!--
Shipped lens, for a DESIGN DOC before implementation. Fill every <TODO: …>, delete what does not
apply, delete this comment. To keep a repo-specific version: run-review.sh new-lens architecture

Design-stage simplification lives HERE, not in the `simplicity` lens: at design time "too much
machinery" and "a better mechanism" are one question, answered in prose before any of it costs code.
-->

# Architecture review — <TODO: what is being designed>

You are reviewing this design independently. You have the repository and this brief; you were not
part of the work, and should not assume anything the brief does not state. No code exists yet — the
question is whether this is the design to build.

You run headless under a **read-only sandbox**: read any file and run read-only git commands freely.
You cannot write, and builds and tests will not run — do not attempt them. **Print the review to
stdout**; the harness captures it.

## The artifact

- **Design doc:** <TODO: committed path or URL, and its revision — it is the authority for intent>
- **Ticket / issue:** <TODO: link, or "none">
- **Canon:** <TODO: the files that state this repo's conventions and constraints>

The *Reading assignment* below names the diff range, if the doc itself is under review as a change.

## Scope

1. **Is there a better design?** Propose alternatives where one exists.
2. <TODO: the contract dimension — the interface, wire format, or API this pins. Does it actually
   serve the clients the ticket describes: surface, shapes, distinguishable errors, versioning?>
3. <TODO: the failure dimension — the concurrency, persistence and recovery model. Is it sound
   under crash, restart, retry and rebalance?>
4. **Totality of the state machine** — does every state show its exit paths, including timeout,
   crash and the abnormal ones? <TODO: name the diagram or model this must agree with, if any.>
5. **Reused components** — where the design promotes an existing component into a new load-bearing
   role, read its ACTUAL code, not its interface summary, and walk it against the new consumer's
   failure interleavings. A component is proven only for the workloads that shipped it.
6. **Reuse, unify, simplify — searched for in the TREE, not just judged in the doc.** Item 5 audits
   the reuse the design *names* and item 7 counts what it *adds*; this one hunts what it never
   mentions. Go looking:
   - **Reuse.** For each thing the design builds, search for something that already does it — a
     sibling module solving the mirror problem, a helper one caller up. Name the file. "Nothing to
     reuse" is a real answer; reaching it by not looking is not.
   - **Unify.** Where the design adds a second thing beside an existing one — a second reader, gate,
     policy, taxonomy, error family — ask whether the two should be one, and what forces them apart.
     Two shapes for one concept diverge; a divergence a reviewer names now is free.
   - **Simplify.** Given what the tree already has, is there a smaller design meeting the same
     requirements? Prefer deleting complexity to rearranging it: a proposal that adds six concepts
     and removes one is a finding about the proposal.

   The failure this catches is a design that is internally coherent and locally minimal while
   duplicating something the repo already owns — which no amount of reading the doc alone will show.
7. **Excess design** — is this more machinery than the problem needs? Count the concepts it adds:
   states, components, events, tables, config knobs, round-trips, new seams. For each, ask what
   breaks if it is removed or merged. A state derivable from another is not a state; a knob nothing
   will vary is a constant; a seam with one implementation on either side is indirection. Cheapest
   to delete now, while it is still prose.

**Out of scope:** naming, formatting, doc prose style, and everything under "settled decisions".

## Premise-level alternatives are in scope

Ask "is this the right MECHANISM at all?", not only "is this the right variant?" A brief scoped to a
design's own frame gets a review trapped in that frame. If the ticket's framing is the thing that is
wrong, say so and name the alternative.

**Name at least one concrete alternative design, always — including when you conclude this one is
right.** Not "consider a simpler approach" but a specific mechanism, with what it costs and what it
buys, and why it does or does not win here. A verdict of "sound as written" that never names the
option it beat is an opinion; the same verdict with the rejected alternative attached is a decision,
and the design doc can record it as one.

## Settled decisions — do not re-litigate

Decided by the owner. Report a consequence you think was missed, but do not re-argue the choice.

1. <TODO: decision — and the reason it was made>

## Load-bearing claims — check each against the tree

The design rests on these. Each is phrased to be checkable; a claim you cannot verify is itself a
finding.

1. <TODO: claim — and where to check it>

## Audit the evidence, not only the design

Two failures an assumption list cannot catch about itself, and both are in scope:

- **Unearned verdicts.** For each claim above, ask what was actually *done*, not what the doc says.
  "Measured" means an experiment ran and its output is quoted, so a reader can re-run it. An
  argument from an existing consumer — "this component already does this", "it is proven" — is not a
  measurement of a **new** consumer, and neither is a code reading, however careful. Name every
  claim whose confidence is stronger than its evidence, and say what would settle it. "Unverified"
  is the honest label and not a defect; a claim marked proven that rests on an argument is one,
  because everything downstream is then trusted at the wrong confidence.
- **Missing claims.** One is owed wherever the design licenses a branch, a state, a field, a retry
  or a guard. Walk the design's change list in the opposite direction: for each thing it adds,
  keeps, inverts or deletes, find the assumption that justifies it. A branch tracing to no
  assumption is unjustified; an assumption licensing nothing is trivia and should be cut.

Where the design promotes an existing component into a new role, these two questions are the same
question: **the reuse bet is that the consumers differ**, so evidence from the old consumer has not
been verified for the new one. That gap is where the defects live.

## Required output

**1. Ranked findings**, most severe first. Each heading is `### F<n> — <short title>` (`F1`,
`F2`, …). The disposition file and the next round cite these ids. For each:

- **Severity** — blocker / major / minor.
- **Location** — the doc section, and the `file:line` in the tree it contradicts where relevant.
- **Failure scenario** — the concrete sequence that goes wrong if the design ships as written.
- **Suggested fix** — the direction, not a patch.

**2. Alternative designs — at least one, mandatory.** For each: the mechanism in a few sentences,
what it costs, what it buys, and why it does or does not beat the design under review. Say plainly
if the answer is "this one wins".

**3. Simplification verdict.** Is there a materially simpler design meeting the same requirements?
Name what you would cut and what breaks if it is cut, and report what scope item 6's search turned
up: the existing code this should reuse, the pair it should unify, or that you looked and found
neither. "Nothing to cut" is a valid answer; say it explicitly rather than by omission.

**4. Verdict** — sound as written / sound with the listed changes / wrong design, with the reason.

## Claim table

One row per load-bearing claim from the brief, in brief order. **No extra rows** — the next round
is seeded with this table, and extras are billed on every later turn. Cap: 15.

- HOLDS — the claim, verbatim from the brief
- BROKEN Fn — the claim
- UNVERIFIED — the claim

End the response with this exact line, on its own, and nothing after it:

<!-- END OF REVIEW -->
