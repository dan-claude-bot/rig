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

## Releasing

A release is a PR, and merging it is the release (#47; box#96's design, on
top of #32/box#83's tag flow):

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
