---
name: grok-review
description: Get an independent second-opinion code review from Grok — a different model from the one running this session — reading the repository inside its own read-only sandbox. Use when the user asks for an independent review, a "second opinion", a "grok review", a review of a branch/PR/diff, or wants the load-bearing claims of a change attacked. Drives the bundled harness through setup, the brief, one review through a lens, and host-side fixes.
---

# Grok review

Grok reads your repository and answers with a review. It is a **different model** from the one
running this session, and that is the point: a fresh subagent gives context isolation but not model
independence — its blind spots correlate with this session's, which is exactly what this step exists
to defeat. The harness is yours; the reading is Grok's. Never substitute a subagent for the reviewer
and call the step done.

Grok runs headless under its own **custom** sandbox profile: it reads any file and runs read-only
git, and it cannot write to the working tree. If a custom profile cannot be applied, grok refuses to
start (a built-in profile would fail open, with no sandbox at all). Everything the harness writes
lives in `<repo>/.grok-review/`, which `setup` adds to `.gitignore`.

Findings are **claims from a third-party model**, not orders.

## Prerequisites

- `grok` installed and logged in (`grok login`).
- Linux, or macOS with the caveat that the deny list is only enforced by the kernel on Linux.
- `bubblewrap`, `util-linux`, `jq` (on Linux, bubblewrap is what makes the deny list real).
- Run `setup` once per repository before the first review. It checks every host requirement, renders
  `.grok/sandbox.toml`, gitignores the state directory, and **measures** the sandbox with a small
  probe run.

## Find the harness

The harness is `scripts/run-review.sh` in this skill's directory. Resolve that directory as the
first of:

- `${CLAUDE_SKILL_DIR}` when it is set and contains `scripts/run-review.sh`;
- `~/.agents/skills/grok-review`, then `<repo>/.agents/skills/grok-review`;
- `~/.zcode/skills/grok-review`, then `<repo>/.zcode/skills/grok-review`;
- `~/.claude/skills/grok-review`, then `<repo>/.claude/skills/grok-review`.

Call it as `bash <skill-dir>/scripts/run-review.sh <verb> …`. It is self-locating: it reads the
shipped lenses from `<skill-dir>/lenses`.

## Verbs

| verb | what it does |
|---|---|
| `setup [--force] [--no-probe]` | check the host, render the sandbox profile, gitignore the state dir, and measure the sandbox |
| `lenses` | list the lenses available in this repo (shipped, overridden, project) |
| `new-lens <name> [--from <lens>]` | scaffold `.grok-review/lenses/<name>.md` for editing |
| `init [<lens>] [options]` | seed the brief for a lens from its template, then stop |
| `review [<lens>] [options]` | run the review (the brief must already be filled in) |
| `status` | is a review running here, what was promoted last |
| `usage [--topic <slug>]` | the ledger: what every attempt consumed |
| `cancel` | stop the review running in this repository |
| `last` | print the path of the last promoted review, or abort |
| `assert-clean` | refuse if any `.grok-review` file is staged for commit |

Options for `init` / `review`: `--topic <slug>`, `--round <N>`, `--since <ref>`, `--full`,
`--base <ref>`, `--effort <level>`, `--force`, `--force-size`, `--parallel`. `--effort` is
`none|minimal|low|medium|high|xhigh|max` and defaults to `medium` (also `GROK_REVIEW_EFFORT`). `--fix`
is **yours, not the harness's** — it changes nothing about the run, only what you do afterwards (see
Phase B below).

## The workflow

### 1. setup — once per repository

```bash
bash <skill-dir>/scripts/run-review.sh setup
```

Present the output verbatim. If the last line reads `setup OK`, the harness is ready. Every missing
requirement is printed with the exact command that fixes it — relay those; do not run installs
yourself. If a probe verdict failed, no review can run until it passes.

The harness's closing `Next:` line names `/grok:review`, which is Claude Code's namespaced command.
Outside Claude Code there is no such command — translate it to `/grok-review review <lens>` (or run
`init <lens>` and then `review`). Do not relay `/grok:review` as something to type.

### 2. Pick a lens

The lens is one kind of review. Six ship: `code` (the default), `architecture`, `adversarial`,
`simplicity`, `security`, `coverage`. Run `lenses` to see the real list — a repository can override
any shipped lens or add its own under `.grok-review/lenses/`, so never assume the shipped set. A lens
with `require:` in its frontmatter refuses a brief whose named sections are empty; that is how
`adversarial` is bounded by its claim list.

### 3. Write the brief — this is your job

```bash
bash <skill-dir>/scripts/run-review.sh init <lens> <options>
```

It prints the brief path and copies the lens template there. Fill in the four sections only this
session can write — they are what turn a general impression into a verifiable review:

- **the artifact** — branch and head SHA, the PR link, the committed spec path. Cite paths and SHAs,
  never "the doc we discussed"; the reviewer has no session context whatsoever;
- **scope** — the dimensions to review, and an explicit out-of-scope list. For `adversarial`, the
  enumerated claim list *is* the scope;
- **settled decisions** — the owner's calls, marked do-not-re-litigate;
- **load-bearing claims** — what the change rests on, each phrased so it can be checked against the
  code.

Every `<TODO: …>` must be gone — the harness refuses a brief that still carries one, or whose
required sections are empty. Do not paste the diff into the brief and do not generate a patch: the
reviewer runs its own `git diff` over the range the harness gives it. Show the user the filled
brief's scope and claims in a few lines before launching. If you cannot yet describe the change in
load-bearing claims, say so rather than inventing them.

### 4. Run it — it takes minutes

```bash
bash <skill-dir>/scripts/run-review.sh review <lens> <options>
```

Run it in the background if your host supports that; otherwise run it with a long timeout and let it
block. The process exiting IS the completion signal — do not poll and do not write a wait loop. Tell
the user it started and that `status` shows whether it is still running and `cancel` stops it.

### 5. Read the result

- **Exit 0** — the last stdout line is the promoted review's path. Read it. It is markdown: ranked
  `### F<n>` findings each with a `file:line` and a failure scenario, then a verdict, then a
  `## Claim table` of HOLDS / BROKEN / UNVERIFIED rows, one per load-bearing claim. Give the user the
  claim table first (it is the shortest true summary), then each finding as `file:line — title` with
  its failure scenario. Say plainly that the findings are claims from another model.
- **Exit non-zero** — the run **ABORTED**. Show the harness's stderr tail verbatim; every abort names
  its own fix. An abort is never "no findings": say no review was produced, do not proceed to a fix
  pass as though it passed, and do not relaunch on your own — the run accounting says what the
  attempt cost, and a blind relaunch re-bills from the top. The usual cause is an expired session
  (`grok login`).

Either way, relay the `--- run accounting ---` block: lens, model, turns, tokens, cost, and anything
the harness said it defaulted (a `--since` defaulted to the previous round's head means this was a
DELTA review).

### 6. Fix — only when the user asked, and only host-side

`--fix` (or the `fix` verb) never reaches the sandbox. You edit, host-side, with your own edit tool
and the normal permission prompts, confirming each finding against the code before touching it.

Take the findings in order (ranked most-severe first). For each, open the cited `file:line` and
**adversarially confirm the claim against the code** — does the failure scenario actually reproduce?
Then:

- **Skip, stating the reason**, any finding whose fix would change intended behaviour, would need
  changes well outside the reviewed diff, or that you judge a false positive after reading the code.
  Never churn risky code on a false positive.
- **Apply** the rest with the smallest edit that resolves the stated failure scenario. Never widen
  scope. Apply structural fixes first, then re-check which remaining findings still stand.

Record one line per finding in the response file the harness names (`<lens>-review[-rN]-response.md`
beside the review), citing the `F<n>` ids:

```
- F1 FIXED in <sha or "working tree"> — <one line>
- F2 WAIVED: <one line of reasoning>
```

That file is scratch under `.grok-review/`, so carry the surviving verdicts into the PR before merge
or the durable record dies with the working tree. It also seeds the next round: a waiver becomes a
claim the next reviewer re-checks against the delta, not a gag. Do not commit.

### 7. Round 2 is a delta

Round 1 recorded the head it reviewed. `/grok-review review <lens> --round 2` reviews only what
changed since then and costs a fraction of the first. If HEAD moved, say so: the last review's
findings are about older code.

## Lenses: override and extend

Put `.grok-review/lenses/<name>.md` in the repository and it wins over the shipped lens of the same
name; a name that does not ship becomes a new lens. There is no list to register it in. A lens that
applies to every review — house rules, components reviewers keep mis-reading — goes in
`.grok-review/lenses/_context.md`, which the harness appends to **every** brief as *Project context*.

## Cost discipline

Grok is an agent, so the `git diff` it runs sits in its context and is re-sent on every step: what a
run reads is multiplied by how long the run turns out to be. The harness keeps this in check, and so
should you:

- **Round N is seeded with round N−1's capped claim table and the disposition file**, not the whole
  previous review. A re-review with no recorded head refuses rather than quietly re-buying the branch;
  `--full` is the explicit opt-out.
- **Effort is pinned to `medium` by default** — the biggest single lever on the burn. Raise it with
  `--effort <level>` or `GROK_REVIEW_EFFORT` only when the change warrants the spend.
- **The size is printed on every run**, over budget or not; past `GROK_REVIEW_MAX_DIFF_LINES` the run
  refuses by default (the reviewer re-sends its whole context every step), and `--force-size` is the
  deliberate override.
- **The ledger** (`.grok-review/usage.log`) gets a row per attempt, failures included. In it `in_tok`
  is uncached input only; `total_tok` is the burn signal; an empty `cost` means the server reported an
  incomplete cost — unknown, never free.
- **One run at a time, repo-wide**, via `.grok-review/.running`; `--parallel` overrides and says so.

## Hard rules

- The reviewer is a **different model**. Do not replace it with a subagent and report the step done.
- An **abort is an abort**. Never report a failed run as "no problems found", and never run a fix pass
  as though it passed.
- **The sandboxed reviewer never edits anything.** All edits are yours, host-side, after the run
  exits, with the run's tree assertion already passed.
- The sandbox does **not** block the model's own API traffic: everything Grok reads is sent to its
  provider. Say so rather than implying otherwise.
