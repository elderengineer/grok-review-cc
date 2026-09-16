# grok-review-cc

Get a second opinion on your code from Grok, without leaving Claude Code. Grok runs in a read-only
sandbox, so it can read your repository but cannot change it.

```
/grok:review code              # review the current branch with the `code` lens
/grok:review security --fix    # review, then let Claude apply the findings
/grok:review code --round 2    # review again, but only what changed since round 1
/grok:setup                    # check the machine and the sandbox, no review
/grok:lenses                   # see your lenses, or make a new one
/grok:status                   # is a review running, and what was reviewed last
/grok:usage                    # what every review attempt has cost so far
/grok:cancel                   # stop the review that is running
/grok:fix                      # apply the last review's findings, without re-reviewing
```

## Install

Linux, or macOS with the caveat that the deny list is only enforced by the kernel on Linux.
`/grok:setup` checks every step below and prints the command for anything missing.

**1. Install grok and log in.**

```bash
curl -fsSL https://grok.com/install.sh | bash
grok login
```

**2. Install bubblewrap.** On Linux this is what makes the deny list real.

```bash
sudo apt install bubblewrap util-linux jq
```

**3. Install the plugin**, from the repository you want to review.

```
/plugin marketplace add elderengineer/grok-review-cc
/plugin install grok@grok-review-cc
/grok:setup
```

When setup prints `setup OK`, run your first review:

```
/grok:review code
```

Claude writes the brief from what it already knows about your change, shows you the scope and the
claims, and starts the review in the background.

> **One known version problem.** grok 1.0.13 with bubblewrap 0.6.1 refuses to start whenever the
> deny list is not empty. It is a version mismatch. It is not an attack, it is not Docker, and no
> change to the profile fixes it. `/grok:setup` spots this pair and prints the fix:
> `export GROK_BIN=$HOME/.grok/downloads/grok-1.0.5-linux-x86_64`.

## Other agents (opencode, ZCode, …)

Claude Code is not the only host. The harness, the lenses and the brief are agent-agnostic; the
plugin packaging is not. `install.sh` installs the portable parts for agents that follow the shared
`SKILL.md` + markdown-command conventions — opencode, ZCode, and anything else that scans
`~/.agents/skills`:

```bash
./install.sh            # symlink the skill into ~/.agents/skills, write the /grok-review command
./install.sh --copy     # copy it instead, so the install is self-contained
./install.sh --uninstall
```

It writes three files, and nothing else:

- `~/.agents/skills/grok-review/` — the skill. It carries `scripts/run-review.sh`, the lenses, and
  the confinement notes; the script self-locates them. opencode and ZCode read `~/.agents/skills`
  automatically, and ZCode also reads `<repo>/.agents/skills`. Claude Code does not discover it
  live — its route is the plugin below — though it can import skills from that directory.
- `~/.config/opencode/commands/grok-review.md` — the `/grok-review` command for opencode.
- `~/.zcode/commands/grok-review.md` — the same command for ZCode.

One entry point covers every verb:

```
/grok-review setup                 # check the machine and measure the sandbox
/grok-review review code --fix      # review the branch, then apply the findings
/grok-review review code --round 2  # review only what changed since round 1
/grok-review status                 # is a review running, what was reviewed last
```

There is no plugin namespace outside Claude Code, so it is `/grok-review`, not `/grok:review`.
`$ARGUMENTS` works the same way, so `--fix`, `--round` and the rest pass straight through.

Claude Code keeps using the plugin and `/grok:review`, `/grok:status`, … — the portable skill route
is for opencode and ZCode. (For the model-invoked form in Claude Code, link the skill into
`~/.claude/skills/`, or just use the plugin.)

## How a review works

You pick a lens. Claude writes a brief. Grok reads the code and answers.

The brief is a file. Claude fills in four things, because only the session that did the work knows
them:

- **The artifact.** The branch, the head SHA, and the path to the design doc or ticket. Real paths,
  not "the doc we talked about".
- **The scope.** What to review, and what to leave alone.
- **Settled decisions.** Choices you already made, so the reviewer does not argue them again.
- **Load-bearing claims.** The things the change depends on, written so they can be checked against
  the code.

Grok then runs its own `git diff`, reads whatever files it needs, and prints:

- numbered findings (`F1`, `F2`, …), each with a `file:line` and a concrete failure scenario;
- a verdict;
- a **claim table** that marks every claim you listed as HOLDS, BROKEN, or UNVERIFIED.

A finding with no failure scenario is just an opinion, and the lenses tell Grok to drop those.
"The claim holds" is a real answer, not a failed review.

The findings are claims from another model, not orders. `--fix` does not let Grok touch your files.
It tells Claude to check each finding against the code and then edit, on your machine, with the
normal permission prompts.

**`/grok:fix` is that same step on its own**, for a review you already ran without `--fix`. It finds
the last review, warns you if HEAD has moved since, then goes through the findings in order. For
each one Claude opens the `file:line` and decides:

- **skip it**, and say why, if the fix would change intended behaviour, would need changes far
  outside the diff, or if the claim does not hold up when Claude reads the code;
- **apply it** otherwise, with the smallest edit that fixes the described failure.

It then writes one line per finding into a notes file next to the review (`F1 FIXED …`,
`F2 WAIVED: …`) and tells you what it changed and what it skipped. It does not commit. Those notes
are given to the next round, so a waiver becomes something the next reviewer re-checks rather than
something it never hears about.

## Lenses

A lens is a template for one kind of review. Six come with the plugin:

| lens | what it asks | when to use it |
|---|---|---|
| `code` | does the change do what the design says? | the default, on a PR |
| `architecture` | is this the right design, and what else could you build? | a design doc, before any code |
| `adversarial` | can these specific claims be **broken**? | a change that rests on a few invariants |
| `simplicity` | could this be less code, fewer ideas, better placed? | a PR that grew while you wrote it |
| `security` | how would an attacker get in? | anything touching input, auth, or secrets |
| `coverage` | does the test suite cover what it claims to? | a PR that only adds tests |

Each lens is a separate run with its own brief. That is on purpose. A brief that asks for everything
gets a review that filters nothing.

Two lenses have extra rules. `adversarial` will not run unless you list the claims to attack; with
no list, it just generates work in proportion to how long it runs. `simplicity` is about quality
only, never bugs, and every suggestion has to say what gets deleted and why that is safe.

### Replacing a lens, or adding your own

Put a file at `.grok-review/lenses/<name>.md` in your repository and it wins over the shipped lens
of the same name. A name that does not ship at all just becomes a new lens. There is no list to
register it in.

```
/grok:lenses                       # what you have, and where each one came from
/grok:lenses new security          # copy the shipped `security` lens so you can edit it
/grok:lenses new fund-safety       # a lens only your repo has
```

This matters more than it sounds. The shipped `security` lens has a generic checklist, so it finds
generic problems. The same lens listing your real entry points, your real credential paths and your
real trust boundaries is a much better tool.

A lens starts with a few settings:

```yaml
---
name: fund-safety
summary: Where can money be lost — stranded, double-paid, unrefundable?
require: settled decisions, the ways money can be lost
---
```

`require` lists the brief sections that must not be empty. That is how a lens sets its own rules, the
way `adversarial` demands a list of claims.

If you want to add facts to *every* review instead of one lens, put them in
`.grok-review/lenses/_context.md`. The harness adds that to each brief as "Project context".

## The sandbox

**The plugin sets the sandbox up for you, but only when you run `/grok:setup`.** That command
writes two things into the repository you are reviewing, and nothing else:

- `.grok/sandbox.toml` — it adds a `[profiles.grok-review]` block. If the file already exists, the
  block is appended and your other profiles are left alone. If the block is already there, it is
  kept unless you pass `--force`. You can commit this file if you want everyone on the repo to
  review under the same rules.
- `.gitignore` — it adds one line, `.grok-review/`, so the harness's own files are never committed.

That is all it touches. `/grok:review` never creates or edits the profile. It only checks that the
profile is there and refuses to run if it is not.

### Why the sandbox is needed

A code review has to read the whole repository, so the reviewer has to be a real agent with a shell
and git, not a model handed a diff. That agent is a third-party model, and it runs on your machine
as you. With no sandbox it can do anything you can do: edit the code it is reviewing, read `~/.ssh`
and `~/.aws`, use your credentials on the network, and read your other repositories.

Grok has its own sandbox, and this plugin uses it, with one detail that matters. If a **built-in**
profile cannot be applied, grok prints a warning and keeps going *with no sandbox at all*. So
`--sandbox read-only` fails in the dangerous direction. A **custom** profile refuses to start
instead, and on Linux its non-empty `deny` list makes that refusal enforced by the kernel through
bubblewrap. That is why setup writes a custom profile:

```toml
[profiles.grok-review]
extends = "read-only"
deny = ["**/.env", "**/*.pem", "**/*.key", "**/id_rsa*", "**/auth.json", "**/.netrc", …]
```

Then it **tests** it. Setup runs one small grok call inside that profile that tries to write into
the repository and read a denied file, and reports four results: START, WRITE, DENY, READ. If any of
them fail, no review will run.

Two more checks. The harness refuses to run if `~/.grok/sandbox.toml` defines the same profile name,
because the user file quietly wins over the project one. And after every review it checks that
`git status` and `HEAD` are unchanged.

One thing the sandbox does **not** do: it does not block the model's own API traffic. Everything
Grok reads is sent to its provider. This plugin makes that clear rather than pretending otherwise.

## What a review costs

Grok is an agent, so the output of the `git diff` it runs becomes part of its context, and that
context is re-sent on every step. A small diff can cost a lot. In the first real run of this plugin,
a 14-line diff used 244,839 tokens across 7 turns.

Six things keep that in check:

- **Reasoning effort is pinned to `medium`.** It is the single biggest lever on the burn: left
  unpinned, the tier comes from `default_reasoning_effort` in `~/.grok/config.toml`, and an `xhigh`
  default is how a 466-line diff became a 41-turn, multi-million-token run. Override with
  `--effort <level>` (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`) or
  `GROK_REVIEW_EFFORT`.
- **A second review only looks at what changed.** Round 1 records the commit it reviewed, and round
  2 diffs from there. If there is no recorded commit, the run stops instead of quietly re-reading
  the whole branch. Use `--full` if you really want the whole thing.
- **You see the size before you pay for it.** Every run prints the file count, line count and byte
  count first, and past `GROK_REVIEW_MAX_DIFF_LINES` (2500) it **refuses** by default — the reviewer
  re-sends its whole context every step, so a big diff is paid many times over. `--force-size` is the
  deliberate override when you have decided to pay it.
- **Every attempt is logged** to `.grok-review/usage.log`, including failed ones. `/grok:usage`
  prints it. Note that `in_tok` counts uncached input only, `total_tok` is the real number to watch,
  and an empty cost column means the server did not report a cost. Empty means unknown, not free.
- **One review at a time per repository.** `/grok:status` shows what is running, `/grok:cancel`
  stops it and still records what it used. `--parallel` overrides this and says so.
- **Round 2 is given round 1's claim table and your notes**, not the whole previous review, which
  would be paid for again on every step.

## When a run fails

A failed run is never reported as "no problems found". The harness stops, returns a non-zero exit
code, and says why. It does that when the brief is incomplete, when a second review has nothing to
compare against, when the diff is empty, when grok exits badly or times out, when the answer is too
short or cut off or missing its claim table, and when the working tree changed while Grok was
running.

Whatever the run produced is kept *next to* the review file, never at it, so a half-finished answer
can never be mistaken for a real review. If the model was reached, the attempt is still written to
the log, so you can see what it cost.

## Layout

```
.claude-plugin/marketplace.json
plugins/grok/
  .claude-plugin/plugin.json
  commands/            review, setup, lenses, status, usage, cancel, fix
  lenses/              the six shipped lenses, any of which a repo can replace
  scripts/run-review.sh  the one script: checks, sandbox, budget, log, lock, probe
  skills/grok-runtime/   SKILL.md and reference/confinement.md
  tests/test-run-review.sh
grok-review/             the portable skill: SKILL.md + symlinks into plugins/grok (scripts, lenses, reference)
commands/grok-review.md  the single /grok-review command for opencode and ZCode
install.sh               install the skill + command into ~/.agents/skills and the host command dirs
```

Each repository you review keeps its files in `<repo>/.grok-review/`, which setup adds to
`.gitignore`: the log, the run marker, your own lenses, and one folder per topic holding its briefs,
reviews, claim tables and notes.

## Tests

`plugins/grok/tests/test-run-review.sh` runs the script against a **fake grok** and a throwaway git
repository. It checks lens overriding, the brief rules, the delta logic, the size limit, the log,
the lock, cancelling, and every check that runs after a review. It never contacts a provider and
never touches this repository's history.

`/grok:setup` is what tests the real sandbox on your machine.
`skills/grok-runtime/reference/confinement.md` records what has actually been measured, what is only
assumed, and the version table behind the warning above.

## License

MIT, see [LICENSE](LICENSE).
