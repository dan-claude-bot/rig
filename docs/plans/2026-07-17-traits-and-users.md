# Machine Traits + `rig users` Implementation Plan (issues #26 + #24, one release)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the trait model (#26) and declarative fleet users (#24) as a
single release. Bootstrap's role list becomes presets over three orthogonal
traits (`class`, `host`, `join`), recorded in a convergent marker
`/etc/rig/role`. A new `rig users` command family makes operator accounts a
first-class, declarative concern on **every** class — the hybrid access model:
humans always enter as themselves and elevate via sudo; root SSH is what
`class` decides *after* users exist. `class=human` machines close it
(`rig users close-root`); `class=server` machines keep it as the **automation**
identity the control plane (Coolify) SSHes in as. The tailnet is network-only
(no Tailscale SSH), so named users are the only attribution at the door.

**Why this shape:** #25's server/host binary bundled three questions that
merely correlated (who lives there / hosts VMs / how it joins). #26 unbundles
them; roles stay as presets so the usual shapes remain one command. The
earlier "server is humanless — `rig users` refuses" was superseded in #26's
comments: a shared root login is unattributable, so operators belong
everywhere; what stays class-specific is the *fate of root SSH*. Root's key
hygiene on servers (`from=`-locking Coolify's key line) is README guidance,
not automation — Coolify owns its key material on the servers it registers,
and two tools converging one file is drift by construction.

**Architecture:**

- `commands/bootstrap.sh` gains a **role→traits map** — the single place a
  role's shape is declared — plus `--class/--host/--join` overrides and roles
  `dev`, `workstation`, `custom`. All per-class behavior keys off traits:
  `/dev/kvm` advisory (`host=yes`), tag policy (derived), next-steps log.
  The marker is written post-join, convergently.
- `join=login` (workstation): a set `TS_AUTHKEY` is a usage error (exit 2,
  before the root check — testable); interactive `tailscale up`; the tag
  assertion **inverts** — any effective tag is a refusal, backed out with
  `tailscale logout`, mirroring the untagged-key refusal on the authkey path.
- **tag:server policy is derived, not a trait**: only `control-plane` and
  `workload` may carry it; every other role refuses it on the effective tags
  (generalizes today's runner + staging checks into one rule).
- New `commands/users-apply.sh`, `commands/users-status.sh`,
  `commands/users-close-root.sh`, with parsing/marker helpers in
  `commands/lib/users-config.sh` so the harness can exercise refusals via
  sourced functions against fixtures (repo precedent: `assert_runner_repo`,
  `json_string_array`).
- `close-root` installs `/etc/ssh/sshd_config.d/00-rig-users.conf`
  (`PermitRootLogin no`). The **name is load-bearing**: sshd_config is
  first-wins, the Include glob expands lexically, and `-` (0x2D) < `.`
  (0x2E), so `00-rig-users.conf` is read before bootstrap's `00-rig.conf`
  and wins. Validate-then-apply exactly like bootstrap (`sshd -t`, rollback,
  `sshd -T` assertion). Bootstrap's effective-config assertion learns to
  accept `permitrootlogin no` (strictly harder) so a re-run never reopens
  root.
- Managed-user bookkeeping: `apply` maintains `/etc/rig/users` (one username
  per line) so a user removed from the input file is found and **locked**
  (never deleted) on the next run.

**Tech Stack:** bash only, shellcheck, existing `ci.yml` (globstar shellcheck
+ `bash test/cli.sh`) — no workflow change needed.

## Non-Goals

- No user deletion; no passwords (all locked, always); no LDAP/SSO/PAM; no
  per-user quotas (Incus project limits are a box concern).
- No management of root's `authorized_keys` (Coolify owns its key on the
  servers it manages; the `from=` lock is README guidance, not code).
- No Coolify application-account (web UI) management.
- No Incus / box installation (box's `setup-host` owns the daemon; the `box`
  role *asserts* the `incus` group exists and refuses with a pointer
  otherwise).
- No behavior change for control-plane/workload/runner beyond the marker
  write and the generalized (identical-in-effect) tag policy.
- Cross-repo box work (restricted-tier verification, project-awareness,
  global install) is referenced in #24 and tracked in heavy-duty/box.

## Global Constraints

- `#!/usr/bin/env bash` + `set -euo pipefail`; per-command log prefix via
  `log`/`warn`/`die` helpers (`rig-users:` for the new family).
- Exit codes: `2` = usage/argument error, `1` = runtime refusal. **All
  argument validation runs BEFORE the root check** so error paths are
  testable as non-root. File parsing counts as validation: a bad users file
  exits 2 with **all** errors reported at once.
- Convergent everywhere: a second identical run is a no-op, says so, exits 0.
- Validate-then-apply for anything that can lock the door or break sudo:
  `sshd -t` before restart (rollback on failure), `visudo -c` before the
  sudoers drop-in lands.
- shellcheck-clean exactly as CI runs it (`shopt -s globstar; shellcheck -x
  bin/* **/*.sh`); `bash test/cli.sh` green as non-root.
- Keep the diff minimal — no drive-by refactors.

---

### Task 1: role→traits map, trait flags, marker, login join path (bootstrap)

**Files:**
- Modify: `commands/bootstrap.sh` (usage heredoc, role case + trait map +
  override flags, TS_AUTHKEY/login validation, kvm advisory keyed on traits,
  generalized tag policy, login-path inverted assertion, marker write,
  next-steps log)
- Modify: `bin/rig` (bootstrap usage lines: roles + trait flags)
- Modify: `test/cli.sh` (bootstrap section additions)

**Behavior contract, in file order:**

1. Usage heredoc: roles `<control-plane|workload|runner|staging|dev|workstation|custom>`;
   flags `--hostname <name>`, `--class <human|server>`, `--host <yes|no>`,
   `--join <authkey|login>`. Document: roles are presets over traits, any
   trait overridable; `custom` requires `--hostname` and all three traits;
   `join=login` needs no pre-auth key and refuses a set `TS_AUTHKEY`
   (unset it or pass `--join authkey`); the preset table in one compact
   block.
2. Role case: the seven roles shift; `role required` / `unknown role`
   messages name them. Then the **role→traits map** — one `case "$ROLE"`
   assigning `CLASS`/`HOST`/`JOIN` per the preset table in issue #26;
   `custom` leaves all three empty.
3. Flag loop gains `--class/--host/--join`, each validating its value set
   (bad value → exit 2 naming the valid values). After the loop:
   `custom` missing `--hostname` → exit 2; `custom` missing any trait →
   exit 2. `TS_HOSTNAME` default stays the role name (custom has none).
4. Post-parse validation (still pre-root-check): `JOIN=login` with a set
   `TS_AUTHKEY` → `die` exit 2: "join=login is interactive: unset TS_AUTHKEY
   or pass --join authkey".
5. Guards: the `/dev/kvm` advisory keys on `HOST=yes` (message unchanged in
   spirit; drops the staging-only wording).
6. `verify_effective_tag` generalizes the runner/staging refusals into the
   derived policy: if role is not `control-plane`/`workload` and the
   effective tags contain `tag:server` → die (message keeps the
   role-specific repair pointers for runner/staging; a generic message for
   other shapes). Keep the existing two die-message strings greppable —
   the harness greps them (`role staging joined with tag:server`,
   runner equivalent).
7. **login path**: when `JOIN=login`, skip the pre-auth key acquisition;
   run `tailscale up --hostname="$TS_HOSTNAME"` (interactive, no
   `--authkey`); then the **inverted** assertion — poll as
   `verify_effective_tag` does, but *any* non-empty effective tag →
   `tailscale logout` + die: "joined TAGGED (…) but join=login expects a
   user-owned, untagged node — a tag here means control granted this device
   fleet identity; use a pre-auth key path (--join authkey) for fleet
   machines." Empty tags + `Running` → OK, log "user-owned join verified".
   The already-joined path runs the same class of check (tags present →
   refusal; no logout on a box that was already joined — detect, refuse,
   name the repair by hand).
8. **Marker**: after tag verification, write `/etc/rig/role` (mkdir -p
   `/etc/rig`) with exactly one line:
   `role=$ROLE class=$CLASS host=$HOST join=$JOIN` — cmp-guarded
   (write+log only on change; "marker already current" otherwise).
9. Next-steps log keys off traits + role: `control-plane` → coolify install
   pointer (as today); `runner` → runner install pointer (as today);
   `HOST=yes` → box setup-host pointer (replaces the staging-only branch);
   all classes → `rig users apply` pointer, with the class-specific tail:
   `class=human` adds "then `rig users close-root` once your admin key
   works"; `class=server` adds "root SSH stays — it is the control plane's
   automation door".
10. `bin/rig` usage: bootstrap line gains the three roles and trait flags,
    one sentence for the trait model.

- [ ] **Step 1: Append failing tests** (`test/cli.sh`, bootstrap section)

```bash
# --- traits: roles are presets, every trait individually settable (#26) -----
check "bootstrap: unknown role still exits 2"    2 "unknown role" "$ROOT/commands/bootstrap.sh" potato
check "bootstrap: bad --class value exits 2"     2 "human|server" "$ROOT/commands/bootstrap.sh" workload --class potato
check "bootstrap: bad --host value exits 2"      2 "yes|no"       "$ROOT/commands/bootstrap.sh" workload --host maybe
check "bootstrap: bad --join value exits 2"      2 "authkey|login" "$ROOT/commands/bootstrap.sh" workload --join carrier-pigeon
check "bootstrap: custom without --hostname exits 2" 2 "--hostname" \
  "$ROOT/commands/bootstrap.sh" custom --class server --host no --join authkey
check "bootstrap: custom without traits exits 2" 2 "--class" "$ROOT/commands/bootstrap.sh" custom --hostname box1
# workstation is join=login by preset: a set TS_AUTHKEY is a usage error, and it
# must die BEFORE the root check — provable non-root, which also proves the
# preset actually landed.
check "bootstrap: workstation + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workstation
# A trait override changes derived behavior, provable non-root: dev is
# join=authkey (TS_AUTHKEY fine → falls through to the root check), but
# --join login flips it into the TS_AUTHKEY refusal.
check "bootstrap: dev --join login + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev --join login
# The login-path inverted assertion needs a real tailnet; grep the refusal so a
# deleted guard cannot ship green (repo precedent: staging/runner tag greps).
check "bootstrap: login-path tagged refusal is present" 0 "" \
  grep -q "join=login expects a user-owned, untagged node" "$ROOT/commands/bootstrap.sh"
# The marker is the traits' ground truth for rig users; assert the write exists.
check "bootstrap: role marker write is present" 0 "" \
  grep -q "/etc/rig/role" "$ROOT/commands/bootstrap.sh"
```

and in the existing non-root block:

```bash
check "bootstrap: dev role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev
check "bootstrap: workstation parses, refuses non-root" 1 "must run as root" env -u TS_AUTHKEY "$ROOT/commands/bootstrap.sh" workstation
check "bootstrap: custom parses, refuses non-root" 1 "must run as root" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" custom --hostname b --class server --host no --join authkey
```

- [ ] **Step 2: Run `bash test/cli.sh`** — new checks FAIL (unknown role /
  unknown flag / missing messages), existing stay green, harness exits 1.
- [ ] **Step 3: Implement** per the behavior contract.
- [ ] **Step 4: `bash test/cli.sh`** — all green, exit 0.
- [ ] **Step 5: shellcheck + syntax** — `shopt -s globstar; shellcheck -x
  bin/* **/*.sh`; `bash -n` each edited script.
- [ ] **Step 6: Commit**

```bash
git add commands/bootstrap.sh bin/rig test/cli.sh
git commit -m "feat(bootstrap): traits under the roles — class/host/join, dev/workstation/custom, /etc/rig/role marker"
```

---

### Task 2: `rig users apply` + `rig users status`

**Files:**
- Create: `commands/lib/users-config.sh` (users-file parser, marker reader,
  role→group mapping — pure functions, no side effects, sourceable by the
  harness)
- Create: `commands/users-apply.sh`, `commands/users-status.sh`
- Modify: `bin/rig` (users subcommand dispatch + usage)
- Modify: `test/cli.sh` (users section)

**Behavior contract:**

1. `commands/lib/users-config.sh`:
   - `parse_users_file <path>`: emits normalized `user|roles|key` lines on
     stdout, or **all** validation errors on stderr and returns 1. Refusals:
     unknown role (naming the valid set `admin rig box`), differing roles
     across one user's lines, `root` as username, malformed line (fewer than
     3 fields / key not starting `ssh-` or `ecdsa-`), duplicate identical
     key line. `#` comments and blanks skipped.
   - `read_role_marker <path>`: prints `class=<v>` etc. from the marker;
     empty output when absent. No policy here — callers decide.
2. `users-apply.sh` (`rig-users:` prefix):
   - Args: `--file <path>` required (`-` = stdin, read once into a temp);
     `--help`; unknown flag exit 2. Parse+validate the whole file (exit 2 on
     any error, all reported) **before** the root check.
   - Root check. Then marker note (never a refusal): `class=server` or no
     marker → log that root SSH stays the automation door / advise
     bootstrapping a marker, respectively.
   - Install `sudo` if missing and any parsed role needs it (`admin`, `rig`).
   - `groupadd -f rig-admin rig`; if any user carries `box`, assert group
     `incus` exists else die 1 pointing at box `setup-host`.
   - Converge each user: `useradd -m -s /bin/bash` if absent, then always
     `usermod -L`; membership in the three rig-managed groups exactly
     (add and remove; other groups untouched); `~/.ssh/authorized_keys`
     written 0700/0600, user-owned, to exactly the file's keys (cmp-guarded).
   - Previously managed users absent from the file (diff against
     `/etc/rig/users`): `usermod -L`, strip the three rig groups, keep home,
     `warn` each. Then rewrite `/etc/rig/users` to the file's users.
   - Sudoers: write the two `%rig-admin`/`%rig` rules to a temp, `visudo -c`
     against it, then install atomically to `/etc/sudoers.d/rig-roles` 0440
     (cmp-guarded; die 1 with the temp preserved for inspection on a
     `visudo` failure, sudoers untouched).
   - Converged-no-change run says "already converged; no changes".
3. `users-status.sh`: `--help`; root check; reads `/etc/rig/users`, prints
   per user: roles (derived from actual group membership), key count from
   `authorized_keys`, locked/active. Exits 0 with "no rig-managed users"
   when the ledger is absent. Reads only — no network, no writes.
4. `bin/rig`: `users` dispatch (`apply`/`status`/`close-root` → their
   scripts; bare or unknown sub → usage exit 2); usage block documents the
   three subcommands in the existing voice.

- [ ] **Step 1: Append failing tests** (`test/cli.sh`; fixtures via mktemp,
  parser exercised through the sourced lib — precedent: `guard()`/`tags()`):
  bare `users` exit 2; `users frobnicate` exit 2; apply `--help` 0;
  `--file` required 2; `--file` needs value 2; missing file 2; unknown flag
  2; parser fixtures: unknown role (message lists valid set), role mismatch
  across lines, `root` refused, malformed line, a valid two-user file parses
  (and a multi-error file reports **both** errors in one run); status
  `--help` 0; non-root refusals for apply (valid fixture file) and status;
  ordering grep: `visudo -c` line precedes the `sudoers.d/rig-roles`
  install line in `users-apply.sh`.
- [ ] **Step 2: `bash test/cli.sh`** — new checks fail.
- [ ] **Step 3: Implement** per contract.
- [ ] **Step 4: `bash test/cli.sh`** — green.
- [ ] **Step 5: shellcheck + syntax** (CI invocation).
- [ ] **Step 6: Commit**

```bash
git add commands/lib/users-config.sh commands/users-apply.sh commands/users-status.sh bin/rig test/cli.sh
git commit -m "feat(users): declarative operators — apply/status over a users file, every class"
```

---

### Task 3: `rig users close-root` + bootstrap accepts the closed state

**Files:**
- Create: `commands/users-close-root.sh`
- Modify: `commands/bootstrap.sh` (effective-config assertion accepts
  `permitrootlogin no`)
- Modify: `test/cli.sh`

**Behavior contract:**

1. `users-close-root.sh`: `--help` documents the model (human-class only;
   verify your admin login in a separate session first) ; unknown flag 2;
   root check; then, in order:
   - Marker gate via `read_role_marker` (path overridable for tests via
     `RIG_ROLE_MARKER`, default `/etc/rig/role`): absent marker → die 1
     "no /etc/rig/role marker: re-run rig bootstrap so this box knows what
     it is; refusing to shut the root door blind"; `class=server` → die 1
     "class=server: root here is the control plane's automation identity —
     closing it severs fleet management"; only `class=human` proceeds.
   - Admin-door gate: at least one member of `rig-admin` with a non-empty
     `~/.ssh/authorized_keys` → else die 1 "no admin user with a key on this
     box — run rig users apply first; never close the only door".
   - Install `/etc/ssh/sshd_config.d/00-rig-users.conf` containing exactly
     `PermitRootLogin no`, cmp-guarded; `sshd -t` on the merged config
     BEFORE `systemctl restart ssh`, rollback (remove/restore) on failure —
     the bootstrap shape verbatim. Then assert `sshd -T` resolves
     `permitrootlogin no` or die.
   - Second run: "root already closed; nothing to do", exit 0.
2. `bootstrap.sh`: the `permitrootlogin` assertion regex becomes
   `(no|prohibit-password|without-password)` with a comment: `no` is the
   post-`close-root` state, strictly harder; bootstrap must never read a
   closed door as a broken one (or reopen it — its drop-in loses to
   `00-rig-users.conf` by first-wins, which is the point).

- [ ] **Step 1: Append failing tests**

```bash
check "users close-root: --help exits 0" 0 "usage:" "$ROOT/commands/users-close-root.sh" --help
check "users close-root: unknown flag exits 2" 2 "unknown flag" "$ROOT/commands/users-close-root.sh" --nope
# The whole command rests on first-wins + lexical include order: '-' < '.', so
# 00-rig-users.conf is read before 00-rig.conf. Assert the actual comparison the
# glob makes, so a renamed drop-in cannot silently lose the fight.
check "users close-root: drop-in name sorts before bootstrap's" 0 "" \
  bash -c '[ "00-rig-users.conf" \< "00-rig.conf" ]'
check "users close-root: drop-in name is the load-bearing one" 0 "" \
  grep -q "00-rig-users.conf" "$ROOT/commands/users-close-root.sh"
# Validate-then-apply ordering, greppable (repo precedent: repo-guard ordering).
# sshd -t must precede the restart in file order.
# marker refusals via the sourced lib against fixture markers:
#   class=server marker → refusal names the control plane
#   absent marker → refusal names bootstrap as the repair
#   class=human marker → gate passes (function returns 0)
# non-root: close-root refuses non-root (exit 1) after arg validation.
```

(Exact harness lines mirror the `guard()` fixture pattern; ordering check
mirrors the `guard_at`/`start_at` line-number comparison.)

- [ ] **Step 2: `bash test/cli.sh`** — new checks fail.
- [ ] **Step 3: Implement** per contract.
- [ ] **Step 4: `bash test/cli.sh`** — green.
- [ ] **Step 5: shellcheck + syntax** (CI invocation).
- [ ] **Step 6: Commit**

```bash
git add commands/users-close-root.sh commands/bootstrap.sh test/cli.sh
git commit -m "feat(users): close-root — shut the human-class root door once an admin key works"
```

---

### Task 4: README — identity model, trait tables, users commands

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write it** (in the README's existing voice):
  - Bootstrap section: role list/examples gain `dev`, `workstation`,
    `custom`; the trait table and roles-as-presets table from #26; the
    marker; the `join=login` story (untagged/user-owned is the *assertion*,
    a tag is the refusal).
  - New **identity model** subsection: the hybrid access model — operators
    on every class, humans never enter as root, `class` decides root SSH's
    fate after `rig users apply`; the attribution rationale (network-only
    tailnet, no identity broker at the door); the detection side benefit
    (any root login that isn't the control plane is anomalous by
    definition); the honest caveat (attribution, not privilege reduction —
    sudo on a Docker box is root-equivalent).
  - `rig users` section: file format, roles table (admin/rig/box,
    incus-admin deliberately not a role), apply/status/close-root, the
    locked-not-deleted convergence rule, close-root's gates, and the
    **README-only** guidance: on `class=server`, lock root's
    `authorized_keys` to the control plane with a
    `from="<control-plane-addr>"` clause on Coolify's key line (rig will
    not write that file — Coolify owns it).
- [ ] **Step 2: Full local gate** — CI shellcheck invocation +
  `bash test/cli.sh`.
- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README identity model — traits, presets, fleet users, root's two fates"
```

---

## Test Plan

- **Harness (`bash test/cli.sh`, non-root, network-free):** everything in the
  per-task steps — trait/flag validation, preset-driven TS_AUTHKEY refusals
  (proving both presets and overrides), users-file refusal matrix through the
  sourced parser, marker-gate refusals through fixtures, the lexical
  drop-in-name assertion, and the two validate-then-apply ordering greps
  (`visudo -c` before sudoers install, `sshd -t` before restart).
- **CI:** unchanged `ci.yml` (globstar shellcheck + harness) covers all new
  files.
- **Rehearsal (manual, out of harness):** Incus container pair —
  1. human-class: `bootstrap dev` (real `tag:local` key) → marker says
     `class=human host=yes join=authkey`; `users apply` a two-user file →
     users/groups/keys/sudoers as specified; re-apply no-ops; remove a user
     → locked, home intact; `status` truthful; `close-root` → `sshd -T`
     resolves `permitrootlogin no`; re-run bootstrap → green, root stays
     closed; drop a user's key, `ssh` as them fails, as the other succeeds.
  2. server-class: `bootstrap workload` → marker `class=server`; `users
     apply` proceeds (operators exist); `close-root` refuses naming the
     control plane.
  3. workstation: `bootstrap workstation` with no key → interactive login
     join, untagged asserted; with a tagged key's identity → refused and
     backed out.

## Addendum (2026-07-17, post-implementation review)

A high-effort adversarial review of the branch diff confirmed ten findings;
all are fixed in the two `fix(...)` commits following the four task commits.
The load-bearing corrections, recorded here because they refine the contracts
above:

- **The `rig` role is not an identity boundary.** `%rig`'s binary-scoped
  NOPASSWD was root-equivalent through `sudo rig users apply` (write yourself
  into `admin`, escalate). Identity management now gates its *invoker*:
  `users apply`/`close-root` refuse a `SUDO_USER` who is not a `rig-admin`
  member; direct root proceeds. Documented honestly in the README.
- **Offboarding must out-revoke PAM.** A `!`-locked password does not block
  pubkey auth under Debian's `UsePAM`; dropped users are now `usermod -L -e 1`
  (account expiry — the switch PAM honors) and their `authorized_keys` is
  renamed `.revoked-by-rig` (access revoked, data kept). Present users get
  expiry cleared idempotently; the ledger keeps dropped users as
  `name revoked` so `status` can tell the truth (`passwd -S` reporting is
  gone — every rig password is locked by design, so it said nothing).
- **Perms are converged state.** `.ssh`/`authorized_keys` ownership and mode
  converge unconditionally every run; only the content write is cmp-guarded —
  StrictModes treats perms as load-bearing, so must apply.
- **`close-root`'s gate is StrictModes-shaped**: per-candidate checks (owner,
  group/world-writable bits on home/`.ssh`/`authorized_keys`, real shell,
  unexpired account), naming each failed check. It proves the admin door
  *should* open, not that it does — the verify-in-a-separate-session advisory
  stays load-bearing.
- **`verify_effective_tag` grows the same back-out|keep discipline as
  `verify_user_owned`**: an already-joined untagged box (possibly a
  legitimate `join=login` machine) is refused *without* `tailscale logout` —
  never back out state this run did not create. `verify_user_owned` now fails
  closed on a poll timeout.
- **The widened `permitrootlogin` acceptance is class-gated**: `no` is
  hardened on `class=human`, but on `class=server` it is a refusal naming the
  likely leftover `00-rig-users.conf` — a repurposed box must not silently
  strand the control plane, and rig will not silently reopen a root door
  either.
- **`box` role is trait-aware**: on `host=no` boxes (incus absent by design)
  it warns and skips rather than aborting the whole apply — a users file is
  fleet-wide; its box grants bind only where VMs live. `host=yes` without
  incus still dies at `box setup-host`.
- **Parser hardening**: usernames validate against `^[a-z_][a-z0-9_-]{0,31}$`
  in the all-errors-at-once pass (a `|` or useradd-hostile name can no longer
  corrupt the stream or die mid-convergence).
