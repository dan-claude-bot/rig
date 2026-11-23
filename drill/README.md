# The drill — running it

`drill/drill.sh` is the instrument; `drills/` is the record it feeds
(see [drills/README.md](../drills/README.md) for what a record means and
how the three repos' drills relate). rig's drill asserts **convergence**:
a machine reaches its role, idempotently. This file is the procedure —
written down so a run is repeatable, not reconstructed from memory each
release (#105, and #107's debt).

## What you need

- **A throwaway Debian 13 machine** you can format, reached as root, with
  `curl`. A VM is fine; a container is not, because this drill converges an
  Incus host. One known-good substrate is a fresh box VM:

  ```sh
  box new --name drill-rig --vm --cpu 4 --memory 8GiB --disk 60GiB
  ```

  Do not use `staging-box`: it is a VM-only, autostarting server seed rather
  than a disposable scratch mint. The box the drill installs carries the
  nested-network subnet selection `box doctor` needs inside a box VM
  (box#80); `--box-ref` selects it. The drill hardens sshd, renames the
  machine, joins it to a tailnet, and installs box/Incus and Docker. The
  machine is its own reset; there is no teardown.
- **The candidate tree, on the machine.** The drill drills **the tree it
  ships in** (#220) — there is no flag naming one somewhere else, because
  separating the instrument from its subject only ever produced mismatch and
  a record that named what was *requested* rather than what ran. So the
  candidate arrives as one file you copy over, built from the checkout you
  want to drill:

  ```sh
  bash dist/release-artifact.sh --version 0.4.0-rc1 --assets-dir /tmp/a
  scp /tmp/a/rig-0.4.0-rc1.sh root@drill-host:
  ```

  No repository name, no ref, no clone, no credential on the drill host. A
  PR is drilled by checking that branch out and building the artifact from
  it; there is no PR-ref problem left to work around, because there is no ref.
  The drill refuses to start if it cannot find the rig tree it is part of —
  piped, process-substituted, or dropped somewhere as a lone copy, it has
  nothing to drill and says so rather than inventing a subject.
- **box's pinned ref.** `--box-ref` is required; the harness refuses to run
  without it and refuses to continue if the box that installed disagrees with
  the one asked for (`INSTALLED_FROM`). Since heavy-duty/rig#103 landed box's
  installer has a sane default when unpinned — the drilled tree's
  `BOX_RELEASE` pin — and a sane default is exactly why the drill will not let
  the ref go unstated: an unpinned run silently drills a shipping pair that is
  not the candidate, and the record it leaves looks clean.
- **A single-use, tagged tailscale pre-auth key** in `TS_AUTHKEY`
  (`tag:local` for the default `staging-server` role — bootstrap refuses
  `tag:server` outside the control-plane shapes). Mint it right before the
  drill, and **keep it off every command line**: a `TS_AUTHKEY=tskey-… cmd`
  prefix lands in shell history, and `--env`/argv forms show in the process
  list. Read it without echo (`read -rs TS_AUTHKEY; export TS_AUTHKEY`), or,
  on a host built with heavy-duty/infra's drill-host runbook, put it in a 0600
  file and set `DRILLHOST_TS_AUTHKEY_FILE`. That script hands it to the VM on
  stdin and removes it when the drill ends.
- **Exactly one operator source.** `--users-from-github <handle>` fetches
  `https://github.com/<handle>.keys` and writes one `admin,box` ledger line
  per public key; the handle must also be a valid lowercase rig username.
  Use `--users <path>` instead for multiple operators or different roles.
  Leg 1 asserts that at least one operator, account and key converged.
- **A run ID** (`--run-id`) when this drill shares a substrate with
  box's or cast's — the shared ID is what lets the per-repo records be
  joined afterwards. Defaults to `drill-<date>`.
- **A direct root entry path.** If the shell carries `SUDO_USER`, that user
  must be in `rig-admin`. In particular, `box shell` preserves a non-admin
  `SUDO_USER` and will be refused before the tailnet key is spent. Enter a
  box VM with `incus exec <box> -- bash -l`, or `unset SUDO_USER` in a root
  shell, before starting.

## Running it

Three lines. The first two are on your machine, in the checkout you want to
drill; the third is on the throwaway, as root.

```sh
bash dist/release-artifact.sh --version 0.4.0-rc1 --assets-dir /tmp/a
scp /tmp/a/rig-0.4.0-rc1.sh root@drill-host:

bash rig-0.4.0-rc1.sh
read -rs TS_AUTHKEY && export TS_AUTHKEY     # paste the key; nothing echoes
/root/.local/share/rig/current/drill/drill.sh \
  --box-ref 0.11.0 --users-from-github danmt --run-id drill-2026-08-26-a --yes
```

The artifact is one self-contained file: it verifies its own payload before
unpacking anything and installs offline, so the drill host needs no
repository name, no ref, no clone and no GitHub credential. `install.sh`
prints the install root it used and the version it landed — the drill lives
in that tree, at `<root>/current/drill/drill.sh`, and `<root>` is
`/root/.local/share/rig` unless `RIG_HOME` said otherwise.

**The drill installs the tree it is running out of.** It stages a copy
outside the install root before it wipes anything, so leg 1's from-scratch
reinstall never asks the installer to copy a directory onto itself or to read
a source that the wipe already took. Then it asserts what landed: the
provenance `install.sh` recorded, and the commit the artifact was built from.
An artifact built at commit `X` therefore drills the rig built from `X`, and
the drill says so itself rather than leaving it to be read off the log.

`--box-ref` is a tag on purpose: since #103 the box that ships is the
`BOX_RELEASE` tag, so a `release/…` branch is the wrong thing to pin for box.

It runs unattended from there. Legs execute as 1, 2. Before leg 2 the drill
installs Debian's Docker package directly, so a pristine machine supplies a
real daemon for the database round-trip. The record lists legs as they ran.
A failing check never aborts the
run (`set -u`, no `-e`: a failing check is data), and the summary counts
passes, failures and skips separately.

## What it asserts

1. **Convergence, and idempotence.** `rig bootstrap <role> --users …`
   reaches the declared role, asserted on *effective* state — the marker,
   `sshd -T`, the granted tailnet tag, the operators' accounts and keys.
   Then bootstrap runs **again**, and the state captured before and after
   the re-run must diff **empty**. The diff is mechanical; "watched it
   not obviously break" is exactly what this leg exists to replace.
   Riding along, the `--host yes` assertions: the **pinned** box
   installed (`INSTALLED_FROM` matches `--box-ref`, fatal if not),
   `box doctor` passes. It stops there and says so in the output — the
   isolation boundary is **box's** drill's assertion, never rig's.
2. **db** — `test/db-integration.sh` from the *installed* tree: a real
   dump/restore round-trip, after the drill installs Docker directly. The
   script's clean-skip contract (no Docker → loud skip, exit 0) remains the
   classifier's tiebreaker and survives into the record as a SKIP, never a
   pass, if Docker provisioning did not leave a daemon.

## What still reaches GitHub, and what no longer does

Stated rather than left to be discovered, because "the drill needs no
repository" is true of rig and not of everything the run touches.

**Gone, all of it rig's own side** (#220): no clone, no raw fetch of the
instrument, no archive download of the subject, and — since #219 packs the
registry into the artifact — no template-registry snapshot download either.
Nothing about getting *rig* onto the machine goes over the network.

**Still there, and neither is this repo's to remove here:**

- **box.** `--box-ref` stays and `rig bootstrap` still installs box at that
  ref over the network. box publishes its own artifact at `0.10.0`; teaching
  rig's converge to consume one is a separate question for a later window.
- **`--users-from-github <handle>`**, which fetches
  `https://github.com/<handle>.keys`. Unauthenticated, and avoidable — pass
  `--users <path>` with a ledger you copied over instead.
- **The ref resolution the record cites** for box and for rig-templates. It
  is `git ls-remote` against public GitHub, so it needs no credential — and
  on a throwaway with no `git` it simply fails, leaving the record's box SHA
  as `unresolved` rather than wrong. rig's own commit is not resolved this
  way any more: it is read off the installed tree's build stamp.

## Who runs it, and where the record goes

The builder runs the drill when they can reach a genuine fresh Debian host or
VM. If their environment cannot — including a builder session already inside
a box — the operator runs it instead. An operator pastes the complete final
stdout into a comment on the release issue. The builder copies that evidence
verbatim into `drills/<version>.md` on the release branch; the issue comment is
the attributed handoff, and the committed file is what the guard reads.

## The record

The run always ends by writing `/root/drills/<version>.md` (the version is
the installed tree's own `VERSION`), printing that path, and echoing the full
record to stdout. It is written to `/root` and not beside the instrument on
purpose: the `drills/` directory next to the drill is one the run is about to
delete and re-create, and evidence does not live inside the thing under test.
The record's rig fields are **measured, never argued** — the version, the
provenance and the build commit all come off the tree that landed, and a tree
no artifact built is recorded `(unstamped)` rather than given an invented
commit. That happens on failures too: **a failed drill is a valid
record**; the gate wants evidence, not success. Skipped legs are named as
not-run so the record can never read as a clean sweep. Commit the file as
`drills/<version>.md` on the release branch; the `drill-recorded` guard reads
that file and nothing else. `--record <path>` overrides the local output path.

The instrument's own honesty — the refusals, the skip accounting, the
capture-and-diff, the emitter — is `test/drill.sh`'s job, and CI runs it
on every PR. The live two-leg run is a release's job, once per cycle.
