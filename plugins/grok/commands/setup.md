---
description: Check this machine for the Grok review harness, render the sandbox profile, gitignore the state directory, and MEASURE the sandbox with a probe run
argument-hint: '[--force] [--no-probe]'
disable-model-invocation: true
allowed-tools: Bash(bash:*)
---

Run the harness's setup mode. It checks every host requirement, renders `[profiles.grok-review]`
into `<repo>/.grok/sandbox.toml`, adds `.grok-review/` to the repository's `.gitignore`, lists the
lenses available here, and then **measures the sandbox**: one small grok run under the profile that
tries to write into the repository and read a denied path, and reports four verdicts (START, WRITE,
DENY, READ).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" setup $ARGUMENTS
```

The probe costs one small model call — it is the only way to measure a sandbox that lives inside the
grok process. `--no-probe` skips it, and then the confinement claim is unmeasured on this machine;
say that plainly if it was skipped.

Present the output verbatim. Every missing requirement is printed with the exact command that fixes
it — relay those commands; do not run installs yourself. If the last line reads `setup OK`, say the
harness is ready and that `/grok:review code` is the first run. If a verdict failed, say which one
and that no review can run until it passes: a reviewer that can write to the tree it is reviewing is
not an independent reviewer.

If setup warns about **grok 1.0.13 with bubblewrap 0.6.1**, relay the `export GROK_BIN=…` line it
prints. That combination refuses to start with any non-empty deny list; it is a version mismatch,
not an attack and not Docker, and no profile edit gets past it.
