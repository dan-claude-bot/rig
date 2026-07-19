# Changelog

History before 0.1.0 lives in git — rig grew its version surface (`VERSION`,
`rig --version`, the side-by-side `versions/<v>` install layout; #35/#36)
on the way to cutting its first release, and this file starts there.

## Unreleased

### Fixed

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
