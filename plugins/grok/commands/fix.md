---
description: Apply the findings of the LAST promoted Grok review host-side, and record the dispositions (Phase B alone, for a review that ran without `--fix`)
disable-model-invocation: true
allowed-tools: Bash(bash:*), Bash(cat:*), Bash(git:*), Read, Edit, Write, Grep, Glob
---

Locate the last promoted review:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" last
```

If it aborts (no promoted review in this repository), say so and stop. Otherwise `cat` the file it
names and check that the head it reviewed is still `HEAD` (`/grok:status` prints both); if HEAD has
moved, warn that the findings were made against an older commit and confirm with the user before
continuing.

Then apply Phase B exactly as `/grok:review … --fix` does — you edit, host-side, with the normal
permission prompts; nothing sandboxed edits anything:

- Take the findings in order (ranked most-severe first). Open each cited `file:line` and
  **adversarially confirm the claim against the code** before any edit — does the failure scenario
  reproduce?
- **Skip, stating the reason**, any finding whose fix would change intended behaviour, would need
  changes well outside the reviewed diff, or that you judge a false positive after reading the code.
- **Apply** the rest with the smallest edit that resolves the stated failure scenario. Structural
  fixes first, then re-check which remaining findings still stand.

Record every finding's disposition in the response file beside the review
(`<lens>-review[-rN]-response.md`), citing the `F<n>` ids:

```
- F1 FIXED in <sha or "working tree"> — <one line>
- F2 WAIVED: <one line of reasoning>
```

Round N+1 is seeded with that file, so a waiver becomes a claim the next reviewer re-checks against
the delta. Finish with what was fixed (file:line each) and what was skipped and why. Do not commit.
