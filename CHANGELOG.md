# Changelog

History before 0.1.0 lives in git — rig grew its version surface (`VERSION`,
`rig --version`, the side-by-side `versions/<v>` install layout; #35/#36)
on the way to cutting its first release, and this file starts there.

## Unreleased

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
