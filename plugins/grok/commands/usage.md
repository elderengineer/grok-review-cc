---
description: Show what every Grok review attempt in this repository consumed — the per-attempt ledger with per-lens totals
argument-hint: '[--topic <slug>]'
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" usage $ARGUMENTS
```

Present the table and the totals. Two columns need care, and say so rather than letting the user
read them wrong:

- `in_tok` is **uncached input only**; cache hits are the separate `cache_read_tok` column.
  `total_tok` (input + both cache buckets + output) is the burn signal for an agentic loop.
- an empty `cost` means the server reported an **incomplete** cost — unknown, never free. Read the
  tokens in that case.

Every attempt is a row, failures included: a run that aborted after reaching the model was billed
exactly like one that produced a review.
