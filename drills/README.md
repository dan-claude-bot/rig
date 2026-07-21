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

**This directory is the record, not the instrument.** rig has **no drill
harness script of its own**; its legs are run by following the documented
procedure, and the harness lives in heavy-duty/box's `drill/`. rig does not
reach into it to decide whether rig may ship: a cross-repo lookup that fails
silently degrades to "pass", which is the UNREADABLE-vs-NONE shape #90 fixed.
The gate reads a file in this repo, and nothing else.

## What the gate requires

`.github/scripts/drill-recorded.sh` runs on every PR. On a `-dev` tree it
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

## The drill

rig's legs:

- tenant guests minted and converged **via box**
- `bash test/db-integration.sh` against a real Postgres on the machine
- the GitHub runner lifecycle — register, take a job, deregister — against a
  fork
- a coolify install

box and rig are **mutually recursive**: `rig bootstrap --host yes` installs box
and runs box's `setup-host`, while box's guests converge back through rig's
installer. Within a single drill you naturally bring the substrate up before
probing it — a host before a guest — but that is how you run a drill, not an
ordering rule between repos.

**The three repos' drills are independent.** Run them in any order, on any
schedule, in separate sittings. What makes that safe is that every drill
**pins the same fixed set of candidate refs**: rig's drill runs `--host yes`
with `BOX_REF=release/<box-version>`, so it exercises the box that will
actually ship; box's drill mints with `RIG_REF=release/<rig-version>`, so it
exercises the rig that will actually ship. Both measure the same pair.

That — not sequencing — is what dissolves the box↔rig recursion. The refs are
static identifiers that exist as soon as the release branches do, long before
any drill runs, so a cycle at runtime becomes two independent tests against
one fixed pair. It also means **candidate refs, not released artifacts**:
`RIG_REPO`/`RIG_REF` are mint-time environment variables, so no repo has to be
released before another can be drilled. Drilling the candidate *is* drilling
the release, because a release PR's diff is `VERSION` + `CHANGELOG.md` and
nothing executable differs.

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

What ran, on what host, the pinned candidate refs, the numbers, and what
failed. Below is the *shape*, in a file named `drills/9.9.9.md` — a version
that can never collide with a real release. **No drill has been recorded here
yet**; this log starts empty rather than reconstructing runs from memory, since
an invented number is worse than no number.

```markdown
# Release drill — 9.9.9 — 2026-01-01

Run ID: drill-2026-01-01-a. Host: bare Debian 13 cloud image, 4 vCPU / 8 GB.
Candidate refs: box@1a2b3c4 (BOX_REF=release/0.4.0), rig@5d6e7f8, cast@9a0b1c2.

| Leg | Result |
| --- | --- |
| tenant guests minted + converged via box | 3/3 |
| re-converge (idempotence) | clean, no changes |
| `test/db-integration.sh` | 14/14 |
| runner lifecycle against a fork | PASS — registered, took a job, deregistered clean |
| coolify install | PASS, ~6 min |

Failed: `rig users apply` left one revoked key in `authorized_keys`
(filed #NNN). Everything else clean.
```

State what failed. A record with no failures listed reads as "nothing broke",
so if a leg was not run, say that instead of omitting it.
