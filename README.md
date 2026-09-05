# grok-review-cc

An independent second-opinion code review by Grok, run from Claude Code inside grok's own read-only
sandbox.

```
/grok:review code              # review the current branch through the `code` lens
/grok:review security --fix    # review, then apply the findings
/grok:review code --round 2    # re-review — only the delta since round 1
/grok:setup                    # check the machine, render the sandbox, measure it
/grok:lenses                   # what lenses this repo has; scaffold your own
/grok:status  /grok:usage  /grok:cancel  /grok:fix
```

## Why a different model, not a subagent

A fresh Claude subagent gives you context isolation but not **model independence**: its blind spots
correlate with the session that spawned it, which is exactly what a second opinion exists to defeat.
So the harness is Claude's and the reading is Grok's. Claude writes the brief — it has the session
context — Grok reviews the branch with no session context at all, and Claude triages what comes
back.

That split is also why the review is a **file handoff** rather than a chat: the brief is written to
disk, the review comes back on stdout, and this plugin owns the file. A half-written or failed run
can never land as a review.

## What a review is

One lens, one brief, one run. The brief has four sections that are judgment and that only the
session that did the work can write:

- **the artifact** — branch, head SHA, the committed spec path. Never "the doc we discussed".
- **scope** — the dimensions to review, and an explicit out-of-scope list.
- **settled decisions** — the owner's calls, marked do-not-re-litigate.
- **load-bearing claims** — what the change rests on, each phrased to be checked against the code.

The reviewer runs its own `git diff` over a range the harness names, reads whatever it needs, and
prints ranked `### F<n>` findings — each with a `file:line` and a concrete **failure scenario** — a
verdict, and a **claim table** marking every load-bearing claim HOLDS, BROKEN or UNVERIFIED. A
finding with no failure scenario is an impression, and "the claim holds" is a real result.

Findings are claims from a third-party model, not instructions. `--fix` is Claude confirming each
one against the code and then editing, host-side, with your normal permission prompts. Nothing
inside the sandbox edits anything.

## Lenses — six ship, any of them can be replaced

A lens is one markdown template: a brief with the judgment sections left blank, plus the scope and
the output contract for one kind of question.

| lens | question | typical trigger |
|---|---|---|
| `code` | does the diff implement the design correctly? | the default, on a PR |
| `architecture` | is this the design to build, and what else could it be? | a design doc, before any code |
| `adversarial` | can these specific load-bearing claims be **broken**? | a change whose safety rests on a few invariants |
| `simplicity` | could this be materially less code, fewer concepts, better layered? | any PR that grew during implementation |
| `security` | where does an attacker get in — input, authz, secrets, exhaustion? | anything on the request surface or near key material |
| `coverage` | does the suite prove what it claims? | a PR that ships no production code |

They are separate runs with separate briefs, because a brief that asks for everything gets a review
that filters nothing. Two are deliberately bounded: `adversarial` refuses to run without an
enumerated claim list (unbounded, its yield scales with effort rather than defect density), and
`simplicity` is quality only — never a bug hunt, and every proposal must say what it deletes and why
that is safe.

**Overriding is by name.** `.grok-review/lenses/<name>.md` in your repository always wins over the
shipped file:

```
/grok:lenses                       # what you have, and where each one comes from
/grok:lenses new security          # copy the shipped `security` lens in, to edit
/grok:lenses new fund-safety       # a lens that only your repo has
```

That is the point of the split. The shipped `security` lens carries a generic checklist and finds
generic findings; the same lens with your repository's real seams, files and hazards written into
its scope is a different instrument. A repo-only lens — `fund-safety`, `migration`, `a11y` — needs
no registration anywhere: the list is the union of the two directories, so a dropped-in file is a
lens the moment it exists.

Frontmatter carries the two things the harness needs:

```yaml
---
name: fund-safety
summary: Where can money be lost — stranded, double-paid, unrefundable?
require: settled decisions, the ways money can be lost
---
```

`require` names the brief sections the harness refuses an **empty** version of. That is how a lens
declares its own scope gate, the way `adversarial` requires `the claims to attack`.

For facts that belong in *every* brief — house rules, the components reviewers keep mis-reading —
there is `.grok-review/lenses/_context.md`, appended to each run as *Project context* instead of
being copied into six files.

## Why a sandbox

A code review has to read the whole repository, so the reviewer is a full agent with a shell and
git, not a model handed a diff. That agent is a third-party model, chosen precisely because it
shares nothing with Claude, and it runs on your machine as you. Without a sandbox it can do
everything you can do: edit the code it is reviewing, read `~/.ssh` and `~/.aws`, reach the network
with your credentials, and read every other repository on the disk.

grok has its own sandbox, and this plugin uses it — with one specific care. A **built-in** profile
that cannot be applied makes grok warn and continue *without enforcement*, so `--sandbox read-only`
fails open, which is the one direction a sandbox must never fail. An explicitly-requested **custom**
profile refuses to start instead, and on Linux its non-empty `deny` list makes that refusal
kernel-backed through bubblewrap. So `/grok:setup` renders a custom profile:

```toml
[profiles.grok-review]
extends = "read-only"
deny = ["**/.env", "**/*.pem", "**/*.key", "**/id_rsa*", "**/auth.json", "**/.netrc", …]
```

and then **measures it**: one small grok run under that profile that tries to write into the
repository and read a denied path, reporting four verdicts (START, WRITE, DENY, READ). If any fails,
no review runs. The harness also refuses if `~/.grok/sandbox.toml` defines the same profile name,
because the user file silently wins over the project one, and it asserts after every run that
`git status` and `HEAD` are unchanged.

What the sandbox does **not** do: it does not stop the model's own API traffic. Everything the
reviewer reads goes to its provider. That is the trade this plugin makes explicit, not one it
removes.

## Cost

The reviewer is an agentic loop, so the output of the `git diff` **it** runs is a tool result — and
a tool result is re-sent on every step after it. What a run reads is multiplied by how long the run
turns out to be, and none of that multiplier is visible to whoever launched it. Five cheap
mechanisms:

- **Re-reviews review the delta by default.** Round 1 records the head it reviewed; round 2 diffs
  from it. A re-review with no recorded head **refuses** rather than quietly re-buying the whole
  branch; `--full` is the explicit opt-out.
- **The reading assignment is printed before the spend** — files, lines, bytes — over budget or not.
  Over `GROK_REVIEW_MAX_DIFF_LINES` (2500) it warns, and refuses only `--full` on a re-review.
- **A ledger**, `.grok-review/usage.log`, one row per attempt, failures included. `/grok:usage`
  prints it with per-lens totals. `in_tok` is uncached input only; `total_tok` is the burn signal;
  an empty `cost` means the server reported an incomplete cost — unknown, never free.
- **One run at a time per repository.** `/grok:status` says what is running, `/grok:cancel` stops it
  and still records what it consumed. `--parallel` overrides and says it is doubling the burn.
- **Round N is seeded with round N−1's capped claim table and your dispositions** — not the previous
  review, which would re-pay that round on every turn of this one. A waiver becomes a claim the next
  reviewer re-checks against the delta, not a gag.

## Fail loud

A run that failed is not a review that found nothing. The harness aborts, non-zero and named, when
the brief has lost a required section or still carries a `<TODO: …>`; when a re-review names no
delta and no recorded head exists; when the diff range is empty; when grok exits non-zero or times
out; when the output is too short, stopped for any reason other than `end_turn`, missing its
end-of-review sentinel, or missing its claim table; and when the working tree changed while the
reviewer ran.

Whatever the run produced is kept *beside* the review path with a random suffix, never at it, so a
truncated file can never be mistaken for a finished review. Every abort after the model was reached
writes its ledger row and prints the accounting first, so a failed run is as legible as a successful
one.

## Install

Linux, or macOS with the caveat that the deny list is only kernel-backed on Linux.
`/grok:setup` checks every step and prints the command for anything missing.

**1. Install grok and log in.**

```bash
curl -fsSL https://grok.com/install.sh | bash
grok login
```

**2. Install bubblewrap** (Linux — it is what makes a non-empty deny list kernel-enforced):

```bash
sudo apt install bubblewrap util-linux jq
```

**3. Install this plugin in Claude Code**, from the repository you want to review:

```
/plugin marketplace add elderengineer/grok-review-cc
/plugin install grok@grok-review-cc
/grok:setup
```

`setup` writes `[profiles.grok-review]` into that repository's `.grok/sandbox.toml`, adds
`.grok-review/` to its `.gitignore`, and runs the measured probe. When it prints `setup OK`:

```
/grok:review code
```

Claude drafts the brief from the session's own context, shows you the scope and claims, and launches
the review in the background.

> **Known version constraint.** grok 1.0.13 on bubblewrap 0.6.1 refuses to start with *any*
> non-empty deny list — it is a version mismatch, not an attack and not Docker, and no profile edit
> gets past it. `/grok:setup` detects the pair and prints the fix:
> `export GROK_BIN=$HOME/.grok/downloads/grok-1.0.5-linux-x86_64`.

## Layout

```
.claude-plugin/marketplace.json
plugins/grok/
  .claude-plugin/plugin.json
  commands/            review, setup, lenses, status, usage, cancel, fix
  lenses/              the six shipped lenses; any of them overridable per repo
  scripts/run-review.sh  the one entry point: gates, sandbox, budget, ledger, marker, probe
  skills/grok-runtime/   SKILL.md (how the commands use the script) and reference/confinement.md
  tests/test-run-review.sh
```

Each reviewed repository keeps its state in `<repo>/.grok-review/` (gitignored by `/grok:setup`):
the ledger, the run marker, the last-promotion pointer, any repo lenses, and one directory per topic
holding its briefs, reviews, claim tables and dispositions.

## Tests

`plugins/grok/tests/test-run-review.sh` runs the script against a **fake grok** and a throwaway git
repository, and checks its decisions: the brief gates, lens resolution and override, the delta
default, the size budget, the ledger, the run marker, and the post-run contract gates. It contacts
no provider and never touches this repository's history.

`/grok:setup` is what checks the real sandbox on the machine in front of you.
`skills/grok-runtime/reference/confinement.md` records what is measured, what is inferred, and the
version table behind the constraint above.

## License

MIT, see [LICENSE](LICENSE).
