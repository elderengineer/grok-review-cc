---
description: List the review lenses available in this repository — the shipped defaults, the ones this repo overrode, and the ones it added — or scaffold a new one
argument-hint: '[new <name> [--from <lens>]]'
disable-model-invocation: true
allowed-tools: Bash(bash:*), Read, Edit, Write
---

Raw arguments: `$ARGUMENTS`

**With no arguments**, list them:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" lenses
```

Present the table. Explain the `WHERE` column in one line: `default` ships with the plugin,
`overridden` means this repo replaced a shipped lens of that name, `project` means this repo added
one that does not ship. Resolution is by name — a file in `.grok-review/lenses/` always wins.

**With `new <name>`**, scaffold it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" new-lens <name> [--from <lens>]
```

`--from <lens>` seeds it from another lens; with no `--from`, a shipped lens of the same name is the
seed (that is how you override one), and otherwise you get a blank lens skeleton.

Then **help the user write it**, with Edit, from what you know about this repository:

- the frontmatter `summary` (one line, shown in the list) and `require` — the comma-separated brief
  sections the harness will refuse an empty version of. `settled decisions` is the default; add the
  section that carries *this* lens's scope, the way `adversarial` requires `the claims to attack`.
- the **Scope** section: name this repository's real seams, files and hazards. A generic checklist
  finds generic findings; the whole value of an override is that it carries the attack surfaces and
  conventions this codebase actually has.
- keep the closing contract intact — the `### F<n>` finding shape, the `## Claim table`, and the
  final `<!-- END OF REVIEW -->` line. The harness gates on all three.

A lens that applies to every review — house rules, the components reviewers keep mis-reading — does
not need a lens of its own: put it in `.grok-review/lenses/_context.md` and the harness appends it
to **every** brief as *Project context*.
