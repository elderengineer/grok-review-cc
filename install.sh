#!/usr/bin/env bash
#
# Install grok-review for agents that read skills and commands (opencode, ZCode, and anything else
# that scans ~/.agents/skills). It installs two things and touches nothing else:
#
#   1. the portable skill      -> ~/.agents/skills/grok-review        (default; symlink or copy)
#   2. the /grok-review command -> ~/.config/opencode/commands/grok-review.md
#                                  ~/.zcode/commands/grok-review.md
#
# Claude Code does not need this script: its plugin (plugins/grok) already installs /grok:review from
# the marketplace. Claude Code also reads ~/.agents/skills, so it picks up the skill from here too.
#
#   ./install.sh                 symlink the skill (tracks this checkout), write the command
#   ./install.sh --copy          copy the skill instead (self-contained, no dependency on this repo)
#   ./install.sh --dest <dir>    install the skill somewhere other than ~/.agents/skills/grok-review
#   ./install.sh --force         replace an existing install
#   ./install.sh --uninstall     remove the skill and the command files
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
  --uninstall   remove the skill and the command files
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

remove_skill() {
  if [ -L "$SKILL_DEST" ]; then
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
  say "removed the skill and the command files."
  say "restart opencode and ZCode for the menus to update."
  exit 0
fi

if [ -e "$SKILL_DEST" ] || [ -L "$SKILL_DEST" ]; then
  [ "$FORCE" = 1 ] || die "$SKILL_DEST already exists — pass --force to replace it."
  remove_skill
fi

mkdir -p "$(dirname "$SKILL_DEST")"
if [ "$MODE" = "copy" ]; then
  cp -RL "$SKILL_SRC" "$SKILL_DEST" || die "copy failed."
  say "copied skill to $SKILL_DEST"
else
  ln -s "$SKILL_SRC" "$SKILL_DEST"
  say "linked skill $SKILL_DEST -> $SKILL_SRC"
fi

install_command() {
  local dest="$1" host="$2"
  mkdir -p "$(dirname "$dest")"
  cp "$CMD_SRC" "$dest"
  say "wrote /grok-review for $host: $dest"
}

install_command "$OPENCODE_CMD" "opencode"
install_command "$ZCODE_CMD" "ZCode"

say "done. The skill name is 'grok-review'; the command is /grok-review."
say "Restart opencode and ZCode so they pick up the new skill and command."
