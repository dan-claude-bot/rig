#!/usr/bin/env bash
set -euo pipefail

# drill-recorded.sh [<runs-file>] [<version-file>] — assert that the version
# this tree is about to ship has a DRILL RECORD in drill/RUNS.md.
#
# defaults: drill/RUNS.md   VERSION
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
# What it asserts is a RECORD, not a RESULT — and that is deliberate, not a
# weakness. A gate that demanded "the drill passed" would have to parse
# somebody's prose for a verdict, and would leave a maintainer who consciously
# ships without a full drill (a doc-only release, a hardware outage) with no
# move except deleting the check. Requiring a record means the waiver is
# WRITTEN DOWN, under the version it applies to, in a commit a reviewer sees.
# Skipping stays possible; skipping silently does not.
#
# Vacuous on a `-dev` tree, which is why it needs no trigger scoping in
# ci.yml (unlike changelog-monotonic.sh, whose input is a diff): every ordinary
# PR carries a `-dev` VERSION and passes without a drill record existing at
# all. The check has something to say on exactly one tree — the release
# ceremony PR — and that is the tree it must be impossible to merge without.

runs="${1:-drill/RUNS.md}"
version_file="${2:-VERSION}"

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

# drill_section <file> <version> — print the BODY under that version's
# heading: everything between it and the next '## ' (or EOF), leading blank
# lines dropped. Empty output means "no record", which is the failure.
#
# Modelled on release-lib.sh's changelog_section(), with one difference that
# is the whole reason it is not that function: changelog_section() matches on
# awk's field $2, which works because a changelog heading is '## <version> …'.
# Here the version is the FOURTH field of '## Release drill — X.Y.Z — DATE',
# and matching by field number would break the moment the em dashes moved. So
# this matches the literal prefix and then compares the version WHOLE.
#
# Whole is the point. A prefix match makes '0.3.0' satisfied by a record for
# '0.3.0-rc1' — a drill run against a release candidate, silently accepted as
# evidence for the final — and, in the other direction, makes an '0.3.0'
# record satisfy '0.3.0-rc1'. Both are the same defect: the string that
# matched is not the artefact that ships. changelog_section()'s exact `$2 ==
# ver` is the precedent; this preserves it through a longer heading.
drill_section() {
  awk -v ver="$2" '
    /^## / {
      if (found) exit
      line = $0; sub(/[[:space:]]+$/, "", line)
      found = 0
      pfx = "## Release drill — "
      if (index(line, pfx) == 1) {
        rest = substr(line, length(pfx) + 1)
        # Split at the version LENGTH, then demand the remainder be either
        # nothing or the optional " — <date>". A trailing "-rc1" lands in
        # tail, fails both, and is correctly not a match. (Double quotes on
        # purpose: an apostrophe here would close the awk program.)
        if (substr(rest, 1, length(ver)) == ver) {
          tail = substr(rest, length(ver) + 1)
          if (tail == "" || index(tail, " —") == 1) found = 1
        }
      }
      next
    }
    found && !body && /^[[:space:]]*$/ { next }
    found { body = 1; print }
  ' "$1"
}

# A missing runs file is not a different failure from a missing section: both
# mean "this release has no recorded drill", and both want the same unblock
# text. The first release under this gate in a repo with no drill/ directory
# yet is the missing-file case, and it must read as a to-do, not as a broken
# invocation.
record=""
if [ -f "$runs" ]; then
  record="$(drill_section "$runs" "$version")"
fi

if [ -z "$record" ]; then
  {
    echo "drill-recorded: VERSION is $version, and $runs has NO drill record for it."
    echo
    cat <<EOF
  This tree is a release ceremony tree — VERSION is bare, so merging it ships
  $version. CONTRIBUTING ("Releasing") requires that release to carry a real
  hardware drill, recorded in $runs under a heading of exactly this shape:

      ## Release drill — $version — YYYY-MM-DD

  The trailing date is optional; the version is matched WHOLE, so a record for
  $version-rc1 (or for a different version entirely) does not count. The
  section must have at least one non-blank line under it — a bare heading is
  not a record.

  Two ways to unblock, and both are a commit on this PR:

    1. RUN THE DRILL and record it. What ran, on what hardware, the numbers,
       and what failed. It is ONE orchestrated run over the whole stack, on
       CANDIDATE refs (RIG_REPO/RIG_REF are mint-time variables, so the run
       pins the commits under test) — drilling the candidate IS drilling the
       release, since a release PR's diff is VERSION + CHANGELOG.md and nothing
       executable differs. Cite the run ID and the other repos' SHAs.

    2. RECORD AN EXPLICIT MAINTAINER WAIVER under the same heading, saying who
       waived it and why. This guard asks for a RECORD, not a passing result,
       so a deliberate skip is allowed — it just has to be visible and
       reviewable rather than silent.

  Do not delete this step to get green. A release that cannot say what was
  drilled is the state this check exists to end.
EOF
  } >&2
  exit 1
fi

lines="$(printf '%s\n' "$record" | grep -c . || true)"
echo "drill-recorded: $runs records a drill for $version ($lines line(s) under the heading)."
