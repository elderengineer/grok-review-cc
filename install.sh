#!/usr/bin/env bash
#
# Install grok-review for agents that read skills and commands (opencode, ZCode, and anything else
# that scans ~/.agents/skills). It installs two things and touches nothing else:
#
#   1. the portable skill       -> ~/.agents/skills/grok-review        (default; symlink or copy)
#   2. the /grok-review command -> ~/.config/opencode/commands/grok-review.md
#                                   ~/.zcode/commands/grok-review.md
#
# Claude Code does not need this script: its plugin (plugins/grok) already installs /grok:review from
# the marketplace. It does not live-load ~/.agents/skills, so the plugin is the Claude Code route.
#
#   ./install.sh                 symlink the skill (tracks this checkout), write the command
#   ./install.sh --copy          copy the skill instead (self-contained, no dependency on this repo)
#   ./install.sh --dest <dir>    install the skill at <dir> (must end in /grok-review)
#   ./install.sh --force         replace an existing install
#   ./install.sh --uninstall     remove the skill and the command files (pass the same --dest)
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$REPO_DIR/grok-review"
CMD_SRC="$REPO_DIR/commands/grok-review.md"

SKILL_DEST="$HOME/.agents/skills/grok-review"
MODE="link"   # link | copy
FORCE=0
UNINSTALL=0

OPENCODE_CMD="$HOME/.config/opencode/commands/grok-review.md"
ZCODE_CMD="$HOME/.zcode/commands/grok-review.md"

die() { echo "install: $*" >&2; exit 1; }
say() { echo "install: $*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: install.sh [--copy | --link] [--dest <dir>] [--force] [--uninstall]

  --link        symlink ~/.agents/skills/grok-review -> this checkout (default; updates track here)
  --copy        copy the skill into place, dereferenced and self-contained
  --dest <dir>  install the skill at <dir> (default: ~/.agents/skills/grok-review)
  --force       replace an existing install
  --uninstall   remove the skill (pass the same --dest) and the command files
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --copy)      MODE="copy" ;;
    --link)      MODE="link" ;;
    --dest)      [ $# -ge 2 ] || usage; SKILL_DEST="$2"; shift ;;
    --force)     FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   usage ;;
    *)           usage ;;
  esac
  shift
done

[ -f "$SKILL_SRC/SKILL.md" ] || die "skill source not found at $SKILL_SRC — run this from the repo."
[ -f "$CMD_SRC" ]            || die "command source not found at $CMD_SRC — run this from the repo."
[ "$(basename "$SKILL_DEST")" = "grok-review" ] ||
  die "--dest must end in /grok-review: the skill name has to match its directory name."

# A skill dir, a symlink, or a plain file all count as present, and all three must be removable.
remove_skill() {
  if [ -L "$SKILL_DEST" ] || [ -f "$SKILL_DEST" ]; then
    rm -f "$SKILL_DEST"
  elif [ -d "$SKILL_DEST" ]; then
    rm -rf "$SKILL_DEST"
  fi
}

remove_commands() {
  rm -f "$OPENCODE_CMD" "$ZCODE_CMD"
}

if [ "$UNINSTALL" = 1 ]; then
  remove_skill
  remove_commands
  say "removed the skill at $SKILL_DEST and the command files."
  say "restart opencode and ZCode for the menus to update."
  exit 0
fi

# Decide whether the skill still needs installing. An existing install must not block a retry: a
# previous run can have written the skill and then failed on a command file, and --force would delete
# a working skill just to finish that. So: --force replaces, --link refreshes in place, and a --copy
# that is already present is left alone while the command files are (re)written.
skip_skill=0
if [ -L "$SKILL_DEST" ] || [ -e "$SKILL_DEST" ]; then
  if [ "$FORCE" = 1 ]; then
    remove_skill
  elif [ "$MODE" = "copy" ]; then
    say "skill already present at $SKILL_DEST — leaving it (--force refreshes)."
    skip_skill=1
  elif [ -d "$SKILL_DEST" ] && [ ! -L "$SKILL_DEST" ]; then
    die "$SKILL_DEST is a directory and --link cannot replace it with a symlink — pass --force."
  fi
  # --link over a symlink or a plain file is refreshed atomically by ln -sfn below.
fi

if [ "$skip_skill" = 0 ]; then
  mkdir -p "$(dirname "$SKILL_DEST")"
  if [ "$MODE" = "copy" ]; then
    # Stage, then swap, so a failed copy cannot leave a half-written tree at the destination.
    stage="$(mktemp -d "${TMPDIR:-/tmp}/grok-review-install.XXXXXX")"
    if ! cp -RL "$SKILL_SRC/." "$stage/"; then
      rm -rf "$stage"
      die "copy failed — destination left untouched."
    fi
    remove_skill
    if ! mv "$stage" "$SKILL_DEST"; then
      rm -rf "$stage"
      die "could not move the skill into place — destination left untouched."
    fi
    say "copied skill to $SKILL_DEST"
  else
    ln -sfn "$SKILL_SRC" "$SKILL_DEST"
    say "linked skill $SKILL_DEST -> $SKILL_SRC"
  fi
fi

# The command resolves the skill from the path it was actually installed at, so --dest is not a
# write-only flag: substitute the real destination for the default home path in the installed copy.
install_command() {
  local dest="$1" host="$2" content
  mkdir -p "$(dirname "$dest")"
  content="$(cat "$CMD_SRC")"
  content="${content//~\/.agents\/skills\/grok-review/$SKILL_DEST}"
  printf '%s\n' "$content" > "$dest"
  say "wrote /grok-review for $host: $dest"
}

install_command "$OPENCODE_CMD" "opencode"
install_command "$ZCODE_CMD" "ZCode"

say "done. The skill name is 'grok-review'; the command is /grok-review."
say "Restart opencode and ZCode so they pick up the new skill and command."
