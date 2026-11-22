# Changelog

History before 0.1.0 lives in git — rig grew its version surface (`VERSION`,
`rig --version`, the side-by-side `versions/<v>` install layout; #35/#36)
on the way to cutting its first release, and this file starts there.

## 0.4.0 — 2026-09-03

### Added

- Releases publish an offline `rig-<version>.sh` installer with a checksum, source provenance, and the pinned template registry (#219).

### Changed

- The drill drills the tree it ships in: it stages that tree and installs from it, never over the network (#220).
- A drill record's rig fields are measured from the installed tree's `VERSION`, `INSTALLED_FROM` and `SOURCE_COMMIT`, never echoed from an argument (#220).
- Bootstrapped hosts install box 0.10.0 (#207).
- Ceremony automation and doctrine are pinned to 0.7.7, so a taxonomy bootstrap press resolves the `operator` label row (#201).
- The release drill runs without a checkout, derives operators from GitHub keys, refuses invalid entry paths before credentials, and prints its complete record (#195).

### Fixed

- `drill/drill.sh` ships executable, so the documented `<root>/current/drill/drill.sh` runs as typed instead of exiting 126 (#220).
- The drill resolves `RIG_HOME` before it judges it, so a traversal spelling such as `/opt/rig/../..` is refused as the `/` it actually is rather than passing a check on its spelling; the resolved path is what the drill wipes, installs to, and names in the refusal (#220).
- Artifact installs retain durable provenance and use their carried template snapshot without GitHub access (#219).
- Rig's tenant help and layering docs no longer say blank box seeds include rig (#216).
- A box tenant is documented as converged by hand from `box root`, not
  auto-converged by box at mint (#210).
- Documented root-in-a-guest commands reach root through `box root`, never
  `box shell` plus `sudo rig` (#210).
- `rig users apply` names box 0.10.0's `box-profile` placement profile (#209).
- Drill instructions use box 0.10.0's mint syntax and current candidate pin (#208).

### Removed

- BREAKING: The drill's `--rig-repo` and `--rig-ref` flags, and the `RIG_REPO`/`RIG_REF` variables behind them, are gone (#220).
- BREAKING: `rig coolify install`, `rig coolify backup install`, and the Coolify drill leg are removed; the remaining db drill provisions Docker directly (#194).
- BREAKING: The `rig runner` command family and runner release-drill leg are removed. The `runner-server` convergence role remains. (#193).

## 0.3.2 — 2026-08-21

### Added

- `refs-guard` refuses a PR body promising `Refs #N` while GitHub says #N closes, on a body edit as much as on a push (#168).
- `rerun-owed` on a fork PR starts its own rerun: `ci-rerun` services the label, or refuses and leaves it standing (#168).
- `rig runner` is keyed on the runner name, not the box: `install --name` creates or converges one instance, each with its own directory, `_work` and unit (#166).
- `rig runner status` lists every runner on the box, discovered from `actions.runner.*` units, flagging the ones rig did not create as unmanaged (#166).
- `rig runner remove --all` tears down every runner on the box (#166).
- `rig runner install --org` registers an instance to a shared organization queue, with `--runnergroup` selecting its runner group (#165).
- Pinned template registries install with rig and serve default converges offline (#153).
- Machine-role templates can declare bootstrap traits and an optional final root install hook (#152).

### Changed

- `RIG_TEMPLATES_PIN` now names the commit the rig-templates `0.1.0` release tags, not a registry head (#187).
- Every tenant role is now defined in the rig-templates registry; rig's tree defines none (#185).
- `RIG_TEMPLATES_PIN` moves to the registry head carrying `staging-box` (#185).
- CI pins third-party actions to immutable commit SHAs and refuses unpinned workflow references (#169).
- Ceremony automation and doctrine are pinned to 0.7.4, with event triggers dispatching a separate hourly board sweep (#167).
- `remove` and `repoint` refuse without `--name` where the box runs more than one runner, and name the candidates (#166).
- BREAKING: `rig runner repoint --name` selects which runner to move; the new name it used to set is now `--rename` (#166).
- `rig runner remove` exits non-zero and names the runners still standing when it could not finish, rather than reporting a removal it did not complete (#166).
- `rig runner remove` stops the service even on the paths where it cannot deregister: reaching GitHub needs the runner's directory, stopping it needs only the unit name (#166).
- `rig runner remove --all` no longer abandons the targets after one that fails — every runner gets its turn and the failures land in the exit status (#166).
- `managed` means rig created the instance, recorded in `.rig-instance`, rather than "the directory sits under the base": a hand-rolled `~github-runner/actions-runner/<name>` is reported `unmanaged` and `install` refuses to register over it (#166).
- The legacy single-runner layout stays `managed` without the marker, since adopting it in place is the migration for every box installed before this (#166).
- `rig runner install` and `repoint` refuse an instance living outside the selected `--user`'s base, naming the user that owns it: building over it would re-own another service user's runner directory (#166).
- Runner status, removal and repointing preserve and report repository or organization scope plus the organization runner group (#165).
- Agent box scratch defaults to a private disk-backed directory instead of RAM-backed `/tmp` (#164).
- Tenant definitions can opt out of agent artifacts and enable shared sshd hardening (#155).
- Machine-role presets now come from the pinned rig-templates registry instead of bootstrap's traits table (#154).

### Fixed

- CONTRIBUTING identifies the builder as the panel requester and resolves the roster from labels.conf (#178).
- `rig runner status`, `remove` and `repoint` no longer die silently — exit 1, no output — on a box that has systemd and no `actions.runner.*` unit, which is the ordinary "nothing installed here" path they promise to converge on (#166).
- `rig runner repoint --rename` refuses a name another instance on this box already answers to, before a token is asked for and before anything is stopped: the collision used to surface after the teardown, leaving the runner deregistered and reachable under neither name (#166).
- `rig runner repoint --rename` with the name the instance already has converges, rather than tearing the runner down to re-register it as itself (#166).
- `rig runner install --name` refuses a directory already holding a runner that answers to another name — hand-rolled, or renamed by `repoint` — instead of adopting it, rewriting its identity and reporting a runner it never created (#166).
- `rig runner status` no longer calls a runner rig created under another service user `unmanaged`: an instance found by the unit scan is classified from the evidence in its directory, like the ones under the selected base (#166).
- Agent tenant boxes ship cron — binary asserted, service enabled and active — so the duty engine can arm its timer (#162).
- The netmap tag read is scoped to `Self`: an untagged node next to tagged peers no longer reads a peer's tag, false-refusing `--join login` and false-verifying untagged authkey joins (#160).

## 0.3.1 — 2026-07-24

### Added

- GitHub entry templates route humans to Discussions and prefill triage work orders and pull requests (#123)
- Platform, drill, docs and labels changes receive dedicated scope labels (#119)
- The `changelog-armed` guard returns, version-keyed (#112, ceremony#13)
- The `.ceremony/` doctrine mirror, verified by `docs-sync` on every PR (#112, ceremony#19)
- `rig template-lint` validates role definitions; rig-templates CI runs it on every PR (#110)
- Drill records cite the rig-templates SHA the converge read (#110)
- `kimi-box` joins the box tenant roles — the Kimi CLI agent guest (#109)
- CI drills the install lifecycle against a real tree — install from the checkout, converge to an empty diff, uninstall to proven absence (#106)
- `drill/drill.sh` — the drill has an instrument: pinned-ref assertion, a mechanical idempotence diff, and a `drills/<version>.md` record emitter (#105)
- `rig platform` prints a stable machine `ID`, derived from `/etc/machine-id`, never the raw value (#95)
- `rig bootstrap --undo` removes only a tailnet join rig can prove it made (#63)

### Changed

- Changelog entries land in per-issue fragments assembled by the release PR (#136)
- Release and labels machinery is consumed from heavy-duty/ceremony@0.1.0 by reference — the workflows shrink to caller stubs, the guard scripts and their tests move upstream (#112, ceremony#13)
- Agent-tenant definitions live in heavy-duty/rig-templates, pinned in-tree and overridable per mint (`RIG_TEMPLATES_DIR`/`_REF`/`_REPO`); the in-tree case arms are gone, `staging-box` stays (#110)
- `bootstrap --host yes` installs a pinned box release instead of `main` (#103)

### Fixed

- The quick-start fence names its channel and carries the release command beside it (#149)
- The drill's docs no longer claim both installers default to `main` — box installs the `BOX_RELEASE` pin, rig the latest release, and its `--box-ref` example is now a tag (#133)
- `kimi-bot-andresmgsl` is on the review panel — the roster predated it joining the bench (#120)

## 0.3.0 — 2026-07-21

### Fixed

- Deleting a shipped release heading from `CHANGELOG.md` is caught on every PR
  (#98, heavy-duty/box#122)
- The heading-uniqueness check no longer sits behind git conditions it does not
  need (#98, heavy-duty/box#143)
- An unreadable check rollup no longer reads as "nothing is failing" (#90)
- CI runs `test/labels-reconcile.sh`, which it had never run (#90)
- `state:needs-human` no longer appears on PRs a human cannot merge
  (#87, heavy-duty/box#136)
- A missing `/run/sshd` no longer reads as a broken sshd config (#92)
- CI's shellcheck sweep reaches `.github/scripts/` (#70)
- Ctrl-D at the `rig uninstall` confirm aborts out loud (#68)
- `users apply` tells "revoke everyone" apart from a truncated users file (#65)

### Added

- CI refuses a release PR with no drill record at `drills/<version>.md`
- `rig platform` — what this machine is, computed at run time, stored nowhere
  (#64)
- `/etc/rig/manifest` records which rig converged a machine, and when (#61)

### Changed

- `state:needs-human` is set at handoff, not by the cron (#96)
- PR labels split into two axes: `state:*` (whose ball) and `blocker:*` (what
  is in the way) (heavy-duty/box#137)
- BREAKING: `--class human|server` is now `--root-door closed|open`; old
  markers still resolve (#77)
- BREAKING: the box tenant roles carry a `-box` suffix (#76)
- BREAKING: machine roles carry a `-server` suffix, and `staging-server` is
  back (#76)
- Changelog entries are one line each, and the whole file now follows the rule
  (#100)

## 0.2.0 — 2026-07-19

### Added

- `users apply` grants the box *tier*, not just its socket (#49)

### Changed

- BREAKING: `rig bootstrap` takes the users file, and requires it (#51)

### Fixed

- A release no longer disarms the changelog under the PRs still in flight (#67)
- A `host=no` box with an `incus` group no longer hands out the bare socket
  (#58)
- Dropping the box role revokes through `box`, not behind its back (#50)
- `rig bootstrap` refuses a users file that names no users (#57)

## 0.1.0 — 2026-07-19

### Fixed

- The release suite accepts the ceremony's own tree (#44)
- The installer survives an environment with no `$HOME` (#39, #41)
- Headless credential prompts refuse loudly instead of dying silently (#42)

### Added

- Merging a release-labeled PR IS the release, and the release re-arms main
  (#47)
- Tagged releases, and an installer that installs them (#32)
