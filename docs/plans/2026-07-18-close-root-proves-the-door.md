# close-root proves the door + `@root` key seeding — Implementation Plan (finishes #17)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish what remains of issue #17 on top of the merged fleet-users
design (#27). Main already ships the admin user (`rig users apply` — role
`admin` → `rig-admin` group, NOPASSWD sudo) and the role-aware root door
(`rig users close-root` — `PermitRootLogin no` gated on `class=human`, a
StrictModes-shaped admin check, and the invoker gate). Three gaps remain,
all named in #17: (1) close-root's gate proves the admin door *should* open,
not that it *does* — add the two reachability proofs #17 specifies
(`sudo -n true` under `runuser`, `sshd -T -C user=<admin>`); (2) #17's
headline lockout-avoidance — seed the admin's `authorized_keys` from root's
own, via a literal `@root` key-field token in the users file; (3) #17's
table said runner "can close root once an admin is proven", but main's class
model refuses close-root on `class=server` (runner) — reconcile in prose,
not code.

**Why this shape:** the admin-door gate exists so close-root never welds
shut the only door. But every check it makes today reads *files*: a sudoers
drop-in that failed to land, or an `AllowUsers`/`Match` block elsewhere in
sshd's config, leaves every file looking right while the door stays shut.
#17 names the two checks that interrogate *behavior* instead: `sudo -n true`
run as the admin (NOPASSWD sudo answers, or it doesn't — `-n` never
prompts), and `sshd -T -C user=<admin>,host=...,addr=...` (the per-user
EFFECTIVE config sshd would apply to exactly that login, Match blocks
resolved). And the one thing no local check can prove — that the operator
*holds* the admin's private key — is what `@root` answers at apply time: the
operator is connected as root *right now* using one of root's keys, so
seeding those keys is live evidence the private key is in their hands,
strictly better than any check rig could invent over a pasted literal.

## The measured lock-root table (from #17, verbatim constraints)

| Measure | Key-based root SSH after | Verdict |
|---|---|---|
| `passwd -l root` | works | harmless |
| `PermitRootLogin prohibit-password` | works | safe — bootstrap's state |
| `usermod --expiredate 1 root` | **breaks** | never |
| root shell → nologin | **breaks** | never |
| `PermitRootLogin no` | breaks root only | close-root's move, gated |

Nothing here may introduce `usermod --expiredate` or a nologin shell for
root — both break key SSH and rig's own root-run convergence path.

## Architecture

- `commands/users-close-root.sh`: the reachability proofs join the existing
  per-candidate gate loop as **additive** `flag()` checks — same refusal
  shape, naming the failing check per candidate. `runuser` may be absent
  off-Debian: precomputed once; absence skips the sudo proof with a loud
  `warn`, never a die (a missing prover must not block the door — but the
  operator is told what to verify by hand). `sshd -T -C` failing *is* a
  flag: fail closed. Allow/Deny entries are matched literally — a pattern
  that would admit the admin still refuses (fail closed; the operator proves
  patterns by hand). Both proofs sit before the drop-in install, pinned by
  line-number ordering asserts.
- `commands/lib/users-config.sh` (`parse_users_file`): the key field admits
  the literal token `@root` — shape-validated in the parse pass (exit 2,
  pre-root-check, testable non-root): exactly `@root`, no trailing material;
  a second `@root` for one user falls into the existing duplicate-line
  refusal for free; `root` as username stays refused. Mixing semantics
  (the simplest sound call): `@root` mixes with literal key lines — seeded
  keys land FIRST, literals append after, fixed order so the cmp-guard sees
  deterministic bytes.
- `commands/users-apply.sh`: resolves `@root` ONCE, after the root check
  (/root/.ssh needs root): root's current `authorized_keys`, comments and
  blanks dropped, key lines copied verbatim (options included — a
  `from=`/`command=` restriction follows its key; rig will not silently
  widen what a key can do). Empty/absent root keys die with the repair.
  Convergence: every run re-seeds from root's then-current file — the
  honest exception #17 weighs (a hand-removed seeded key returns) is
  resolved toward convergence, with "switch the line to literal keys" as
  the escape hatch, documented in usage and README.
- The runner row: **no gate change.** The `class=server` refusal in
  `assert_marker_human` grows the explanation (server-class machines are
  automation identities; root is the management plane; runner stays
  server-class deliberately; `--class human` at bootstrap is the path for a
  humanly-administered CI box), and the README identity-model section gets
  one short divergence paragraph.

**Tech Stack:** bash only, shellcheck, existing `ci.yml` (globstar
shellcheck + `bash test/cli.sh`) — no workflow change.

## Non-Goals

- No change to the class gate: `class=server` still refuses close-root, no
  `--force`, runner included.
- No `--admin-key` flag (#17's option (b)) — the users file already carries
  literal keys; `@root` covers the lockout case.
- No filtering/rewriting of root's key options on seed (no stripping
  `from=`/`command=`) — verbatim copy, documented caveat.
- No root `authorized_keys` management (Coolify owns its key material).
- No pattern-matching engine for `AllowUsers`/`DenyUsers` — literal match,
  fail closed, documented.

## Global Constraints

- `set -euo pipefail`; `rig-users:` log/warn/die prefixes; exit 2 usage
  (pre-root-check), exit 1 runtime refusal; cmp-guarded convergent writes.
- Never `usermod --expiredate 1 root`, never a nologin shell for root.
- shellcheck-clean as CI runs it (`shopt -s globstar; shellcheck -x bin/*
  **/*.sh`); `bash test/cli.sh` green as non-root.

---

### Task 1: reachability proofs in close-root's gate

**Files:** `commands/users-close-root.sh`, `test/cli.sh`

- [x] Tests: grep the two calls (`runuser -u "$a" -- sudo -n true`,
  `sshd -T -C "user=`) and pin both before the drop-in install line
  (`install -m 0644 "$TMP" "$DROPIN"`) with fail-closed line-number
  asserts; grep the graceful runuser-absent branch.
- [x] Implement: per-candidate flags after the shape checks; `HAVE_RUNUSER`
  precomputed with a single warn; `sshd -T -C` parsed for
  `pubkeyauthentication yes`, literal DenyUsers hit, AllowUsers-without-
  the-admin; resolve failure flags.
- [x] `bash test/cli.sh` green; shellcheck clean.

### Task 2: `@root` seeding

**Files:** `commands/lib/users-config.sh`, `commands/users-apply.sh`,
`test/cli.sh`

- [x] Tests through the sourced `parse()` harness: exact token parses and
  emits `user|roles|@root`; trailing material refused; mixes with literal
  lines; second `@root` is a duplicate; root cannot seed itself; an
  `@root` fixture reaches the non-root refusal (proving parse-pass
  validation); grep apply's keyless-root die.
- [x] Implement: parser token cases; apply resolves post-root-check, dies
  on empty; seeded-first/literals-after write through the existing
  cmp-guard; usage documents the semantics.
- [x] `bash test/cli.sh` green; shellcheck clean.

### Task 3: the runner row, reconciled in prose

**Files:** `commands/lib/users-config.sh` (refusal message), `README.md`,
`test/cli.sh`

- [x] Extend the `class=server` refusal to own the divergence ("runner
  included"); fixture test asserts the new wording alongside the existing
  "control plane" assert.
- [x] README: one divergence paragraph in the identity-model section; the
  `@root` paragraph in the apply section; the reachability sentence in the
  close-root section. Surgical — a concurrent PR adds a class table to the
  same README area.

## Test Plan

- **Harness:** the `@root` refusal matrix through the sourced parser
  (non-root, network-free); grep-the-shipped-script guards for both
  reachability calls with before-the-drop-in ordering asserts; the extended
  server-refusal wording through the fixture marker gate.
- **Rehearsal (manual, out of harness — the #17 shape):** throwaway cloud
  box: bootstrap `--class human`; `users apply` a file whose admin line is
  `@root`; from a second terminal, SSH in as the admin with the SAME key
  used for root (the seeded one) — the inbound connection is the proof rig
  cannot self-assert; `close-root`; confirm root refused, admin accepted;
  re-run apply and close-root — both no-op; add a literal key line, re-run,
  confirm seeded-first ordering and convergence.
