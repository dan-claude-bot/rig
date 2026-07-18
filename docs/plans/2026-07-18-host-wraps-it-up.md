# "Calling rig with host gives you all wrapped up" — box grant delegation + the e2e-devserver proof

**Goal:** finish the host-class story end to end. `rig bootstrap` on a
`host=yes` machine already installs the box CLI and runs box's `setup-host`
(merged as PR #28). What was still missing, and what this plan delivers in one
PR:

1. **`rig users apply` delegates the box role to `box grant` / `box revoke`**
   — so an operator with role `box` receives box 0.6.0's full restricted tier
   (box#75), not a bare `incus` group membership.
2. **A CI job that proves the whole chain on a real runner** — install rig
   from the tree under review, bootstrap a dev box (tailnet join skipped via a
   new env-only `RIG_SKIP_JOIN=1` escape), apply a users file, and mint a real
   container box AS the granted operator. "I want to see green in GitHub
   knowing I can set up a devserver end to end."

Context issues: rig#12 (the dev role — the Incus claudebox host) and rig#25
(machine classes). Both shaped the host trait this plan builds on; neither is
closed by it — this is the maintainer's direct wrap-it-up request.

## Part A — the delegation (`commands/users-apply.sh`)

### Why a bare group add is wrong

box's restricted tier rides incus-user, and incus-user auto-creates each user
a **private NAT bridge with none of box's hardening** (no ACL, no DNS
isolation) and pins their project to it. `box grant` (box#75,
`host/grant-user.sh`) is the convergence that fixes that: group, project
creation, unpin the private bridge, `restricted.networks.access=boxnet` and
ONLY boxnet, snapshots allowed, the box-net profile installed in their
project. rig's old behavior — `usermod -aG incus` and done — left the
unhardened bridge one `--network` flag away from any box the operator mints.
rig was silently undercutting the contract box exists to enforce.

### The design decision: who owns the incus group?

`box grant` also adds the `incus` group itself, and on a grant that **it**
started and that later fails, it verifiably backs the membership out — a
half-granted user must not hold live socket access onto an un-narrowed
project. If rig added the group first, box grant would read the user as a
pre-existing member and *keep* the group on failure: rig's eager add would
disarm box's own safety. So under delegation:

- **The incus ADD is box grant's alone.** rig's exact-membership loop still
  *declares* incus wanted (so the removal arm never strips a granted
  membership), but skips the add when delegating.
- **The REMOVE stays rig's.** The moment the box role is gone, rig strips the
  group; `box revoke`'s own `gpasswd -d` is guarded on membership, so
  whichever side acts first, the other is a clean no-op. The two tools
  converge the same truth and cannot fight.

### Gates and failure law

- Delegation requires `host=yes` in the role marker AND `command -v box`.
  `host=no` keeps the existing skip-with-warning; a `host=yes` box without
  the box CLI is a refusal naming bootstrap as the repair (mirror of the
  existing absent-group die) — never a quiet fallback to the bare group add.
- `box grant` runs **after** the per-user convergence loop; a failure is a
  **die** with repair steps: an operator this apply claims to provision who
  holds no tier is a real refusal, and box's back-out has already closed the
  group by then.
- On the dropped-user path, a **bare** `box revoke` runs (never the purge
  flag — rig revokes, never deletes; the project and boxes stay restorable,
  `box grant` brings everything back). Its failure is a **warn**: rig's own
  group strip already closed access, and dying would strand the ledger write
  over messaging. Membership is read *before* the strip so an already-revoked
  user does not re-trigger revoke on a converged re-run.
- `users status` gains one pointer line: the tier's substance (project,
  narrowing) is box's domain — status stays a fast, daemon-free read.

## Part B — `RIG_SKIP_JOIN` + the `e2e-devserver` job

### The escape hatch (`commands/bootstrap.sh`)

`RIG_SKIP_JOIN=1` skips the **entire** tailscale section (install, join, tag
verification). Contract:

- **Env-only**: no flag, absent from `--help`. A flag is an invitation; an
  env var buried in a CI workflow is a confession.
- **Loud on every run**: the warn ("this machine is NOT on the tailnet —
  rehearsal/CI only") fires each time, so no transcript of a skipped
  bootstrap reads like a joined one.
- **The role marker still lands**: it records the *configured* traits (join=
  is the declared mode, not an attest — an already-joined re-run never
  re-joins either), and `rig users apply`'s host= gate reads it — the very
  gate the CI chain exercises.

### The job (`.github/workflows/ci.yml`)

ubuntu-latest, `timeout-minutes: 15`, one echo banner per phase so a red job
names the failing phase:

1. Install rig from the checkout (`/opt/rig` + `/usr/local/bin` symlink —
   not `install.sh`, which downloads REPO@REF; CI proves the tree under
   review, same reasoning as box's own CI).
2. `RIG_SKIP_JOIN=1 rig bootstrap dev --hostname devsrv-e2e`; assert the
   loud skip, the honest marker, `command -v box`, and `incus network show
   boxnet` (bootstrap curls heavy-duty/box@main — the accepted external dep;
   it is exactly the artifact a real bootstrap installs).
3. Users file (throwaway ed25519 keys): `e2eadmin admin`, `e2eop box`.
   `rig users apply` as real root via `su - root -c` (the invoker gate admits
   root itself; CI is the bring-up shape). Assert the grant: group, project
   `user-<uid>`, `restricted.networks.access=boxnet`, and box-net visible
   from the operator's side of the socket.
4. As e2eop (`runuser -u` — fresh process, database groups, no re-login;
   stdin pinned): `box new --name e2e --container`, `box list`,
   `box exec e2e -- true`. Container mode is box's own CI trade: the tier's
   mechanics are identical; the VM boundary stays a real-hardware ritual.
5. Teardown: `box rm e2e --force`, then drop e2eop from the file and re-apply
   — the revoke path, asserted as group-gone AND project-kept.

## Tests (`test/cli.sh`)

Grep-guards and fail-closed line-number ordering asserts, per the harness's
own patterns (the delegation needs root + a live Incus — that is the CI
job's role; the harness proves the shipped script):

- `box grant "$u"` exists, rides the `host=yes` marker arm, requires
  `command -v box`, and orders AFTER the group-convergence add.
- Absent box CLI on host=yes refuses naming bootstrap; a failed grant
  refuses the apply.
- `box revoke "$prev"` exists on the dropped path; a call-line `--purge`
  cannot ship green (absence grep).
- `RIG_SKIP_JOIN`: warn present, absent from `--help` output, and the gate
  precedes the marker write (skip falls through — the marker still lands).
- Non-root refusals unchanged.

## Non-goals

- No Incus touched by rig, ever — grant/revoke delegate; box owns the daemon
  (the standing law from users-apply and bootstrap's box block).
- No purge path: rig never deletes what it revokes.
- No tailnet in CI, and no pretense of one: the skip is loud by contract.

## Conflict awareness

PRs #29 and #30 touch bootstrap's box-install block, users-apply/users-config
and test/cli.sh on their own branches. This branch bases on main and keeps
its edits tightly localized (the tailscale-block wrap is indentation-only
around unchanged lines) so the eventual rebases stay mechanical.
