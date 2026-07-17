# rig `bootstrap staging` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `staging` bootstrap role alongside `control-plane` / `workload` /
`runner` — the host archetype for a machine whose job is to **host staging
VMs**: Incus VMs minted by the `box` CLI (heavy-duty/box) from its `staging`
template, each later converged from *inside* with `rig bootstrap workload` and
registered in the control plane as its own server.

**Why this shape:** the host and its guests sit on opposite sides of a trust
boundary. The guests are servers the control plane manages; the **host is
not** — it must never carry `tag:server`, and the fleet has already been bitten
once by a host that wrongly did. The role is deliberately minimal host
plumbing: hardening, tailnet join (key minted with `tag:local`), hostname —
and **nothing about Incus or box**. box's own `setup-host` owns Incus
configuration; two tools converging the same daemon is drift by construction,
so rig only *points* at box's installer in its closing log. The guest side
needs zero rig changes — `rig bootstrap workload` already is the staging-box
role.

**Architecture:** `staging` joins the existing role case in
`commands/bootstrap.sh`; no new files, no new flags. Since issue #16 / PR #20,
the tailnet tag is **not a rig argument** — the pre-auth key carries its tags
and rig asserts on the tag control actually *granted* (`.Self.Tags`), post-join
and on every re-run. So the role's tag policy lands in `verify_effective_tag`,
exactly where the `runner` policy lives: role `staging` **refuses an effective
`tag:server`** (die, exit 1 — a runtime refusal, not a usage error). The
`/dev/kvm` advisory and the box next-step pointer live in the execution path;
argument validation stays pure and root-free.

**Tech Stack:** bash only, shellcheck, existing `ci.yml` (globstar shellcheck +
`bash test/cli.sh`) — no workflow change needed.

## Non-Goals

- **No Incus, no box install** — box's `setup-host` is the single owner of the
  Incus daemon's configuration. rig prints a pointer, nothing more.
- **No VM provisioning** — minting boxes is box's job (`box new --template
  staging`, companion issue heavy-duty/box#68).
- **No control-plane/Coolify API usage** — guests register themselves via the
  existing workload flow.
- **No `dev` role** — a dev-box host role is anticipated (same plumbing, honest
  name) but explicitly out of scope here.

## Global Constraints

- `#!/usr/bin/env bash` + `set -euo pipefail`; log prefix `rig-bootstrap:`
  via the existing `log`/`warn`/`die` helpers.
- Exit codes: `2` = usage/argument error, `1` = runtime refusal. **All argument
  validation runs BEFORE the root check** so error paths are testable as
  non-root.
- The tag policy asserts the **effective** tag, never a requested one — there
  is no `--ts-tag` to refuse anymore (it died in PR #20; passing it exits 2
  with a pointer at the key). The issue's original "refuse `--ts-tag
  tag:server`" acceptance is therefore satisfied at the stronger, post-join
  layer, same as `runner`.
- `/dev/kvm` absence is a **warning, not a failure** — the role is rehearsed in
  containers where `/dev/kvm` legitimately isn't there.
- Convergent: a second run changes nothing and exits 0.
- shellcheck-clean exactly as CI runs it (`shopt -s globstar; shellcheck -x
  bin/* **/*.sh`); `bash test/cli.sh` green as non-root.
- Keep the diff minimal — no drive-by refactors. (One deliberate exception:
  `bin/rig`'s bootstrap usage line still advertises the removed `--ts-tag`
  flag and the old `tag:ci` default — stale since PR #20. It gets corrected in
  the same breath as adding `staging` to the role list, because shipping a new
  role into a help text that lies about the flag surface would be worse than
  the drive-by.)

---

### Task 1: role wiring in `commands/bootstrap.sh` + dispatcher usage + tests

**Files:**
- Modify: `commands/bootstrap.sh` (role case, effective-tag refusal, `/dev/kvm`
  advisory, closing next-step log, usage heredoc)
- Modify: `bin/rig` (bootstrap usage line: role list + stale-flag correction)
- Modify: `test/cli.sh` (bootstrap section additions)

**Behavior contract, in file order:**

1. Usage heredoc: role list becomes `<control-plane|workload|runner|staging>`;
   one added sentence: staging hosts box-minted staging VMs, its key should be
   minted with `tag:local`, and it refuses `tag:server` — the host is never
   managed by the control plane; its guest VMs are.
2. Role case arm: `control-plane|workload|runner|staging) shift ;;` and both
   error messages (`role required`, `unknown role`) name the four roles.
3. `verify_effective_tag`: after the `runner` refusal, the `staging` one — same
   shape (`grep -qx 'tag:server'` against the effective tags), message
   `role staging joined with tag:server ...` naming the repair (mint a
   `tag:local` key), rationale comment: hosts are never managed by the control
   plane, their guest VMs are; the fleet has been bitten by a host wrongly
   carrying `tag:server`. `die` with default status → exit 1.
4. Guards section (execution path, after the root check): when role is
   `staging` and `/dev/kvm` is absent, `warn` — the host exists to run VMs, but
   a container rehearsal legitimately has no `/dev/kvm`, so this must not fail.
5. Closing log: `staging` branch pointing at the box CLI — install box, run
   `box setup-host` to prepare Incus, then `box new --template staging`.
6. `bin/rig` usage: `bootstrap <control-plane|workload|runner|staging>
   [--hostname <name>]`; drop the stale `[--ts-tag <tag>]` and
   `tag:ci`-default sentence; say the tag comes from the pre-auth key and that
   roles `runner` and `staging` refuse `tag:server`.

- [ ] **Step 1: Append failing tests**

In `test/cli.sh`, bootstrap section:

```bash
check "bootstrap: staging + removed --ts-tag exits 2" 2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" staging --ts-tag tag:server
# The staging tag:server refusal rides the EFFECTIVE tag, inside
# verify_effective_tag — a path that needs a real tailnet, so it belongs to the
# rehearsal. What the harness CAN prove is that the refusal exists in the shipped
# script: grep the die message, so a deleted guard cannot ship green (the same
# reason the runner-install repo guard is grepped below).
check "bootstrap: staging effective-tag refusal is present" 0 "" \
  grep -q "role staging joined with tag:server" "$ROOT/commands/bootstrap.sh"
```

and in the existing non-root block:

```bash
check "bootstrap: staging role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" staging
```

The existing `unknown role exits 2` (potato) check already covers the
still-fails-usage path and stays untouched.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/cli.sh`
Expected: the staging checks FAIL (`unknown role: staging` → wrong exit/output
for the first and third; missing die message for the grep); everything existing
stays green; harness exits 1.

- [ ] **Step 3: Implement the role**

Per the behavior contract above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/cli.sh`
Expected: all checks pass, exit 0.

- [ ] **Step 5: shellcheck + syntax**

Run: `shopt -s globstar; shellcheck -x bin/* **/*.sh` (exactly CI's
invocation) and `bash -n` on each edited script.
Expected: exit 0, no findings.

- [ ] **Step 6: Commit**

```bash
git add commands/bootstrap.sh bin/rig test/cli.sh
git commit -m "feat(bootstrap): staging role — the host archetype for box-minted staging VMs"
```

---

### Task 2: README roles documentation

**Files:**
- Modify: `README.md` (bootstrap section: heading role list, example block, the
  roles paragraph)

- [ ] **Step 1: Write it**

Content requirements (in the README's existing voice):

- Heading/example gain `staging` (`rig bootstrap staging --hostname my-vm-host`).
- One honest paragraph in the roles discussion: `staging` is the box that
  *hosts* staging boxes — Incus VMs minted by the `box` CLI, each converged
  from inside with `rig bootstrap workload` and registered in the control plane
  as its own server. Mint its key with `tag:local`; the role **refuses an
  effective `tag:server`** — the host is never managed by the control plane,
  its guests are. rig deliberately installs no Incus and no box (box's
  `setup-host` owns that); it points there when done.

- [ ] **Step 2: Full local gate**

Run: CI's shellcheck invocation + `bash test/cli.sh`.
Expected: silent shellcheck; all tests pass.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README section for the staging bootstrap role"
```

---

## Test Plan

- **Harness (`bash test/cli.sh`, non-root, network-free):** staging parses and
  reaches the root check (exit 1 `must run as root`); staging + the removed
  `--ts-tag` dies at arg validation (exit 2, message points at the key —
  proving validation precedes the root check); the effective-tag refusal
  message is present in the script; unknown roles still exit 2.
- **CI:** unchanged `ci.yml` covers the edits (globstar shellcheck + harness).
- **Rehearsal (manual, out of harness):** pristine Debian box → `rig bootstrap
  staging` with a real single-use `tag:local` key → hardened sshd drop-in,
  tailnet join, hostname `staging`, `/dev/kvm` warning absent on real hardware,
  closing log points at box; second run is a no-op. A `tag:server` key must
  die post-join with the staging refusal.

## Addendum (2026-07-17, written before implementation)

Issue #22 predates the merge of PR #20 (issue #16: the tag comes from the key).
Its acceptance criterion "`rig bootstrap staging --ts-tag tag:server` exits 1
with a refusal, before the root check" names a flag that no longer exists —
`--ts-tag` now dies (exit 2) for every role, before the root check, pointing at
the key. The staging `tag:server` policy therefore lands where the runner's
did: on the **effective** tag in `verify_effective_tag`, exit 1, which is the
strictly stronger check (it guards the tag the key actually granted, not the
one rig hoped for). This plan is the up-to-date statement of the work.
