---
description: Get an independent second-opinion review from Grok through one lens — you write the brief, Grok reviews the branch inside a read-only sandbox; add `--fix` to apply the findings afterwards
argument-hint: '[<lens>] [--topic <slug>] [--round <N>] [--since <ref>|--full] [--base <ref>] [--fix] [--force] [--force-size] [--parallel]'
disable-model-invocation: true
allowed-tools: Bash(bash:*), Bash(cat:*), Bash(git:*), Read, Edit, Write, Grep, Glob
---

Run one sandboxed Grok review through the harness, then report its findings. If `--fix` was typed,
apply them afterwards (Phase B) — otherwise this command is review-only.

Raw slash-command arguments:
`$ARGUMENTS`

**Why Grok and not a Claude subagent.** A fresh subagent gives you context isolation but not model
independence: its blind spots correlate with this session's, which is exactly what this step exists
to defeat. The harness is Claude's; the reading is Grok's. Never substitute a subagent for the
reviewer and call the step done.

## Phase 0 — the lens

The lens is the first word that is not a flag. If none was typed, use `code`. Run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" lenses` if you need the list — a repo can
override any shipped lens or add its own, so never assume the shipped set.

Say in one line which lens runs and why. `--fix` is yours, not the harness's: strip it from the
arguments you pass on. Everything else (`--topic`, `--round`, `--since`, `--full`, `--base`,
`--force`, `--force-size`, `--parallel`) passes through verbatim.

## Phase 1 — the brief, which you write

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" init <lens> <rest>
```

It prints the brief path and copies the lens template there (it refuses if a brief already exists —
that is fine, use the one that is there, and pass `--force` only if the user asked for a reset).

**Now fill it in.** The template supplies the structure; four sections are judgment and only this
session can write them, and they are what turn a general impression into a verifiable review:

- **the artifact** — branch and head SHA, the PR link, the committed spec path. Cite paths and SHAs,
  never "the doc we discussed". The reviewer has no session context whatsoever;
- **scope** — the dimensions to review, and an explicit out-of-scope list. For `adversarial`, the
  enumerated claim list *is* the scope;
- **settled decisions** — the owner's calls, marked do-not-re-litigate;
- **load-bearing claims** — what the change rests on, each phrased so it can be checked against the
  code.

Read the diff and the spec first, then write. Every `<TODO: …>` must be gone — the harness refuses a
brief that still carries one, and refuses one whose required sections are empty. Do not paste the
diff into the brief and do not generate a `.patch`: the reviewer runs its own `git diff`, over the
range the harness names for it.

Show the user the filled brief's scope and claims in a few lines before launching. If the change is
one you cannot describe in load-bearing claims yet, say so rather than inventing them.

## Phase 2 — the run

```typescript
Bash({
  command: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" review <lens> <rest>`,
  description: "grok review (sandboxed)",
  run_in_background: true,
  timeout: 2000000
})
```

Always in the background: a review takes minutes. The process exiting IS the completion signal — do
not poll and do not write a sentinel-grep wait loop. Tell the user it started, and that
`/grok:status` shows whether it is still running and `/grok:cancel` stops it.

When it completes:

- **Exit 0** — the last stdout line is the promoted review's path. `cat` it. It is markdown: ranked
  `### F<n>` findings, then a verdict, then a `## Claim table` of HOLDS / BROKEN / UNVERIFIED. Give
  the user the claim table first (it is the shortest true summary), then each finding as
  `file:line — title` with its failure scenario. Findings are CLAIMS from a third-party model: say
  so, and do not confirm or fix anything unless `--fix` was typed.
- **Exit non-zero** — the run ABORTED. Show the harness's stderr tail verbatim; every abort names
  its own fix. An abort is never "no findings": say plainly that no review was produced, do not
  proceed to a fix pass as though the review passed, and do not relaunch on your own — the run
  accounting says what the attempt cost, and a blind relaunch re-bills from the top. The usual cause
  is an expired session (`grok login`).

Either way, relay the `--- run accounting ---` block: lens, model, reading assignment, turns,
tokens, cost, and anything the harness said it defaulted (a `--since` defaulted to the previous
round's head means this was a DELTA review).

## Phase B — `--fix` (only when `--fix` was typed, and only after Phase 2 exited 0)

You apply the findings, host-side, with your own Edit tool and the normal permission prompts. The
sandboxed reviewer never edits anything; the tree assertion for Phase 2 has already passed, and the
edits you make now happen after it.

Take the findings in order (ranked most-severe first). For each, open the cited `file:line` and
**adversarially confirm the claim against the code** — does the failure scenario actually reproduce?
Then:

- **Skip, stating the reason**, any finding whose fix would change intended behaviour, would need
  changes well outside the reviewed diff, or that you judge a false positive after reading the code.
  Never churn risky code on a false positive.
- **Apply** the rest with the smallest edit that resolves the stated failure scenario. Never widen
  scope. Apply structural fixes first, then re-check which of the remaining findings still stand —
  drop the ones the structural fix evaporated rather than fixing them out of momentum.

Then **record the disposition**, one line per finding, in the response file the harness named
(`<lens>-review[-rN]-response.md` beside the review):

```
- F1 FIXED in <sha or "working tree"> — <one line>
- F2 WAIVED: <one line of reasoning>
```

That file is scratch under `.grok-review/`, so carry the surviving verdicts into the PR before merge
or the durable record dies with the working tree. It also seeds the next round: a waiver is a claim
the next reviewer re-checks against the delta, not a gag.

Finish with what was fixed (file:line each) and what was skipped and why. Do not commit. Suggest
`/grok:review <lens> --round 2`: round 1 recorded the head it reviewed, so round 2 reviews only the
delta and costs a fraction of the first.
