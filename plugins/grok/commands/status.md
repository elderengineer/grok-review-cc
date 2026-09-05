---
description: Show whether a Grok review is running in this repository, the last promoted review, and the last ledger rows
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" status
```

Present the output compactly. If a run is live, say which lens and topic it is on and how long ago
it started — a review takes minutes, and that is not a reason to launch another one. If the marker
is stale, say the next run clears it by itself. If the last promoted review was made against a
commit that is no longer HEAD, say so: its findings are about older code, and `/grok:review <lens>
--round 2` reviews only what has changed since.
