#!/usr/bin/env bash
#
# Tests for run-review.sh: lens resolution and override, the brief gates, the usage discipline
# (delta scoping, the size budget, the ledger, the one-run marker), and the post-run contract gates.
#
# Everything runs against a FAKE grok (a script this test writes, handed over as GROK_BIN) and a
# THROWAWAY git repo. No real grok is ever invoked, no provider is ever billed, and this repository's
# own history is never touched. The fake is identified to the harness by GROK_BIN, never by name, and
# nothing here kills a process it did not start.
#
# The throwaway repo deliberately does NOT live in $TMPDIR: run-review.sh refuses to run when the
# repo root is under /tmp or /var/tmp, because the read-only grok profile still permits writes there.
# It lives under the REAL $HOME/.cache instead — captured before $HOME is redirected for the
# ~/.grok/sandbox.toml collision check — and one dedicated case does create a repo under /tmp,
# purely to assert that refusal fires.
#
#   plugins/grok/tests/test-run-review.sh
#
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$TEST_DIR")"
SCRIPT="$PLUGIN_DIR/scripts/run-review.sh"
SENTINEL='<!-- END OF REVIEW -->'

REAL_HOME="$HOME"
TMP="$(mktemp -d "$REAL_HOME/.cache/grok-review-test.XXXXXX")" || exit 1
REPO="$TMP/repo"
FAKE="$TMP/bin/grok"
export FAKE_LOG="$TMP/calls.log"
export FAKE_MSG="$TMP/last-brief.txt"
export HOME="$TMP/home"          # so a real ~/.grok/sandbox.toml never shadows the reviewed profile
export GROK_BIN="$FAKE"
mkdir -p "$TMP/bin" "$HOME/.grok"
: >"$FAKE_LOG"
printf '{"fake":true}\n' >"$HOME/.grok/auth.json"

PASS=0 FAIL=0
TMPROOT=""
cleanup() { rm -rf "$TMP" ${TMPROOT:+"$TMPROOT"}; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
died()  { [ "$1" -ne 0 ] && echo 0 || echo 1; }   # rc -> the 0/1 `check` wants
lived() { [ "$1" -eq 0 ] && echo 0 || echo 1; }
have()  { grep -qF -- "$2" "$1"; }

# --- the fake grok ---------------------------------------------------------------------------------
# It emits the documented headless JSON result shape (14-headless-mode.md § json): text, stopReason,
# num_turns, usage{…}, modelUsage{…} and — only when the server reported a COMPLETE cost —
# total_cost_usd. FAKE_MODE picks the failure a case wants to drill.
cat >"$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
brief=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-file) brief="$2"; shift 2 ;;
    --version) echo "grok 1.0.5 (fake)"; exit 0 ;;
    *) shift ;;
  esac
done
[ -n "$brief" ] && cp "$brief" "$FAKE_MSG"
echo "call ${FAKE_MODE:-ok}" >>"$FAKE_LOG"

body_ok() {
  cat <<'TXT'
### F1 — a finding

- **Severity** — major
- **Location** — src/a.txt:1
- **Failure scenario** — the concrete sequence that goes wrong, spelled out at enough length that
  the harness's minimum-bytes gate is comfortably cleared by a genuine review rather than by luck.
- **Suggested fix** — the direction, not a patch.

Verdict: mergeable with the listed changes.

## Claim table

- BROKEN F1 — the first load-bearing claim
- HOLDS — the second load-bearing claim

<!-- END OF REVIEW -->
TXT
}

emit() { # <text> <stopReason>
  python3 -c '
import json, sys
print(json.dumps({
  "text": sys.argv[1], "stopReason": sys.argv[2], "num_turns": 7,
  "usage": {"input_tokens": 1000, "cache_read_input_tokens": 40000,
            "output_tokens": 2000, "total_tokens": 43000},
  "modelUsage": {"grok-fake-1": {"modelCalls": 7}},
  "total_cost_usd": 0.1234,
}))' "$1" "$2"
}

case "${FAKE_MODE:-ok}" in
  ok)          emit "$(body_ok)" end_turn ;;
  short)       emit "too short" end_turn ;;
  nosentinel)  emit "$(body_ok | grep -v 'END OF REVIEW')" end_turn ;;
  noclaims)    emit "$(body_ok | sed '/## Claim table/,$d')$(printf '\n<!-- END OF REVIEW -->\n')" end_turn ;;
  badstop)     emit "$(body_ok)" max_tokens ;;
  notext)      emit "" end_turn ;;
  badjson)     echo "not json at all" ;;
  exit7)       echo "provider exploded" >&2; exit 7 ;;
  denymount)   echo "required read-deny mounts are not in effect (read-deny path /run/docker.sock could not be opened: Permission denied)" >&2; exit 1 ;;
  unenforced)  echo "sandbox profile applied without enforcement" >&2; emit "$(body_ok)" end_turn ;;
  treechange)  touch "$FAKE_REPO/injected.txt"; emit "$(body_ok)" end_turn ;;
  hang)        sleep 30 ;;
esac
FAKEEOF
chmod +x "$FAKE"

# --- the throwaway repository ------------------------------------------------------------------------
export FAKE_REPO="$REPO"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t.test
git -C "$REPO" config user.name Test
seed_repo() {
  git -C "$REPO" checkout -q main
  echo base > "$REPO/src/a.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm base
}
seed_repo

run() { ( cd "$REPO" && bash "$SCRIPT" "$@" ); }

# Write a brief that passes every gate, for <lens> [round]
good_brief() { # <path> [extra-section]
  cat > "$1" <<EOF
# Review — the thing

## The artifact

- Branch \`feat-x\`, head abc1234.

## Scope

1. Correctness of the change.

**Out of scope:** naming and formatting.

${2:-}

## Settled decisions — do not re-litigate

1. We keep the existing storage engine, because migrating it is a separate ticket.

## Load-bearing claims — check each against the code

1. The new writer is idempotent — check src/a.txt.

## Claim table

Fill one row per claim.

$SENTINEL
EOF
}

banner() { echo; echo "== $1"; }

# ==================================================================================================
banner "setup"
out="$(run setup --no-probe 2>&1)"; rc=$?
check "setup --no-probe succeeds" "$(lived $rc)"
check "setup renders the custom profile" "$(grep -q '\[profiles.grok-review\]' "$REPO/.grok/sandbox.toml" && echo 0 || echo 1)"
check "setup gitignores .grok-review/" "$(grep -qxF '.grok-review/' "$REPO/.gitignore" && echo 0 || echo 1)"
check "setup says the probe was skipped" "$(grep -q 'SKIPPED' <<<"$out" && echo 0 || echo 1)"
check "setup lists the shipped lenses" "$(grep -q 'adversarial' <<<"$out" && echo 0 || echo 1)"
out2="$(run setup --no-probe 2>&1)"
check "setup is idempotent (keeps the existing profile)" "$(grep -q 'already in' <<<"$out2" && echo 0 || echo 1)"
check "setup does not duplicate the gitignore line" "$([ "$(grep -cxF '.grok-review/' "$REPO/.gitignore")" = 1 ] && echo 0 || echo 1)"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "setup"

# a branch with something to review
git -C "$REPO" checkout -q -b feat-x
printf 'line %s\n' 1 2 3 4 5 >> "$REPO/src/a.txt"
git -C "$REPO" commit -qam "change"

# ==================================================================================================
banner "lenses: shipped, overridden, project-only"
out="$(run lenses 2>&1)"
check "lists the six shipped lenses" "$(for l in code architecture adversarial simplicity security coverage; do grep -q "^$l " <<<"$out" || exit 1; done; echo 0)"
check "shipped lenses report WHERE=default" "$(grep -qE '^code +default' <<<"$out" && echo 0 || echo 1)"
check "a lens summary is shown" "$(grep -q 'Does the diff implement' <<<"$out" && echo 0 || echo 1)"

run new-lens security >/dev/null 2>&1
check "new-lens seeds an override from the shipped lens" "$([ -f "$REPO/.grok-review/lenses/security.md" ] && echo 0 || echo 1)"
out="$(run lenses 2>&1)"
check "the override reports WHERE=overridden" "$(grep -qE '^security +overridden' <<<"$out" && echo 0 || echo 1)"
rc=$(run new-lens security >/dev/null 2>&1; echo $?)
check "new-lens refuses to clobber without --force" "$(died $rc)"

run new-lens fund-safety >/dev/null 2>&1
out="$(run lenses 2>&1)"
check "a repo-only lens reports WHERE=project" "$(grep -qE '^fund-safety +project' <<<"$out" && echo 0 || echo 1)"
check "the scaffold carries the sentinel contract" "$(have "$REPO/.grok-review/lenses/fund-safety.md" "$SENTINEL" && echo 0 || echo 1)"
rc=$(run new-lens "../escape" >/dev/null 2>&1; echo $?)
check "new-lens refuses a path-shaped name" "$(died $rc)"
rm -f "$REPO/.grok-review/lenses/fund-safety.md"

# ==================================================================================================
banner "init"
out="$(run init code 2>&1)"; rc=$?
BRIEF="$REPO/.grok-review/feat-x/code-review-prompt.md"
check "init seeds the brief at the topic path" "$([ -f "$BRIEF" ] && echo 0 || echo 1)"
check "init strips the lens frontmatter" "$(head -1 "$BRIEF" | grep -qv -- '---' && echo 0 || echo 1)"
check "init keeps the sentinel" "$(have "$BRIEF" "$SENTINEL" && echo 0 || echo 1)"
check "the topic defaults to the branch" "$(grep -q '/feat-x/' <<<"$out" && echo 0 || echo 1)"
rc=$(run init code >/dev/null 2>&1; echo $?)
check "init refuses to clobber an existing brief" "$(died $rc)"
rc=$(run init code --force >/dev/null 2>&1; echo $?)
check "init --force resets it" "$(lived $rc)"
rc=$(run init no-such-lens >/dev/null 2>&1; echo $?)
check "an unknown lens is refused" "$(died $rc)"
err="$(run init code --force --fix 2>&1)"; rc=$?
check "--fix is tolerated, not a usage error" "$(lived $rc)"
check "…and says Claude applies it host-side" "$(grep -q 'host-side' <<<"$err" && echo 0 || echo 1)"

# ==================================================================================================
banner "brief gates"
err="$(run review code 2>&1)"; rc=$?
check "an unfilled brief is refused" "$(died $rc)"
check "…and it names the placeholders" "$(grep -q 'placeholder' <<<"$err" && echo 0 || echo 1)"

good_brief "$BRIEF"
sed -i '/^\*\*Out of scope/d' "$BRIEF"
rc=$(run review code >/dev/null 2>&1; echo $?)
check "a brief with no 'Out of scope' is refused" "$(died $rc)"

good_brief "$BRIEF"
python3 - "$BRIEF" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace("1. We keep the existing storage engine, because migrating it is a separate ticket.\n","")
open(p,'w').write(s)
PY
err="$(run review code 2>&1)"; rc=$?
check "an empty 'settled decisions' is refused" "$(died $rc)"
check "…naming that section" "$(grep -qi 'settled decisions' <<<"$err" && echo 0 || echo 1)"

good_brief "$BRIEF"
python3 - "$BRIEF" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace("<!-- END OF REVIEW -->",""));
PY
rc=$(run review code >/dev/null 2>&1; echo $?)
check "a brief without the sentinel is refused" "$(died $rc)"

# A lens declares its own required sections: `adversarial` refuses an empty claim list.
run init adversarial >/dev/null 2>&1
ADV="$REPO/.grok-review/feat-x/adversarial-review-prompt.md"
good_brief "$ADV" "## The claims to attack — this is the scope
"
err="$(run review adversarial 2>&1)"; rc=$?
check "adversarial refuses an empty 'claims to attack'" "$(died $rc)"
check "…because the LENS required that section" "$(grep -qi 'claims to attack' <<<"$err" && echo 0 || echo 1)"
good_brief "$ADV" "## The claims to attack — this is the scope

1. The writer is idempotent — src/a.txt.
"
rc=$(FAKE_MODE=ok run review adversarial >/dev/null 2>&1; echo $?)
check "adversarial runs once the claim list is filled" "$(lived $rc)"

# ==================================================================================================
banner "sandbox gates"
good_brief "$BRIEF"
mv "$REPO/.grok/sandbox.toml" "$TMP/sandbox.toml.bak"
rc=$(run review code >/dev/null 2>&1; echo $?)
check "a missing .grok/sandbox.toml is refused" "$(died $rc)"
printf '[profiles.other]\nextends = "read-only"\n' >"$REPO/.grok/sandbox.toml"
rc=$(run review code >/dev/null 2>&1; echo $?)
check "a file without the named profile is refused" "$(died $rc)"
cp "$TMP/sandbox.toml.bak" "$REPO/.grok/sandbox.toml"
mkdir -p "$HOME/.grok"
printf '[profiles.grok-review]\nextends = "workspace"\n' >"$HOME/.grok/sandbox.toml"
err="$(run review code 2>&1)"; rc=$?
check "a shadowing ~/.grok profile is refused" "$(died $rc)"
check "…saying the user file wins" "$(grep -qi 'user file' <<<"$err" && echo 0 || echo 1)"
rm -f "$HOME/.grok/sandbox.toml"

# ==================================================================================================
banner "the happy path"
rm -f "$REPO/.grok-review/feat-x/code-review.md"
good_brief "$BRIEF"
out="$(FAKE_MODE=ok run review code 2>"$TMP/err.txt")"; rc=$?
OUTFILE="$REPO/.grok-review/feat-x/code-review.md"
check "the review is promoted" "$(lived $rc)"
check "…at the review path" "$([ -f "$OUTFILE" ] && echo 0 || echo 1)"
check "…and the last stdout line is that path" "$([ "$(tail -1 <<<"$out")" = "$OUTFILE" ] && echo 0 || echo 1)"
check "the model that answered is stamped on it" "$(have "$OUTFILE" 'grok-fake-1' && echo 0 || echo 1)"
check "the head it reviewed is recorded" "$([ "$(cat "$REPO/.grok-review/feat-x/code-review.head")" = "$(git -C "$REPO" rev-parse HEAD)" ] && echo 0 || echo 1)"
check "the claim table is extracted for the next round" "$(have "$REPO/.grok-review/feat-x/code-review.claims.md" 'HOLDS' && echo 0 || echo 1)"
check "'last' points at it" "$([ "$(run last)" = "$OUTFILE" ] && echo 0 || echo 1)"
check "a ledger row is written" "$(awk -F'\t' '$6=="ok"{n++} END{exit !(n>=1)}' "$REPO/.grok-review/usage.log" && echo 0 || echo 1)"
check "the ledger records the topic and lens" "$(awk -F'\t' '$2=="feat-x" && $3=="code"{n++} END{exit !(n>=1)}' "$REPO/.grok-review/usage.log" && echo 0 || echo 1)"
check "the accounting is printed" "$(grep -q 'run accounting' "$TMP/err.txt" && echo 0 || echo 1)"
check "the reading assignment is printed before the spend" "$(grep -q 'reading assignment' "$TMP/err.txt" && echo 0 || echo 1)"
check "the brief handed over names the diff range" "$(have "$FAKE_MSG" 'Reading assignment' && echo 0 || echo 1)"
check "…and re-appends the sentinel the comment strip removed" "$(have "$FAKE_MSG" "$SENTINEL" && echo 0 || echo 1)"
check "no scratch is left at the review path" "$(! ls "$REPO/.grok-review/feat-x/"*.partial.* >/dev/null 2>&1 && echo 0 || echo 1)"
rc=$(run review code >/dev/null 2>&1; echo $?)
check "a second run refuses to overwrite the review" "$(died $rc)"

# ==================================================================================================
banner "project context"
mkdir -p "$REPO/.grok-review/lenses"
echo "This repository stores money; never churn the ledger code." >"$REPO/.grok-review/lenses/_context.md"
good_brief "$REPO/.grok-review/feat-x/simplicity-review-prompt.md"
FAKE_MODE=ok run review simplicity >/dev/null 2>&1
check "_context.md is appended to the brief" "$(have "$FAKE_MSG" 'never churn the ledger code' && echo 0 || echo 1)"
check "…under a Project context heading" "$(have "$FAKE_MSG" '## Project context' && echo 0 || echo 1)"
rm -f "$REPO/.grok-review/lenses/_context.md"

# ==================================================================================================
banner "rounds and delta scoping"
rc=$(run review code --round 3 >/dev/null 2>&1; echo $?)
check "a round with no recorded previous head refuses" "$(died $rc)"

printf 'more\n' >> "$REPO/src/a.txt"
git -C "$REPO" commit -qam "round 2 work"
R2="$REPO/.grok-review/feat-x/code-review-r2-prompt.md"
run init code --round 2 >/dev/null 2>&1
good_brief "$R2"
cat > "$REPO/.grok-review/feat-x/code-review-response.md" <<'EOF'
- F1 FIXED in deadbee — the writer is idempotent now
EOF
err="$(FAKE_MODE=ok run review code --round 2 2>&1 >/dev/null)"; rc=$?
check "round 2 runs" "$(lived $rc)"
check "…defaulting --since to round 1's head" "$(grep -q 'since defaulted' <<<"$err" && echo 0 || echo 1)"
check "…telling the reviewer to diff the delta" "$(have "$FAKE_MSG" 'review the DELTA' && echo 0 || echo 1)"
check "…seeding it with round 1's claim table" "$(have "$FAKE_MSG" 'Previous round' && echo 0 || echo 1)"
check "…and with the dispositions" "$(have "$FAKE_MSG" 'F1 FIXED in deadbee' && echo 0 || echo 1)"
check "…without pasting the previous review" "$(! have "$FAKE_MSG" 'Suggested fix' && echo 0 || echo 1)"
check "round 2 writes its own review file" "$([ -f "$REPO/.grok-review/feat-x/code-review-r2.md" ] && echo 0 || echo 1)"

rc=$(run review code --round 2 --since HEAD --full >/dev/null 2>&1; echo $?)
check "--since and --full together are refused" "$(died $rc)"
rc=$(run review code --round 3 --since HEAD >/dev/null 2>&1; echo $?)
check "--since HEAD is refused (nothing changed)" "$(died $rc)"
rc=$(run review code --round 3 --since main~99 >/dev/null 2>&1; echo $?)
check "--since a nonexistent ref is refused" "$(died $rc)"

# ==================================================================================================
banner "the size budget and the empty range"
git -C "$REPO" checkout -q main
mkdir -p "$REPO/.grok-review/empty"
good_brief "$REPO/.grok-review/empty/code-review-prompt.md"
before="$(grep -c call "$FAKE_LOG")"
rc=$(run review code --topic empty >/dev/null 2>&1; echo $?)
check "an empty diff range is refused before anything is spent" "$(died $rc)"
check "…and nothing was sent to the model" "$([ "$(grep -c call "$FAKE_LOG")" = "$before" ] && echo 0 || echo 1)"
git -C "$REPO" checkout -q feat-x

mkdir -p "$REPO/.grok-review/sizebudget"
good_brief "$REPO/.grok-review/sizebudget/code-review-prompt.md"
err="$(GROK_REVIEW_MAX_DIFF_LINES=1 FAKE_MODE=ok run review code --topic sizebudget 2>&1 >/dev/null)"; rc=$?
check "over the size budget it warns but runs" "$(lived $rc)"
check "…printing the budget message" "$(grep -q 'budget' <<<"$err" && echo 0 || echo 1)"
good_brief "$REPO/.grok-review/sizebudget/code-review-r2-prompt.md"
err="$(GROK_REVIEW_MAX_DIFF_LINES=1 run review code --topic sizebudget --round 2 --full 2>&1 >/dev/null)"; rc=$?
check "--full on a re-review over budget is refused" "$(died $rc)"
check "…naming --force-size as the deliberate override" "$(grep -q 'force-size' <<<"$err" && echo 0 || echo 1)"

# ==================================================================================================
banner "the repo-wide run marker"
mkdir -p "$REPO/.grok-review"
echo "$$ $(awk '{print $22}' /proc/$$/stat) code 'other' now" >"$REPO/.grok-review/.running"
good_brief "$REPO/.grok-review/feat-x/security-review-prompt.md"
err="$(run review security 2>&1 >/dev/null)"; rc=$?
check "a live marker makes a second run refuse" "$(died $rc)"
check "…naming --parallel as the override" "$(grep -q 'parallel' <<<"$err" && echo 0 || echo 1)"
err="$(FAKE_MODE=ok run review security --parallel 2>&1 >/dev/null)"; rc=$?
check "--parallel runs anyway" "$(lived $rc)"
check "…and says it doubles the burn" "$(grep -qi 'doubles the burn' <<<"$err" && echo 0 || echo 1)"
check "…and leaves the other run's marker alone" "$([ -f "$REPO/.grok-review/.running" ] && echo 0 || echo 1)"

echo "999999 12345 code 'gone' then" >"$REPO/.grok-review/.running"
good_brief "$REPO/.grok-review/feat-x/architecture-review-prompt.md"
err="$(FAKE_MODE=ok run review architecture 2>&1 >/dev/null)"; rc=$?
check "a stale marker is cleared with a note" "$(lived $rc)"
check "…saying so" "$(grep -q 'stale run marker' <<<"$err" && echo 0 || echo 1)"
check "the marker is released on exit" "$([ ! -f "$REPO/.grok-review/.running" ] && echo 0 || echo 1)"

# ==================================================================================================
banner "post-run contract gates"
gate_case() { # <mode> <topic> <description> <expected-ledger-outcome>
  local mode="$1" topic="$2" desc="$3" want="$4" p rc
  p="$REPO/.grok-review/$topic/code-review-prompt.md"
  mkdir -p "$(dirname "$p")"
  good_brief "$p"
  rc=$(FAKE_MODE="$mode" run review code --topic "$topic" >/dev/null 2>&1; echo $?)
  check "$desc" "$(died $rc)"
  check "…nothing is promoted at the review path" "$([ ! -f "$REPO/.grok-review/$topic/code-review.md" ] && echo 0 || echo 1)"
  if [ -n "$want" ]; then
    check "…and the attempt is in the ledger" "$(awk -F'\t' -v t="$topic" '$2==t{n++} END{exit !(n>=1)}' "$REPO/.grok-review/usage.log" && echo 0 || echo 1)"
  fi
}
gate_case short      g-short   "a response too short to be a review is refused"      1
gate_case nosentinel g-nosent  "a response with no end-of-review sentinel is refused" 1
gate_case noclaims   g-noclaim "a response with no claim table is refused"            1
gate_case badstop    g-badstop "a response that stopped early is refused"             1
gate_case notext     g-notext  "a result with no text is refused"                     1
gate_case badjson    g-badjson "a result that is not JSON is refused"                 1
gate_case exit7      g-exit7   "a non-zero grok exit is refused"                      1
gate_case unenforced g-unenf   "a run that reported no enforcement is refused"        1

p="$REPO/.grok-review/g-deny/code-review-prompt.md"; mkdir -p "$(dirname "$p")"; good_brief "$p"
err="$(FAKE_MODE=denymount run review code --topic g-deny 2>&1 >/dev/null)"
check "the bwrap read-deny failure names the version fix" "$(grep -q 'GROK_BIN' <<<"$err" && echo 0 || echo 1)"
check "…and says it is not Docker" "$(grep -qi 'NOT Docker' <<<"$err" && echo 0 || echo 1)"

p="$REPO/.grok-review/g-tree/code-review-prompt.md"; mkdir -p "$(dirname "$p")"; good_brief "$p"
err="$(FAKE_MODE=treechange run review code --topic g-tree 2>&1 >/dev/null)"; rc=$?
check "a tree changed under the reviewer is refused" "$(died $rc)"
check "…the review itself is kept for hand promotion" "$(ls "$REPO/.grok-review/g-tree/"*.partial.* >/dev/null 2>&1 && echo 0 || echo 1)"
check "…but not at the review path" "$([ ! -f "$REPO/.grok-review/g-tree/code-review.md" ] && echo 0 || echo 1)"
check "…and it names the rev-parse that repairs the next round" "$(grep -q 'rev-parse HEAD' <<<"$err" && echo 0 || echo 1)"
rm -f "$REPO/injected.txt"

p="$REPO/.grok-review/g-timeout/code-review-prompt.md"; mkdir -p "$(dirname "$p")"; good_brief "$p"
rc=$(GROK_REVIEW_TIMEOUT=1 FAKE_MODE=hang run review code --topic g-timeout >/dev/null 2>&1; echo $?)
check "a timeout is refused" "$(died $rc)"
check "…and recorded as an attempt" "$(awk -F'\t' '$6=="timeout"{n++} END{exit !(n>=1)}' "$REPO/.grok-review/usage.log" && echo 0 || echo 1)"

# ==================================================================================================
banner "status, usage, cancel, assert-clean"
out="$(run status 2>&1)"
check "status reports no running review" "$(grep -q 'no review is running' <<<"$out" && echo 0 || echo 1)"
check "status names the last promoted review" "$(grep -q 'last promoted review' <<<"$out" && echo 0 || echo 1)"
out="$(run usage 2>&1)"
check "usage prints the ledger" "$(grep -q 'per-lens totals' <<<"$out" && echo 0 || echo 1)"
check "usage explains the token columns" "$(grep -q 'UNCACHED' <<<"$out" && echo 0 || echo 1)"
out="$(run usage --topic feat-x 2>&1)"
check "usage --topic filters" "$(! grep -q 'g-short' <<<"$out" && echo 0 || echo 1)"
rc=$(run cancel >/dev/null 2>&1; echo $?)
check "cancel with nothing running aborts" "$(died $rc)"

# A real cancel: launch a run whose fake grok hangs, wait for it to claim the marker, TERM it, and
# check the harness recorded the attempt and released the marker rather than leaving one behind.
mkdir -p "$REPO/.grok-review/cancelme"
good_brief "$REPO/.grok-review/cancelme/code-review-prompt.md"
( GROK_REVIEW_TIMEOUT=60 FAKE_MODE=hang run review code --topic cancelme >/dev/null 2>&1 ) &
launched=$!
for _ in $(seq 40); do [ -f "$REPO/.grok-review/.running" ] && break; sleep 0.25; done
check "a live run claims the repo-wide marker" "$([ -f "$REPO/.grok-review/.running" ] && echo 0 || echo 1)"
out="$(run status 2>&1)"
check "status reports it as RUNNING" "$(grep -q 'RUNNING' <<<"$out" && echo 0 || echo 1)"
out="$(run cancel 2>&1)"; rc=$?
wait "$launched" 2>/dev/null
check "cancel succeeds" "$(lived $rc)"
check "…and says it signalled the run" "$(grep -q 'sent TERM' <<<"$out" && echo 0 || echo 1)"
check "…the marker is released" "$([ ! -f "$REPO/.grok-review/.running" ] && echo 0 || echo 1)"
check "…the attempt is recorded as cancelled" "$(awk -F'\t' '$6=="cancelled"{n++} END{exit !(n>=1)}' "$REPO/.grok-review/usage.log" && echo 0 || echo 1)"
check "…and nothing was promoted" "$([ ! -f "$REPO/.grok-review/cancelme/code-review.md" ] && echo 0 || echo 1)"

rc=$(run assert-clean >/dev/null 2>&1; echo $?)
check "assert-clean passes on a clean index" "$(lived $rc)"
mkdir -p "$REPO/.grok-review/x" && echo hi >"$REPO/.grok-review/x/note.md"
git -C "$REPO" add -f .grok-review/x/note.md
rc=$(run assert-clean >/dev/null 2>&1; echo $?)
check "assert-clean refuses a staged .grok-review file" "$(died $rc)"
git -C "$REPO" reset -q

# ==================================================================================================
banner "a repo under /tmp"
TMPROOT="$(mktemp -d /tmp/grok-review-tmptest.XXXXXX)"
git -C "$TMPROOT" init -q -b main
git -C "$TMPROOT" config user.email t@t.test; git -C "$TMPROOT" config user.name Test
echo a >"$TMPROOT/a.txt"; git -C "$TMPROOT" add -A; git -C "$TMPROOT" commit -qm base
git -C "$TMPROOT" checkout -q -b feat; echo b >>"$TMPROOT/a.txt"; git -C "$TMPROOT" commit -qam b
mkdir -p "$TMPROOT/.grok" "$TMPROOT/.grok-review/feat"
printf '[profiles.grok-review]\nextends = "read-only"\ndeny = ["**/*.pem"]\n' >"$TMPROOT/.grok/sandbox.toml"
good_brief "$TMPROOT/.grok-review/feat/code-review-prompt.md"
rc=$( ( cd "$TMPROOT" && bash "$SCRIPT" review code ) >/dev/null 2>&1; echo $?)
check "a repo under /tmp is refused (read-only still permits writes there)" "$(died $rc)"

# ==================================================================================================
echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
