#!/usr/bin/env bash
set -euo pipefail

# drill-recorded.sh [<drills-dir>] [<version-file>] — assert that the version
# this tree is about to ship has a DRILL RECORD at <drills-dir>/<version>.md.
#
# defaults: drills   VERSION
#
# CONTRIBUTING ("Releasing") says a release carries a real-hardware drill.
# Nothing enforced it, so no release in this family has ever had one: the
# ceremony is four correct mechanical steps — bump VERSION, stamp the
# changelog, re-arm, merge — and every one of them is checked by a script,
# while the one step that costs an afternoon on real hardware was checked by
# a reviewer remembering. Reviewers remember exactly as long as the release is
# interesting, which is never at 0.4.3. A bot finally blocked on it; this is
# that block, moved into CI where it does not depend on anyone's attention.
#
# ONE FILE PER VERSION, which is what this script is now mostly about. The
# first cut of this guard kept every record as a section inside one
# drill/RUNS.md, and paid for it: it needed an awk extractor that matched a
# literal '## Release drill — ' prefix, tolerated an optional ' — DATE' tail,
# compared the version WHOLE so that '0.3.0-rc1' could not answer for '0.3.0',
# and then separately insisted the extracted body hold a non-blank line. Every
# one of those rules existed only because records shared a file. Both sibling
# repos shipped a DEFECT out of that complexity during review — a
# `sed '/./,$!d'` extractor where `.` matches a space, so a heading plus one
# tab satisfied the gate (box#149, cast#138), and heading-grammar drift on the
# other side. Splitting the records makes nearly all of it unrepresentable:
# `0.3.0.md` and `0.3.0-rc1.md` are simply different files, there is no
# heading to parse and no grammar to drift, and the whole-version comparison
# is done by the filesystem.
#
# PER-REPO, and that is the load-bearing design decision. The obvious
# alternative — have rig ask box's repo whether the drill ran — cannot fail
# safely: the lookup needs a network call, a token, and a checkout that may be
# a fork, and every one of those failure modes lands on "could not read", which
# a naive implementation spells `|| true` and reads as PASS. That is exactly
# the UNREADABLE-vs-NONE bug #90 fixed one layer up (an unreadable check rollup
# reading as "nothing is failing"), and re-introducing it in the release gate
# would be worse: it degrades to green on precisely the tree that ships. So rig
# records rig's own legs in rig's own repo, and this script reads a file that
# is either in the checkout or is not.
#
# The directory is `drills/`, NOT `.drills/`. A dot-directory is invisible to
# every glob that has not set `dotglob`, which is how #70 here and box#116 /
# box#118 all happened: a file that exists but that no sweep can see is worse
# than no file, because it reads as covered.
#
# What it asserts is a RECORD, not a RESULT — and that is deliberate, not a
# weakness. A gate that demanded "the drill passed" would have to parse
# somebody's prose for a verdict, and would leave a maintainer who consciously
# ships without a full drill (a doc-only release, a hardware outage) with no
# move except deleting the check. Requiring a record means the waiver is
# WRITTEN DOWN, in a file named for the version it applies to, in a commit a
# reviewer sees. Skipping stays possible; skipping silently does not.
#
# Vacuous on a `-dev` tree, which is why it needs no trigger scoping in
# ci.yml (unlike changelog-monotonic.sh, whose input is a diff): every ordinary
# PR carries a `-dev` VERSION and passes without a drill record existing at
# all. The check has something to say on exactly one tree — the release
# ceremony PR — and that is the tree it must be impossible to merge without.

drills="${1:-drills}"
version_file="${2:-VERSION}"

# An unreadable version file is an ERROR, never a silent pass. There is no
# version to be lenient about, so leniency here could only mean "ship
# unevidenced" — the exact degradation the per-repo decision above exists to
# avoid.
[ -f "$version_file" ] || {
  echo "drill-recorded: no such file: $version_file" >&2
  exit 1
}

version="$(tr -d '[:space:]' < "$version_file")"
[ -n "$version" ] || {
  echo "drill-recorded: $version_file is empty — there is no version to check a drill against." >&2
  exit 1
}

# The -dev half. A development tree is not shipping anything, so there is
# nothing to evidence; saying so out loud (rather than exiting 0 in silence)
# is the #98 lesson — a guard that prints nothing is indistinguishable from a
# guard that did nothing.
case "$version" in
  *-dev)
    echo "drill-recorded: VERSION is $version — a development tree has nothing to assert (the drill gates a RELEASE, and this is not one)."
    exit 0
    ;;
esac

record="$drills/$version.md"

# WHITESPACE IS NOT A RECORD. This is the one surviving piece of the rule set
# the old section-parsing guard needed, and it survives because it is the one
# part that splitting the files does not make unrepresentable: an empty file,
# or a file holding only spaces, tabs and newlines, exists at the right path
# and is still no evidence. It is the same property box#149 and cast#138 both
# got wrong with `sed '/./,$!d'` (`.` matches a space), where a record of one
# tab shipped an evidence-free release. `grep -q '[^[:space:]]'` is the whole
# check now, with no extractor in front of it to get wrong.
#
# Written as if/then, NOT as `[ -f "$record" ] && recorded=yes`. Under `set -e`
# a bare `a && b` statement whose last command fails takes the whole script
# down with its exit status — so a miss would exit 1 here, before the failure
# message below ever printed, and the author would see nothing.
recorded=no
if [ -f "$record" ] && grep -q '[^[:space:]]' "$record"; then
  recorded=yes
fi

if [ "$recorded" != yes ]; then
  {
    echo "drill-recorded: VERSION is $version, and there is no drill record at $record."
    echo
    cat <<EOF
  This tree is a release ceremony tree — VERSION is bare, so merging it ships
  $version. CONTRIBUTING ("Releasing") requires that release to carry a real
  hardware drill, recorded in a file named for the version, exactly:

      $drills/$version.md

  One file per version, so the name IS the match: a record for
  $version-rc1 lives at a different path and does not count. The file must
  hold at least one non-whitespace character — an empty file, or one of only
  spaces and tabs, is not a record.

  Two ways to unblock, and both are a commit on this PR:

    1. RUN THE DRILL and record it. What ran, on what hardware, the numbers,
       and what failed. rig's drill asserts CONVERGENCE — a machine reaches
       its role, idempotently — against a PINNED set of candidate refs
       (RIG_REPO/RIG_REF and BOX_REF are mint-time variables, so the run pins
       the commits under test). Drilling the candidate IS drilling the
       release, since a release PR's diff is VERSION + CHANGELOG.md and
       nothing executable differs. Cite the run ID and the other repos' SHAs.
       The three repos' drills are independent — rig's does not wait on box's.

    2. RECORD AN EXPLICIT MAINTAINER WAIVER in that same file, saying who
       waived it and why. This guard asks for a RECORD, not a passing result,
       so a deliberate skip is allowed — it just has to be visible and
       reviewable rather than silent.

  See $drills/README.md for what a record should contain.

  Do not delete this step to get green. A release that cannot say what was
  drilled is the state this check exists to end.
EOF
  } >&2
  exit 1
fi

lines="$(grep -c . "$record" || true)"
echo "drill-recorded: $record records a drill for $version ($lines non-blank line(s))."
