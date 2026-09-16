#!/usr/bin/env bash
#
# One independent Grok review, over a file handoff, in any git repository.
#
#   run-review.sh setup      [--force] [--no-probe]
#   run-review.sh lenses     [--json]
#   run-review.sh new-lens   <name> [--from <name>] [--force]
#   run-review.sh init       [<lens>] [--topic <slug>] [--round <N>] [--force]
#   run-review.sh review     [<lens>] [--topic <slug>] [--round <N>] [--since <ref> | --full] …
#   run-review.sh status | usage [--topic <slug>] | cancel | last | assert-clean
#
# The reviewer runs headless under a CUSTOM grok sandbox profile (`.grok/sandbox.toml`): it reads
# any file and runs read-only git itself, and it cannot write to the working tree. The review
# arrives on stdout and THIS script owns the response file, so a half-written or failed run never
# lands as a review.
#
# A review is not cheap, and its cost is not the diff read once: the reviewer is an agentic loop, so
# the output of the `git diff` IT runs sits in its context and is re-sent on every subsequent step —
# an unnecessarily large read is billed dozens of times over. Hence the usage discipline: delta
# diffs for re-reviews (--since, defaulted from the previous round's recorded head), a diff-size
# budget that makes the size VISIBLE before the spend, a TSV ledger of what every run consumed, and
# a repo-wide marker that keeps runs sequential by default.
#
# Everything the harness writes lives under <repo>/.grok-review/ (gitignored by `setup`), except the
# sandbox profile, which grok resolves only from <repo>/.grok/sandbox.toml or ~/.grok/sandbox.toml.
#
set -euo pipefail

SENTINEL='<!-- END OF REVIEW -->'
# The lens's own closing instruction, immediately above the sentinel in every shipped lens and in the
# template below. The brief is assembled so the injected sections (reading assignment, delta, previous
# round, project context) sit BEFORE it: a comment strip deletes the sentinel, and without this split
# the instruction is left dangling above "## Reading assignment" — the reviewer ends the response on
# the next heading it reads rather than on the sentinel the instruction names.
CLOSING_INSTRUCTION='End the response with this exact line, on its own, and nothing after it:'
MIN_BYTES=400

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULT_LENS_DIR="$PLUGIN_DIR/lenses"

GROK_BIN="${GROK_BIN:-$(command -v grok || echo "$HOME/.grok/bin/grok")}"
# The model stays UNPINNED on purpose: --model is not passed, so grok uses `[models] default` from
# ~/.grok/config.toml, and the model that actually answered is read back off the result and stamped
# on the review file. Pinning it here would be a second source of truth for the reviewer's identity,
# and it drifts silently.
#
# Effort IS pinned, defaulting to `medium`. Leaving it unpinned handed the tier to
# `default_reasoning_effort` in ~/.grok/config.toml, and an `xhigh` default is how a 466-line diff
# became a 41-turn, multi-million-token run. Override it per run with `--effort <level>` or set
# GROK_REVIEW_EFFORT. Canonical levels: none, minimal, low, medium, high, xhigh, max.
MODEL="${GROK_REVIEW_MODEL:-}"
EFFORT="${GROK_REVIEW_EFFORT:-medium}"
TIMEOUT_SECS="${GROK_REVIEW_TIMEOUT:-1800}"
SANDBOX="${GROK_REVIEW_SANDBOX:-grok-review}"

# The size of what the reviewer is about to pull into its own context. It is not paid once: the
# `git diff` output is a tool result, and a tool result is re-sent on every step after it, so the
# line count below multiplies by the length of the run.
MAX_DIFF_LINES="${GROK_REVIEW_MAX_DIFF_LINES:-2500}"
# Round N is seeded with round N-1's claim table, not the whole previous review. Extras are billed
# on every later turn, so the extract is capped.
CLAIM_TABLE_CAP="${GROK_REVIEW_CLAIM_TABLE_CAP:-15}"

die() { echo "ABORT: $*" >&2; exit 1; }
say() { echo "grok-review: $*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: run-review.sh <command> [options]

  setup     [--force] [--no-probe]   check the host, render the sandbox profile, gitignore the
                                     state dir, and MEASURE the sandbox with a small probe run
  lenses    [--json]                 list the lenses available here: shipped defaults, repo
                                     overrides, and repo-only lenses
  new-lens  <name> [--from <lens>]   scaffold .grok-review/lenses/<name>.md for editing, seeded
            [--force]                from <lens> (or the shipped lens of the same name)
  init      [<lens>] [options]       seed the brief for a lens from its template, then stop
  review    [<lens>] [options]       run the review (the brief must already be filled in)
  status                             is a review running here, what was promoted last
  usage     [--topic <slug>]         the ledger: what every attempt consumed
  cancel                             stop the review running in this repository
  last                               print the path of the last promoted review, or abort
  assert-clean                       refuse if any .grok-review file is staged for commit

options for init / review:
  --lens <name>   the lens to review through (also accepted as the first positional word)
  --topic <slug>  groups a brief, its rounds and its dispositions. Default: the current branch
  --round <N>     re-review round, >= 2; suffixes every path with -r<N>
  --since <ref>   review only the DELTA, `git diff <ref>...HEAD`. Must be an ancestor of HEAD and
                  not HEAD. With --round >= 2 this DEFAULTS to the head the previous round
                  recorded; with no recorded head the run refuses rather than silently re-ship the
                  whole branch
  --full          review the whole <base>...HEAD diff even on a re-review — explicit, because it
                  pays again for the rounds already reviewed
  --base <ref>    the branch this change is measured against. Default: origin's default branch,
                  else main/master/develop/trunk, whichever resolves first
  --effort <lvl>  reasoning effort for the reviewer: none|minimal|low|medium|high|xhigh|max.
                  Default: medium (GROK_REVIEW_EFFORT). The reviewer re-sends its whole context on
                  every step, so this is the single biggest cost lever.
  --force         overwrite an existing brief (init) or review file (review)
  --force-size    run even though the diff exceeds GROK_REVIEW_MAX_DIFF_LINES
  --parallel      run even though another review holds .grok-review/.running

env: GROK_BIN GROK_REVIEW_MODEL GROK_REVIEW_EFFORT GROK_REVIEW_TIMEOUT GROK_REVIEW_SANDBOX
     GROK_REVIEW_MAX_DIFF_LINES GROK_REVIEW_CLAIM_TABLE_CAP GROK_REVIEW_BASE
EOF
  exit 2
}

# --- repository layout ---------------------------------------------------------------------------
need_repo() {
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "not inside a git repository — the reviewer diffs a branch, so there has to be one."
  STATE="$ROOT/.grok-review"
  LENS_DIR="$STATE/lenses"
  LEDGER="$STATE/usage.log"
  MARKER="$STATE/.running"
  LASTFILE="$STATE/last"
  PROFILE_FILE="$ROOT/.grok/sandbox.toml"
}

# --- lenses: shipped defaults, overridable per repository ----------------------------------------
# Resolution is by NAME: <repo>/.grok-review/lenses/<name>.md wins over the shipped
# plugins/grok/lenses/<name>.md. A repo can therefore replace a default lens, or add one that does
# not ship at all, without forking the plugin. Nothing here enumerates the shipped set — the list
# IS the union of the two directories, so a dropped-in file is a lens the moment it exists.
lens_name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }

resolve_lens() { # <name> → path on stdout
  local n="$1"
  [ -f "$LENS_DIR/$n.md" ] && { echo "$LENS_DIR/$n.md"; return 0; }
  [ -f "$DEFAULT_LENS_DIR/$n.md" ] && { echo "$DEFAULT_LENS_DIR/$n.md"; return 0; }
  return 1
}

lens_origin() { # <name> → default | overridden | project
  if [ -f "$LENS_DIR/$1.md" ]; then
    [ -f "$DEFAULT_LENS_DIR/$1.md" ] && echo overridden || echo project
  else
    echo default
  fi
}

# One frontmatter key. Frontmatter is optional; a lens without it is still a lens.
lens_meta() { # <file> <key>
  awk -v k="$2" '
    NR==1 && $0 != "---" { exit }
    NR==1 { inside = 1; next }
    inside && $0 == "---" { exit }
    inside && match($0, "^[[:space:]]*" k "[[:space:]]*:[[:space:]]*") { print substr($0, RLENGTH + 1); exit }
  ' "$1"
}

lens_body() { # <file> — the template, frontmatter removed
  awk 'NR==1 && $0=="---" { fm=1; next } fm && $0=="---" { fm=0; next } !fm' "$1"
}

lens_list() { # → "<name> <origin> <summary>" per line, sorted
  local f n
  {
    [ -d "$DEFAULT_LENS_DIR" ] && ls "$DEFAULT_LENS_DIR" 2>/dev/null
    [ -d "$LENS_DIR" ] && ls "$LENS_DIR" 2>/dev/null
  } | grep -E '\.md$' | grep -v '^_' | sed 's/\.md$//' | sort -u | while read -r n; do
    f="$(resolve_lens "$n")" || continue
    printf '%s\t%s\t%s\n' "$n" "$(lens_origin "$n")" "$(lens_meta "$f" summary)"
  done
}

show_lenses() {
  local n o s
  printf '%-22s %-11s %s\n' LENS WHERE SUMMARY
  while IFS=$'\t' read -r n o s; do
    printf '%-22s %-11s %s\n' "$n" "$o" "${s:-—}"
  done < <(lens_list)
  echo
  echo "default    ships with the plugin        $DEFAULT_LENS_DIR"
  echo "overridden this repo replaced it        $LENS_DIR"
  echo "project    this repo added it           $LENS_DIR"
  echo
  echo "Override or add one:  run-review.sh new-lens <name> [--from <lens>]"
  [ -f "$LENS_DIR/_context.md" ] &&
    echo "Project context:      $LENS_DIR/_context.md is appended to EVERY brief."
  return 0
}

new_lens() { # <name> [--from <lens>] [--force]
  local name="$1" from="" force=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)  [ $# -ge 2 ] || usage; from="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) usage ;;
    esac
  done
  lens_name_ok "$name" || die "lens name '$name' is not usable — use lowercase letters, digits, '.', '-' and '_', starting with a letter or digit."
  local dest="$LENS_DIR/$name.md" src=""
  if [ -e "$dest" ] && [ "$force" -ne 1 ]; then
    die "$dest already exists — edit it, or pass --force to reset it."
  fi
  src="$(resolve_lens "${from:-$name}")" || src=""
  mkdir -p "$LENS_DIR"
  if [ -n "$src" ]; then
    cp "$src" "$dest"
    say "seeded $dest from $src — edit it; it now wins over the shipped lens of that name."
  else
    cat >"$dest" <<EOF
---
name: $name
summary: <TODO: one line — what this lens asks that the others do not>
require: settled decisions, load-bearing claims
---

# $name review — <TODO: the change, in a few words>

You are reviewing this independently. You have the repository and this brief; you were not part of
the work, and should not assume anything the brief does not state.

You run headless under a **read-only sandbox**: read any file and run read-only git commands freely.
You cannot write, and builds and tests will not run — do not attempt them. **Print the review to
stdout**; the harness captures it. Diff exactly the range named under *Reading assignment* below.

## The artifact

- <TODO: what is under review — a branch and its head SHA, a design doc path, a PR link>
- <TODO: the spec or the intent this is measured against>

## Scope

<TODO: the dimensions to review. Be specific; an open-ended sweep is a generator rather than a
filter — its yield scales with effort spent rather than with defect density.>

**Out of scope:** <TODO: what not to report>, and everything under "settled decisions" below.

## Settled decisions — do not re-litigate

Decided by the owner. Report a consequence you think was missed, but do not re-argue the choice.

1. <TODO: decision — and the reason it was made>

## Load-bearing claims — check each against the code

1. <TODO: claim — and where to check it>

## Required output

Ranked findings, most severe first. Each heading is \`### F<n> — <short title>\` (\`F1\`, \`F2\`, …).
The disposition file and the next round cite these ids. For each:

- **Severity** — blocker / major / minor.
- **Location** — \`file:line\`.
- **Failure scenario** — concrete inputs or ordering → the wrong outcome. A finding without one is
  an impression; drop it.
- **Suggested fix** — the direction, not a patch.

Then an explicit **verdict**, with the reason.

## Claim table

One row per load-bearing claim from the brief, in brief order. **No extra rows** — the next round
is seeded with this table, and extras are billed on every later turn. Cap: $CLAIM_TABLE_CAP.

- HOLDS — the claim, verbatim from the brief
- BROKEN Fn — the claim
- UNVERIFIED — the claim

$CLOSING_INSTRUCTION

$SENTINEL
EOF
    say "scaffolded a new lens at $dest — fill every <TODO: …> in the template sections."
  fi
}

# --- brief gates ---------------------------------------------------------------------------------
# The brief minus its HTML comments. Every lens carries a header comment that NAMES the required
# sections, so a substring search over the raw file is satisfied by the boilerplate alone — the gate
# would pass a brief whose real sections were never written. Single-line comments are removed first:
# deleting the `<!--`→`-->` range without that would swallow everything up to the sentinel.
brief_body() { sed -E 's/<!--.*-->//g' "$1" | sed '/<!--/,/-->/d'; }

# Body of ONE markdown section, up to the next header. The title must BEGIN with the section name —
# matching it anywhere lets a decorative "## Example of how claims to attack look", or a prose line
# that merely names the section, donate its list items to the real section left empty. First match
# only, so a later look-alike header cannot stand in for an empty real one.
section_body() {
  awk -v re="^#+[[:space:]]+$2" '
    /^#+[[:space:]]/ { if (inside) { inside = 0; done = 1 } else if (!done && tolower($0) ~ re) { inside = 1 }; next }
    inside
  ' <<<"$1"
}

# A section that exists but says nothing is not a section.
require_items() { # <body> <section-name> <lens>
  local items; items="$(section_body "$1" "$2")"
  grep -qE '^[[:space:]]*([0-9]+\.|[-*])[[:space:]]+\S' <<<"$items" ||
    die "brief's '$2' section has no entries — see $(resolve_lens "$3"). That section IS the scope; empty, the pass is a generator rather than a filter."
}

# Rows of a review's Claim table: list items or markdown-table cells carrying HOLDS / BROKEN /
# UNVERIFIED. Presence-only — this does not judge whether the verdict is true.
claim_rows() { grep -iE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]].*\b(HOLDS|BROKEN|UNVERIFIED)\b|^[[:space:]]*\|.*\b(HOLDS|BROKEN|UNVERIFIED)\b' <<<"$1" || true; }

claim_row_count() { # <review-file>
  local rows
  rows="$(claim_rows "$(section_body "$(cat "$1")" 'claim table')")"
  printf '%s\n' "$rows" | grep -c '[^[:space:]]' || true
}

# Compact state for the NEXT round: the claim table, truncated to CLAIM_TABLE_CAP. Returns 1 when
# the review has no such rows — missing is a failed review, not an empty table.
extract_claim_table() { # <review-file> → stdout
  local rows n
  rows="$(claim_rows "$(section_body "$(cat "$1")" 'claim table')")"
  n="$(printf '%s\n' "$rows" | grep -c '[^[:space:]]' || true)"
  [ "${n:-0}" -gt 0 ] || return 1
  echo "## Claim table"
  echo
  if [ "$n" -gt "$CLAIM_TABLE_CAP" ]; then
    echo "<!-- $n rows in the review; showing the first $CLAIM_TABLE_CAP (GROK_REVIEW_CLAIM_TABLE_CAP). -->"
    echo
    printf '%s\n' "$rows" | head -n "$CLAIM_TABLE_CAP"
  else
    printf '%s\n' "$rows"
  fi
}

# --- reading grok's headless JSON result ----------------------------------------------------------
# One scalar field, addressed by a dotted path so the nested spend fields (`usage.total_tokens`) come
# out of the same helper as the top-level ones (`text`). Absent and null both read as the empty
# string, and a real 0 reads as "0": that distinction is load-bearing for `total_cost_usd`, which is
# ABSENT — not zero — whenever the server reported an incomplete cost.
json_str() { # <file> <dotted-path>
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" 'getpath($k | split(".")) | if . == null then "" else . end' "$1"
  else
    python3 - "$1" "$2" <<'PY'
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8"))
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
    if v is None:
        break
print("" if v is None else v)
PY
  fi
}

# The same field as a count. Anything absent, null or non-numeric is 0 — a ledger column that reads
# "0 tokens" is honest about a result that carried no usage block, whereas an empty column there
# would silently drop out of the totals.
json_int() { # <file> <dotted-path>
  local v; v="$(json_str "$1" "$2" 2>/dev/null || true)"
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

# Which model actually answered, read off `modelUsage`'s keys rather than off what we asked for —
# with nothing pinned, the request no longer names it. Empty when grok reported no per-model
# breakdown; that is a missing label on a finished review, never a reason to fail one.
json_models() {
  if command -v jq >/dev/null 2>&1; then jq -r '(.modelUsage // {}) | keys | join(", ")' "$1"
  else python3 -c 'import json,sys; print(", ".join(sorted((json.load(open(sys.argv[1])).get("modelUsage") or {}))))' "$1"; fi
}

# --- the usage ledger ------------------------------------------------------------------------------
# One append-only TSV line per attempt, success or failure. Reading this file is the cheapest thing
# in the harness; relaunching is the most expensive.
#
# Two columns need care:
#  * `in_tok` (`usage.input_tokens`) is UNCACHED INPUT ONLY — cache hits are the separate
#    `cache_read_tok` column. The burn signal for an agentic loop is `total_tok`, defined by the CLI
#    as input + both cache buckets + output (`~/.grok/docs/user-guide/14-headless-mode.md`
#    § *Token field policy*).
#  * `cost` is ABSENT, not zero, whenever the server did not report a complete cost
#    (`cost_is_partial`, the common case on pool/OAuth routes). It is recorded as an EMPTY column
#    then, never as 0, because a 0 would sum into a fake bill that reads as free.
LEDGER_COLS=$'when\ttopic\tlens\tround\tmodel\toutcome\tdiff_lines\tdiff_bytes\tturns\tin_tok\tcache_read_tok\tout_tok\ttotal_tok\tcost'

ledger_run() { # <outcome> — read straight off grok's JSON result in $RAW
  [ -n "${LEDGER:-}" ] || return 0
  local model cost
  model="${MODEL_USED:-}"
  [ -n "$model" ] || model="$(json_models "${RAW:-/dev/null}" 2>/dev/null || true)"
  cost="$(json_str "${RAW:-/dev/null}" total_cost_usd 2>/dev/null || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TOPIC:--}" "${LENS:--}" "${ROUND:-1}" "${model:--}" "$1" \
    "${DIFF_LINES:-0}" "${DIFF_BYTES:-0}" \
    "$(json_int "${RAW:-/dev/null}" num_turns)" \
    "$(json_int "${RAW:-/dev/null}" usage.input_tokens)" \
    "$(json_int "${RAW:-/dev/null}" usage.cache_read_input_tokens)" \
    "$(json_int "${RAW:-/dev/null}" usage.output_tokens)" \
    "$(json_int "${RAW:-/dev/null}" usage.total_tokens)" \
    "$cost" \
    >>"$LEDGER" 2>/dev/null || true
}

# Every post-run abort goes through here, so no failure path can die without saying what it cost.
# The PRE-run gates (brief, sandbox, existing output, marker) deliberately do not: nothing reached
# the model, and a ledger row for them would read as a review that was launched and lost.
fail() { # <outcome> <die-message…>
  ledger_run "$1"
  shift
  die "$@"
}

show_ledger() { # [topic]
  [ -s "$LEDGER" ] || die "no usage ledger at $LEDGER — no run has been recorded in this repository yet."
  local rows
  if [ -n "${1:-}" ]; then
    rows="$(awk -F'\t' -v t="$1" '$2==t' "$LEDGER")"
    [ -n "$rows" ] || die "no runs recorded for topic '$1' (see: run-review.sh usage)."
  else
    rows="$(cat "$LEDGER")"
  fi
  { printf '%s\n' "$LEDGER_COLS"; printf '%s\n' "$rows"; } |
    awk -F'\t' '{ printf "%-20s %-16s %-16s %-5s %-14s %-28s %8s %9s %5s %9s %13s %8s %10s %9s\n",
                  $1,substr($2,1,16),$3,$4,substr($5,1,14),substr($6,1,28),$7,$8,$9,$10,$11,$12,$13,$14 }'
  echo "per-lens totals:"
  printf '%s\n' "$rows" | awk -F'\t' '
    { runs[$3]++; i[$3]+=$10; ca[$3]+=$11; o[$3]+=$12; t[$3]+=$13; c[$3]+=$14 }
    END { for (k in runs) printf "  %-16s %3d run(s)  in %10d + cache %11d  out %8d  total %11d tok  $%.4f\n",
                                 k, runs[k], i[k], ca[k], o[k], t[k], c[k] }
  ' | sort
  printf '%s\n' "$rows" | awk -F'\t' '
    { n++; gi+=$10; gca+=$11; go+=$12; gt+=$13; gc+=$14 }
    END { printf "  %-16s %3d run(s)  in %10d + cache %11d  out %8d  total %11d tok  $%.4f\n",
                 "ALL", n, gi, gca, go, gt, gc }
  '
  echo
  echo "in_tok is UNCACHED input; cache_read_tok is the cache bucket; total_tok is the burn signal."
  echo "An empty cost column means the server reported an incomplete cost — unknown, never free,"
  echo "so the \$ totals above are a LOWER BOUND whenever any row's cost column is blank."
}

# --- the run marker --------------------------------------------------------------------------------
# Field 22 of /proc/<pid>/stat is the process's start time in jiffies since boot: unique per process
# on this boot, and NOT reused when the kernel recycles a PID. Stamping it in the marker is what
# makes "is the holder still alive?" answerable. Without it, `kill -0` says yes for ANY process that
# inherited the number, and every later run refuses until that unrelated process happens to exit.
proc_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || true; }

marker_alive() { # <marker-content> → 0 when the recorded process is still the one that wrote it
  local held="$1" pid rest started
  pid="${held%% *}"
  rest="${held#* }"; started="${rest%% *}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # A field 2 that is not a number came from an older marker format that recorded no start time:
  # fall back to liveness alone and treat the holder as LIVE. Unknown must mean "refuse", never
  # "clear it" — guessing stale is what lets two runs proceed.
  [[ ! "$started" =~ ^[0-9]+$ ]] || [ "$started" = "$(proc_start "$pid")" ]
}

# --- status / cancel / last -------------------------------------------------------------------------
show_status() {
  if [ -f "$MARKER" ]; then
    local held; held="$(cat "$MARKER" 2>/dev/null || true)"
    if marker_alive "$held"; then
      echo "RUNNING: $held"
      echo "  cancel it with: run-review.sh cancel"
    else
      echo "STALE MARKER: $held"
      echo "  that process is gone; the next run clears it by itself."
    fi
  else
    echo "no review is running in this repository."
  fi
  echo
  if [ -s "$LASTFILE" ]; then
    local p h
    p="$(cat "$LASTFILE")"
    h="$(cat "$LASTFILE.head" 2>/dev/null || true)"
    echo "last promoted review: $p"
    if [ -n "$h" ]; then
      if [ "$h" = "$(git rev-parse HEAD 2>/dev/null)" ]; then
        echo "  reviewed HEAD ($(git rev-parse --short "$h")) — still current."
      else
        echo "  reviewed $(git rev-parse --short "$h" 2>/dev/null || echo "$h"), and HEAD has moved since."
      fi
    fi
  else
    echo "no review has been promoted in this repository yet."
  fi
  echo
  if [ -s "$LEDGER" ]; then
    echo "last attempts:"
    { printf '%s\n' "$LEDGER_COLS"; tail -5 "$LEDGER"; } |
      awk -F'\t' '{ printf "  %-20s %-14s %-14s %-4s %-26s %8s %11s\n", $1,substr($2,1,14),$3,$4,substr($6,1,26),$7,$13 }'
  fi
}

do_cancel() {
  [ -f "$MARKER" ] || die "no review is running in this repository (no $MARKER)."
  local held pid
  held="$(cat "$MARKER" 2>/dev/null || true)"
  pid="${held%% *}"
  if ! marker_alive "$held"; then
    rm -f "$MARKER"
    echo "nothing was running — cleared a stale marker ($held)."
    exit 0
  fi
  kill -TERM "$pid" 2>/dev/null || die "could not signal $pid — cancel it by hand."
  echo "sent TERM to $pid ($held)."
  # The harness traps TERM: it kills its grok child, writes the ledger row for what the attempt
  # consumed, and releases the marker. Give it a moment so this command can report the outcome
  # rather than leaving the caller to guess.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$MARKER" ] || { echo "the run released the marker; the attempt is recorded in $LEDGER."; exit 0; }
    sleep 0.5
  done
  echo "WARNING: $MARKER still held after 5s. If $pid is gone, the next run clears it by itself."
}

show_last() {
  [ -s "$LASTFILE" ] || die "no promoted review in this repository yet — run a review first."
  local p; p="$(cat "$LASTFILE")"
  [ -f "$p" ] || die "$LASTFILE points at $p, which no longer exists."
  echo "$p"
}

# Everything the harness writes lives under .grok-review/, which `setup` gitignores. This gate is by
# PATH COMPONENT rather than by .gitignore, so it means the same thing in a clone that predates the
# ignore line — and it deliberately does not match the plugin's own files.
assert_clean() {
  local staged
  staged="$(git diff --cached --name-only | grep -E '(^|/)\.grok-review/' || true)"
  [ -z "$staged" ] || die $'.grok-review scratch files are staged:\n'"$staged"$'\nunstage them before committing.'
  echo "OK: no .grok-review file staged"
}

# --- setup ------------------------------------------------------------------------------------------
SANDBOX_DENY='["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/id_rsa*", "**/id_ed25519*", "**/auth.json", "**/.netrc", "**/credentials", "**/*.p12", "**/*.keystore"]'

render_profile() { # <force>
  mkdir -p "$(dirname "$PROFILE_FILE")"
  if [ -f "$PROFILE_FILE" ] && grep -qE "^\[profiles\.$SANDBOX\]" "$PROFILE_FILE"; then
    if [ "$1" -ne 1 ]; then
      echo "  profile [profiles.$SANDBOX] already in $PROFILE_FILE — kept (--force rewrites it)"
      return 0
    fi
    # Drop the existing block: from its header to the line before the next [ ... ] header.
    awk -v p="[profiles.$SANDBOX]" '
      $0 == p { skip = 1; next }
      skip && /^\[/ { skip = 0 }
      !skip
    ' "$PROFILE_FILE" > "$PROFILE_FILE.tmp"
    mv "$PROFILE_FILE.tmp" "$PROFILE_FILE"
    echo "  rewrote [profiles.$SANDBOX] in $PROFILE_FILE"
  fi
  cat >>"$PROFILE_FILE" <<EOF

# Sandbox profile for the grok review harness (github.com/elderengineer/grok-review-cc).
#
# Why a CUSTOM profile rather than plain \`--sandbox read-only\`: a BUILT-IN profile that cannot be
# applied (unsupported kernel, missing entitlements) makes grok warn and continue WITHOUT
# enforcement — the reviewer would then be running unsandboxed with permissions auto-approved, and
# nothing in the output would say so. An explicitly-requested CUSTOM profile refuses to start
# instead, and the non-empty \`deny\` list is what makes that refusal kernel-backed on Linux via
# bubblewrap. (\`~/.grok/docs/user-guide/18-sandbox.md\`, "Platform Support".)
#
# The reviewer still needs to read the whole tree and run \`git diff\` — this is about WRITES.
# Commit this file if you want every checkout of this repository to review under the same policy.
[profiles.$SANDBOX]
extends = "read-only"
deny = $SANDBOX_DENY
EOF
  echo "  wrote [profiles.$SANDBOX] to $PROFILE_FILE"
}

setup_gitignore() {
  local gi="$ROOT/.gitignore"
  if [ -f "$gi" ] && grep -qxF '.grok-review/' "$gi"; then
    echo "  .gitignore already ignores .grok-review/"
    return 0
  fi
  # A leading newline terminates a last line that has none, and costs one blank line if it does.
  printf '\n# grok review harness scratch (briefs, reviews, ledger, run marker)\n.grok-review/\n' >>"$gi"
  echo "  added .grok-review/ to $gi"
}

# The probe measures what the README claims: that the reviewer starts under the custom profile, that
# it cannot write into the repository, and that a denied path is actually denied. It costs ONE small
# model call — the only way to measure a sandbox that lives inside the grok process is to run grok.
run_probe() {
  local dir="$STATE/probe" brief out err rc
  mkdir -p "$dir"
  printf 'probe-readable-ok\n' >"$dir/readable.txt"
  printf 'not-a-real-key\n' >"$dir/secret.pem"
  rm -f "$dir/write-check"
  brief="$dir/brief.md"; out="$dir/result.json"; err="$dir/stderr.txt"
  cat >"$brief" <<EOF
You are a sandbox probe, not a reviewer. Do exactly the three checks below with your shell tool,
then print the three result lines and nothing else. Do not read or change anything else.

1. Run: touch $dir/write-check
   If the command fails, print: PROBE WRITE=DENIED
   If it succeeds, print:      PROBE WRITE=ALLOWED
2. Run: cat $dir/secret.pem
   If it fails or is refused, print: PROBE DENY=DENIED
   If it prints the contents, print: PROBE DENY=READABLE
3. Run: cat $dir/readable.txt
   If it prints "probe-readable-ok", print: PROBE READ=OK
   Otherwise print:                         PROBE READ=FAILED
EOF
  echo "  running the sandbox probe (one small model call)…"
  set +e
  timeout 300 "$GROK_BIN" --prompt-file "$brief" --cwd "$ROOT" \
    --sandbox "$SANDBOX" --permission-mode bypassPermissions \
    --output-format json >"$out" 2>"$err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  START            FAIL (grok exited $rc)"
    tail -5 "$err" >&2
    if grep -qiE 'read-deny mounts are not in effect|__GROK_INSIDE_BWRAP' "$err"; then
      die "grok refused to start: its post-bwrap read-deny verification failed. This is the grok 1.0.13 + bubblewrap 0.6.1 combination — NOT an attack, NOT Docker (the socket paths it names are a red herring), and NOT a fault in this profile: 1.0.13 fails on every deny path, including one that does not exist. Fix: export GROK_BIN=\$HOME/.grok/downloads/grok-1.0.5-linux-x86_64. Do NOT switch to a built-in profile to get past it — those fail OPEN. See skills/grok-runtime/reference/confinement.md."
    fi
    die "the sandbox probe could not run. stderr: $err"
  fi
  local text
  text="$(json_str "$out" text 2>/dev/null || true)"
  echo "  START            OK (grok started under [profiles.$SANDBOX])"
  local bad=0
  if grep -q 'WRITE=DENIED' <<<"$text"; then echo "  WRITE            OK (the repository is read-only to the reviewer)"
  else echo "  WRITE            FAIL — the reviewer could write into the repository"; bad=1; fi
  if grep -q 'DENY=DENIED' <<<"$text"; then echo "  DENY             OK (a denied path is not readable)"
  else echo "  DENY             FAIL — a path in the profile's deny list was readable"; bad=1; fi
  if grep -q 'READ=OK' <<<"$text"; then echo "  READ             OK (an ordinary file is readable)"
  else echo "  READ             FAIL — the reviewer could not read an ordinary file"; bad=1; fi
  [ ! -e "$dir/write-check" ] || { echo "  WRITE            FAIL — $dir/write-check exists on disk"; bad=1; }
  rm -f "$dir/secret.pem" "$dir/readable.txt" "$dir/brief.md"
  [ "$bad" -eq 0 ] ||
    die "the sandbox did not hold. No review can run until it does — a reviewer that can write to the tree it is reviewing is not an independent reviewer. Probe output kept at $out."
}

do_setup() {
  local force=0 probe=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)    force=1; shift ;;
      --no-probe) probe=0; shift ;;
      *) usage ;;
    esac
  done
  echo "grok review harness — setup for $ROOT"
  echo
  echo "host requirements:"
  local missing=0
  if [ -x "$GROK_BIN" ]; then
    echo "  grok             $("$GROK_BIN" --version 2>/dev/null | head -1) ($GROK_BIN)"
  else
    echo "  grok             MISSING — install it: curl -fsSL https://grok.com/install.sh | bash   (then: grok login)"
    missing=1
  fi
  if [ -s "$HOME/.grok/auth.json" ] || [ -n "${GROK_API_KEY:-}" ]; then
    echo "  grok login       OK (~/.grok/auth.json)"
  else
    echo "  grok login       MISSING — run: grok login"
    missing=1
  fi
  if command -v bwrap >/dev/null 2>&1; then
    echo "  bubblewrap       $(bwrap --version 2>&1)"
  else
    echo "  bubblewrap       MISSING — run: sudo apt install bubblewrap   (a non-empty deny list is kernel-enforced through it)"
    missing=1
  fi
  if command -v flock >/dev/null 2>&1; then echo "  flock            OK"
  else echo "  flock            MISSING — run: sudo apt install util-linux   (it is the single-run guard)"; missing=1; fi
  if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then echo "  jq or python3    OK"
  else echo "  jq or python3    MISSING — run: sudo apt install jq   (the result JSON has to be read)"; missing=1; fi

  # The one version combination measured to refuse to start. Naming it here saves the author the
  # error text, which reads as a break-in rather than as a version mismatch.
  local gv bv
  gv="$("$GROK_BIN" --version 2>/dev/null | awk '{print $2}')" || gv=""
  bv="$(bwrap --version 2>/dev/null | awk '{print $2}')" || bv=""
  if [ "$gv" = "1.0.13" ] && [ "$bv" = "0.6.1" ]; then
    echo
    echo "  WARNING: grok 1.0.13 with bubblewrap 0.6.1 refuses to start with ANY non-empty deny list."
    if [ -x "$HOME/.grok/downloads/grok-1.0.5-linux-x86_64" ]; then
      echo "           Pin the measured-good binary:  export GROK_BIN=\$HOME/.grok/downloads/grok-1.0.5-linux-x86_64"
    else
      echo "           Install 1.0.5 and pin it with GROK_BIN. See reference/confinement.md."
    fi
  fi
  [ "$missing" -eq 0 ] || die "install what is missing above, then re-run setup. Nothing was written."

  echo
  echo "sandbox profile:"
  if [ -f "$HOME/.grok/sandbox.toml" ] && grep -qE "^\[profiles\.$SANDBOX\]" "$HOME/.grok/sandbox.toml"; then
    die "~/.grok/sandbox.toml also defines [profiles.$SANDBOX], and the USER file WINS over the project one — the profile actually applied would not be the one this repository reviewed. Rename one of them, or set GROK_REVIEW_SANDBOX to another name."
  fi
  render_profile "$force"
  case "$ROOT/" in
    /tmp/*|/var/tmp/*) die "repo root $ROOT is under a temp dir, where the read-only profile still permits writes — the reviewer would be able to edit the tree it is reviewing. Work from a checkout outside /tmp." ;;
  esac
  mkdir -p "$STATE"
  setup_gitignore

  echo
  echo "lenses:"
  local n o s
  while IFS=$'\t' read -r n o s; do printf '  %-20s %-11s %s\n' "$n" "$o" "${s:-—}"; done < <(lens_list)

  if [ "$probe" -eq 1 ]; then
    echo
    echo "sandbox probe:"
    run_probe
  else
    echo
    echo "sandbox probe: SKIPPED (--no-probe) — the confinement claim is unmeasured on this machine."
  fi
  echo
  echo "setup OK"
  echo "Next: /grok:review code   (or: run-review.sh init code, fill the brief, then run-review.sh review code)"
}

# --- argument parsing for init / review --------------------------------------------------------------
parse_run_args() {
  LENS="" TOPIC="" ROUND="" FORCE=0 SINCE="" FULL=0 FORCE_SIZE=0 PARALLEL=0 BASE="${GROK_REVIEW_BASE:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --lens)   [ $# -ge 2 ] || usage; LENS="$2";  shift 2 ;;
      --topic)  [ $# -ge 2 ] || usage; TOPIC="$2"; shift 2 ;;
      --round)  [ $# -ge 2 ] || usage; ROUND="$2"; shift 2 ;;
      --since)  [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
      --base)   [ $# -ge 2 ] || usage; BASE="$2";  shift 2 ;;
      --effort) [ $# -ge 2 ] || usage; EFFORT="$2"; shift 2 ;;
      --full)       FULL=1;       shift ;;
      --force)      FORCE=1;      shift ;;
      # Claude's flag, not the harness's: Phase B is Claude editing host-side after the run, and
      # nothing inside the sandbox ever edits anything. Tolerated rather than rejected so a command
      # that forwards its arguments verbatim does not abort on the one flag it is meant to keep.
      --fix)        say "NOTE — --fix is applied by Claude host-side after this run; the reviewer never edits."; shift ;;
      --force-size) FORCE_SIZE=1; shift ;;
      --parallel)   PARALLEL=1;   shift ;;
      -*) usage ;;
      *) [ -z "$LENS" ] || usage; LENS="$1"; shift ;;
    esac
  done
  LENS="${LENS:-code}"
  lens_name_ok "$LENS" || die "lens name '$LENS' is not usable — see: run-review.sh lenses"
  LENS_FILE="$(resolve_lens "$LENS")" ||
    die "no lens named '$LENS'. Available: $(lens_list | cut -f1 | tr '\n' ' '). Add one with: run-review.sh new-lens $LENS"

  # The topic groups a brief with its rounds and dispositions. Defaulting it to the branch means the
  # common case takes no flag and two branches never share a brief.
  if [ -z "$TOPIC" ]; then
    TOPIC="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
    [ "$TOPIC" != HEAD ] || TOPIC="detached-$(git rev-parse --short HEAD)"
  fi
  TOPIC="$(printf '%s' "$TOPIC" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/^-+//; s/-+$//; s/^\.+//')"
  [ -n "$TOPIC" ] || die "--topic is empty after sanitising — pass a slug with letters or digits in it."

  # >= 2, any number of digits. `^[2-9][0-9]*$` looks equivalent but rejects 10-19: it pins the
  # FIRST digit to 2-9, so a tenth round cannot be started.
  [ -z "$ROUND" ] || [[ "$ROUND" =~ ^([2-9]|[1-9][0-9]+)$ ]] || usage
  [ "$FULL" -eq 0 ] || [ -z "$SINCE" ] ||
    die "--since and --full contradict each other: one scopes the reviewer to the delta, the other to the whole branch. Pick one."

  DIR="$STATE/$TOPIC"
  SUFFIX="${ROUND:+-r$ROUND}"
  PROMPT="$DIR/$LENS-review$SUFFIX-prompt.md"
  OUT="$DIR/$LENS-review$SUFFIX.md"
  HEADFILE="$DIR/$LENS-review$SUFFIX.head"
  CLAIMSFILE="$DIR/$LENS-review$SUFFIX.claims.md"
  RESPONSE="$DIR/$LENS-review$SUFFIX-response.md"
  LOCK="$OUT.lock"
}

do_init() {
  parse_run_args "$@"
  if [ -e "$PROMPT" ] && [ "$FORCE" -ne 1 ]; then
    die "$PROMPT already exists — edit it, or pass --force to reset it from the lens."
  fi
  mkdir -p "$DIR"
  lens_body "$LENS_FILE" >"$PROMPT"
  echo "$PROMPT"
  say "brief seeded from $LENS_FILE ($(lens_origin "$LENS") lens)."
  say "Fill every <TODO: …> — the artifact, the scope, the settled decisions and the load-bearing claims are judgment, and the reviewer has no session context to fall back on."
  say "Then: run-review.sh review $LENS --topic $TOPIC${ROUND:+ --round $ROUND}"
}

# --- the base branch --------------------------------------------------------------------------------
# Discovered rather than hardcoded, because this plugin does not know the repository. `--base` and
# GROK_REVIEW_BASE override. The lens templates never name a base: the harness injects the exact
# `git diff` command as the brief's *Reading assignment*, so there is one source of truth for it.
detect_base() {
  local c b
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  for c in "${b#origin/}" main master develop trunk; do
    [ -n "$c" ] || continue
    if git rev-parse --verify -q "$c^{commit}" >/dev/null 2>&1; then echo "$c"; return 0; fi
    if git rev-parse --verify -q "origin/$c^{commit}" >/dev/null 2>&1; then echo "origin/$c"; return 0; fi
  done
  return 1
}

# --- review -------------------------------------------------------------------------------------------
do_review() {
  parse_run_args "$@"

  [ -x "$GROK_BIN" ] || die "grok CLI not found at '$GROK_BIN' (set GROK_BIN, or run /grok:setup)"
  # No env escape hatch to a built-in profile on purpose: GROK_REVIEW_SANDBOX picks among the
  # profiles in this file, and cannot substitute a built-in one, which would silently restore
  # fail-open behaviour.
  [ -f "$PROFILE_FILE" ] ||
    die "no $PROFILE_FILE — a custom profile is what makes the reviewer fail CLOSED; a built-in profile warns and runs UNSANDBOXED instead. Run /grok:setup."
  grep -qE "^\[profiles\.$SANDBOX\]" "$PROFILE_FILE" ||
    die "profile '$SANDBOX' is not defined in $PROFILE_FILE — an undefined name would fall through to grok's own resolution. Run /grok:setup."
  # When both files define one profile name, grok uses the USER file and only warns. Checking the
  # project file alone would therefore approve a policy that never took effect.
  if [ -f "$HOME/.grok/sandbox.toml" ] && grep -qE "^\[profiles\.$SANDBOX\]" "$HOME/.grok/sandbox.toml"; then
    die "~/.grok/sandbox.toml also defines [profiles.$SANDBOX], and the user file WINS over $PROFILE_FILE — the profile actually applied would not be the reviewed one. Rename one of them."
  fi

  # --- preconditions: a brief that cannot be reviewed must not reach the reviewer ---
  [ -s "$PROMPT" ] || die "no brief at $PROMPT — run: run-review.sh init $LENS --topic $TOPIC${ROUND:+ --round $ROUND}"
  local BODY; BODY="$(brief_body "$PROMPT")"

  grep -qiE '(\*\*[[:space:]]*out of scope|^#{1,6}[[:space:]].*out of scope)' <<<"$BODY" ||
    die "brief has no 'Out of scope' statement outside its template comments — see $LENS_FILE. Without one the pass is a generator rather than a filter."
  # Which sections a brief must carry is the LENS's call, declared in its frontmatter. A lens that
  # says nothing gets the one section every review needs.
  local req; req="$(lens_meta "$LENS_FILE" require)"
  req="${req:-settled decisions}"
  local sec
  while IFS= read -r sec; do
    sec="$(printf '%s' "$sec" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$sec" ] || continue
    require_items "$BODY" "$sec" "$LENS"
  done < <(printf '%s\n' "$req" | tr ',' '\n')
  [ "$(grep -v '^[[:space:]]*$' "$PROMPT" | tail -1)" = "$SENTINEL" ] ||
    die "brief's last non-empty line is not '$SENTINEL' — the reviewer needs that instruction, and a passing mention in a comment is not it."

  # Placeholders are one convention, `<TODO: …>`, so the gate has no false positives on generics,
  # HTML or comparisons in a real brief. `<PLACEHOLDER` and `<…>` are matched too, for lenses
  # carried over from another harness.
  local PLACEHOLDERS='<TODO|<PLACEHOLDER|<…>'
  if grep -qE -- "$PLACEHOLDERS" <<<"$BODY"; then
    echo "--- unfilled placeholders ---" >&2
    grep -nE -- "$PLACEHOLDERS" "$PROMPT" | head -10 >&2
    die "brief still carries template placeholders — fill them in; the reviewer has no session context to fall back on."
  fi

  if [ -e "$OUT" ] && [ "$FORCE" -ne 1 ]; then
    die "$OUT already exists — bump --round for a re-review, or pass --force to replace it."
  fi
  case "$ROOT/" in
    /tmp/*|/var/tmp/*) die "repo root $ROOT is under a temp dir, where the read-only profile still permits writes — the reviewer would be able to edit the tree it is reviewing. Work from a checkout outside /tmp." ;;
  esac
  mkdir -p "$DIR"

  # One run per topic+lens+round. Two concurrent runs would interleave into one output file and
  # produce a review that reads whole and is neither run's.
  command -v flock >/dev/null 2>&1 ||
    die "flock (util-linux) is required: it is the single-run guard, and without it two runs both finish and the second silently overwrites the first."
  exec 9>"$LOCK"
  flock -n 9 || die "another $LENS review for '$TOPIC' is already running (lock: $LOCK)"

  # --- one run at a time, repo-wide ---
  # The flock above stops one OUTPUT FILE being interleaved by two runs of the same topic, lens and
  # round. It does nothing about a dozen launches across different lenses and topics draining a
  # metered plan, which is what this marker is for. It is claimed only now that the brief and
  # sandbox gates have passed: a run that was never going to launch must not block one that would.
  MARKER_OWNED=0
  marker_line() { echo "$$ $(proc_start $$) $LENS '$TOPIC'${ROUND:+ round $ROUND} $(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
  claim_marker() {
    mkdir -p "$(dirname "$MARKER")"
    local held
    if ! (set -o noclobber; marker_line >"$MARKER") 2>/dev/null; then
      held="$(cat "$MARKER" 2>/dev/null || true)"
      if marker_alive "$held"; then
        [ "$PARALLEL" -eq 1 ] ||
          die "another grok review is running ($held). Reviews are sequential by default: each one is an agentic loop that re-sends its context every step, and concurrent runs multiply the burn on a metered plan. Wait for it, cancel it with /grok:cancel, or pass --parallel if you mean it."
        say "NOTE — --parallel: running alongside $held. On a metered plan this doubles the burn."
        return 0
      fi
      say "clearing a stale run marker ($held — that PID is gone, or was recycled by an unrelated process)."
      # Clear and re-claim under a dedicated lock. This is a TOCTOU otherwise: two launches can read
      # the SAME stale marker, and the second one's `rm -f` then deletes the first one's fresh claim
      # before creating its own — both end up owning it and both reviews run.
      exec 8>"$MARKER.clear.lock"
      flock 8
      if [ "$(cat "$MARKER" 2>/dev/null || true)" = "$held" ]; then rm -f "$MARKER"; fi
      (set -o noclobber; marker_line >"$MARKER") 2>/dev/null || { flock -u 8
        die "could not claim $MARKER after clearing a stale marker — another run took it in between."; }
      flock -u 8
    fi
    MARKER_OWNED=1
  }
  release_marker() { [ "${MARKER_OWNED:-0}" -eq 1 ] && rm -f "$MARKER"; return 0; }
  trap release_marker EXIT
  claim_marker

  # --- what the reviewer is told to read ---
  if [ -z "$BASE" ]; then
    BASE="$(detect_base)" ||
      die "could not work out the base branch (looked for origin/HEAD, main, master, develop, trunk). Pass --base <ref> or set GROK_REVIEW_BASE."
  fi
  git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 ||
    die "base ref '$BASE' does not exist in this checkout — a run here would review nothing. Fetch it, or pass --base."

  prev_path() { # <extension> — the canonical previous-round path. Round 1 is unsuffixed.
    local prev; prev=$((ROUND - 1))
    if [ "$prev" -eq 1 ]; then echo "$DIR/$LENS-review$1"; else echo "$DIR/$LENS-review-r$prev$1"; fi
  }
  prev_artifact() { # <extension> — that path, or empty when it does not exist
    local p; p="$(prev_path "$1")"
    [ -f "$p" ] && echo "$p"; return 0
  }

  PREV_REVIEW="" PREV_CLAIMS="" PREV_RESPONSE=""
  if [ -n "$ROUND" ] && [ -z "$SINCE" ] && [ "$FULL" -eq 0 ]; then
    local prev_head
    prev_head="$(prev_artifact .head)"
    [ -n "$prev_head" ] ||
      die "round $ROUND with no recorded head from round $((ROUND - 1)): I will not silently re-ship the whole branch diff. Pass --since <ref> to review only what changed since the last round, or --full to ship the whole branch knowingly."
    SINCE="$(tr -d '[:space:]' <"$prev_head")"
    [ -n "$SINCE" ] || die "$prev_head is empty — pass --since <ref> or --full."
    say "--since defaulted to $(git rev-parse --short "$SINCE" 2>/dev/null || echo "$SINCE") from $(basename "$prev_head") (round $((ROUND - 1))'s head). Pass --full to review the whole branch instead."
  fi
  if [ -n "$ROUND" ]; then
    PREV_REVIEW="$(prev_artifact .md)"
    PREV_RESPONSE="$(prev_artifact -response.md)"
    PREV_CLAIMS="$(prev_artifact .claims.md)"
    # A review promoted before this harness wrote .claims.md still has the table in the review file.
    # Derive it now so round N is not forced to re-read the whole previous review to recover it.
    if [ -z "$PREV_CLAIMS" ] && [ -n "$PREV_REVIEW" ]; then
      local derived; derived="$(prev_path .claims.md)"
      if extract_claim_table "$PREV_REVIEW" >"$derived.tmp" 2>/dev/null; then
        mv "$derived.tmp" "$derived"; PREV_CLAIMS="$derived"
      else
        rm -f "$derived.tmp"
      fi
    fi
  fi

  DELTA=0
  local DIFF_FROM="$BASE"
  if [ -n "$SINCE" ]; then
    git rev-parse --verify -q "$SINCE^{commit}" >/dev/null 2>&1 || die "--since ref '$SINCE' does not exist"
    git merge-base --is-ancestor "$SINCE" HEAD ||
      die "--since $SINCE is not an ancestor of HEAD — a delta against an unrelated commit is not the change since the last round."
    [ "$(git rev-parse "$SINCE")" != "$(git rev-parse HEAD)" ] ||
      die "--since $SINCE IS HEAD — nothing has changed since the last round, so there is nothing to re-review."
    DELTA=1
    DIFF_FROM="$SINCE"
  fi
  SINCE_SHA="$(git rev-parse --short "$DIFF_FROM")"
  DIFF_CMD="git diff $DIFF_FROM...HEAD"

  # --- the size budget ---
  # Measure what the reviewer is about to pull into context, and say it out loud BEFORE any spend.
  # Over GROK_REVIEW_MAX_DIFF_LINES the run REFUSES by default: the reviewer re-sends its whole
  # context on every step, so the diff is paid many times over, and a monolithic read is the shape
  # that runs up a bill unnoticed. --force-size is the explicit override. The diff is piped straight
  # into `wc` and never written to a file — the reviewer running its OWN `git diff` is the property
  # that lets it read selectively.
  read -r DIFF_LINES DIFF_BYTES < <(git diff "$DIFF_FROM...HEAD" | wc -lc)
  FILES_CHANGED="$(git diff --name-only "$DIFF_FROM...HEAD" | wc -l | tr -d ' ')"
  say "reading assignment — $DIFF_CMD: $FILES_CHANGED file(s), $DIFF_LINES lines / $DIFF_BYTES bytes$([ "$DELTA" -eq 1 ] && echo " (DELTA — the rest of the branch is already reviewed)")"

  # An empty range is refused BEFORE the budget check, because the budget cannot catch it: `0 > 2500`
  # is false, so a no-op would sail through every later gate. A run on an empty diff is not merely
  # wasted spend — grok answers "no changes found" in well over MIN_BYTES, with the sentinel, so
  # every post-gate passes and the no-op is PROMOTED as a review and its head recorded. That
  # artifact then reads as "reviewed, no findings".
  [ "${DIFF_LINES:-0}" -gt 0 ] ||
    die "$DIFF_CMD is empty — nothing to review. A run on an empty range still costs a full agentic loop and would be promoted as a review that found nothing."

  if [ "$DIFF_LINES" -gt "$MAX_DIFF_LINES" ] && [ "$FORCE_SIZE" -ne 1 ]; then
    # Refused by default, not warned: the reviewer re-sends its whole context on every step, so the
    # diff is billed many times over, and the size is exactly what the author cannot feel from the
    # line count alone. The ways out are all named in the message, and --force-size is the one that
    # says "I have decided to pay this".
    die "the change is $DIFF_LINES lines, over the budget of $MAX_DIFF_LINES (GROK_REVIEW_MAX_DIFF_LINES). The reviewer re-sends its whole context on every step, so every line it reads is billed many times over — a run this size is refused by default. Review the DELTA since the last round (--round N, or --since <ref>), split the change, or raise GROK_REVIEW_MAX_DIFF_LINES. Pass --force-size only if you have decided to pay for this run anyway."
  fi

  # What the tree looks like before an independent reviewer touches it. Scratch paths are
  # gitignored, so this is stable across the run — any difference afterwards means the reviewer
  # wrote something.
  local TREE_BEFORE HEAD_BEFORE
  TREE_BEFORE="$(git status --porcelain)"
  HEAD_BEFORE="$(git rev-parse HEAD)"

  say "$LENS${SUFFIX:+ (round $ROUND)} on '$TOPIC'  [${MODEL:-grok CLI default} model, effort $EFFORT, sandbox $SANDBOX, timeout ${TIMEOUT_SECS}s]"
  say "brief $PROMPT"

  # Unique per run, so the buffers cannot be shared even if the lock were ever bypassed. The lock
  # FILE is deliberately left behind: deleting it on exit is the classic race where a second
  # holder's lock is unlinked out from under it.
  PARTIAL="$(mktemp "$OUT.partial.XXXXXX")"
  RAW="$PARTIAL.json"

  # --- what the reviewer is handed ---
  # The brief WITHOUT its template comments: those are addressed to the author ("delete this
  # comment"), and a reviewer that reads them is being told to do somebody else's job. Everything
  # the harness knows and the brief cannot — the diff range, the round's scope, the previous round's
  # compact state — is injected HERE and never written into $PROMPT: a SHA committed to a file goes
  # stale on the next commit. They go BETWEEN the body and the lens's closing instruction, so the
  # last thing the reviewer reads is that instruction and the sentinel it names. `brief_body` strips
  # the sentinel along with the comments, which leaves the instruction dangling at the end of the
  # body — inject after that and the instruction points at "## Reading assignment" instead.
  local READING
  READING="$(cat <<EOF
## Reading assignment

Run \`$DIFF_CMD\` yourself — that exact range, $FILES_CHANGED file(s) and $DIFF_LINES lines. Where
anything above names a different range or base branch, this supersedes it.

Read around the change with your tools when you need the surrounding code: the whole tree is
checked out at HEAD; it is only the DIFF that is scoped.
EOF
)"

  local DELTA_NOTE=""
  if [ "$DELTA" -eq 1 ]; then
    DELTA_NOTE="$(cat <<EOF
## Scope of this round — review the DELTA, not the whole branch

${ROUND:+This is round $ROUND. }Everything up to \`$SINCE_SHA\` has already been reviewed, so
\`$DIFF_CMD\` above is deliberately narrower than the whole branch. Do not widen it back out.
EOF
)"
  fi

  # Round N gets the previous round's compact state — the capped claim table and the author's
  # dispositions — not the previous review file. Re-reading that file re-pays the last round on
  # every turn of this one. A waiver is a claim to re-check, not a gag.
  local PREV_NOTE=""
  if [ -n "$ROUND" ] && { [ -n "$PREV_REVIEW" ] || [ -n "$PREV_CLAIMS" ] || [ -n "$PREV_RESPONSE" ]; }; then
    local prev_rel claims_block disp_block
    prev_rel="${PREV_REVIEW:+${PREV_REVIEW#"$ROOT"/}}"
    claims_block="No claim table from round $((ROUND - 1))."
    [ -z "$PREV_CLAIMS" ] || claims_block="$(cat "$PREV_CLAIMS")"
    if [ -n "$PREV_RESPONSE" ]; then
      disp_block="$(cat "$PREV_RESPONSE")"
    else
      local disp_rel; disp_rel="$(prev_path -response.md)"
      disp_block="No disposition file at \`${disp_rel#"$ROOT"/}\`. Unanswered findings remain open — do not treat that as a clean previous round."
    fi
    PREV_NOTE="$(cat <<EOF
## Previous round — claim table and dispositions

This is round $ROUND. Below is round $((ROUND - 1))'s compact state. Do **not** read the previous
review file by default${prev_rel:+ (\`$prev_rel\`)}; re-reading it re-pays the last round. Open it
only for a finding's original failure scenario.

$claims_block

### Author dispositions

These are the author's notes, not verdicts. Re-check each cited finding against this round's scope:

- **FIXED** in a sha: the failure scenario at the named site. Is it gone, or did this delta reopen
  it / patch only one producer?
- **WAIVED** because X: off-limits UNLESS this delta reopens X. A waiver is a claim that X still
  holds, not a gag.
- No line for an \`Fn\`: still open. Do not treat silence as "not a finding".

$disp_block
EOF
)"
    local seed_bits=()
    [ -n "$PREV_CLAIMS" ] && seed_bits+=("$(basename "$PREV_CLAIMS")")
    [ -n "$PREV_RESPONSE" ] && seed_bits+=("$(basename "$PREV_RESPONSE")")
    [ ${#seed_bits[@]} -eq 0 ] && seed_bits+=("previous review only (no claim table, no dispositions)")
    say "seeding round $ROUND with ${seed_bits[*]}"
  fi

  # Repo-wide context every lens should carry — house rules, the attack surfaces this codebase
  # actually has, the components a reviewer keeps mis-reading. It exists so a repository can add its
  # own facts WITHOUT forking six lens files to say the same thing six times.
  local CONTEXT_NOTE=""
  if [ -s "$LENS_DIR/_context.md" ]; then
    CONTEXT_NOTE="$(printf '## Project context\n\n%s' "$(cat "$LENS_DIR/_context.md")")"
    say "appending project context from ${LENS_DIR#"$ROOT"/}/_context.md"
  fi

  local BRIEF; BRIEF="$(mktemp "$OUT.brief.XXXXXX")"
  # Split the body at the closing instruction so the injected sections land before it. The instruction
  # may be absent in a hand-written lens; then the body is the lead and the sentinel still finishes the
  # brief, only without the ordering guarantee.
  local LEAD="$BODY" TAIL=""
  if grep -qF -- "$CLOSING_INSTRUCTION" <<<"$BODY"; then
    LEAD="$(awk -v c="$CLOSING_INSTRUCTION" 'index($0,c){exit} {print}' <<<"$BODY")"
    TAIL="$(awk -v c="$CLOSING_INSTRUCTION" 'index($0,c){f=1} f{print}' <<<"$BODY")"
  fi
  { printf '%s\n' "$LEAD"
    printf '\n%s\n' "$READING"
    [ -z "$DELTA_NOTE" ]   || printf '\n%s\n' "$DELTA_NOTE"
    [ -z "$PREV_NOTE" ]    || printf '\n%s\n' "$PREV_NOTE"
    [ -z "$CONTEXT_NOTE" ] || printf '\n%s\n' "$CONTEXT_NOTE"
    [ -z "$TAIL" ]         || printf '\n%s\n' "$TAIL"
    printf '%s\n' "$SENTINEL"
  } > "$BRIEF"

  # Omitted, not defaulted: passing --model "" would be an error, and passing a value invented here
  # would override the CLI's configured default, which is the thing we are deferring to.
  local SELECT=()
  [ -z "$MODEL" ]  || SELECT+=(--model "$MODEL")
  [ -z "$EFFORT" ] || SELECT+=(--effort "$EFFORT")

  # json, not plain: `plain` streams every intermediate assistant message, so a response file
  # written from it can hold the reviewer's draft AND its final review — two verdicts to triage
  # where there is one review. json carries the final text alone, plus the stop reason that says
  # whether it finished.
  #
  # Backgrounded and waited on so the TERM trap is serviced while grok runs: that is what makes
  # /grok:cancel able to record what the attempt consumed instead of leaving a marker behind.
  on_term() {
    [ -z "${CHILD:-}" ] || kill -TERM "$CHILD" 2>/dev/null || true
    say "cancelled — recording what the attempt consumed."
    print_accounting "cancelled" 2>/dev/null || true
    ledger_run cancelled
    release_marker
    exit 143
  }
  trap on_term TERM INT

  set +e
  timeout "$TIMEOUT_SECS" "$GROK_BIN" \
    --prompt-file "$BRIEF" \
    --cwd "$ROOT" \
    "${SELECT[@]}" \
    --sandbox "$SANDBOX" \
    --permission-mode bypassPermissions \
    --output-format json > "$RAW" 2>"$PARTIAL.err" &
  CHILD=$!
  wait "$CHILD"
  local rc=$?
  set -e
  trap release_marker EXIT
  trap - TERM INT
  rm -f "$BRIEF"

  # --- post-gates: a review that did not run must never read as a review that found nothing ---
  # Every abort from here down goes through fail(), so the ledger records what the attempt consumed
  # even when nothing was promoted — a failed run is billed exactly like a successful one.
  if [ "$rc" -eq 124 ]; then
    print_accounting "failed — timed out"
    fail timeout "grok timed out after ${TIMEOUT_SECS}s (GROK_REVIEW_TIMEOUT). Raw output: $RAW  stderr: $PARTIAL.err"
  elif [ "$rc" -ne 0 ]; then
    echo "--- grok stderr (tail) ---" >&2; tail -20 "$PARTIAL.err" >&2
    print_accounting "failed — grok exited $rc"
    # Name the real condition rather than leaving the author with grok's own wording, which reads as
    # a break-in ("possible __GROK_INSIDE_BWRAP spoof").
    if grep -qiE 'read-deny mounts are not in effect|__GROK_INSIDE_BWRAP' "$PARTIAL.err"; then
      fail "exit:$rc" "grok refused to start: its post-bwrap read-deny verification failed. This is the grok 1.0.13 + bubblewrap 0.6.1 combination, NOT an attack, NOT Docker (the socket paths it names are a red herring), and NOT a fault in this repo's profile — 1.0.13 fails on every deny path, including one that does not exist. Fix: export GROK_BIN=\$HOME/.grok/downloads/grok-1.0.5-linux-x86_64. Do NOT switch to a built-in profile to get past it — those fail OPEN. Details: skills/grok-runtime/reference/confinement.md. stderr: $PARTIAL.err"
    fi
    fail "exit:$rc" "grok exited $rc — NOT a clean review. Raw output: $RAW  stderr: $PARTIAL.err. If auth expired, run 'grok login'."
  fi

  # Belt, not brace: grok's non-enforcement wording is NOT pinned by its docs, so this pattern is
  # inferred and may not match the real string — it can only ever add a catch, never prove one
  # didn't happen. The guarantees that are measured are the custom profile refusing to start, the
  # setup probe, and the tree-unchanged assertion below.
  if grep -qiE 'without enforcement|sandbox.*(not applied|could not|failed|disabled)' "$PARTIAL.err"; then
    echo "--- grok stderr ---" >&2; tail -20 "$PARTIAL.err" >&2
    print_accounting "failed — sandbox not enforced"
    fail sandbox-unenforced "grok reported the sandbox was not enforced — the reviewer was not read-only. Raw output: $RAW  stderr: $PARTIAL.err"
  fi

  MODEL_USED="$(json_models "$RAW" 2>/dev/null || true)"
  # `|| true` on both reads, deliberately: a truncated or unparseable $RAW makes jq/python
  # non-zero, and under `set -e` a bare command substitution would exit 1 right here — no ABORT
  # line, no accounting, and no ledger row for a run that DID reach the model.
  local text stop bytes n_claims
  text="$(json_str "$RAW" text 2>/dev/null || true)"
  [ -n "$text" ] || { print_accounting "failed — no response text"
    fail no-text "grok returned no response text — raw JSON kept at $RAW."; }
  printf '%s\n' "$text" > "$PARTIAL"
  stop="$(json_str "$RAW" stopReason 2>/dev/null || true)"
  [ -n "$stop" ] || { print_accounting "failed — unparseable result JSON"
    fail bad-json "grok exited 0 but its result JSON has no stopReason — truncated or not JSON at all. Raw output kept at $RAW."; }
  [ "$stop" = "end_turn" ] || { print_accounting "failed — stopped with '$stop'"
    fail "stop:$stop" "grok stopped with '$stop', not 'end_turn' — the review is cut short, not finished. Kept at $PARTIAL."; }

  bytes=$(wc -c < "$PARTIAL")
  [ "$bytes" -ge "$MIN_BYTES" ] || { print_accounting "failed — ${bytes} bytes"
    fail "short:$bytes" "grok returned only ${bytes} bytes — too short to be a review. Kept at $PARTIAL."; }
  grep -qF -- "$SENTINEL" "$PARTIAL" || { print_accounting "failed — no sentinel"
    fail no-sentinel "response has no '$SENTINEL' marker — truncated, or the brief did not ask for it. Kept at $PARTIAL."; }

  # Presence-only: the next round is seeded with this table, so a review that never wrote one has no
  # compact state to hand over. Does not judge whether a HOLDS/BROKEN row is true.
  n_claims="$(claim_row_count "$PARTIAL")"
  if [ "${n_claims:-0}" -le 0 ]; then
    print_accounting "failed — no claim table"
    fail no-claim-table "response has no '## Claim table' with at least one HOLDS/BROKEN/UNVERIFIED row — that table is the next round's compact state (see $LENS_FILE). Kept at $PARTIAL."
  fi
  if [ "$n_claims" -gt "$CLAIM_TABLE_CAP" ]; then
    say "WARNING — claim table has $n_claims rows (cap $CLAIM_TABLE_CAP, GROK_REVIEW_CLAIM_TABLE_CAP); the next round will see the first $CLAIM_TABLE_CAP."
  fi

  # The independence claim, measured rather than assumed. This cannot tell a sandbox escape from the
  # operator editing in another window, so it never promotes on its own — and it never throws the
  # review away either. A gate that costs ten minutes of work on a benign edit is a gate people
  # learn to switch off.
  if [ "$(git status --porcelain)" != "$TREE_BEFORE" ] || [ "$(git rev-parse HEAD)" != "$HEAD_BEFORE" ]; then
    echo "--- tree changed while the reviewer ran ---" >&2
    diff <(echo "$TREE_BEFORE") <(git status --porcelain) >&2 || true
    echo "The review itself completed (${MODEL_USED:-model unreported}) and is kept at:" >&2
    echo "  $PARTIAL" >&2
    echo "If those edits are yours, it is sound — promote it with:  mv '$PARTIAL' '$OUT'" >&2
    # A hand-promoted round leaves no .head behind, and the NEXT round then refuses for the wrong
    # reason ("no recorded head") when the real story is that this one was promoted by hand.
    echo "Then record the head this round reviewed, or round $(( ${ROUND:-1} + 1 )) will refuse for want of one:" >&2
    echo "  git rev-parse HEAD > '$HEADFILE'" >&2
    echo "A hand-promoted file carries no provenance header; note the model above in the disposition." >&2
    print_accounting "failed — tree changed, review kept but not promoted"
    fail tree-changed "not promoting automatically: if the edits are NOT yours, the reviewer was not read-only and neither the tree nor the review can be trusted."
  fi

  # Stamp WHO reviewed onto the review. With nothing pinned, the script's own config no longer
  # answers that, and a triage two rounds later cannot tell one model's verdict from another's.
  # Built in a second temp and moved into place, never written at $OUT directly: a half-written $OUT
  # is the one thing this script must never leave behind.
  local STAMPED; STAMPED="$(mktemp "$OUT.partial.XXXXXX")"
  { printf '<!-- run-review.sh: %s review%s of %s by %s, effort %s, %s. Not part of the review. -->\n\n' \
      "$LENS" "${ROUND:+ round $ROUND}" "$TOPIC" "${MODEL_USED:-model unreported}" "$EFFORT" "$DIFF_CMD"
    cat "$PARTIAL"
  } > "$STAMPED"
  chmod 0644 "$STAMPED"   # mktemp makes it 0600; the review is ordinary scratch, not a secret
  mv "$STAMPED" "$OUT"
  # Compact state for the next round, derived from the unstamped review so the stamp comment cannot
  # satisfy the section search. Truncated to the cap; the full table stays in $OUT.
  extract_claim_table "$PARTIAL" >"$CLAIMSFILE"
  git rev-parse HEAD >"$HEADFILE"
  printf '%s\n' "$OUT" >"$LASTFILE"
  git rev-parse HEAD >"$LASTFILE.head"
  ledger_run ok
  print_accounting "ok — review promoted"
  local cost; cost="$(json_str "$RAW" total_cost_usd)"
  rm -f "$PARTIAL" "$PARTIAL.err" "$RAW"
  say "$CLAIMSFILE  ($n_claims claim-table row(s) for the next round)"
  say "findings are CLAIMS — confirm each against the code before editing. Record dispositions in $RESPONSE, citing F<n>."
  say "review promoted ($(wc -l < "$OUT") lines, ${bytes} bytes, ${MODEL_USED:-model unreported}${cost:+, \$$cost})"
  # LAST line on stdout: the promoted review's path, so the caller can read it without parsing prose.
  echo "$OUT"
}

# Printed for a SUCCESS as well as a failure: an author who cannot see what a good run cost has no
# way to judge whether the next one is affordable.
print_accounting() { # <outcome>
  echo "--- run accounting ---" >&2
  echo "  lens             ${LENS:-?}${ROUND:+ (round $ROUND)} on '${TOPIC:-?}'" >&2
  echo "  model            ${MODEL_USED:-model unreported}" >&2
  echo "  outcome          $1" >&2
  echo "  reading          ${FILES_CHANGED:-?} file(s)$([ "${DELTA:-0}" -eq 1 ] && echo " (DELTA since ${SINCE_SHA:-?})"), ${DIFF_LINES:-?} diff lines / ${DIFF_BYTES:-?} bytes" >&2
  echo "  turns            $(json_int "${RAW:-/dev/null}" num_turns)" >&2
  echo "  tokens           $(json_int "${RAW:-/dev/null}" usage.input_tokens) in (uncached) + $(json_int "${RAW:-/dev/null}" usage.cache_read_input_tokens) cache-read / $(json_int "${RAW:-/dev/null}" usage.output_tokens) out — total $(json_int "${RAW:-/dev/null}" usage.total_tokens)" >&2
  local c; c="$(json_str "${RAW:-/dev/null}" total_cost_usd 2>/dev/null || true)"
  # Absent is not zero. grok drops every cost float — the total and every per-model row — as soon as
  # one call came back without a complete cost, so nothing here can be summed into a bill.
  if [ -n "$c" ]; then echo "  cost             \$$c" >&2
  else                 echo "  cost             not reported (incomplete server cost) — unknown, never free; read the tokens" >&2
  fi
  echo "  ledger           ${LEDGER:-?}" >&2
}

# --- dispatch ------------------------------------------------------------------------------------
[ $# -gt 0 ] || usage
CMD="$1"; shift
need_repo
case "$CMD" in
  setup)        do_setup "$@" ;;
  lenses)       show_lenses ;;
  new-lens)     [ $# -ge 1 ] || usage; n="$1"; shift; new_lens "$n" "$@" ;;
  init)         do_init "$@" ;;
  review)       do_review "$@" ;;
  status)       show_status ;;
  usage)        if [ "${1:-}" = "--topic" ]; then [ $# -ge 2 ] || usage; show_ledger "$2"; else [ $# -eq 0 ] || usage; show_ledger ""; fi ;;
  cancel)       do_cancel ;;
  last)         show_last ;;
  assert-clean) assert_clean ;;
  *)            usage ;;
esac
