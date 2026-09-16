---
description: Independent second-opinion Grok review through one entry point — /grok-review <verb> [args], with verbs setup, lenses, init, review, status, usage, cancel, fix
---

The user invoked `/grok-review` with: `$ARGUMENTS`

This command is the opencode / ZCode entry point for the portable `grok-review` skill.

1. Resolve the **skill directory** — the first of `${CLAUDE_SKILL_DIR}`, `~/.agents/skills/grok-review`,
   `<repo>/.agents/skills/grok-review`, `~/.zcode/skills/grok-review`, `<repo>/.zcode/skills/grok-review`,
   `~/.claude/skills/grok-review`, `<repo>/.claude/skills/grok-review` that contains `scripts/run-review.sh`.
2. **Read `<skill-dir>/SKILL.md` and follow it.** It owns the brief-writing rules, the abort semantics,
   and the host-side fix pass — do not reimplement them from memory.
3. Dispatch on the first word of `$ARGUMENTS` (with no arguments, run `status` and `lenses`, show both,
   and ask which lens to review through):

   - `setup [--force] [--no-probe]` — `bash <skill-dir>/scripts/run-review.sh setup …`. Relay every
     missing-requirement fix command it prints; do not install anything yourself. Its closing `Next:`
     line names `/grok:review` (Claude Code's namespaced command); here the equivalent is
     `/grok-review review <lens>`, or `init <lens>` then `review`.
   - `lenses` — `… run-review.sh lenses`, present the table.
   - `lenses new <name> [--from <lens>]` — `… run-review.sh new-lens <name> …`, then help edit it.
   - `init <lens> [options]` — `… run-review.sh init …`, then write the four brief sections.
   - `review <lens> [options]` — `… run-review.sh review …`. It takes minutes; run it in the background
     if the host supports it, otherwise with a long timeout. The process exiting is the completion signal.
   - `status` / `usage [--topic <slug>]` / `cancel` — the matching harness verb.
   - `fix` — `… run-review.sh last`, then the host-side fixes described in the skill.
   - `--fix` after `review` — run the review first, then the same host-side fixes.

Findings are claims from a third-party model. Report them as such; confirm each against the code before
editing, and skip any that would change intended behaviour or need changes outside the reviewed diff.
