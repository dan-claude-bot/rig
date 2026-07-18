# Class-model remnants — closing issues #12 and #25

**Goal:** finish the four remnants that keep rig#12 (the `dev` role) and rig#25
(machine classes) open. The bulk of both issues already landed on `main` via
PR #27 (traits model: role→class/host/join map, the `dev` and `workstation`
roles, `/etc/rig/role`, the effective-tag refusals, `rig users`) and PR #28
(host-class bootstrap installs box + runs its `setup-host`). What remains is
documentation debt and two small behaviors both issues explicitly asked for.

## Tasks

- [x] **README: `claudebox` → `box`** (#12 comment, item 1). The philosophy
  line still links `heavy-duty/claudebox`; the repo renamed to
  `heavy-duty/box`. The redirect works today and is one squatted rename away
  from not working. Negative-grep test pins the stale slug out.
- [x] **README: the per-role identity table** (#25, item 4). *The identity
  model* section carries the prose but not #25's at-a-glance class comparison.
  Add a compact table translated onto the current traits (class/host/join per
  role, who lives there, root SSH's fate) plus a who-installs-what /
  who-runs-as-what paragraph. No wholesale rewrite of the section.
- [x] **README: say out loud that the box install is unpinned** (#12 comment,
  item 5). box has no tags/releases and its installer resolves `refs/heads`
  only, so host-class bootstrap can only track a moving `heavy-duty/box@main`.
  The issue's decision: install `main` **and the README says so and why** —
  `BOX_REPO`/`BOX_REF` as the pin points, `RIG_SKIP_BOX_INSTALL=1` as the
  opt-out.
- [x] **bootstrap: verify the box install took effect** (#12 comment, item 3 —
  "rig trusting an exit code instead of checking effective state"). After the
  installer claims success, prove `command -v box` resolves; a hollow success
  WARNS (box is the host extra — never fatal) with the manual pointer.
- [x] **coolify verbs: role-marker sanity warnings** (#25, item 3's named
  consumer — "`rig <cmd>` sanity warnings later (e.g. `coolify install` on a
  non-control-plane box)"). Both `coolify install` and `coolify backup
  install` read `/etc/rig/role` via the lib's `read_role_marker` and warn when
  it names a non-control-plane role.
- [x] **Tests** in `test/cli.sh`, existing patterns only: live marker-warning
  checks through `RIG_ROLE_MARKER` fixtures (non-root), grep-the-shipped-script
  guards for the root-gated paths, line-number ordering assert for the
  effective check, fail-closed defaults.

## Behavior contract

- **bootstrap, box block** (`commands/bootstrap.sh`): on the installer-success
  path, `command -v box` decides the message — found → success log naming
  `box new` and `box doctor` (box's own effective-state verdict; rig never
  interrogates Incus, so the deeper verification is delegated, not
  reimplemented); absent → `warn` with the `BOX_MANUAL` pointer. Never `die`
  in either branch; exit codes and all skip/failure paths unchanged.
- **coolify install / coolify backup install**: the marker check is
  ADVISORY — absent marker or `role=control-plane …` stays silent; any other
  marker line warns and proceeds. It runs after arg validation and **before**
  the root check (testable non-root; a 0644 file needs no privilege), reads
  the path from `RIG_ROLE_MARKER` (default `/etc/rig/role`), and never
  changes an exit code: usage errors stay 2, the root refusal stays 1.
- **README**: content-only edits; no command semantics described differently
  from what ships.

## Non-goals

- No new roles, traits, flags, or marker consumers beyond the two coolify
  verbs. No changes to box. No gating (warn-only) — `close-root` remains the
  only command the marker can refuse.
