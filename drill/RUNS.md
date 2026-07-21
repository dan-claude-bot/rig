# Drill run log

rig's own record of its real-hardware drill legs. One section per run,
appended. **This file is the record, not the instrument.**

rig has **no drill harness script of its own yet**. Its legs are run by hand,
following the documented procedure:

- tenant guests minted and converged **via box**
- `bash test/db-integration.sh` against a real Postgres on the machine
- the GitHub runner lifecycle — register, take a job, deregister — against a
  fork
- a coolify install

The harness lives in heavy-duty/box's `drill/`. rig does **not** reach into it
to decide whether rig may ship. A cross-repo lookup that fails silently
degrades to "pass", which is the UNREADABLE-vs-NONE shape #90 fixed — so the
gate reads this file, in this repo, and nothing else.

The drill itself is **one orchestrated run over the whole stack** —
`rig bootstrap --host yes` on a bare host (which installs box and runs box's
`setup-host`), then `box new` for a creds-free seed, then that seed converging
via `rig bootstrap <tenant>-box`, then cast on top. box and rig are mutually
recursive, so there is no order to drill them in: rig is both the host-builder
below box and the guest-converger above it.

It drills **candidate refs, not released artifacts**: `RIG_REPO`/`RIG_REF` are
mint-time environment variables, so a run pins the exact commits under test.
Drilling the candidate *is* drilling the release, because a release PR's diff
is `VERSION` + `CHANGELOG.md` and nothing executable differs. One run emits one
shared **run ID**; each repo records its own legs under its own heading, citing
that run ID and the other two repos' commit SHAs (CONTRIBUTING, "Releasing").

## What the gate requires

`.github/scripts/drill-recorded.sh` runs on every PR. On a `-dev` tree it
asserts nothing — a development tree has no release to evidence. On a bare
`VERSION` — a release ceremony tree — it requires a section here headed
exactly:

    ## Release drill — X.Y.Z — YYYY-MM-DD

The trailing ` — DATE` is optional; the version is matched **whole**, so a
`0.3.0-rc1` record does not satisfy `0.3.0` and the reverse is equally false.
The section must extract non-empty: at least one non-blank line before the
next `## `.

The guard requires a **record**, not a passing result. A maintainer waiver is
a legitimate outcome of a release — but it is written here, under that
version's heading, so that skipping the drill is a deliberate, reviewable
commit rather than a silence.

### What a record should contain

What ran, on what, the numbers, and what failed. Below is the *shape*, not a
run that happened — no drill has been recorded here yet:

    ## Release drill — 9.9.9 — 2026-01-01

    Run ID: drill-2026-01-01-a. Host: bare Debian 13 cloud image, 4 vCPU / 8 GB.
    Candidate refs: box@1a2b3c4, rig@5d6e7f8, cast@9a0b1c2.

    | Leg | Result |
    | --- | --- |
    | tenant guests minted + converged via box | 3/3 |
    | `test/db-integration.sh` | 14/14 |
    | runner lifecycle against a fork | PASS — registered, took a job, deregistered clean |
    | coolify install | PASS, ~6 min |

    Failed: `rig users apply` left one revoked key in `authorized_keys`
    (filed #NNN). Everything else clean.

State what failed. A record with no failures listed reads as "nothing broke",
so if a leg was not run, say that instead of omitting it.

## Runs

*None recorded yet.* This log starts empty rather than reconstructing runs
from memory — an invented number is worse than no number. The first release
cut under the gate writes the first section here.
