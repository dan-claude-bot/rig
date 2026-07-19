# Changelog

History before 0.1.0 lives in git — rig grew its version surface (`VERSION`,
`rig --version`, the side-by-side `versions/<v>` install layout; #35/#36)
on the way to cutting its first release, and this file starts there.

## Unreleased

### Added

- **`users apply` grants the box *tier*, not just its socket** (#49) — role
  `box` resolved to exactly one action, `usermod -aG incus`. That is the
  socket; it is step 1 of the five `box grant` performs, so every box-role
  user still needed an admin to run `box grant <user>` by hand before their
  first `box new` would do anything but refuse ("your project has no box-net
  profile"), and until that admin arrived they held an `incus` membership
  with no converged project — incus-user would lazily hand them a stock
  unhardened NAT bridge, which is worse than no grant at all. On `host=yes`
  apply now calls `box grant` per box-role user, after `useradd` (grant
  refuses an unknown account) and with the group ADD deferred to grant, so a
  grant that fails partway can take the socket back with it. Failures split
  the way the `host=` guard beside them already splits: a missing `box` CLI
  on `host=yes` dies (a broken VM host), a per-user grant failure warns and
  continues (one box-role user must not stop apply for the fleet). `host=no`
  and marker-less boxes keep their existing skip-with-warning. An
  `incus-admin` member is warned, not fatal — `box grant` refuses them today,
  which heavy-duty/box#99 fixes box-side with no rig change needed.

### Fixed

- **A `host=no` box with an `incus` group no longer hands out the bare
  socket** (#58) — `users apply` consulted the `host=` trait only when group
  `incus` was ABSENT (die on `host=yes`, skip on `host=no`). When the group
  was PRESENT the trait was never asked, so a `host=no` or marker-less box
  that nonetheless carried the group — `box setup-host` ran, then the box was
  re-bootstrapped with other traits — gave every box-role user a bare
  `usermod -aG incus`: the socket with no tier behind it, which `incus-user`
  answers by lazily building an UNHARDENED project under whoever opens it
  (`incusbr-<uid>`, NAT on v4 and v6, no ACL, no `dns.mode=none`, no port
  isolation). The marker now decides in BOTH directions, through one new pure
  gate (`assert_marker_hosts_vms`, testable against fixture markers non-root
  like `assert_marker_human`): the box role applies only where the box CLAIMS
  to host VMs, so the verdict is identical whether or not the group exists.
  The machine deliberately does not overrule the marker — but the skip is not
  silent either: when the group exists and the trait disagrees, the warning
  names the contradiction and `rig bootstrap` as the repair. On such a box
  exact-membership convergence now strips box-role users out of `incus`, on
  the same reasoning: a membership inherited from a previous life is the same
  half-grant as a freshly added one.
- **Dropping the box role revokes through `box`, not behind its back**
  (#50) — `users apply` converged group `incus` with a bare `gpasswd -d`,
  the same move it makes for `rig-admin` and `rig`. Those two are rig's;
  `incus` is box's, and `box revoke` does strictly more with it: it says
  out loud that supplementary groups are read at LOGIN, so a session the
  dropped operator already holds keeps the Incus socket until it dies, and
  hands over `loginctl terminate-user <user>` as the remedy. rig logged
  `removed <user> from incus` and moved on, so an operator who dropped
  someone from the users file and watched apply succeed believed the VM
  access was gone — and was wrong for as long as that user held a session.
  Both removal paths (the per-user convergence and the dropped-user sweep)
  now call `box revoke`, which keeps one owner for the group. Never
  `--purge`: that deletes the user's boxes, images and project, and
  destroying someone's running machines is not a convergence step — it
  stays an explicit admin act. The exit code is not trusted (#12's lesson):
  a revoke that returns 0 with the membership still standing has not closed
  the socket, and rig falls back to removing the group itself, as it also
  does where box is not installed. Every fallback path carries the session
  warning, because the silence was the bug.

## 0.1.0 — 2026-07-19

### Fixed

- **The release suite accepts the ceremony's own tree** (#44) —
  `test/release.sh` demanded a literal `## Unreleased` heading in the real
  `CHANGELOG.md`, extracting non-empty and containing `#32`. All three are
  false by construction on the `release: X.Y.Z` tree the ceremony's own PR
  produces (it stamps that heading into `## X.Y.Z — date`), so the first
  real release PR turned CI red and the flow blocked itself — invisible to
  both fork rehearsals, which tag a branch (`release.yml` runs; `ci.yml`
  never does). The guard now asserts what it was for: whatever the TOP
  `## ` section is — `Unreleased` between releases, the stamped version on
  and right after one — the exact `changelog_section` the workflow runs
  extracts it non-empty. The rotting issue-number grep is gone.

- **The installer survives an environment with no `$HOME`** (#39) —
  cloud-init's `runcmd` runs `install.sh` with no `$HOME` set, and under
  `set -u` the first expansion died with a bash unbound-variable stack
  instead of an install — found live by box#88's template seed, which
  pins `HOME=/root` as its own scar. The installer now derives the home
  from `getent` for the effective user (root included) before any path
  is built from `$HOME`, and when getent has no answer either it refuses
  by name. Driven with a shim getent both ways: the derived-home install
  lands, the no-answer refusal is pinned. (#41 — merged without its
  entry; restored here at the release gate.)
- **Headless credential prompts refuse loudly instead of dying silently**
  (#42) — the interactive credential prompts (`TS_AUTHKEY` in `bootstrap`,
  `RUNNER_TOKEN` in `runner install`, `RUNNER_REMOVE_TOKEN` in
  `runner remove`, and both tokens in `runner repoint` — a site the new
  no-bare-read test caught after the issue counted three) were bare
  `read -rsp`: with stdin not a tty (CI,
  `box exec`, any script), `read` fails, `set -e` ends the run, and the
  log just *stops* — exit 1, no last word, measured live in the
  2026-07-19 release drill. Each prompt now checks for a tty first and
  dies naming the variable that unblocks an unattended run (`runner
  remove` also names `--local`), and every `read` is `|| die`-guarded so
  EOF at a real prompt gets the same courtesy. `db.sh` already held the
  line here; now all of rig does.

### Added

- **Merging a release-labeled PR IS the release — and the release re-arms
  main itself** (#47) — the rig twin of heavy-duty/box#96, born of the
  ceremony retro: the tag was a separate, manual, silent-when-forgotten
  step, and a forgotten tag produces no red X. `release.yml` now fires on
  pushes to main (fork-sourced ceremony PRs get a read-only token on
  `pull_request` events), reading the transition from the push itself:
  `event.before` to the pushed head. A decide step answers four states —
  release-flow *work* merged under the `release` label (`-dev` endstates,
  the post-release window) no-ops green with a NOTICE; the two genuinely
  ambiguous bare states refuse loudly; a true transition then requires a
  merged, `release`-labeled PR behind the commit (read via the API — the
  label is the operator's declared intent). Then, in the same job, it
  API-creates the tag at the merge commit, publishes with the extracted
  notes — and bumps main to `X.Y.(Z+1)-dev` itself, direct push with a
  loud open-a-PR fallback, so no follow-up bump PR exists on the paved
  road. A `GITHUB_TOKEN`-created tag never fires the tag-push trigger, so
  the paths cannot double-publish — and that tag-push path survives intact
  as the documented manual fallback and backfill.

- **Tagged releases, and an installer that installs them** (#32) — the rig
  half of the flow designed in heavy-duty/box#83, near-verbatim. A release
  is a PR, then a tag: the `release: X.Y.Z` PR bumps `VERSION` and stamps
  this file's Unreleased section with version + date; the merge commit is
  tagged bare `X.Y.Z` (box's tag scheme — no `v` prefix). `release.yml`
  turns the tag into the GitHub release — after asserting tag == `VERSION`
  (mismatch fails loudly and creates nothing) — with that version's section
  of this file as the body, extracted by the same `changelog_section` the
  test harness drives. No assets: for a pure-bash tree, GitHub's source
  tarball for the tag IS the package. `install.sh` now defaults to the
  **latest release**: the tag is resolved by following the
  `releases/latest` redirect and reading the `Location` header — no API, no
  token — and the download is `archive/refs/tags/<tag>.tar.gz`. `RIG_REF`
  picks the other two channels: a tag pins (`refs/tags` outranks a
  same-named branch), a branch (`RIG_REF=main`) tracks the development
  tree. Until 0.1.0 is cut the default channel has nothing to resolve and
  dies saying exactly that, naming `RIG_REF=main` as the way to install
  today — it never falls back to main silently, because "I installed the
  latest release" must not quietly mean "I installed whatever main was that
  second". Step 5 of #32 — pinning `BOX_REF` in the host-installs-box path
  — stays open until box cuts its next tagged release.
