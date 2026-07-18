#!/usr/bin/env bash
# Release plumbing shared by .github/workflows/release.yml and the test
# harness (test/release.sh) — pure functions, sourced, never executed on
# their own (repo precedent: labels-reconcile.sh's decide_state, the
# commands/lib/*.sh parsers).

# changelog_section <file> <version>
#
# Print the BODY of that version's CHANGELOG.md section: everything between
# its heading and the next '## ' heading (or EOF). A release heading is
# stamped '## <version> — <date>' and the Unreleased one is bare
# '## Unreleased'; the second field is the version either way, so both
# shapes match. The heading itself is not printed — the release title
# already names the version — and leading blank lines are dropped. Empty
# output means "no such section", which release.yml turns into a refusal: a
# tag with no changelog entry must not ship an empty release.
changelog_section() {
  awk -v ver="$2" '
    /^## / { if (found) exit; found = ($2 == ver); next }
    found && !body && /^[[:space:]]*$/ { next }
    found { body = 1; print }
  ' "$1"
}
