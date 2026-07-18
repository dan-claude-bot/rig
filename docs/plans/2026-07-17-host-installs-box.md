# rig `bootstrap host=yes` installs box + runs setup-host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `rig bootstrap` converges a VM-host machine (trait `host=yes` —
roles `dev`, `staging`, `workstation`, and `custom --host yes`), it should
**install the `box` CLI globally and run box's own `setup-host`** automatically,
instead of printing `next: install the box CLI and run 'box setup-host'`. This
turns a documented to-do into a real, convergent install step, completing rig#12
(the `dev` role — the Incus claudebox host) and rig#25 (machine classes: the
host class installs box + rig users).

**Why this shape:** a `host=yes` box exists to run guest boxes; a bootstrap that
hardens the OS and joins the tailnet but then hands the operator a manual
checklist has left the machine half-built. The box CLI *is* the host's reason
for existing, so bootstrap finishes the job. But rig must finish it **the same
way `rig users apply` already assumes it happens** — by delegating to box, never
by touching Incus itself.

## The design law this respects

`commands/users-apply.sh` carries the law verbatim: *"rig NEVER installs Incus:
box's setup-host owns the daemon and its group."* Two tools converging one
daemon is drift by construction, and box is the single owner. This change does
**not** weaken that law — it *fulfils* it. rig does not `apt-get install incus`,
does not configure the daemon, does not create the `incus` group. It runs
**box's own global installer** as root; box installs Incus via its `setup-host`.
rig delegates; box owns.

The symmetry is the point: `users-apply` dies on a `host=yes` box whose `incus`
group is absent, pointing at `box setup-host`. After this change, an ordinary
`rig bootstrap dev` is what *makes that group exist* — so the two commands now
close the loop instead of one pointing at a manual step the other assumed.

## Architecture

One block appended to `commands/bootstrap.sh`, after the role-marker write; no
new files, no new flags. It keys off the existing `HOST` trait (so every
`host=yes` shape — preset or `--host yes` override — gets it, and `--host no`
opts a laptop out with zero role logic). The install runs box's raw `install.sh`
piped to `bash` with `BOX_YES=1` in the environment (non-interactive **and**
keeps `setup-host`). Source is pinnable via `BOX_REPO` / `BOX_REF`
(default `heavy-duty/box@main`).

**Tech Stack:** bash only, shellcheck, existing `ci.yml` (globstar shellcheck +
`bash test/cli.sh`) — no workflow change needed; the new code is a `.sh` file
already covered by both jobs.

## Non-Goals

- **No Incus install by rig, no daemon config, no `incus` group creation** —
  box's `setup-host` owns all of it. rig runs box's installer; box owns Incus.
- **No guest provisioning** — minting boxes is box's job (`box new`).
- **No tailnet for guests** — rig#12's constraint: the *host* joins the tailnet
  (done above in the tailscale block); guest boxes never do. box does not join
  the tailnet, so nothing here needs to enforce it.
- **No credentials on the host** — rig#12's constraint: box is creds-free, so
  the delegation introduces none.

## Global Constraints

- `#!/usr/bin/env bash` + `set -euo pipefail`; log prefix `rig-bootstrap:` via
  the existing `log` / `warn` / `die` helpers.
- Runs **only as root**, only after the full bootstrap (root check, sshd
  hardening, tailnet join + tag verification, role-marker write) has succeeded —
  so a box that failed to become what it claims never installs box.
- **Never aborts the bootstrap.** box is the host *extra*; the OS + tailnet core
  is already done and asserted. A missing curl, a dead network, or a box
  installer that errors is a `warn` with a manual-command pointer, never a `die`.
- **Convergent:** box's installer is a no-op once box is installed, so a re-run
  changes nothing.
- shellcheck-clean exactly as CI runs it (`shopt -s globstar; shellcheck -x
  bin/* **/*.sh`); `bash test/cli.sh` green as non-root.
- Keep the diff minimal — no drive-by refactors.

---

## Behavior contract (in file order, `commands/bootstrap.sh`)

After the role-marker write (`install -m 0644 "$MARKER_TMP" "$MARKER"`), before
the closing `log "done — role …"`:

1. **Guard:** `if [ "$HOST" = "yes" ]; then` — the exact guard line, no `&&`
   (distinguishing it from the `/dev/kvm` advisory `if [ "$HOST" = "yes" ] && …`
   up in the guards section).
2. **Pin points:** `BOX_REPO="${BOX_REPO:-heavy-duty/box}"`,
   `BOX_REF="${BOX_REF:-main}"`, and a `BOX_INSTALL_URL` built from them; a
   `BOX_MANUAL` string (`curl -fsSL … | BOX_YES=1 bash`) reused in every pointer.
3. **Opt-out first:** `RIG_SKIP_BOX_INSTALL=1` → `log` the skip with the manual
   pointer, do nothing else. (Rehearsals in containers, offline boxes,
   hand-managed hosts.)
4. **No-curl:** `command -v curl` absent → `warn` with the manual pointer, skip.
5. **Install:** `log` the intent (naming the pinned `BOX_REPO@BOX_REF` and that
   box owns Incus), then `if curl -fsSL "$BOX_INSTALL_URL" | BOX_YES=1 bash;`:
   - success → `log` box installed + host set up, pointer to `box new`;
   - failure (no network, installer error — the pipe fails under `pipefail`) →
     `warn` with the manual pointer. **Never `die`.**

`BOX_YES=1` in the *environment* (not a flag) is load-bearing: it makes box's
installer non-interactive **and** keeps `setup-host`, so the Incus stack is
actually built rather than the CLI merely dropped on PATH. Running as root, box
installs globally to `/opt/box` + `/usr/local/bin`.

The old `if [ "$HOST" = "yes" ]; then log "next: install the box CLI …"` block is
**replaced** by this — the message it printed is now the thing rig does.

---

## The box#71 dependency (ordering / correctness)

The **global, world-readable** install path — box under `/opt/box` with a
`/usr/local/bin` shim readable by every non-root user — depends on **box PR
#71**. Until #71 merges, box's root install lands in `/root`, and non-root users
(the `dev` box's human operator; any `box`-role rig user) cannot reach it. So
this rig step is **correct once box#71 is merged**; before then it installs box
for root but not for the humans who need it.

This is a comment in `bootstrap.sh` and is called out in the PR body. The rig
step itself is right and ships now (it is convergent and delegates correctly);
the *effective* multi-user outcome is gated on box#71. No rig code changes when
#71 lands — box's installer changes where it writes.

---

## Test Plan

### Harness (`bash test/cli.sh`, non-root, network-free)

The install itself needs root, the network, and a real host — none of which the
harness can fabricate — so, exactly like the effective-tag refusals and the
runner repo guard, the shipped script is proven by grepping its load-bearing
pieces:

- **Guarded on host=yes** — the exact guard line (`grep -qxE`) belongs to the
  box block alone.
- **Runs box's installer non-interactively** — `BOX_YES=1 bash` present.
- **Pinnable, default `heavy-duty/box@main`** — `BOX_REPO:-heavy-duty/box`.
- **Opt-out honored** — `RIG_SKIP_BOX_INSTALL` present.
- **rig never apt-installs incus** — a *negative* grep (`grep -nE 'apt-get
  install.* incus'` exits 1 = pass), so the design law cannot silently erode.
- **Ordering** — box install (`BOX_YES=1 bash`) sits *after* the role-marker
  write (`install -m 0644 "$MARKER_TMP"`); compare line numbers, same idiom as
  the `visudo -c` / `sshd -t` ordering asserts, defaults fail closed.
- **Skip/failure keeps a manual pointer** — `prepare Incus` present.
- Existing bootstrap tests unchanged: `dev` / `staging` parse and refuse
  non-root (they reach the root check long before the box block); unknown roles
  still exit 2.

### CI

Unchanged `ci.yml` covers the edits (globstar `shellcheck -x` + `bash
test/cli.sh`). No workflow change.

### Rehearsal (manual, out of harness — the effective-state proof)

Unit tests stop at the script's text; only a real host proves the daemon came
up. On a pristine Debian `host=yes` box (real hardware with `/dev/kvm`, or a
nested-virt VM):

1. `rig bootstrap dev --hostname dev-rehearsal` with a real single-use
   `tag:local` key → hardened sshd drop-in, tailnet join as `dev-rehearsal`,
   role marker `host=yes`, then **box installed and `setup-host` run**.
2. Assert **effective** state, not file existence:
   - `incus info` returns the daemon's info (setup-host built the stack);
   - `getent group incus` exists;
   - as a **fresh user added to the `incus` group** (not root): `box templates`
     lists templates and `incus list` works — the world-readable path (box#71)
     is what makes this succeed for a non-root human.
3. **Convergence:** a second `rig bootstrap dev` run reports box already
   installed and changes nothing; `incus info` unchanged.
4. **Opt-out:** `RIG_SKIP_BOX_INSTALL=1 rig bootstrap dev` skips the install and
   logs the manual pointer; nothing Incus-related is touched.
5. **box#71 gate:** before box#71 merges, step 2's *fresh incus-group user*
   check fails (box lives in `/root`); after it merges, it passes with no rig
   change. This is the acceptance line that must be re-run once box#71 lands.

The `staging` shape is the same box block; rehearsing `dev` exercises it.

## Notes

- rig#12's two hard constraints hold and are commented at the step: the host
  joins the tailnet (guests never do — box doesn't join, fine); no credentials
  on the host (box is creds-free, fine).
- The `users-apply` "absent incus group on host=yes → die pointing at
  setup-host" path stays valid as the fallback for the opt-out / failed-install
  cases; ordinary bootstrap now makes that group exist, closing the loop.
