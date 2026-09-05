---
name: security
summary: Where does an attacker get in — input, authz, secrets, exhaustion?
require: settled decisions, load-bearing claims
---

<!--
Shipped lens. Fill every <TODO: …>, delete what does not apply, delete this comment.
To keep a repo-specific version: run-review.sh new-lens security

This lens covers the ATTACKER's path in. Loss or corruption under HONEST operation — where nobody
is attacking and the world merely misbehaves — is a different threat model and deserves its own
lens; one brief asking for both gets the shallower half of each. The `security` lens with this
repo's real attack surfaces written into scope beats a generic checklist every time, so this is a
good lens to override: run-review.sh new-lens security
-->

# Security review — <TODO: what changed, in a few words>

Review this change as someone trying to get in, get data out, or take the service down. Assume the
attacker can reach every public entry point, control every field of every request, and see timing
and error text. <TODO: what else can this attacker do here — run their own peer, publish their own
data, hold a valid low-privilege account?>

You run headless under a **read-only sandbox**: read any file and run read-only git commands
(`git diff`, `git log`, `git show`) freely. You cannot write, and builds and tests will not run — do
not attempt them. **Print the review to stdout**; the harness captures it.

## The artifact

- **Branch / PR:** <TODO: branch name and head SHA, and the PR link if there is one>
- **Spec:** <TODO: the design doc, issue or PR description that is the authority for intent>
- **Canon:** <TODO: the files that state this repo's security rules>

The diff range is under *Reading assignment* below.

## Scope — the attack surfaces this repo actually has

<TODO: replace the generic items below with this repository's real seams — name the endpoints, the
parsers, the trust boundaries and the credentials by path. A generic checklist finds generic
findings.>

1. **Untrusted input at every seam.** Client-supplied parameters; data from peers and third parties;
   anything an attacker can author and pay to have delivered; outbound fetches to attacker-chosen
   hosts (SSRF — check the allowlist, redirect handling and the DNS-rebind window); and any boundary
   where a type annotation is erased before the other side runs.
2. **Authorization, not just authentication.** Does every operation check that *this* caller owns
   *this* object? Look for an identifier taken from the request and trusted as ownership proof, and
   for enumerable identifiers.
3. **Secrets and key material.** Never logged, never serialized into an event or persisted state,
   never in an error returned to a client, never in a crash-reporter payload. If redaction exists,
   verify it actually redacts (read the implementation, not the call site).
4. **Error and log surfaces.** A raw exception, storage error, or internal path returned to a client
   is a finding. Timing differences on a secret-dependent branch count.
5. **Injection and deserialization.** Query strings built by concatenation; polymorphic
   deserialization of anything attacker-influenced; configuration that makes a component accept a
   type it should not.
6. **Resource exhaustion.** Unbounded collections, caches and per-caller state; a stream or
   subscription path with no concurrency cap; a rate limiter applied after the expensive work rather
   than before it; any per-request work an attacker can amplify.
7. **Replay and idempotency.** A request that is safe once and harmful twice; a nonce or index
   reused; a signature valid in a context other than the one it was issued for.

**Out of scope:** style, naming, formatting; correctness bugs with no attacker path (the `code`
lens); and everything under "settled decisions" below.

## Settled decisions — do not re-litigate

Decided by the owner. Report a consequence they did not consider; do not re-argue the choice.

1. <TODO: decision — and the reason it was made>

## Load-bearing claims — check each against the code

1. <TODO: claim — e.g. "every endpoint validates that the caller owns the referenced object"; and
   where to check it>

## Required output

Ranked findings, most severe first. Each heading is `### F<n> — <short title>` (`F1`, `F2`, …).
The disposition file and the next round cite these ids. For each:

- **Severity** — blocker / major / minor.
- **Location** — `file:line`.
- **Attack** — who the attacker is, what they send or do, and what they get. A finding without a
  path from an attacker-controlled input to the bad outcome is an impression; drop it.
- **Impact** — money, data, availability, or key compromise.
- **Price** — what the attack COSTS the attacker against what it WINS them, in real numbers, and
  which of our limits the ratio rests on. A path that costs 1000x what it wins is a different object
  from one that pays for itself, and grading them alike is how this pass becomes a generator. Say
  plainly when you cannot price it.
- **Suggested fix** — the direction, not a patch.

Then an explicit **verdict**: no exploitable finding / exploitable with the listed changes required /
do not ship, with the reason.

## Claim table

One row per load-bearing claim from the brief, in brief order. **No extra rows** — the next round
is seeded with this table, and extras are billed on every later turn. Cap: 15.

- HOLDS — the claim, verbatim from the brief
- BROKEN Fn — the claim
- UNVERIFIED — the claim

End the response with this exact line, on its own, and nothing after it:

<!-- END OF REVIEW -->
