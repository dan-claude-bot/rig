# rig `runner install` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `rig runner install` command that turns a bootstrapped workload
box into a self-hosted GitHub Actions runner — the official `actions/runner`
agent as a **systemd service under an unprivileged user**, with **no Docker**
and **zero inbound ports**.

**Why this shape:** the runner is an *agent, not a server* — it opens an HTTPS
long-poll out to GitHub and receives jobs down that already-established
connection, so a box behind a deny-all firewall (or on a tailnet) can run CI
jobs that reach hosts GitHub never could. Docker is deliberately refused:
`docker` group membership is root-equivalent (the socket is a root API), and on
a box whose design goal is a narrow blast radius for repo-controlled code that
is a gratuitous path to root. Docker arrives only if/when a job genuinely needs
it, and the isolation model gets revisited then (`--ephemeral`), not assumed.

**Architecture:** one new command script `commands/runner-install.sh` dispatched
by `bin/rig` (mirroring `coolify install`), test cases appended to
`test/cli.sh`, README section. No new dependencies — bash + the tools a
`rig bootstrap`-ed Debian box already has (`curl`, `tar`, `useradd`, `runuser`,
systemd). CI (shellcheck + cli tests) already globs `commands/*.sh`, so it
covers the new script with no workflow change.

**Tech Stack:** bash only, shellcheck, GitHub Actions (existing `ci.yml`).

## Global Constraints

- Every script starts `#!/usr/bin/env bash` + `set -euo pipefail`.
- shellcheck-clean at default severity: `shellcheck install.sh bin/rig commands/*.sh test/cli.sh` exits 0.
- Exit codes: `2` = usage/argument error, `1` = runtime refusal (e.g. not
  root). **All argument validation runs BEFORE the root check** so error paths
  are testable as non-root.
- **No credential ever touches disk via rig.** The registration token is read
  from the `RUNNER_TOKEN` env var or an interactive `read -rsp` prompt, handed
  to `config.sh` in memory, and never logged. (The runner itself persists its
  own derived credential under its install dir, owned by the runner user —
  that is the runner's design, not rig's doing.)
- **The runner user is never root and gets no supplementary groups** — no
  `docker`, no `sudo`. rig must not install Docker here, ever.
- Nothing org-specific in this repo — README/usage examples use generic names
  (`acme/widgets`); no real hostnames, tags beyond generic examples, or fleet
  details.
- Convergent: a second run of the same command changes nothing and exits 0.
- Conventional Commits (`type: subject`; no scope enum in this repo).
- Version pin is **required** (`--version <pin>`, no default), matching
  `coolify install`. Divergence from Coolify's `AUTOUPDATE=false` posture: the
  installed runner **self-updates** (GitHub refuses jobs from stale runners —
  a runner that never updates silently stops working). The pin states what you
  install today; GitHub owns the treadmill after that. This difference is
  deliberate and gets a README sentence.

---

### Task 1: `runner install` command + dispatcher wiring + tests

**Files:**
- Create: `commands/runner-install.sh`
- Modify: `bin/rig` (dispatch `runner install`, extend usage text)
- Modify: `test/cli.sh` (append cases before the `echo "---"` line)

**Interfaces:**
- Consumes: dispatcher passes post-`runner install` args verbatim; harness `check` function.
- Produces: `commands/runner-install.sh` taking
  `--repo <owner/repo> --version <pin> [--name <name>] [--labels <csv>] [--user <user>]`.

**Command contract (`commands/runner-install.sh`):**

Usage text (heredoc, shown on `--help` and usage errors):

```
usage: rig runner install --repo <owner/repo> --version <pin> [options]

  --repo <owner/repo>   GitHub repository the runner registers to (required)
  --version <pin>       actions/runner release to install, e.g. 2.335.1
                        (required; no default — you state what you install)
  --name <name>         runner name (default: this host's hostname)
  --labels <csv>        extra runner labels (default: ci-runner)
  --user <name>         unprivileged service user (default: github-runner;
                        created if absent; never root)

Installs GitHub's official actions/runner as a systemd service under an
unprivileged user. The runner is an agent, not a server: it long-polls
GitHub outbound and needs ZERO inbound ports. No Docker is installed and
the runner user gets no supplementary groups.

Provide the short-lived registration token via the RUNNER_TOKEN env var or
the interactive prompt (get one from the repo's Settings > Actions >
Runners > "New self-hosted runner", or:
  gh api -X POST repos/<owner/repo>/actions/runners/registration-token).
It is consumed at registration and never written to disk by rig.
```

Behavior, in order:

1. **Arg parsing** (before the root check). `-h|--help` → usage, exit 0.
   Unknown flag → `die "unknown flag: $1" 2`. Flags needing values use the
   existing `[ $# -ge 2 ] || die "--x needs a value" 2` pattern.
2. **Validation** (still before the root check):
   - `--repo` required (`die "--repo <owner/repo> is required" 2`); must match
     `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$` else `die "--repo must be owner/repo" 2`.
   - `--version` required (`die "--version <pin> is required" 2`); normalize a
     leading `v` away (`VERSION="${VERSION#v}"`).
   - `--user` must not be `root`: `die "runner user must not be root" 2`.
3. **Guards:** root check (`must run as root`, exit 1) and the same
   Debian-family warn block `bootstrap.sh` uses. Also
   `command -v curl >/dev/null || die "curl is required (run rig bootstrap first)"`.
4. **Registration token — only when registration is actually pending.**
   Registration is pending unless the runner user already exists AND
   `$RUNNER_DIR/.runner` exists (user absent ⇒ nothing can be registered ⇒
   pending): if the user exists, derive `USER_HOME`/`RUNNER_DIR` as in step 5
   and test `-e "$RUNNER_DIR/.runner"`. When NOT pending, skip token
   acquisition entirely — a converged second run must never demand a fresh
   short-lived token the operator no longer holds, and must exit 0. When
   pending: `RUNNER_TOKEN` from env, else
   `read -rsp "runner registration token (short-lived): " RUNNER_TOKEN; echo`.
   Empty → `die "empty registration token"`.
5. **User:** if `id -u "$RUNNER_USER"` fails, `useradd --create-home
   --shell /bin/bash "$RUNNER_USER"` and log; else log "user exists". Derive
   `USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"`;
   `RUNNER_DIR="$USER_HOME/actions-runner"`.
6. **Download + unpack** (skip whole step, with a log line, when
   `$RUNNER_DIR/bin/Runner.Listener` already exists — upgrades are the
   runner's own self-update, not a rig re-run):
   - Arch map: `x86_64` → `x64`, `aarch64` → `arm64`, else
     `die "unsupported arch: $(uname -m)"`.
   - `URL="https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-${ARCH}-${VERSION}.tar.gz"`.
   - Download to a `mktemp -d` workspace (with `trap cleanup EXIT`), extract
     into `$RUNNER_DIR` (`mkdir -p` first), `chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"`.
   - No checksum flag: the transport is TLS to github.com and the runner
     self-updates from the same origin forever after — a one-time hash adds
     ritual, not trust. (Stated here so it reads as a decision, not an
     omission.)
   - Run `"$RUNNER_DIR"/bin/installdependencies.sh` as root (idempotent apt
     installs of the runner's native deps).
7. **Configure** (skip, with a log line, when `$RUNNER_DIR/.runner` exists —
   already registered):
   ```bash
   (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- env HOME="$USER_HOME" \
     ./config.sh --url "https://github.com/${REPO}" --token "$RUNNER_TOKEN" \
     --name "$RUNNER_NAME" --labels "$LABELS" --unattended --replace)
   ```
   (`config.sh` refuses to run as root, hence `runuser`; `--replace` makes
   re-registration after a box rebuild convergent; `--unattended` because rig
   already collected everything interactive.)
8. **Service** via the runner's own `svc.sh` (must run as root, and svc.sh
   resolves paths relative to cwd — keep the literal `cd` wrapper):
   ```bash
   if [ ! -e "$RUNNER_DIR/.service" ]; then
     (cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER")
   fi
   (cd "$RUNNER_DIR" && ./svc.sh start)   # idempotent
   ```
9. **Final logs:** runner name + labels; "verify it shows Idle under the
   repo's Settings > Actions > Runners"; remind that the deny-all provider
   firewall stays the operator's job outside rig (existing README stance) and
   that the box needs no inbound ports for this.

Log prefix: `rig-runner:` (matching `rig-bootstrap:` / `rig-coolify:`), same
`log`/`warn`/`die` helpers as `bootstrap.sh`.

**Dispatcher (`bin/rig`):** add a `runner)` case exactly mirroring `coolify)`
(sub must be `install`, else usage + exit 2), and add to the usage heredoc:

```
  runner install --repo <owner/repo> --version <pin> [options]
      GitHub Actions runner as a systemd service under an unprivileged
      user — outbound-only, no Docker. Prompts for the short-lived
      registration token (RUNNER_TOKEN env overrides). Run as root.
```

- [ ] **Step 1: Append failing tests**

In `test/cli.sh`, insert before the `echo "---"` line:

```bash
check "bare runner shows usage, exit 2"  2 "usage:"          "$ROOT/bin/rig" runner
check "runner: --help exits 0"           0 "usage:"          "$ROOT/commands/runner-install.sh" --help
check "runner: repo required, exit 2"    2 "--repo"          "$ROOT/commands/runner-install.sh" --version 2.335.1
check "runner: version required, exit 2" 2 "--version"       "$ROOT/commands/runner-install.sh" --repo acme/widgets
check "runner: repo needs value"         2 "needs a value"   "$ROOT/commands/runner-install.sh" --repo
check "runner: rejects bad repo slug"    2 "owner/repo"      "$ROOT/commands/runner-install.sh" --repo not-a-slug --version 2.335.1
check "runner: refuses --user root"      2 "must not be root" "$ROOT/commands/runner-install.sh" --repo acme/widgets --version 2.335.1 --user root
check "runner: unknown flag exits 2"     2 "unknown flag"    "$ROOT/commands/runner-install.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "runner: refuses non-root"       1 "must run as root" env RUNNER_TOKEN=x "$ROOT/commands/runner-install.sh" --repo acme/widgets --version 2.335.1
else
  echo "skip: runner non-root refusal (running as root)"
fi
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/cli.sh`
Expected: the 16 existing checks pass; the `bare runner` check is
already green pre-implementation (the dispatcher's unknown-command branch
prints the usage text and exits 2, which happens to satisfy it); every
`runner:` check FAILS (file not found → exit 127); harness exits 1.

- [ ] **Step 3: Implement `commands/runner-install.sh` and wire `bin/rig`**

Per the command contract above. `chmod +x commands/runner-install.sh`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/cli.sh`
Expected: `25 passed, 0 failed` (or 22 + 3 skip lines as root), exit 0.

- [ ] **Step 5: shellcheck**

Run: `shellcheck install.sh bin/rig commands/*.sh test/cli.sh`
Expected: exit 0, no output.

- [ ] **Step 6: Commit**

```bash
git add commands/runner-install.sh bin/rig test/cli.sh
git commit -m "feat: runner install command — GitHub Actions runner as an unprivileged systemd service"
```

---

### Task 2: README section

**Files:**
- Modify: `README.md` (new `### rig runner install` subsection under
  Commands, after `coolify install`)

**Interfaces:**
- Consumes: the Task 1 command surface, verbatim.
- Produces: operator-facing doc matching the README's existing voice.

- [ ] **Step 1: Write the section**

Content requirements (write in the README's existing voice, don't paste this
list):

- Heading: `### rig runner install --repo <owner/repo> --version <pin>`.
- Workload-box command; run after `rig bootstrap workload`. Example block:
  ```sh
  rig bootstrap workload --hostname my-ci-box --ts-tag tag:ci
  rig runner install --repo acme/widgets --version 2.335.1
  ```
- The agent-not-server point: the runner long-polls GitHub outbound and
  receives jobs down that connection — **zero inbound ports**, so it works
  behind a deny-all firewall and can trigger deploys on hosts only it can
  reach (e.g. a tailnet-only control plane).
- The posture: official `actions/runner` as a systemd service under an
  unprivileged user (default `github-runner`, created if absent, never root,
  no supplementary groups); **no Docker, deliberately** — the docker socket
  is a root API and `docker` group membership is root-equivalent; add Docker
  only when a job truly needs it and rethink isolation then.
- Flags: `--name` (default: hostname), `--labels` (default: `ci-runner`;
  GitHub adds `self-hosted` itself), `--user`.
- Token handling: `RUNNER_TOKEN` env or interactive prompt; short-lived;
  never written to disk by rig.
- The version-pin note: pin is required like `coolify install`, but unlike
  Coolify the runner then **self-updates** — GitHub refuses stale runners, so
  freezing it means it silently stops taking jobs. Deliberate divergence.
- Convergent: safe to re-run; an already-registered runner is left alone.

- [ ] **Step 2: Full local gate**

Run: `shellcheck install.sh bin/rig commands/*.sh test/cli.sh && bash test/cli.sh`
Expected: shellcheck silent; `25 passed, 0 failed`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README section for runner install"
```

---

## Integration (orchestrator, after final review — not an SDD task)

1. Push the branch to the fork and open the PR **against upstream**:
   `git push -u fork feat/runner-install`, then
   `gh pr create --repo heavy-duty/rig --head claude-hdb:feat/runner-install ...`
   with a body summarizing the posture (outbound-only agent, unprivileged
   user, no Docker, token never on disk) and noting that the end-to-end
   functional test is the box rehearsal (README Testing section) — the CLI
   tests cover argument/refusal paths only.
2. Run the `record` skill in the consuming project's brain.
