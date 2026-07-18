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

# ...and the SHIPPED changelog fits the extractor: an Unreleased section the
# release PR will stamp, extractable by the exact function release.yml runs.
check "CHANGELOG.md: has an Unreleased section" 0 "" \
  grep -qx "## Unreleased" "$ROOT/CHANGELOG.md"
check "CHANGELOG.md: Unreleased extracts non-empty (the format fits the tool)" \
  0 "#32" changelog_section "$ROOT/CHANGELOG.md" Unreleased

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
