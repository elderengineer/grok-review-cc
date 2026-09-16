---
name: grok-runtime
description: Internal contract for the Grok review harness — how /grok:review, /grok:setup, /grok:lenses, /grok:status, /grok:usage, /grok:cancel and /grok:fix call scripts/run-review.sh, what a lens is, what a promoted review looks like, and what an abort means. Read reference/ only on failure.
user-invocable: false
---

# grok review runtime

The plugin runs one **independent** review of a branch or a design doc: a reviewer that shares no
session, and no model, with this one. A fresh Claude subagent gives context isolation but not model
independence — its blind spots correlate with this session's, which is the thing the step exists to
defeat. The harness is Claude's; the reading is Grok's.

Four jobs the harness owns, none of which the reviewer can be asked to do for itself:
**confinement** (grok's own custom sandbox profile, fail-closed, measured by `setup`), **cost** (the
delta default, the size budget, the ledger, the one-run marker), **fail-loud** (an abort is never
"no findings"), and the Claude-side UX (writing the brief, Phase B, the dispositions).

## The one entry point

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" setup [--force] [--no-probe]   # /grok:setup
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" lenses | new-lens <name>       # /grok:lenses
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" init   <lens> [args…]          # /grok:review, phase 1
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" review <lens> [args…]          # /grok:review, phase 2
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" status | usage | cancel | last | assert-clean
```

`review` runs in the background (`run_in_background: true`); the process exiting is the completion
signal. There is no daemon, no polling, no id scraping: the review file either exists (promoted) or
does not (aborted, evidence kept beside it).

## Lenses: shipped, overridable, extensible

A lens is one markdown template — a brief with the judgment sections left blank — plus optional
frontmatter (`summary`, `require`). Resolution is by NAME:

| where | wins | what it is |
|---|---|---|
| `<repo>/.grok-review/lenses/<name>.md` | yes | this repo's override, or a lens only this repo has |
| `plugins/grok/lenses/<name>.md` | fallback | the shipped default |

Nothing enumerates the set — the list IS the union of the two directories, so a dropped-in file is a
lens the moment it exists. Six ship: `code`, `architecture`, `adversarial`, `simplicity`,
`security`, `coverage`. They are separate runs with separate briefs, because a brief that asks for
everything gets a review that filters nothing.

`require: a, b` in the frontmatter names the brief sections the harness refuses an *empty* version
of. That is how `adversarial` is bounded by its claim list: unbounded, an adversarial sweep's yield
scales with effort rather than defect density. Default when absent: `settled decisions`.

`<repo>/.grok-review/lenses/_context.md`, when present, is appended to **every** brief as *Project
context* — repo facts that would otherwise be copied into six lens files.

## The exchange, in `<repo>/.grok-review/<topic>/`

The topic groups a brief with its rounds and dispositions; it defaults to the branch name.

| file | written by |
|---|---|
| `<lens>-review[-rN]-prompt.md` | Claude, from the lens template (`init` seeds it) |
| `<lens>-review[-rN].md` | the harness, from Grok's stdout — **only on promotion** |
| `<lens>-review[-rN].head` | the harness, on promotion — the head SHA that round reviewed |
| `<lens>-review[-rN].claims.md` | the harness, on promotion — the capped claim table for round N+1 |
| `<lens>-review[-rN]-response.md` | Claude, the dispositions |
| `../usage.log`, `../last`, `../.running` | the harness — ledger, last promotion, run marker |

## What a promoted review is

Markdown: ranked `### F<n>` findings each with a location and a **failure scenario**, an explicit
verdict, and a `## Claim table` of HOLDS / BROKEN / UNVERIFIED rows — one per load-bearing claim in
the brief. The harness gates on the table's presence: it is round N+1's compact state, capped at
`GROK_REVIEW_CLAIM_TABLE_CAP` (15). "The claim holds" is a real result.

## What an abort is

Non-zero exit, `ABORT:` on stderr naming the cause and its fix, nothing at the review path. The
harness aborts when the brief has lost a required section or still carries a `<TODO: …>`; when a
review file already exists; when another run holds the lock or the repo-wide marker; when a
re-review names no delta and no recorded head exists; when `--since` is not an ancestor of HEAD or
is HEAD; when the diff range is empty; when `--full` on a re-review busts the size budget; when grok
exits non-zero or times out; when the output is short, stopped for any reason other than `end_turn`,
missing the `<!-- END OF REVIEW -->` sentinel, or missing its claim table; and when the working tree
changed while the reviewer ran.

Report an abort as an abort. Never proceed to a fix pass as though the review passed with no
findings. Do not relaunch on your own — the accounting says what the attempt cost.

Every abort **after the model was reached** writes its ledger row and prints the accounting first,
so a failed run is as legible as a successful one. Gates that fire before anything was sent write
nothing: a row for them would read as a review that launched and was lost. Whatever the run produced
is kept beside the review path with a random suffix (`.json` raw result, `.partial.XXXXXX` extracted
text, `.err` stderr) and **never at the review path itself**, so a truncated file can never be
mistaken for a finished review.

## Cost, and why the harness is this careful

The reviewer is an agentic loop. The output of the `git diff` **it** runs is a tool result, and a
tool result sits in the context and is re-sent on every step after it — so what a run reads is
multiplied by how long the run turns out to be, and none of that multiplier is visible to whoever
launched it.

- **Effort is pinned to `medium` by default** — the biggest single lever on the burn. Unpinned, the
  tier comes from `default_reasoning_effort` in `~/.grok/config.toml`, which is how a small diff can
  run at `xhigh` and cost millions of tokens. Override with `--effort <level>` or
  `GROK_REVIEW_EFFORT` (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`).
- **`--since <ref>` scopes the reviewer to the delta**, and with `--round N` it is the DEFAULT: round
  N−1 recorded its head, round N reads that and diffs from it. A re-review with no recorded head
  **refuses** rather than quietly re-buying the whole branch. `--full` is the explicit opt-out.
- **The size is printed on every run**, over budget or not. Past `GROK_REVIEW_MAX_DIFF_LINES` (2500)
  it **refuses by default** — the reviewer re-sends its whole context every step, so the diff is paid
  many times over, and `--full` is not special-cased: it is the same gate. `--force-size` is the
  deliberate override.
- **The ledger** (`.grok-review/usage.log`) gets a row per attempt, success and failure alike.
  `in_tok` is uncached input only; `total_tok` is the burn signal; an empty `cost` means the server
  reported an incomplete cost — unknown, never free.
- **One run at a time, repo-wide**, via `.grok-review/.running`. A marker whose process is gone is
  cleared with a note. `--parallel` overrides and says it is doubling the burn.
- **Round N is seeded with round N−1's capped claim table and the disposition file** — not the
  previous review, which would re-pay that round on every turn of this one.

## Phase B — `--fix`

`--fix` never reaches the sandbox. The run is identical with or without it; Phase B is Claude,
host-side, with its own Edit tool and the normal permission prompts, confirming each finding against
the code before editing and skipping — with a stated reason — any that would change intended
behaviour, need changes well outside the diff, or that turn out to be false positives. A third-party
model with a shell and edit rights running as the user is the thing this plugin exists to prevent.

## On failure, read

- `reference/confinement.md` — what holds the reviewer, what is measured versus inferred, and the
  grok/bubblewrap version combination that refuses to start
