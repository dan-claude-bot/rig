# Contributing

How change lands in this repo. The short version: PRs are born as drafts,
three reviewer bots take the first rounds, a human takes the last word — and
labels tell you where everything is without opening anything.

## The PR loop

1. **Fork and branch.** Contributors work from forks; upstream branches are
   for maintainers. Title the PR conventionally (`feat:`, `fix:`, `docs:`).
2. **Open as a draft** while you build. Drafts are invisible to the reviewer
   bots on purpose.
3. **When it's ready**: mark ready-for-review and request all three bots —
   `claude-bot-andresmgsl`, `codex-bot-andresmgsl`, `grok-bot-andresmgsl`.
   They poll roughly every 15 minutes.
4. **Rounds are answered whole.** Wait until all three have reviewed, then
   answer the entire round in a **single reply**, push the fixes, and
   re-request the bots that didn't approve. Prefer verification over
   argument: a test settles what a comment thread can't.
5. **Reviews end in a verdict.** A reviewer — bot or human — either
   **approves** or **requests changes**, never a bare comment. A
   comment-only review is a non-verdict: it doesn't say whether the round
   passed, and the state machine (and anyone scanning the board) has to
   guess. The verdict carries *blockingness only*, the body carries the
   feedback: non-blocking nits ride an **approval** and the author addresses
   them at their discretion; anything blocking — including a question that
   gates the verdict — is **request changes**, saying what unblocks it. The
   reconciler treats a comment-only review as not-approved, so commenting
   without a verdict only stalls the PR. The machine never reads review
   bodies: when a comment-only reviewer's line is really an agreement, that
   judgment belongs to the **author** — escalate by requesting the
   maintainer's review (step 6), and the reconciler flips the label on that
   request, because an explicit request is a fact it can trust.
6. **When the round passes, the author hands the PR to the maintainer** in
   three acts, in this order: post the tagged round summary, request the
   maintainer's review, then set `state:needs-human` yourself — removing the
   state label it replaces. The review request is what *earns* the label,
   provided the PR carries **no `blocker:*` label**. A blocker means the work
   is still yours whatever the round said, so on a conflicted or red PR
   neither the request nor your own label write will stick — the sweep takes
   it straight back off. With three formal head-current approvals the labels
   workflow requests the maintainer automatically; when part of the panel is
   comment-only, reading their agreement is the author's judgment, so the
   author makes the request.

   Writing the label by hand is an **optimistic write, not a transfer of
   ownership**. The machine stays the authority — but because the workflow
   wakes on `labeled`, the author's own write fires the sweep that validates
   it, and a handoff that had not earned the label is corrected seconds later.
   Forgetting the write is not a failure either; it only means the label waits
   for the cron, which is the lag this replaced.
7. **Checks must be green**: `shellcheck`, `bash test/cli.sh` and
   `bash test/release.sh` locally mirror what CI runs; the db dump/restore
   round-trip (`test/db-integration.sh`) executes in CI where Docker is
   present.
8. **Feature PRs land their changelog entry as part of the PR** (box's
   convention): add it under `CHANGELOG.md`'s `## Unreleased` heading —
   that section becomes the release notes verbatim when a release is cut.

## Changelog entries

Every PR that changes behaviour adds one line to `## Unreleased`. One line is
the whole rule — if it wraps more than twice in your editor, cut it down.

- **Say what changed, and stop.** Why it was wrong, how it was found, what it
  cost, what it implies — that belongs in the PR body and the commit message,
  which is where anyone chasing the reasoning already goes. This file answers
  one question: what is different in this version.
- **Any word that can be removed, is removed.**
- **Lead with the surface, not the mechanism.** "`state:needs-human` is set at
  handoff" beats "the labels workflow now also wakes on `labeled`".
- **Cite the issue or PR** — `(#96)` — and let the reader follow it for the
  rest.
- **Mark a breaking change** with a leading `BREAKING:`.
- Group under `### Added` / `### Changed` / `### Fixed` / `### Removed`.
- No bold run-in headings, no sub-paragraphs, no code blocks, no prose essays.

Good:

- `state:needs-human` is set at handoff, not by the cron (#96)
- An unreadable check rollup no longer reads as "nothing is failing" (#90)
- BREAKING: `--class human|server` is now `--root-door closed|open` (#77)

Not an entry — that is a PR body:

- **`state:needs-human` no longer waits on the cron to become true** (#96) —
  the labels workflow now also wakes on `pull_request_target: labeled` and
  `unlabeled`, and the author sets it themselves when handing a PR over. A
  review landing was never a trigger. There is no `pull_request_review_target`,
  and on fork PRs — which is all of them here — ...

## Releasing

A release is a PR, and merging it is the release (#47; box#96's design, on
top of #32/box#83's tag flow). It takes the ordinary PR loop above, with one
extra gate before the handoff:

**draft → ready → bot round → drill → `state:needs-human` → maintainer merge
(which IS the release).**

The **drill** is a real-hardware run — tenant guests minted and converged via
box, `test/db-integration.sh`, the GitHub runner lifecycle against a fork, a
coolify install — recorded in **one file per version**:

```
drills/<version>.md
```

named for the version exactly as `VERSION` carries it. See
[`drills/README.md`](drills/README.md) for what a record should contain.

`.github/scripts/drill-recorded.sh` enforces it on every release: a bare
`VERSION` with no non-empty `drills/<version>.md` turns CI red, naming the
version. It is **not a thing a reviewer has to remember** — that is how every
release in this family shipped undrilled until a bot finally blocked on one. On
a `-dev` tree it asserts nothing, so it is invisible to ordinary PRs. rig reads
rig's own record and never box's repo: a cross-repo lookup fails on a token,
a fork checkout or a network blip, and all of those degrade to "pass" —
the UNREADABLE-vs-NONE shape #90 fixed.

One file per version is what keeps the guard small. Records used to share a
single log, which forced a heading grammar, an optional-date tail, a
whole-version comparison and a non-blank-body rule just to read them back — and
both sibling repos shipped a defect out of that complexity in review. Now
`0.3.0.md` and `0.3.0-rc1.md` are simply different files.

**The three repos' drills are INDEPENDENT.** Run them in any order, on any
schedule, in separate sittings. What makes that safe is that every drill **pins
the same fixed set of candidate refs**: rig's drill runs `--host yes` with
`BOX_REF=release/<box-version>`, so it exercises the box that will actually
ship; box's drill mints with `RIG_REF=release/<rig-version>`, so it exercises
the rig that will actually ship. Both measure the same pair.

That — not sequencing — is what dissolves the box↔rig recursion. box and rig
are mutually recursive (`rig bootstrap … --host yes` installs box and runs
box's `setup-host`; box's `box new` seeds converge back through rig's installer
at `@RIG_REPO@/@RIG_REF@`), but the refs are static identifiers that exist as
soon as the release branches do, long before any drill runs, so a cycle at
runtime becomes independent tests against one fixed pair. Within a single drill
you naturally bring the substrate up before probing it — a host before a guest
— but that is how you run a drill, not an ordering rule between repos.

Each repo drills in a **different way** and asserts a different thing: rig
asserts **convergence** (a machine reaches its role, idempotently), box asserts
the **isolation contract** (the VM trust boundary), cast asserts **promotion**
(A→B reproduces, the diff is idempotent). Three different exercises sharing a
substrate, not three phases of one script — which is exactly why the records
are per-repo.

It drills **candidate refs, not released artifacts.** `RIG_REPO`/`RIG_REF` are
mint-time environment variables (default `heavy-duty/rig@main`), so a run pins
the exact commits under test. That is what dissolves the chicken-and-egg: no
repo has to be released before another can be drilled.

**Drilling the candidate IS drilling the release.** A release PR's diff is
`VERSION` + `CHANGELOG.md` and nothing else — no executable difference exists
between the tree that was drilled and the tree that ships.

Drills that share a substrate share **one run ID**. Each repo records *its own*
legs in its own `drills/<version>.md`, citing that run ID and the other two
repos' commit SHAs, so the records can be joined after the fact by anyone
reading them. The guard still reads only this repo's file — there is no
cross-repo lookup anywhere in the gate. Releases do **not** have to be
published in a fixed order. If a defect shows up only in the combination:
patch, re-drill, re-record. The three releases converge on a set that holds
together; they are not required to be right in one pass.

A **maintainer waiver** is possible — a doc-only release, a hardware outage —
but it must be **recorded in `drills/<version>.md` for that version**, saying
who waived it and why. The guard asks for a *record*, not a passing result,
precisely so that skipping is a deliberate, reviewable commit instead of a
silence. Deleting the check is not the move.

The mechanics:

1. A small PR — `release: X.Y.Z`, carrying the `release` label — bumps
   `VERSION` from `X.Y.Z-dev` and stamps `CHANGELOG.md`'s Unreleased
   section as `## X.Y.Z — YYYY-MM-DD`. **Then re-arm the file in the same
   PR**: add a fresh, empty `## Unreleased` immediately above the section
   you just stamped (#66). Stamping alone *disarms* main — a PR authored
   before the release and merged after it wrote its entry under
   `## Unreleased`, and with that heading gone git files the entry under
   whatever now occupies the position, which is the release that already
   shipped. It lands cleanly, with no conflict and nothing for the author
   to notice, so the empty section is the only thing standing between a
   late merge and a changelog that misattributes a shipped release. No
   workflow does this for you: `release.yml` re-arms `VERSION`, never the
   changelog. `test/release.sh` enforces the pairing — whenever `VERSION`
   ends in `-dev` the top section must be `## Unreleased`. CI green on it,
   same loop as any PR.
2. Merge it — that IS the ship decision. `release.yml`'s
   `release-on-merge` job asserts, in order, fail-loud, creating nothing:
   the merged tree's `VERSION` is non-`-dev`; this PR is the one that
   changed it (a mislabeled ordinary PR fails here); the changelog section
   for that version extracts non-empty; no tag or release exists yet.
   Then, same job, it tags the merge commit bare `X.Y.Z` (no `v` prefix —
   box's tag scheme) and publishes the GitHub release with that section as
   the body. No assets — the source tarball for the tag is the package
   `install.sh` downloads.
3. The release re-arms main itself: the same workflow run bumps `VERSION`
   to `X.Y.(Z+1)-dev` and pushes the commit straight to main — no
   follow-up PR (it opens one only if branch protection refuses the
   direct push, loudly). A dev install therefore never impersonates the
   release in the `versions/<v>` layout. On the *manual* tag path the
   bump stays yours: open the one-line PR after publishing.

Manual fallback (and backfill): if the merge-path run fails, fix what it
named, then tag the merge commit `X.Y.Z` by hand and push the tag — the
original tag-push job still turns any correct tag into the release, and
the merge path's nothing-exists-yet assert keeps the two from
double-publishing.

## Labels — who sets what

The full taxonomy lives in [LABELS.md](LABELS.md). What matters day to day is
who sets each kind — most of it is machinery, and hand-moving a
machine-owned label just gets corrected on the next pass:

| Labels | Set by |
|---|---|
| `state:*` | the labels workflow ([.github/workflows/labels.yml](.github/workflows/labels.yml)) — recomputed from GitHub's own facts on PR events (label changes included) and every 15 minutes. Machine-owned, with one exception: the author sets `state:needs-human` at handoff (step 6) and the workflow reconciles it. Otherwise never by hand. Exactly one per PR: *whose ball is it.* |
| `blocker:*` | the same workflow, from the same facts — *what is in the way.* Any number per PR, or none. Never by hand: applying one does not stop a merge, and removing one does not unblock anything. Fix the thing and the next sweep drops the label. |
| `stale` | the same workflow — 48h without commits, comments, or reviews. `blocked` PRs are exempt: they are quiet legitimately. |
| `scope:*` on PRs | actions/labeler, from the changed paths ([.github/labeler.yml](.github/labeler.yml)). Additive — you may add more, the machine won't remove them. |
| `scope:*` on issues | you, when opening or triaging — issues have no paths to derive from. |
| `blocked`, `release` | you — automation never guesses intent. |
| `merge-next` | you or the agent owning the queue. Which PR lands first is a judgement about how they conflict, so the workflow never sets it — it only **clears** it, the moment the PR stops being something a human could merge. |
| `bug` / `enhancement` / `documentation` | you, on issues only — a PR's type already lives in its title. |

## Issues

Give issues the same care as PR titles: say the surface in the title, apply a
`scope:` label and a type label (`bug` / `enhancement` / `documentation`) when
you open one, and `blocked` when it waits on something — that is what keeps
the board navigable as the issue count grows.
