#!/usr/bin/env bash
# The release flow's testable half (#32): changelog extraction, latest-tag
# resolution, and the installer's three channels. Dependency-free and
# NETWORK-FREE — wherever the code under test would call curl, the curl on
# PATH is a stub this harness wrote. Run: bash test/release.sh
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
# The extraction the workflow runs is the extraction under test — one
# function, sourced by release.yml and by this harness (repo precedent:
# test/labels-reconcile.sh sourcing the reconciler's decide_state).
# shellcheck source=.github/scripts/release-lib.sh
. "$ROOT/.github/scripts/release-lib.sh"
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
# Runs cmd, asserts exit code and (if non-empty) that combined output
# contains want_substr.
check() {
  local desc="$1" want="$2" substr="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -e "$substr"; then
    echo "FAIL: $desc — output missing '$substr'"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $desc"; PASS=$((PASS + 1))
}

WORK="$(mktemp -d)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"

# --- changelog_section: the release body, extracted --------------------------
# A fixture changelog with the three heading shapes the flow produces: the
# bare '## Unreleased', stamped '## X.Y.Z — date' releases, and a last
# section that runs to EOF.
FIXCH="$WORK/CHANGELOG.fixture.md"
cat > "$FIXCH" <<'MD'
# Changelog

History before 0.1.0 lives in git.

## Unreleased

- an unreleased entry

## 0.2.0 — 2026-07-18

### Added

- **the newer entry** (#42) — prose.

### Fixed

- a fix in 0.2.0

## 0.1.0 — 2026-07-01

- the first entry
MD
sect_has() { changelog_section "$1" "$2" | grep -qF -e "$3"; }
check "changelog: extracts the asked-for section" 0 "the newer entry" \
  changelog_section "$FIXCH" 0.2.0
check "changelog: the whole section, subheadings included" 0 "a fix in 0.2.0" \
  changelog_section "$FIXCH" 0.2.0
check "changelog: stops at the next release heading" 1 "" \
  sect_has "$FIXCH" 0.2.0 "the first entry"
check "changelog: never leaks the preceding section" 1 "" \
  sect_has "$FIXCH" 0.2.0 "an unreleased entry"
check "changelog: the heading itself is not the body" 1 "" \
  sect_has "$FIXCH" 0.2.0 "## 0.2.0"
first_line() { changelog_section "$1" "$2" | head -n1; }
check "changelog: leading blank lines are dropped" 0 "### Added" \
  first_line "$FIXCH" 0.2.0
check "changelog: the bare Unreleased heading matches too" 0 "an unreleased entry" \
  changelog_section "$FIXCH" Unreleased
check "changelog: the last section runs to EOF" 0 "the first entry" \
  changelog_section "$FIXCH" 0.1.0
absent() { [ -z "$(changelog_section "$1" "$2")" ]; }
check "changelog: an unknown version yields NOTHING (the refusal signal)" 0 "" \
  absent "$FIXCH" 3.3.3
check "changelog: a date-stamped heading never matches by date" 0 "" \
  absent "$FIXCH" 2026-07-18

# ...and the SHIPPED changelog fits the extractor. The real file has two
# legitimate states, and the old check knew only one (#44, found the day the
# first release PR turned CI red): BETWEEN releases there is an `## Unreleased`
# section feature PRs append to; on a `release: X.Y.Z` tree — and on main
# right after it, until the next feature PR — that section IS the stamped
# `## X.Y.Z — date`. Demanding the literal heading (or, worse, an issue
# number inside it) made the release PR of the ceremony unshippable by
# construction. What the guard is FOR is format drift: whatever the top
# section is called, the exact function release.yml runs must extract it
# non-empty.
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "CHANGELOG.md: has a top section (Unreleased or a stamped release)" 0 "" \
  bash -c '[ -n "$(grep -m1 "^## " "$1")" ]' _ "$ROOT/CHANGELOG.md"

# --- the arming rule: is main's changelog ready for a late merge? ------------
# #66: stamping the Unreleased heading DISARMS the file. A PR authored before
# a release and merged after it wrote its entry under `## Unreleased`; once
# that heading has become `## X.Y.Z — date`, git lands the entry under the
# release that already shipped — cleanly, no conflict, nothing for the author
# to notice. It happened here: #60's #58 entry landed inside `## 0.1.0` at
# 67386b4, repaired two minutes later by 0ff520c.
#
# The check above cannot see this, and #44 is why: demanding a literal
# `## Unreleased` is FALSE BY CONSTRUCTION on the tree the ceremony's own PR
# produces, which made the release PR unshippable. That relaxation must not
# be undone.
#
# What distinguishes the two states the old guard collapsed is VERSION.
# A stamped top section is legal exactly when VERSION is bare — the ceremony
# PR, and main until the -dev bump lands. The moment VERSION carries -dev,
# main is a place feature PRs merge into, and the top section MUST be
# `## Unreleased` or the next late merge is misfiled.
#
# Note the asymmetry, which is deliberate: on a BARE version the top heading
# is not constrained at all. The ceremony re-arms in the same PR
# (CONTRIBUTING step 1), so its tree legitimately carries an EMPTY
# `## Unreleased` above the section it just stamped — and an empty top
# section is exactly what the old non-empty assert would have rejected.
# What must extract non-empty on a bare VERSION is the section that SHIPS,
# which is the same assert release.yml makes before it publishes.
#
# changelog_armed <version> <changelog-file> — 0 armed, 1 disarmed.
changelog_armed() {
  local ver="$1" file="$2" top
  top="$(grep -m1 '^## ' "$file")"
  [ -n "$top" ] || return 1
  case "$ver" in
    *-dev) [ "$top" = "## Unreleased" ] ;;
    *)     [ -n "$(changelog_section "$file" "$ver")" ] ;;
  esac
}

# The guard itself, against the real tree.
check "CHANGELOG.md: armed for the VERSION it carries (#66)" 0 "" \
  changelog_armed "$(cat "$ROOT/VERSION")" "$ROOT/CHANGELOG.md"

# ...and the rule proven against trees built for the purpose, because a guard
# that is only ever run against a passing tree has not been shown to fail.
# Each is a real VERSION + CHANGELOG.md pair the flow actually produces.
armtree() { # armtree <name> <version> <changelog-body...>  -> prints the dir
  local d="$WORK/arm-$1"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/VERSION"
  shift 2; printf '%s\n' "$@" > "$d/CHANGELOG.md"; printf '%s' "$d"
}
armed() { changelog_armed "$(cat "$1/VERSION")" "$1/CHANGELOG.md"; }

# The ceremony PR's own tree, re-armed per CONTRIBUTING step 1: VERSION bare,
# an empty Unreleased sitting above the section it just stamped. GREEN — this
# is the case #44 was about, and the empty section must not break it.
T="$(armtree ceremony 0.2.0 '# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' '- **A shipped thing** (#1) — prose.')"
check "arming: the re-armed ceremony tree passes (#44 stays fixed)" 0 "" armed "$T"

# The same ceremony WITHOUT the re-arm — old-style, stamped straight over the
# heading. Also GREEN: VERSION is bare, so a stamped top is legal. The guard
# refuses to make the ceremony unshippable, which is the whole #44 lesson.
T="$(armtree ceremony-old 0.2.0 '# Changelog' '' '## 0.2.0 — 2026-07-19' '' '- **A shipped thing** (#1) — prose.')"
check "arming: an un-re-armed ceremony tree still passes (bare VERSION)" 0 "" armed "$T"

# main AFTER release.yml's -dev bump, with the changelog left disarmed. This
# is #66 exactly, and the state cast sat in at the time of writing. RED.
T="$(armtree disarmed 0.2.1-dev '# Changelog' '' '## 0.2.0 — 2026-07-19' '' '- **A shipped thing** (#1) — prose.')"
check "arming: a -dev main with a stamped top section FAILS (#66)" 1 "" armed "$T"

# The same main, re-armed. The Unreleased section is EMPTY — no feature PR has
# merged since the release — and that is a correct, expected state. GREEN.
T="$(armtree rearmed 0.2.1-dev '# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' '- **A shipped thing** (#1) — prose.')"
check "arming: a -dev main with an EMPTY Unreleased passes (no entries yet)" 0 "" armed "$T"

# Steady state between releases: entries accumulating under Unreleased.
T="$(armtree steady 0.2.1-dev '# Changelog' '' '## Unreleased' '' '### Fixed' '' '- **A pending thing** (#2) — prose.' '' '## 0.2.0 — 2026-07-19' '' '- **A shipped thing** (#1) — prose.')"
check "arming: the normal between-releases tree passes" 0 "" armed "$T"

# A release PR that bumped VERSION but forgot to stamp: the version it claims
# to ship has no section, so release.yml would publish empty notes. RED here,
# one round earlier than the workflow's own refusal.
T="$(armtree unstamped 0.3.0 '# Changelog' '' '## Unreleased' '' '- **A pending thing** (#2) — prose.')"
check "arming: a bare VERSION whose section was never stamped FAILS" 1 "" armed "$T"

# And a file with no '## ' heading at all is disarmed, not silently fine.
T="$(armtree headless 0.2.1-dev '# Changelog' '' 'no sections here')"
check "arming: a changelog with no sections FAILS" 1 "" armed "$T"

# --- the monotonicity rule: was a SHIPPED heading deleted? -------------------
# #98. Arming asks about ONE heading — does the top section agree with
# VERSION? — so it is silent about the rest of the file. The failure it cannot
# see is an entry written under '## Unreleased' that REPLACES the heading
# below it instead of inserting above it: git merges the one-line edit
# cleanly, arming stays green (the top section is still right), and the
# shipped release loses its section entirely. "A heading disappeared" is not a
# property of a tree, it is a property of a DIFF — so unlike every check
# above, these cases need real git repos, which is why the guard is its own
# script rather than a function sourced here.
MONO="$ROOT/.github/scripts/changelog-monotonic.sh"
check "changelog-monotonic.sh: exists and is the guard under test" 0 "" test -f "$MONO"

# The stock changelog every case below starts from: an Unreleased section and
# two shipped releases, committed on branch 'base' — which plays origin/main.
# The caller then rewrites CHANGELOG.md on 'work' and commits.
MONO_BASE=('# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.' '' '## 0.1.0 — 2026-07-01' '' \
  '- **The first thing** (#0) — prose.')
monorepo() { # monorepo <name> -> prints the dir, left checked out on 'work'
  local d="$WORK/mono-$1"; mkdir -p "$d"
  git -C "$d" init -q -b base
  git -C "$d" config user.email harness@example.invalid
  git -C "$d" config user.name harness
  printf '%s\n' "${MONO_BASE[@]}" > "$d/CHANGELOG.md"
  git -C "$d" add CHANGELOG.md
  git -C "$d" commit -qm 'base: two shipped releases'
  git -C "$d" checkout -q -b work
  printf '%s' "$d"
}
monowrite() { # monowrite <dir> <line...> — rewrite CHANGELOG.md and commit
  local d="$1"; shift
  printf '%s\n' "$@" > "$d/CHANGELOG.md"
  git -C "$d" commit -qam 'work: edit the changelog'
}
mono() { # mono <dir> [VAR=val ...] — run the guard there, base ref 'base'
  local d="$1"; shift
  ( cd "$d" && env "$@" bash "$MONO" base 2>&1 )
}

# An untouched branch with NO commit of its own: 'work' still points at the
# base commit, so the merge base IS HEAD and containment compared the file
# against itself. That is the vacuous path (#98), not a containment result —
# the green message therefore names uniqueness, the half that actually ran.
# A guard that prints nothing is indistinguishable from one that did nothing,
# but a guard that prints the WRONG half is worse: it is a false receipt.
T="$(monorepo clean)"
check "monotonic: an untouched branch passes" 0 "uniqueness on HEAD checked 2" mono "$T"
check "monotonic: ...saying containment was VACUOUS, not that it verified 2" 0 \
  "containment vacuous" mono "$T"
# A negative, because the point is that the two wordings do NOT collapse: with
# the pull_request gate gone (#98) this is the shape of EVERY push to main, and
# "are still present" there would be a containment claim on the one event where
# deletion is undetectable by construction.
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "monotonic: ...and never claims the headings are still present" 1 "" \
  bash -c 'cd "$1" && bash "$2" base | grep -q "are still present"' _ "$T" "$MONO"

# The same shape against a REAL base — an unrelated commit on 'work', the
# changelog untouched — which is what an untouched-changelog PR branch
# actually looks like. Here containment genuinely ran and held, so this is
# the case that pins the containment wording and its count. The two forms
# must not collapse into one another.
T="$(monorepo clean-realbase)"
printf '%s\n' '# rig' > "$T/README.md"
git -C "$T" add README.md
git -C "$T" commit -qm 'work: an unrelated commit, changelog untouched'
check "monotonic: an untouched changelog on a REAL base reports containment" 0 \
  "all 2 release heading(s)" mono "$T"
check "monotonic: ...and says they are still present, the containment claim" 0 \
  "are still present" mono "$T"

# The legitimate edit this guard must never object to: a new entry INSERTED
# above the shipped heading, which is left alone.
T="$(monorepo insert)"
monowrite "$T" '# Changelog' '' '## Unreleased' '' '### Fixed' '' \
  '- **A pending thing** (#2) — prose.' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.' '' '## 0.1.0 — 2026-07-01' '' \
  '- **The first thing** (#0) — prose.'
check "monotonic: an entry inserted ABOVE the shipped heading passes" 0 "" mono "$T"

# ...and the bug itself: the same entry typed OVER '## 0.2.0'. 0.2.0's body is
# now under '## Unreleased' and 0.2.0 has no section. RED, naming the version.
T="$(monorepo deleted)"
monowrite "$T" '# Changelog' '' '## Unreleased' '' '### Fixed' '' \
  '- **A pending thing** (#2) — prose.' '' \
  '- **A shipped thing** (#1) — prose.' '' '## 0.1.0 — 2026-07-01' '' \
  '- **The first thing** (#0) — prose.'
check "monotonic: a DELETED shipped heading FAILS (#98)" 1 "DELETES release heading" mono "$T"
check "monotonic: ...and the failure names the version that vanished" 1 "## 0.2.0" mono "$T"

# Deleting the OLDEST release is the same defect, not a lesser one — the set
# is a set, position in the file buys no leniency.
T="$(monorepo deleted-old)"
monowrite "$T" '# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.'
check "monotonic: deleting an OLDER release heading fails too" 1 "## 0.1.0" mono "$T"

# The duplicate half. Containment cannot catch this: the second copy is
# head-side SURPLUS and `comm -23` (base minus head) is blind to extras on the
# head side, so uniqueness-on-HEAD is a separate assert. rig's symptom is not
# box's — changelog_section() has `if (found) exit`, so it stops at the second
# copy and TRUNCATES rather than absorbing.
T="$(monorepo dupe)"
monowrite "$T" '# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A pending thing** (#2) — prose.' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.' '' '## 0.1.0 — 2026-07-01' '' \
  '- **The first thing** (#0) — prose.'
check "monotonic: a DUPLICATED version heading FAILS" 1 "DUPLICATE release heading" mono "$T"
check "monotonic: ...and the failure names the repeated version" 1 "## 0.2.0" mono "$T"
# ...and that the duplicate really does truncate, so the assert above is
# guarding a live defect rather than a stylistic preference: extraction stops
# at the second copy, dropping the body that sits under it.
check "monotonic: the duplicate TRUNCATES extraction (rig's symptom, not box's)" 0 \
  "A pending thing" changelog_section "$T/CHANGELOG.md" 0.2.0
check "monotonic: ...the real body under the second copy is dropped" 1 "" \
  sect_has "$T/CHANGELOG.md" 0.2.0 "A shipped thing"

# '## Unreleased' is deliberately OUTSIDE the guarded set: it fails the
# version shape, so the ceremony stamping it away — the one edit that legally
# removes a top heading — is invisible here. This is the case that would make
# every release PR unshippable if the set were "all '## ' headings".
T="$(monorepo stamp)"
monowrite "$T" '# Changelog' '' '## 0.3.0 — 2026-07-20' '' \
  '- **A pending thing** (#2) — prose.' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.' '' '## 0.1.0 — 2026-07-01' '' \
  '- **The first thing** (#0) — prose.'
check "monotonic: stamping '## Unreleased' into a release passes (not guarded)" 0 "" mono "$T"
# ...and the ceremony's re-arm — a fresh empty Unreleased above the stamp —
# is equally fine, which is CONTRIBUTING step 1's tree.
T="$(monorepo stamp-rearmed)"
monowrite "$T" '# Changelog' '' '## Unreleased' '' '## 0.3.0 — 2026-07-20' '' \
  '- **A pending thing** (#2) — prose.' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.' '' '## 0.1.0 — 2026-07-01' '' \
  '- **The first thing** (#0) — prose.'
check "monotonic: the re-armed ceremony tree passes too" 0 "" mono "$T"

# The skip path, both halves. A base ref that does not resolve is a sensible
# local degradation — and a silent one, which is the failure shape this family
# of checks exists to refuse. So STRICT flips exactly that case red.
mono_noref() { local d="$1"; shift; ( cd "$d" && env "$@" bash "$MONO" no/such/ref 2>&1 ); }
T="$(monorepo noref)"
check "monotonic: an unresolvable base ref SKIPS containment locally" 0 "containment SKIPPED" mono_noref "$T"
check "monotonic: ...and the skip says uniqueness already ran, not that nothing did" 0 \
  "already ran and passed" mono_noref "$T"
check "monotonic: ...but is a FAILURE under STRICT=1 (what CI sets)" 1 "STRICT=1" \
  mono_noref "$T" CHANGELOG_MONOTONIC_STRICT=1
check "monotonic: ...and the STRICT failure blames the checkout, not the script" 1 \
  "fetch-depth: 0" mono_noref "$T" CHANGELOG_MONOTONIC_STRICT=1

# A missing changelog is an error on any setting — it is not a degradation,
# it is a wrong invocation.
T="$(monorepo nofile)"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "monotonic: a missing changelog file is an error, never a skip" 1 "no such file" \
  bash -c 'cd "$1" && bash "$2" base nope.md 2>&1' _ "$T" "$MONO"

# --- #98: uniqueness is a property of HEAD, so nothing base-side may gate it --
# Containment needs the merge base. Uniqueness needs only the file in front of
# it. As first written (and as inherited from heavy-duty/box, fixed there in
# box#144 for box#143) the duplicate check sat DOWNSTREAM of the base-ref,
# merge-base and base-blob conditions, so each of the degradation paths below
# exited 0 on a tree carrying a duplicate in plain sight — the base-blob one
# not even through skip(), but a bare `exit 0` that STRICT could not reach.
#
# These cases pin the ORDER, which is the actual invariant. Every monorepo
# fixture above commits MONO_BASE on 'base', so no case up there ever reaches
# the base-absent branch at all; and asserting the exit code alone is what let
# the original ship, since the clean base-absent case is green either way.
mononocl() { # mononocl <name> -> a repo whose 'base' has NO changelog, on 'work'
  local d="$WORK/mono-$1"; mkdir -p "$d"
  git -C "$d" init -q -b base
  git -C "$d" config user.email harness@example.invalid
  git -C "$d" config user.name harness
  printf '%s\n' '# rig' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm 'base: no changelog yet'
  git -C "$d" checkout -q -b work
  printf '%s' "$d"
}
monoadd() { # monoadd <dir> <line...> — the branch INTRODUCES CHANGELOG.md
  local d="$1"; shift
  printf '%s\n' "$@" > "$d/CHANGELOG.md"
  git -C "$d" add CHANGELOG.md
  git -C "$d" commit -qm 'work: introduce the changelog'
}

# The changelog is absent at the merge base AND the branch introduces a
# duplicate. Before the fix this exited 0 on "nothing could have been deleted".
T="$(mononocl 98-newdup)"
monoadd "$T" '# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A pending thing** (#2) — prose.' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.'
check "monotonic: a duplicate introduced where the base had NO changelog is CAUGHT (#98)" 1 \
  "DUPLICATE release heading" mono "$T"
check "monotonic: ...and STRICT does not change that (it was never a skip)" 1 \
  "DUPLICATE release heading" mono "$T" CHANGELOG_MONOTONIC_STRICT=1
# ...and the clean counterpart still passes, now SAYING uniqueness ran. Without
# this the case above could be satisfied by failing the base-absent path
# outright, which would redden every changelog-introducing branch.
T="$(mononocl 98-newok)"
monoadd "$T" '# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.'
check "monotonic: ...while a CLEAN introduced changelog still passes" 0 \
  "nothing could have been deleted" mono "$T"
check "monotonic: ...saying uniqueness was checked, not that nothing was" 0 \
  "uniqueness on HEAD already passed" mono "$T"

# No git at all (a tarball, an unpacked release): uniqueness still has
# everything it needs, so a duplicate is caught rather than skipped past.
mkdir -p "$WORK/mono-98-nogit"
printf '%s\n' '# Changelog' '' '## 0.2.0 — 2026-07-19' '' \
  '## 0.2.0 — 2026-07-19' > "$WORK/mono-98-nogit/CHANGELOG.md"
check "monotonic: a duplicate OUTSIDE a git work tree is caught (#98)" 1 \
  "DUPLICATE release heading" mono "$WORK/mono-98-nogit"

# An unresolvable base ref: same — the skip belongs to containment, not to the
# script, so uniqueness has already run by the time skip() is reachable.
T="$(monorepo 98-nobase)"
monowrite "$T" '# Changelog' '' '## Unreleased' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A pending thing** (#2) — prose.' '' '## 0.2.0 — 2026-07-19' '' \
  '- **A shipped thing** (#1) — prose.' '' '## 0.1.0 — 2026-07-01' '' \
  '- **The first thing** (#0) — prose.'
check "monotonic: a duplicate is caught even when the base ref will not resolve (#98)" 1 \
  "DUPLICATE release heading" mono_noref "$T"

# --- ci.yml: the monotonic step is actually wired (#98) ----------------------
# The guard runs from ci.yml, not from this suite, so pin the wiring the same
# way release.yml's is pinned — a script nothing invokes is not a check.
CIY="$ROOT/.github/workflows/ci.yml"
check "ci.yml: runs the monotonic guard" 0 "" \
  grep -q "changelog-monotonic.sh" "$CIY"
check "ci.yml: ...with STRICT=1, so a skip is red rather than quietly green" 0 "" \
  grep -qF "CHANGELOG_MONOTONIC_STRICT: '1'" "$CIY"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "ci.yml: ...against the PR's base branch" 0 "" \
  grep -qF 'origin/${{ github.base_ref' "$CIY"
# The step must NOT be pull-request-only. Deletion is vacuous on a push to main
# (the merge base IS HEAD), but DUPLICATION is vacuous on no tree at all, so
# gating the whole script left a duplicate reaching main by any other route
# unasserted. Dropping the gate is only safe with the ref_name fallback:
# `github.base_ref` is EMPTY on a push, a bare `origin/` does not resolve, and
# STRICT=1 promotes that to a hard failure on every push to main.
#
# Scoped to the step's OWN block, deliberately. As a file-wide grep this
# negative forbade any FUTURE step in ci.yml from being pull_request-gated and
# would have failed citing #98 when one legitimately was — #98 constrains this
# step, not the file. The companion check below is what keeps the awk honest:
# an extractor that matched nothing would turn the negative into a tautology
# that passes forever, including after someone renames the step and re-adds
# the gate.
# Terminates on a new STEP or a new JOB. The job boundary is not optional: the
# monotonic step is the LAST step of its job, so stopping only at the next
# `- name:` runs the block into the job below and swallows that job's
# level `if:` — the same bug this scoping fixed, moved from "any step in the
# file" to "this step plus the head of the next job" (found on box#144).
mono_step_block() {
  awk '/^      - name: no shipped changelog heading/ {f=1; print; next}
       f && (/^      - / || /^  [^ ]/) {exit}
       f {print}' "$CIY"
}
# Anchored: an `if:` inside a `run:` line is not a step condition.
mono_step_gated() { mono_step_block | grep -q '^        if:'; }
check "ci.yml: the monotonic step itself is NOT pull_request-gated (#98)" 1 "" \
  mono_step_gated
check "ci.yml: ...and the block was actually found (guards the awk above)" 0 \
  "changelog-monotonic" mono_step_block
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "ci.yml: ...and falls back to ref_name, so a push has a base to resolve" 0 "" \
  grep -qF 'github.base_ref || github.ref_name' "$CIY"
# Without full history the base ref does not resolve, and STRICT turns that
# into a red run — so the fetch depth is load-bearing, not incidental.
check "ci.yml: the checkout has full history (the base ref must resolve)" 0 "" \
  grep -qF "fetch-depth: 0" "$CIY"

# --- the drill rule: does the version being shipped have a record? ----------
# CONTRIBUTING ("Releasing") has always required a real-hardware drill and
# nothing enforced it, so no release in this family has ever carried one: every
# other ceremony step is checked by a script, and the one that costs an
# afternoon was checked by a reviewer remembering. A bot finally blocked on it.
#
# Records are ONE FILE PER VERSION, at drills/<version>.md. The first cut of
# this guard kept them as sections in a single drill/RUNS.md and needed a
# heading grammar, an optional-date tail, a whole-version comparison and a
# non-blank-body rule to read them back — all of it there only because the
# records shared a file, and both sibling repos shipped a defect out of it in
# review. Splitting the files deletes most of these tests along with the code
# they covered: `0.3.0.md` and `0.3.0-rc1.md` cannot be confused by any
# grammar, because there is no grammar.
#
# Fixtures carry their OWN version file and their OWN drills dir, inside the
# fixture dir. This is not tidiness — it is heavy-duty/box#146, verbatim:
# fixtures that read the REPO's VERSION exercised the `-dev` branch on every
# ordinary tree, so the whole bare-version half of the guard was untested and
# went red for the first time while somebody was cutting a release. A fixture
# must state the tree it is about.
DRILL="$ROOT/.github/scripts/drill-recorded.sh"
check "drill-recorded.sh: exists and is the guard under test" 0 "" test -f "$DRILL"
check "drill-recorded.sh: is executable" 0 "" test -x "$DRILL"

drilltree() { # drilltree <name> <version> -> prints the dir (no drills/ yet)
  local d="$WORK/drill-$1"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/VERSION"
  printf '%s' "$d"
}
drillrec() { # drillrec <dir> <version> <line...> — write drills/<version>.md
  mkdir -p "$1/drills"; local f="$1/drills/$2.md"; shift 2
  printf '%s\n' "$@" > "$f"
}
drill() { bash "$DRILL" "$1/drills" "$1/VERSION" 2>&1; }

# A development tree. Vacuous by construction — every ordinary PR looks like
# this, and none of them can be asked to have drilled a release that does not
# exist. It passes with no drills/ directory present AT ALL, which is the
# state this repo ships in today.
T="$(drilltree dev 0.2.1-dev)"
check "drill: a -dev tree passes with NO drills dir at all" 0 "" drill "$T"
check "drill: ...saying so out loud, not exiting 0 in silence" 0 \
  "nothing to assert" drill "$T"

# The release ceremony tree, drilled and recorded. GREEN.
T="$(drilltree recorded 0.3.0)"
drillrec "$T" 0.3.0 '# Release drill — 0.3.0 — 2026-07-21' '' \
  'Host: bare Debian 13. Candidate refs pinned: box@1a2b3c4, cast@9a0b1c2.' '' \
  '- convergence, then re-converge: clean' \
  '- db-integration: 14/14' '- runner lifecycle: PASS'
drillrec "$T" 0.2.0 '# Release drill — 0.2.0 — 2026-07-01' '' 'an older run'
check "drill: a bare VERSION with a non-empty record for it passes" 0 \
  "records a drill for 0.3.0" drill "$T"

# The gate itself: a release tree with no drills/ directory at all. RED,
# naming the version, because "which release is unevidenced" is the only fact
# the author needs. This is the state a repo is in the first time it cuts a
# release under the gate — it must read as a to-do, not a broken invocation.
T="$(drilltree norecord 0.3.0)"
check "drill: a bare VERSION with NO drills dir FAILS" 1 \
  "no drill record" drill "$T"
check "drill: ...and the failure names the version" 1 "VERSION is 0.3.0" drill "$T"
check "drill: ...and names the file it wanted" 1 "drills/0.3.0.md" drill "$T"

# A drills/ that exists but holds nothing for THIS version. Same failure —
# other releases having been drilled says nothing about this one.
T="$(drilltree otherversion 0.4.0)"
drillrec "$T" 0.3.0 '# Release drill — 0.3.0' '' 'the previous release'
check "drill: a drills dir with no file for THIS version FAILS" 1 \
  "no drill record" drill "$T"
check "drill: ...naming the version that is unevidenced" 1 "VERSION is 0.4.0" drill "$T"

# ...and the failure has to say how to get out of it. Both moves are a commit
# on the PR, and the second one is the point of asking for a RECORD rather
# than a RESULT: a waiver is allowed, it just cannot be silent.
check "drill: ...and the failure names the unblock — run the drill" 1 \
  "RUN THE DRILL" drill "$T"
check "drill: ...and the waiver, recorded, as the other way out" 1 \
  "MAINTAINER WAIVER" drill "$T"
check "drill: ...and points at the README for what a record contains" 1 \
  "README.md" drill "$T"

# An EMPTY file at the right path. This is the failure a laxer guard invites —
# the ceremony PR touches the file to get green and fills it in never.
T="$(drilltree emptyfile 0.3.0)"
mkdir -p "$T/drills"; : > "$T/drills/0.3.0.md"
check "drill: a PRESENT but EMPTY record FAILS" 1 "no drill record" drill "$T"

# ...and WHITESPACE is not a record either. This is the ONE piece of the old
# section-parsing rule set that splitting the files did not make
# unrepresentable, so it is the one that still needs a test. It is here because
# the siblings got it wrong: box#149 and cast#138 both extracted with
# `sed '/./,$!d'`, where `.` matches a space, so one tab satisfied the gate and
# shipped an evidence-free release. All three reviewers caught it there.
# Nothing caught it here, because there was nothing to catch — which is exactly
# the state in which a later simplification quietly reintroduces it.
T="$(drilltree blank 0.3.0)"
drillrec "$T" 0.3.0 '   ' '	' ''
check "drill: a record of only spaces, tabs and newlines FAILS (box#149, cast#138)" \
  1 "no drill record" drill "$T"

# The version is matched WHOLE, both directions — and now the filesystem does
# it, since the version IS the filename. A drill run against a release
# candidate is not evidence for the final release, and the reverse is equally
# false: in both cases the string that matched is not the artefact that ships.
T="$(drilltree whole-rc 0.3.0)"
drillrec "$T" 0.3.0-rc1 '# Release drill — 0.3.0-rc1' '' 'the rc drill'
check "drill: an -rc1 record does NOT satisfy the bare version" 1 \
  "no drill record" drill "$T"
T="$(drilltree whole-final 0.3.0-rc1)"
drillrec "$T" 0.3.0 '# Release drill — 0.3.0' '' 'the final drill'
check "drill: ...and a bare-version record does NOT satisfy the -rc1" 1 \
  "no drill record" drill "$T"

# A missing VERSION file is a wrong invocation, not a degradation — there is
# no version to be lenient about, so it must never read as a pass.
T="$(drilltree noversion 0.3.0)"
rm -f "$T/VERSION"
check "drill: a missing VERSION file is an error, never a pass" 1 "no such file" drill "$T"

# The real files, last. The shipped README must be readable, and the guard the
# repo actually runs must pass on the VERSION the repo actually carries.
check "drills/README.md: exists" 0 "" test -f "$ROOT/drills/README.md"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "drills/README.md: documents the one-file-per-version naming rule" 0 "" \
  bash -c 'grep -qF "drills/<version>.md" "$1"' _ "$ROOT/drills/README.md"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "drills/README.md: says a FAILED drill is still a valid record" 0 "" \
  bash -c 'grep -qi "failed drill is still a valid record" "$1"' _ "$ROOT/drills/README.md"
# The old single-file record must be gone, not merely unreferenced: a stale
# drill/RUNS.md would be a second place to write a record that nothing reads.
check "drill/RUNS.md: is gone — records live one per version now" 1 "" \
  test -e "$ROOT/drill/RUNS.md"
# The property is that the guard's VERDICT IS CORRECT FOR THIS TREE — not that
# it always passes. Those come apart on a ceremony tree: a -dev tree is vacuous
# and must pass, but a ceremony tree passes only once a human has run the drill
# and written the record, which is the entire point of the gate. Asserting
# exit 0 unconditionally made test/release.sh UN-GREENABLE on every release
# branch before its drill, and surfaced as a `release-flow tests` failure rather
# than as the gate doing its job — the same misattribution shape as box#146,
# where a fixture read the repo's real VERSION and only misbehaved on the
# ceremony tree. Caught when box#148 went red for the wrong-looking reason.
THIS_VER="$(tr -d '[:space:]' < "$ROOT/VERSION")"
case "$THIS_VER" in
  *-dev)
    check "drill-recorded.sh: THIS tree is -dev, and the guard is vacuous on it" 0 "" \
      bash "$DRILL" "$ROOT/drills" "$ROOT/VERSION" ;;
  *)
    if [ -s "$ROOT/drills/$THIS_VER.md" ]; then
      check "drill-recorded.sh: THIS ceremony tree HAS its record, and the guard accepts it" 0 "" \
        bash "$DRILL" "$ROOT/drills" "$ROOT/VERSION"
    else
      check "drill-recorded.sh: THIS ceremony tree has NO record yet, and the guard refuses it" 1 "no drill record at" \
        bash "$DRILL" "$ROOT/drills" "$ROOT/VERSION"
    fi ;;
esac
# ...and with no arguments at all, since that is how ci.yml invokes it. The
# defaults must be the paths this repo actually uses.
# ...and with its DEFAULT arguments, as CI runs it. What this pins is that the
# defaults ARE the paths this repo uses — so it asserts the defaults reach the
# same verdict as the explicit call above, not a fixed exit code. Hard-coding 0
# here would fail on a ceremony tree for the same wrong reason the check above
# used to.
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "drill-recorded.sh: ...and its DEFAULT arguments agree, as CI runs it" 0 "" \
  bash -c '
    cd "$1" || exit 9
    bash .github/scripts/drill-recorded.sh >/dev/null 2>&1; d=$?
    bash .github/scripts/drill-recorded.sh drills VERSION >/dev/null 2>&1; e=$?
    [ "$d" -eq "$e" ]' _ "$ROOT"

# ci.yml: the guard runs from there, so pin the wiring — a script nothing
# invokes is not a check (same reasoning as the monotonic pins above).
check "ci.yml: runs the drill guard" 0 "" grep -q "drill-recorded.sh" "$CIY"
# ...and is NOT trigger-gated. It is vacuous on every -dev tree already, so an
# `if:` could only ever exempt the one tree it exists for.
drill_step_block() {
  awk '/^      - name: a release version has a recorded drill/ {f=1; print; next}
       f && (/^      - / || /^  [^ ]/) {exit}
       f {print}' "$CIY"
}
drill_step_gated() { drill_step_block | grep -q '^        if:'; }
check "ci.yml: the drill step itself is NOT trigger-gated" 1 "" drill_step_gated
check "ci.yml: ...and the block was actually found (guards the awk above)" 0 \
  "drill-recorded" drill_step_block

# CONTRIBUTING must state the gate, and must state what the drill actually is.
# The three repos' drills are INDEPENDENT — run in any order, on any schedule —
# and what makes that safe is that each one pins the same fixed set of
# CANDIDATE refs, so box and rig measure the same pair. That, not sequencing,
# is what dissolves the mutual recursion (rig builds the host box runs on, and
# box mints the seeds rig converges). An earlier draft of this doc claimed a
# fixed box → rig → cast release order; it is wrong, and this pins the
# correction.
CONTRIB="$ROOT/CONTRIBUTING.md"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "CONTRIBUTING: the release flow names the drill gate" 0 "" \
  bash -c 'grep -qF "drills/<version>.md" "$1"' _ "$CONTRIB"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "CONTRIBUTING: ...and says the three repos' drills are INDEPENDENT" 0 "" \
  bash -c 'grep -qi "drills are independent" "$1"' _ "$CONTRIB"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "CONTRIBUTING: ...pinned to one fixed set of candidate refs" 0 "" \
  bash -c 'grep -qi "same fixed set of candidate refs" "$1"' _ "$CONTRIB"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "CONTRIBUTING: ...which is what dissolves the recursion, not sequencing" 0 "" \
  bash -c 'grep -qF "RIG_REF" "$1"' _ "$CONTRIB"
# The negative that keeps the correction from being re-lost: no fixed release
# order may be claimed. Nothing requires box to ship before rig.
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "CONTRIBUTING: ...and never claims a fixed box-then-rig release order" 1 "" \
  bash -c 'grep -qi "box first, then rig" "$1"' _ "$CONTRIB"

# --- release.yml: the pins ---------------------------------------------------
# The workflow itself runs only on a tag push upstream, so pin its
# load-bearing pieces the way the harness pins root-only paths (repo
# precedent: the tag-refusal greps in test/cli.sh).
RY="$ROOT/.github/workflows/release.yml"
check "release.yml: exists" 0 "" test -f "$RY"
check "release.yml: triggers on tag pushes" 0 "" grep -q "tags:" "$RY"
check "release.yml: sources the shared lib (one extractor, not a copy)" 0 "" \
  grep -q "release-lib.sh" "$RY"
check "release.yml: the body comes from changelog_section" 0 "" \
  grep -q "changelog_section CHANGELOG.md" "$RY"
check "release.yml: a tag/VERSION mismatch refuses to create" 0 "" \
  grep -q "refusing to create a release" "$RY"
check "release.yml: an empty changelog section refuses too" 0 "" \
  grep -q "has no '## " "$RY"
check "release.yml: gh release create verifies the tag" 0 "" \
  grep -q -- "--verify-tag" "$RY"
# Ordering: the mismatch assert must precede the create (line compare, the
# repo's marker-then-box idiom; defaults fail closed).
assert_at="$(grep -n "refusing to create a release" "$RY" | head -n1 | cut -d: -f1)"
create_at="$(grep -n "gh release create" "$RY" | head -n1 | cut -d: -f1)"
check "release.yml: the assert precedes the create" \
  0 "" test "${assert_at:-999999}" -lt "${create_at:-0}"

# --- release.yml, the merge path: the pins (#47; box#96's design) ------------
# Merging the release-labeled ceremony PR IS the release. Same grep-pin
# treatment for the merge path's load-bearing pieces: the gate, the four
# fail-loud asserts, the same-job tag+publish, and the surviving tag-push
# fallback.
# The merge door rides pushes to MAIN, not pull_request events: a fork PR's
# pull_request run gets a read-only GITHUB_TOKEN (permissions: cannot raise
# it), and every ceremony PR this org merges is cross-repo from the bot
# fork — the tag create would 403 after green asserts (#48 round 1). The
# label — the operator's intent — is read via the API off the merge commit.
check "release.yml: the merge door rides pushes to main (fork-token-proof)" 0 "" \
  grep -qF "branches: [main]" "$RY"
# YAML maps are last-key-wins: a second sibling push: key silently replaces
# the first and kills a door (grok's round-2 catch — the tag fallback had
# stopped triggering). Exactly ONE push key may exist.
check "release.yml: exactly one on.push key (duplicate keys drop a door)" 0 "1" \
  grep -cE '^  push:' "$RY"
check "release.yml: ...and the doors split on the ref (tag door takes tags)" 0 "" \
  grep -qF "startsWith(github.ref, 'refs/tags/')" "$RY"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "release.yml: the release label is read via the API off the merge commit" 0 "" \
  grep -qF 'commits/$MERGE_SHA/pulls' "$RY"
check "release.yml: a transition without a labeled PR refuses" 0 "" \
  grep -qF "no merged, release-labeled PR is behind this commit" "$RY"
# The decide step tells the label's two meanings apart (LABELS.md gives
# `release` to release-flow WORK as well as to the ceremony PR): work under
# the label is a green NOTICE no-op — in the -dev steady state and in the
# post-release window (bare, unchanged, already released) — while every
# half-ceremony refuses. Pin each verdict's message and the gating output.
check "release.yml: decide — dev-tree work no-ops green (not a red run per infra PR)" 0 "" \
  grep -qF "release-flow work under the release label, not a ceremony" "$RY"
check "release.yml: decide — a -dev endstate is always work (the bump PR no-ops green)" 0 "" \
  grep -qF "a dev tree is by definition not a release" "$RY"
check "release.yml: decide — post-release-window work no-ops green" 0 "" \
  grep -qF "release-flow work merged in the post-release window" "$RY"
check "release.yml: decide — bare, unchanged, never released refuses to guess" 0 "" \
  grep -qF "Refusing to guess" "$RY"
# shellcheck disable=SC2016  # the $-refs are the inner bash -c's, deliberately
check "release.yml: decide gates every later step on ceremony=yes" 0 "" \
  bash -c '[ "$(grep -cF "if: steps.decide.outputs.ceremony == '\''yes'\''" "$1")" -ge 3 ]' _ "$RY"
check "release.yml: assert 3 — an empty section refuses to publish" 0 "" \
  grep -qF "refusing to publish an empty release" "$RY"
check "release.yml: assert 4 — an existing tag or release refuses (idempotent)" 0 "" \
  grep -qF "refusing to re-release" "$RY"
# Same-job matters: a GITHUB_TOKEN-created tag fires no tag-push workflow,
# so the publish must live NEXT TO the tag creation. The workflow keeps
# release-on-merge as its last job (pinned by comment there) so the awk
# range runs to EOF; both acts must land inside it.
MJOB="$(awk '/^  release-on-merge:/,0' "$RY")"
mjob_has() { printf '%s' "$MJOB" | grep -qF -e "$1"; }
check "release.yml: the merge job API-creates the tag itself" 0 "" \
  mjob_has "git/refs"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "release.yml: ...at the pushed main head (github.sha = the merge commit)" 0 "" mjob_has 'sha="$MERGE_SHA"' 
# The release re-arms main itself: the post-release -dev bump is arithmetic,
# not judgment, so it rides the same job — direct push, PR fallback.
check "release.yml: the release bumps main to the next -dev itself" 0 "" \
  grep -qF "bump main to the next -dev" "$RY"
check "release.yml: ...with a PR fallback when the direct push is refused" 0 "" \
  grep -qF "opening the bump PR instead" "$RY"
check "release.yml: ...and publishes in the SAME job" 0 "" \
  mjob_has "gh release create"
# Ordering, the marker-then-box idiom again: the last assert's refusal must
# precede the tag creation (asserts first, acts last; defaults fail closed).
massert_at="$(grep -n "refusing to re-release" "$RY" | head -n1 | cut -d: -f1)"
mtag_at="$(grep -n "git/refs" "$RY" | head -n1 | cut -d: -f1)"
check "release.yml: the merge-path asserts precede the tag" \
  0 "" test "${massert_at:-999999}" -lt "${mtag_at:-0}"
# ...and the manual path SURVIVES: tag-push trigger plus a push-gated job,
# the documented fallback and backfill.
check "release.yml: the tag-push trigger survives (manual fallback intact)" 0 "" \
  grep -qF "tags: ['**']" "$RY"
check "release.yml: the fallback job is gated to push events" 0 "" \
  grep -qF "github.event_name == 'push'" "$RY"

# --- the installer's ref logic, extracted ------------------------------------
# install.sh must stay a single curl|bash file, so its channel functions live
# inline; extract them here and drive them for real (the valid_version awk
# idiom from test/cli.sh), against a stub curl — never the network.
RL="$WORK/installer-fns.sh"
awk '/^resolve_latest_tag\(\) \{/,/^\}/' "$ROOT/install.sh" > "$RL"
awk '/^ref_candidate_urls\(\) \{/,/^\}/' "$ROOT/install.sh" >> "$RL"
check "installer fns extracted (guards the awk)" 0 "redirect_url" cat "$RL"

STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'CURL'
#!/usr/bin/env bash
# The harness's curl — never the network. Scripted via env:
#   CURL_STUB_FAIL      nonempty -> every call exits 22 (curl's HTTP error)
#   CURL_STUB_REDIRECT  what -w %{redirect_url} answers (the HEAD probe)
#   CURL_STUB_OK        substring a download URL must carry to succeed
#   CURL_STUB_TARBALL   copied to -o's target on a successful download
#   CURL_STUB_LOG       every URL asked for, one per line, appended
set -u
out="" url="" probe=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) probe=1; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "${CURL_STUB_LOG:-}" ]; then printf '%s\n' "$url" >> "$CURL_STUB_LOG"; fi
if [ -n "${CURL_STUB_FAIL:-}" ]; then exit 22; fi
if [ "$probe" -eq 1 ]; then printf '%s' "${CURL_STUB_REDIRECT:-}"; exit 0; fi
case "$url" in
  *"${CURL_STUB_OK:-/__nothing_succeeds__/}"*) cp "${CURL_STUB_TARBALL:?}" "${out:?}"; exit 0 ;;
  *) exit 22 ;;
esac
CURL
chmod +x "$STUB/curl"

rlt() { # rlt [VAR=val ...] — resolve_latest_tag under the stub curl
  # The single-quoted $1 is the inner bash's positional, not this shell's.
  # shellcheck disable=SC2016
  env PATH="$STUB:$PATH" "$@" bash -c 'set -euo pipefail
    . "$1"; resolve_latest_tag heavy-duty/rig' _ "$RL"
}
check "resolve: a releases/tag redirect yields the tag" 0 "0.1.0" \
  rlt CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases/tag/0.1.0
# A repo with NO releases redirects to /releases (measured live against
# heavy-duty/rig itself) — that must fail, never invent a ref.
check "resolve: the no-releases redirect (/releases) fails" 1 "" \
  rlt CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases
check "resolve: no redirect at all fails" 1 "" rlt
check "resolve: a tagless releases/tag/ redirect fails" 1 "" \
  rlt CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases/tag/
check "resolve: a failing curl fails (network down is not a channel)" 1 "" \
  rlt CURL_STUB_FAIL=1

rcu_line() { # rcu_line <n> — the nth candidate URL for an explicit ref
  bash -c 'set -euo pipefail
    . "$1"; ref_candidate_urls acme/widgets 1.2.3 | sed -n "${2}p"' _ "$RL" "$1"
}
check "candidates: refs/tags first — the pin outranks a same-named branch" 0 \
  "https://github.com/acme/widgets/archive/refs/tags/1.2.3.tar.gz" rcu_line 1
check "candidates: refs/heads is the fallback" 0 \
  "https://github.com/acme/widgets/archive/refs/heads/1.2.3.tar.gz" rcu_line 2

# --- the three channels, driven through the REAL installer -------------------
# Full install.sh runs against throwaway roots with the stub curl on PATH: the
# channel selection, the tag-first fallback, and the loud no-releases refusal
# are all DRIVEN, not grepped (the test/cli.sh install-drill idiom).
TBDIR="$WORK/tb"; mkdir -p "$TBDIR/rig-7.7.7-relflow/bin"
cp "$ROOT/bin/rig" "$TBDIR/rig-7.7.7-relflow/bin/rig"
chmod +x "$TBDIR/rig-7.7.7-relflow/bin/rig"
echo "7.7.7-relflow" > "$TBDIR/rig-7.7.7-relflow/VERSION"
tar -C "$TBDIR" -czf "$WORK/release.tgz" rig-7.7.7-relflow

rinst() { # rinst <home> <bin> [VAR=val ...] — a real install.sh run, stubbed net
  local h="$1" b="$2"; shift 2
  env -u RIG_REF PATH="$STUB:$PATH" HOME="$FAKEHOME" \
      RIG_ROLE_MARKER="$WORK/no-marker" RIG_HOME="$h" RIG_BIN="$b" \
      CURL_STUB_TARBALL="$WORK/release.tgz" "$@" bash "$ROOT/install.sh"
}

# Channel 1 — RIG_REF unset, a release exists: resolve the tag, download
# refs/tags/<tag>, and the installed tree records exactly that ref.
H1="$WORK/h1"; B1="$WORK/b1"
check "channel latest: resolves and installs the release tag" 0 "done" \
  rinst "$H1" "$B1" \
    CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases/tag/7.7.7-relflow \
    CURL_STUB_OK=refs/tags/7.7.7-relflow
check "channel latest: the tree landed under the tag's version" 0 "" \
  test -x "$H1/versions/7.7.7-relflow/bin/rig"
check "channel latest: INSTALLED_FROM names the resolved tag" 0 \
  "heavy-duty/rig@7.7.7-relflow" cat "$H1/versions/7.7.7-relflow/INSTALLED_FROM"

# Channel 1, transitional — RIG_REF unset, NO release exists (rig today):
# fail LOUDLY, name RIG_REF=main as the way out, install nothing. The stub
# would happily serve refs/heads/main here — a silent fallback would pass the
# download and FAIL this check by succeeding.
H2="$WORK/h2"; B2="$WORK/b2"
check "channel latest: no releases yet — dies, never hangs, never falls back" \
  1 "RIG_REF=main" rinst "$H2" "$B2" \
    CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases \
    CURL_STUB_OK=refs/heads/main
check "channel latest: the refusal says what is missing" 1 "no release" \
  rinst "$H2" "$B2" CURL_STUB_REDIRECT=https://github.com/heavy-duty/rig/releases
check "channel latest: the refusal installed NOTHING" 1 "" test -e "$H2"

# Channel 2 — RIG_REF=<tag>: refs/tags wins, and the latest-release probe is
# never consulted (a pin resolves nothing).
H3="$WORK/h3"; B3="$WORK/b3"; LOG3="$WORK/log3"
check "channel pinned: RIG_REF=<tag> installs from refs/tags" 0 "refs/tags/7.7.7-relflow" \
  rinst "$H3" "$B3" RIG_REF=7.7.7-relflow \
    CURL_STUB_OK=refs/tags/7.7.7-relflow CURL_STUB_LOG="$LOG3"
check "channel pinned: no releases/latest probe for an explicit ref" 1 "" \
  grep -q "releases/latest" "$LOG3"
check "channel pinned: exactly one download (the tag hit first)" 0 "1" \
  grep -c . "$LOG3"

# Channel 3 — RIG_REF=<branch>: the tag candidate misses, refs/heads lands.
H4="$WORK/h4"; B4="$WORK/b4"; LOG4="$WORK/log4"
check "channel dev: a branch ref falls back to refs/heads" 0 "done" \
  rinst "$H4" "$B4" RIG_REF=feature-x \
    CURL_STUB_OK=refs/heads/feature-x CURL_STUB_LOG="$LOG4"
check "channel dev: the tag URL was still tried FIRST" 0 "refs/tags/feature-x" \
  sed -n 1p "$LOG4"
check "channel dev: ...then the branch URL" 0 "refs/heads/feature-x" \
  sed -n 2p "$LOG4"

# Neither a tag nor a branch: both candidates miss, and the die says so.
H5="$WORK/h5"; B5="$WORK/b5"
check "channel: a ref that is neither tag nor branch dies naming both tries" \
  1 "not a tag and not a branch" rinst "$H5" "$B5" RIG_REF=no-such-ref

rm -rf "$WORK"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
