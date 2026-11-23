# Drill records

Per-release evidence for rig's real-hardware drill. **One file per version**,
named for the version exactly as `VERSION` carries it:

    drills/<version>.md

So `0.3.0` is recorded in `drills/0.3.0.md`, and `0.3.0-rc1` in
`drills/0.3.0-rc1.md`. They are different files, which is the whole point: the
filesystem does the whole-version comparison that an earlier single-file
version of this had to do with an awk extractor and a heading grammar. A
record for the candidate cannot be mistaken for evidence for the final.

The directory is `drills/`, not `.drills/` — a dot-directory is invisible to
any glob without `dotglob`, which is how #70 here and box#116 / box#118 all
happened.

**This directory is the record, not the instrument.** The instrument is
[`drill/drill.sh`](../drill/README.md) (#105): it runs the legs, asserts that
what landed is the tree it ships in and the box that was pinned, decides
idempotence by a mechanical state diff, and emits the record file this
directory holds. rig does not reach into
another repo's harness to decide whether rig may ship: a cross-repo lookup
that fails silently degrades to "pass", which is the UNREADABLE-vs-NONE shape
#90 fixed. The gate reads a file in this repo, and nothing else.

## What the gate requires

The `drill-recorded` guard (heavy-duty/ceremony's action, pinned in
`ci.yml`) runs on every PR. On a `-dev` tree it
asserts nothing — a development tree has no release to evidence. On a bare
`VERSION` — a release ceremony tree — it requires `drills/<version>.md` to
exist and to hold at least one non-whitespace character. An empty file, or one
of only spaces and tabs, is not a record (box#149 and cast#138 both shipped an
extractor where a single tab satisfied the gate).

The guard requires a **record**, not a passing result. A maintainer waiver is
a legitimate outcome of a release — but it is written in that version's file,
so that skipping the drill is a deliberate, reviewable commit rather than a
silence. **A failed drill is still a valid record**: the gate wants evidence,
not success.

## The rc ladder

**A release candidate carries its own record, and the round can follow the
publish.** The gate requires a record, not a passing result. So
`drills/X.Y.Z-rcN.md` may be a **pending record**: it says what the candidate is,
what changed since the last drilled tree, and which legs are owed. It is
explicitly not a waiver. The round then runs after the merge, **against the
published `X.Y.Z-rcN` tag** (`git checkout X.Y.Z-rcN` before `drill/drill.sh`),
and its record is appended to the same file. This is the ladder heavy-duty/crew
runs (its `drills/README.md`, "The rc ladder"), adopted here.

- **The tag pins what a branch cannot.** The drilled tree is the tree that ships.
- **Downstream does not wait.** box and crew can pin the candidate while the
  round is pending.
- **The final cannot skip it.** `X.Y.Z` is promoted only after the candidate's
  record has its round appended. A pending rc record is never carried forward as
  evidence for the final.

## The drill

rig's legs (#105; `drill/drill.sh` runs them):

- `rig bootstrap <role>` converges the machine to its role — then runs
  **again**, and the captured state must diff **empty** (idempotence,
  decided mechanically). On a host=yes role this is also what installs the
  pinned box and asserts its host stack stands.
- `bash test/db-integration.sh` against a real Postgres on the machine, after
  the drill installs Debian's Docker package directly as a prerequisite

box and rig are **mutually recursive**: `rig bootstrap --host yes` installs box
and runs box's `setup-host`, while box's guests converge back through rig's
installer. Within a single drill you naturally bring the substrate up before
probing it — a host before a guest — but that is how you run a drill, not an
ordering rule between repos.

**The three repos' drills are independent.** Run them in any order, on any
schedule, in separate sittings. What makes that safe is that every drill
**fixes the same candidate pair** before it starts. rig's drill runs
`--host yes` with `BOX_REF=<box-version>` — the bare shipping tag, since #103
made the box that ships the `BOX_RELEASE` tag rather than a moving
`release/…` branch — so it exercises the box that will actually ship, and its
own half of the pair is not a ref at all any more but the tree the harness
ships in (#220). box's drill mints with `RIG_REF=release/<rig-version>`
against rig's own installer, so it exercises the rig that will actually ship.
Both measure the same pair. The record also cites the **rig-templates SHA**
the converge read (#110) — the drilled tree's `RIG_TEMPLATES_PIN` unless the
drill was pointed elsewhere via `RIG_TEMPLATES_REF` — so the
mechanism+registry pair a release freezes is the pair the drill proved.

**rig fixes its own half differently from box, and since #220 it does not use
a ref at all.** rig's drill drills the tree it ships in: the candidate is
built into a self-contained installer, copied to the machine and installed,
and the drill runs out of what landed. So rig's side of the pair is pinned by
*being* the tree rather than by naming one, which is strictly stronger — a
ref says what was requested, and the record now says what ran. box's side
still names a ref, because box is still installed over the network.

That — not sequencing — is what dissolves the box↔rig recursion. Neither
half's identity depends on the other having been released: box's ref is a
static identifier that exists as soon as its release branch does, and rig's
candidate is a file on the drill host. A cycle at runtime becomes two
independent tests against one fixed pair. It also means **candidates, not
released artifacts** — no repo has to be released before another can be
drilled. Drilling the candidate *is* drilling the release, because a release
PR's diff is `VERSION` + `CHANGELOG.md` and nothing executable differs.

Each repo drills in a **different way** and asserts a different thing: rig
asserts **convergence** (a machine reaches its role, idempotently), box asserts
the **isolation contract** (the VM trust boundary), cast asserts **promotion**
(A→B reproduces, the diff is idempotent). Three different exercises sharing a
substrate, not three phases of one script — which is exactly why the records
are per-repo.

Drills that share a substrate share **one run ID**; each repo records its own
legs in its own file, citing that run ID and the other repos' commit SHAs, so
the records can be joined after the fact. If a defect shows up only in the
combination: patch, re-drill, re-record. The three releases converge on a set
that holds together; they are not required to be right in one pass. Releases
do **not** have to be published in a fixed order.

## What a record should contain

What ran, on what host, which rig and which box, the numbers, and what
failed. The rig line is **measured, never argued** (#220): its version, the
commit its installer artifact was built from — `-dirty`-stamped when that
build's work tree was — and the provenance `install.sh` recorded, all read off
the tree that landed rather than echoed back from an argument. A record that
cannot be reproduced says so on its face: a tree no artifact built is
`(unstamped)`, never given a commit it does not have.

Below is the *shape*, in a file named `drills/9.9.9.md` — a version
that can never collide with a real release. **No drill has been recorded here
yet**; this log starts empty rather than reconstructing runs from memory, since
an invented number is worse than no number.

```markdown
# Release drill — 9.9.9 — 2026-01-01

Run ID: drill-2026-01-01-a. Host: bare Debian 13 cloud image, 4 vCPU / 8 GB.
Rig under drill: 9.9.9, built from 5d6e7f8… — artifact:rig-9.9.9.sh sha256:….
Candidate box: box@1a2b3c4 (BOX_REF=0.4.0).

| Leg | Result |
| --- | --- |
| convergence — bootstrap staging-server reaches its role | PASS (312s) |
| re-converge (idempotence) | clean, no changes |
| --host yes: pinned box installed, host stack up | PASS — box doctor clean |
| `test/db-integration.sh` | PASS — 14 passed, 0 failed |

Failed: `rig users apply` left one revoked key in `authorized_keys`
(filed #NNN). Everything else clean.
```

State what failed. A record with no failures listed reads as "nothing broke",
so if a leg was not run, say that instead of omitting it.
