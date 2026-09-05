# Confinement — what holds the reviewer, and the host that breaks it

Read this before changing the sandbox profile or the harness's sandbox gates. The happy path does
not need it: every requirement aborts at runtime naming its own fix.

The reviewer runs headless under the **`grok-review` profile** in `<repo>/.grok/sandbox.toml`, which
`/grok:setup` renders. It reads any file and runs read-only git commands, and it **cannot write to
the working tree**. That is why the review comes back on stdout and the script owns the review file
— an independent reviewer that can edit the code under review is not one.

## Why a custom profile, and not `--sandbox read-only`

A *built-in* profile that cannot be applied (unsupported kernel, missing entitlements) makes grok
warn and continue **without enforcement** (`~/.grok/docs/user-guide/18-sandbox.md`, "Platform
Support"), so `--sandbox read-only` fails **open** — the one direction a sandbox must never fail. An
explicitly-requested **custom** profile refuses to start instead, on both macOS and Linux, and on
Linux the non-empty `deny` list is what makes that refusal kernel-backed through bubblewrap.

Hence: `GROK_REVIEW_SANDBOX` selects among the profiles in that file and **cannot** substitute a
built-in one. Since an empty `deny` list would mean a built-in profile, there is no profile edit
that trades enforcement for convenience — do not reach for one.

grok resolves custom profiles from exactly two places: `~/.grok/sandbox.toml` (user) and
`<cwd>/.grok/sandbox.toml` (project). There is no path override, which is why the harness writes
into the reviewed repository rather than somewhere private. When both files define the same profile
name, **the user file wins and grok only warns** — so `setup` and every `review` refuse outright if
`~/.grok/sandbox.toml` defines `[profiles.grok-review]`. Checking the project file alone would
approve a policy that never took effect.

## Measured versus inferred

**Measured**, and load-bearing:

- `/grok:setup`'s probe runs grok under the real profile and reports four verdicts — START (the
  binary starts under the custom profile at all), WRITE (a `touch` into the repository is refused),
  DENY (a path matching the profile's deny list is unreadable), READ (an ordinary file is
  readable). It costs one small model call, because a sandbox that lives inside the grok process
  cannot be measured from outside it.
- The repo root is not under `/tmp` or `/var/tmp`, where the `read-only` base still permits writes.
- `git status --porcelain` and `HEAD` are unchanged after the run. This cannot tell a sandbox escape
  from the operator editing in another window, so it never promotes on its own — and never throws
  the review away either. A gate that costs ten minutes of work on a benign edit is a gate people
  learn to switch off.

**Inferred**, and worth no more than that: the stderr scan for a non-enforcement warning. grok's
docs do not pin that wording, so the pattern can only ever add a catch, never prove one did not
happen. Do not treat it as the guarantee; the fail-closed profile, the probe and the tree assertion
are the guarantee.

## The version constraint, in full

**grok 1.0.13 cannot run this harness on bubblewrap 0.6.1.** After re-exec into bwrap it verifies
its kernel read-deny mounts, the verification fails for every deny path, and it refuses to start
with `required read-deny mounts are not in effect (read-deny path <p> could not be opened:
Permission denied) … possible __GROK_INSIDE_BWRAP spoof`.

**It is the binary, not the paths.** Measured 2026-09-03 on bubblewrap 0.6.1:

| profile's `deny` list | grok 1.0.13 | grok 1.0.5 |
|---|---|---|
| a repo file, mode 664, readable | refuses | starts |
| a path that **does not exist** | refuses | starts |
| the project profile | refuses | starts, and enforces |

Enforcement on 1.0.5 was measured, not assumed: the reviewer answers `Permission denied` on a denied
file, reads a non-denied file normally, and a `touch` into the tree comes back `BLOCKED … Permission
denied`. Pin it:

```bash
export GROK_BIN="$HOME/.grok/downloads/grok-1.0.5-linux-x86_64"
```

`/grok:setup` detects exactly this pair and prints that line. Re-test on a bubblewrap or grok
upgrade — the constraint is a bug in one version, not a permanent fact.

**Docker is not the cause.** The first paths 1.0.13 names are `/run/containerd/containerd.sock` and
`/run/docker.sock`, which reads as a Docker interaction. It is not: 1.0.5 runs clean with
`docker.service`, `docker.socket` and `containerd` all active, and 1.0.13 fails with every one of
them stopped and the socket files deleted. Stopping Docker neither helps nor is needed. The sockets
are simply early entries in the deny set that fails wholesale, and they are root-owned, so their
error is `Permission denied` rather than something more obviously self-inflicted.

## What the rendered profile denies

```toml
[profiles.grok-review]
extends = "read-only"
deny = ["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/id_rsa*", "**/id_ed25519*",
        "**/auth.json", "**/.netrc", "**/credentials", "**/*.p12", "**/*.keystore"]
```

`read-only` already limits writes to `~/.grok/` and the temp directories and, on Linux, blocks
child-process network through seccomp. The `deny` list adds kernel-enforced read+write denial for
credential-shaped paths on top of it — and, just as importantly, makes the profile non-empty, which
is what makes an unappliable profile refuse to start instead of running unenforced.

Two things it deliberately does not do. It does not restrict *reads* of the tree: a code review has
to read the whole repository, which is why the reviewer is a full agent with a shell and git rather
than a model handed a diff. And it does not stop the model's own API traffic — built-in tools that
make HTTP requests in-process are never affected by a profile; the agent needs the network to
function. Everything the reviewer reads goes to its provider. That is the trade this plugin makes
explicit, not one it removes.
