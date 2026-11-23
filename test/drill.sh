#!/usr/bin/env bash
# test/drill.sh — the drill harness's HONESTY, proven without hardware.
#
# drill/drill.sh is the instrument (#105), so what this suite tests is the
# instrument itself: the refusals, the classifications, the capture-and-diff
# that decides idempotence, and the record emitter — the parts whose lies
# would be believed, months later, by a reader of drills/<version>.md. The
# two-leg live run on a real Debian machine is #107's exercise, not this
# file's: nothing here needs root, Docker, a tailnet or the network.
#
# Extraction pattern is test/release.sh's: the functions under test are
# awk-extracted from drill/drill.sh and driven against fixtures, so the tests
# exercise the shipped bytes, and the extraction check itself guards the awk
# against a drifted function boundary.
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
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

# refute <desc> <substr> <file> — the file must NOT contain the substring.
refute() {
  if grep -qF -e "$2" "$3"; then
    echo "FAIL: $1 — found forbidden '$2'"
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $1"; PASS=$((PASS + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the functions under test, extracted -------------------------------------
FNS="$WORK/drill-fns.sh"
for fn in tree_of self_tree rig_home_of assert_installed_from tree_source_commit assert_source_commit classify_leg capture_state default_record_path render_github_users publish_record emit_record; do
  awk "/^${fn}\(\) \{/,/^\}/" "$ROOT/drill/drill.sh" >> "$FNS"
done
for fn in tree_of self_tree rig_home_of assert_installed_from tree_source_commit assert_source_commit classify_leg capture_state default_record_path render_github_users publish_record emit_record; do
  check "extraction guards the awk: ${fn}() landed" 0 "${fn}() {" grep -F "${fn}() {" "$FNS"
done
# shellcheck source=/dev/null
. "$FNS"

# =============================================================================
# tree_of — the versioned tree behind a CLI's symlink chain
# =============================================================================
IR="$WORK/install"; mkdir -p "$IR/versions/1.2.3/bin"
: > "$IR/versions/1.2.3/bin/rig"
ln -s "versions/1.2.3" "$IR/current"
mkdir -p "$WORK/bin"
ln -s "$IR/current/bin/rig" "$WORK/bin/rig"
check "tree_of resolves a current-symlink chain to versions/<v>" 0 "$IR/versions/1.2.3" \
  tree_of "$WORK/bin/rig"
ln -s "$IR/gone/bin/rig" "$WORK/bin/dangling"
check "tree_of refuses a dangling chain — a tree that is not there is not a tree" 1 "" \
  tree_of "$WORK/bin/dangling"

# =============================================================================
# self_tree — the SUBJECT (#220). The drill drills the tree it ships in, so a
# script that cannot locate one has nothing to drill and must say so. These are
# the two ways to arrive without a tree, and both used to be legitimate entry
# paths back when the subject came over the network.
# =============================================================================
ST="$(readlink -f "$WORK")/rigtree"; mkdir -p "$ST/drill" "$ST/bin"
: > "$ST/install.sh"; printf '9.9.9\n' > "$ST/VERSION"; : > "$ST/bin/rig"
: > "$ST/drill/drill.sh"
check "self_tree resolves the rig tree a drill script ships in" 0 "$ST" \
  self_tree "$ST/drill/drill.sh"

# The advertised entry path, and the acceptance criterion's own shape: the
# drill invoked through the install's 'current' symlink. It must resolve to the
# VERSIONED tree — a logical answer of '<root>/current' has no versions/
# component, so the root derived from it would be the installer's default and
# the drill would wipe one place while installing to another.
SYMROOT="$(readlink -f "$WORK")/symroot"
mkdir -p "$SYMROOT/versions/9.9.9/drill" "$SYMROOT/versions/9.9.9/bin"
: > "$SYMROOT/versions/9.9.9/install.sh"
printf '9.9.9\n' > "$SYMROOT/versions/9.9.9/VERSION"
: > "$SYMROOT/versions/9.9.9/bin/rig"
: > "$SYMROOT/versions/9.9.9/drill/drill.sh"
ln -s "versions/9.9.9" "$SYMROOT/current"
check "self_tree resolves through the install's current symlink to the versioned tree" 0 \
  "$SYMROOT/versions/9.9.9" self_tree "$SYMROOT/current/drill/drill.sh"
# The positional parameters belong to the child bash, intentionally — the two
# functions have to compose in one shell for this to prove anything.
# shellcheck disable=SC2016
check "…so the root derived from it is the one the install will re-create" 0 "$SYMROOT" \
  bash -c '. "$1"; rig_home_of "$(self_tree "$2")"' _ "$FNS" "$SYMROOT/current/drill/drill.sh"

NOTRIG="$WORK/notrig"; mkdir -p "$NOTRIG/drill"; : > "$NOTRIG/drill/drill.sh"
check "…and refuses a directory that is not a rig tree — a lone copy drills nothing" 1 "" \
  self_tree "$NOTRIG/drill/drill.sh"
: > "$NOTRIG/install.sh"; printf '9.9.9\n' > "$NOTRIG/VERSION"
check "…still refuses when only some of the tree's marks are there" 1 "" \
  self_tree "$NOTRIG/drill/drill.sh"
self_tree_through_process_substitution() { self_tree <(printf ''); }
check "…and refuses a process substitution: no file, so no tree above it" 1 "" \
  self_tree_through_process_substitution

# =============================================================================
# rig_home_of — the install root the drill wipes has to be the one the install
# re-creates, or the drill measures one install and leaves another behind.
# =============================================================================
check "rig_home_of derives the install root from a versioned tree" 0 "/opt/rig" \
  rig_home_of /opt/rig/versions/0.3.3
check "…root's default layout too" 0 "/root/.local/share/rig" \
  rig_home_of /root/.local/share/rig/versions/0.3.3
check "…and refuses a tree that is not installed — a checkout has no root to wipe" 1 "" \
  rig_home_of /home/dan/src/rig

# =============================================================================
# assert_installed_from — the refusal keeps its place on a narrower reason
# (#220 D5): not "a stale ref was exported" — there is no rig ref any more —
# but "the install landed where we think it did, from the source we think it
# did". box is still installed by ref, and rig is still asserted through
# whatever answers on PATH.
# =============================================================================
TREE="$WORK/tree-main"; mkdir -p "$TREE"
printf 'artifact:rig-9.9.9.sh sha256:abc123\n' > "$TREE/INSTALLED_FROM"
check "matching INSTALLED_FROM passes silently" 0 "" \
  assert_installed_from rig "$TREE" "artifact:rig-9.9.9.sh sha256:abc123"
check "a mismatch refuses — another rig answered on PATH" 1 "FATAL" \
  assert_installed_from rig "$TREE" "local:/opt/rig/versions/9.9.9"
check "…the refusal names the source that was ASKED for" 1 "local:/opt/rig/versions/9.9.9" \
  assert_installed_from rig "$TREE" "local:/opt/rig/versions/9.9.9"
check "…and the source that actually LANDED" 1 "artifact:rig-9.9.9.sh sha256:abc123" \
  assert_installed_from rig "$TREE" "local:/opt/rig/versions/9.9.9"
assert_installed_from rig "$TREE" "local:/opt/rig/versions/9.9.9" 2>"$WORK/from-refusal" >/dev/null
refute "…and it no longer blames a stale export the drill can no longer be given" \
  "export" "$WORK/from-refusal"
check "an unreadable INSTALLED_FROM refuses too — absence is not a match" 1 "<unreadable>" \
  assert_installed_from rig "$WORK/no-such-tree" "artifact:rig-9.9.9.sh sha256:abc123"
check "box keeps the ref-shaped assertion, because box is still installed by ref" 1 "heavy-duty/box@0.10.0" \
  assert_installed_from box "$TREE" "heavy-duty/box@0.10.0"

# =============================================================================
# tree_source_commit + assert_source_commit — "from an artifact built at commit
# X, a run drills the rig built from X", asserted by the drill rather than read
# off a log. The stamp travels with the tree through the staging copy and
# install.sh's own copy, so comparing it end to end is what makes the record
# cite a commit instead of an intention.
# =============================================================================
SC_OK="$WORK/tree-stamped"; mkdir -p "$SC_OK"
printf '21afc76c7fa2e63654df34d5d7a332950f60fb5e\n' > "$SC_OK/SOURCE_COMMIT"
SC_DIRTY="$WORK/tree-dirty"; mkdir -p "$SC_DIRTY"
printf '21afc76c7fa2e63654df34d5d7a332950f60fb5e-dirty\n' > "$SC_DIRTY/SOURCE_COMMIT"
SC_NONE="$WORK/tree-unstamped"; mkdir -p "$SC_NONE"
check "tree_source_commit reads the artifact build's stamp" 0 "21afc76c7fa2e63654df34d5d7a332950f60fb5e" \
  tree_source_commit "$SC_OK"
check "…and carries a dirty build's -dirty suffix through verbatim" 0 "-dirty" \
  tree_source_commit "$SC_DIRTY"
check "a tree no artifact built says (unstamped), never an invented commit" 0 "(unstamped)" \
  tree_source_commit "$SC_NONE"
check "assert_source_commit passes when the stamps agree" 0 "" \
  assert_source_commit "$SC_OK" "21afc76c7fa2e63654df34d5d7a332950f60fb5e"
check "a stamp mismatch is FATAL — the drilled tree is not the shipped tree" 1 "FATAL" \
  assert_source_commit "$SC_OK" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
check "…and the refusal names both commits" 1 "ships in a tree built from deadbeef" \
  assert_source_commit "$SC_OK" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
check "a dirty build cannot pass as its own clean commit" 1 "FATAL" \
  assert_source_commit "$SC_DIRTY" "21afc76c7fa2e63654df34d5d7a332950f60fb5e"
check "two unstamped trees agree — a checkout drilling itself is a real use" 0 "" \
  assert_source_commit "$SC_NONE" "(unstamped)"
check "…but an unstamped install cannot pass for a stamped one" 1 "FATAL" \
  assert_source_commit "$SC_NONE" "21afc76c7fa2e63654df34d5d7a332950f60fb5e"

# =============================================================================
# classify_leg — a loud skip is a SKIP, never a pass (box#153's defect class)
# =============================================================================
printf 'skip: docker not installed — nothing to exercise\n' > "$WORK/out-skip"
printf 'ok: seeded\nok: restored\n---\n14 passed, 0 failed\n' > "$WORK/out-pass"
printf 'FAIL: restore blew up\n' > "$WORK/out-fail"
check "exit 0 + 'skip:' line classifies as skip" 0 "skip" classify_leg 0 "$WORK/out-skip"
check "exit 0, no skip line, classifies as pass" 0 "pass" classify_leg 0 "$WORK/out-pass"
check "non-zero exit classifies as fail" 0 "fail" classify_leg 1 "$WORK/out-fail"
check "a skip line cannot rescue a non-zero exit (fail wins)" 0 "fail" \
  classify_leg 1 "$WORK/out-skip"

# =============================================================================
# capture_state + diff — the idempotence verdict's machinery. The claim in
# #105's acceptance criteria: the assertion is a REAL diff of captured state,
# and it FAILS when convergence is broken — demonstrated here, mechanically,
# on every CI run, by breaking the state between two captures.
# =============================================================================
FIX="$WORK/fix"; mkdir -p "$FIX/sudoers.d"
printf 'role=staging-server root-door=open host=yes join=authkey\n' > "$FIX/role"
printf 'schema=1\nbootstrapped_by=9.9.9\nbootstrapped_at=T\nconverged_by=9.9.9\nconverged_at=T\n' > "$FIX/manifest"
printf 'dan active\nghost revoked\n' > "$FIX/ledger"
printf 'APT::Periodic::Update-Package-Lists "1";\n' > "$FIX/autoup"
printf '127.0.0.1 localhost\n127.0.1.1\tstaging-server\n' > "$FIX/hosts"
printf 'nosuchdrilluser ALL=(ALL) NOPASSWD:ALL\n' > "$FIX/sudoers.d/00-rig-nosuch"
# A stubbed sshd, so the effective-config section is exercised rather than
# skipped on a box with no daemon (repo precedent: test/release.sh's curl).
STUB="$WORK/stub"; mkdir -p "$STUB"
# The single-quoted $SSHD_FIXTURE is the STUB's expansion, not this shell's.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ncat "$SSHD_FIXTURE"\n' > "$STUB/sshd"; chmod +x "$STUB/sshd"
printf 'passwordauthentication no\npermitrootlogin prohibit-password\n' > "$FIX/sshd-T"

cap() {   # cap <outfile> — capture_state against the fixture set
  RIG_ROLE_MARKER="$FIX/role" RIG_MANIFEST="$FIX/manifest" \
  DRILL_LEDGER="$FIX/ledger" DRILL_AUTOUPGRADES="$FIX/autoup" \
  DRILL_ETC_HOSTS="$FIX/hosts" DRILL_SUDOERS_DIR="$FIX/sudoers.d" \
  SSHD_FIXTURE="$FIX/sshd-T" PATH="$STUB:$PATH" \
  bash -c '. "$1"; capture_state "$2"' _ "$FNS" "$2" 2>/dev/null
  :
}
# cap runs capture_state in a child bash so the PATH stub cannot leak into
# this harness; $2 arrives as the capture's outfile.
cap out "$WORK/cap1"
cap out "$WORK/cap2"
check "two captures over untouched state diff EMPTY (the converged verdict)" 0 "" \
  diff -u "$WORK/cap1" "$WORK/cap2"
check "the capture reads the fixtures, not the machine (marker line present)" 0 "role=staging-server" \
  grep -o 'role=staging-server[^"]*' "$WORK/cap1"
check "…the sshd section captured the effective config" 0 "passwordauthentication no" \
  cat "$WORK/cap1"
check "…a ledger user with no account reads as one, deterministically" 0 "(no account)" \
  cat "$WORK/cap1"

# Break convergence: the re-run "changed" the role marker and root's door.
printf 'role=staging-server root-door=closed host=yes join=authkey\n' > "$FIX/role"
printf 'passwordauthentication yes\npermitrootlogin prohibit-password\n' > "$FIX/sshd-T"
cap out "$WORK/cap3"
check "a broken convergence makes the diff NON-empty — the assertion can fail" 1 "root-door=closed" \
  diff -u "$WORK/cap1" "$WORK/cap3"
check "…and the diff names the drifted sshd keyword, not just 'differs'" 1 "passwordauthentication yes" \
  diff -u "$WORK/cap1" "$WORK/cap3"

# =============================================================================
# emit_record — the record is drills/README.md's shape, and it cannot lie:
# a failed run still emits, a skipped leg is named, no clean-sweep reading.
# =============================================================================
emit() {   # emit <outfile> — emit_record with the harness globals staged
  DRILL_VERSION="9.9.9" RUN_ID="drill-2026-01-01-a" \
  RIG_SOURCE_COMMIT="21afc76c7fa2e63654df34d5d7a332950f60fb5e-dirty" \
  RIG_FROM="artifact:rig-9.9.9.sh sha256:abc123" \
  BOXREF="0.4.0" BOX_SHA="1a2b3c4" \
  TPLREPO="heavy-duty/rig-templates" TPLREF="9f8e7d6c5b4a39281706f5e4d3c2b1a098765432" TPL_SHA="9f8e7d6" TPL_SOURCE="snapshot" \
  bash -c '
    . "$1"
    pass=12 fail=1 skipped=1
    findings=("FAIL: Docker prerequisite did not start" "SKIP: db round-trip did not run — no Docker daemon" "NOTE: something worth a line")
    LEG_NAMES=("convergence — bootstrap staging-server reaches its role" "re-converge (idempotence)" "test/db-integration.sh")
    LEG_RESULTS=("PASS (312s)" "clean, no changes" "SKIPPED — no Docker daemon")
    emit_record "$2"
  ' _ "$FNS" "$2"
}
emit out "$WORK/record.md"
check "record: the version-and-date heading" 0 "# Release drill — 9.9.9 — " head -1 "$WORK/record.md"
check "record: the run ID that joins the family's records" 0 "Run ID: drill-2026-01-01-a" cat "$WORK/record.md"
check "record: the rig fields are the installed tree's, not an argument's (#220)" 0 \
  "Rig under drill: 9.9.9, built from 21afc76c7fa2e63654df34d5d7a332950f60fb5e-dirty — artifact:rig-9.9.9.sh sha256:abc123." \
  cat "$WORK/record.md"
check "record: an artifact built from a dirty work tree is stamped -dirty" 0 "-dirty" cat "$WORK/record.md"
refute "record: no rig ref field survives — there is no rig ref to cite" "RIG_REF=" "$WORK/record.md"
check "record: box still cites a ref, because box is still installed by one" 0 "Candidate box: box@1a2b3c4 (BOX_REF=0.4.0)." cat "$WORK/record.md"
check "record: the template registry SHA and actual source ride alongside the pair (#110/#153)" 0 "rig-templates@9f8e7d6 (ref 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432, snapshot)" cat "$WORK/record.md"
check "record: one table row per leg, result verbatim" 0 "| re-converge (idempotence) | clean, no changes |" cat "$WORK/record.md"
check "record: the numbers, skips counted apart from passes" 0 "12 passed, 1 failed, 1 skipped" cat "$WORK/record.md"
check "record: a FAILED run still names what failed (evidence, not success)" 0 "FAIL: Docker prerequisite did not start" cat "$WORK/record.md"
check "record: a skipped leg is stated as NOT run, by name" 0 "SKIP: db round-trip" cat "$WORK/record.md"
check "record: the skip section says the record is not evidence for it" 0 "not evidence" cat "$WORK/record.md"
check "record: the isolation boundary is named as box's, in words" 0 "NOT asserted here" cat "$WORK/record.md"
refute "record with a skip cannot read as a clean sweep" "Failed: nothing" "$WORK/record.md"
refute "notes are findings for the log, not failures for the record" "NOTE: something" "$WORK/record.md"

# The all-green shape: says so plainly, and only then. No RIG_SOURCE_COMMIT or
# RIG_FROM here on purpose — the emitter's own defaults have to hold, because a
# record whose rig line went blank is the failure mode this file exists for.
DRILL_VERSION="9.9.9" RUN_ID="drill-2026-01-01-a" \
BOXREF="0.4.0" BOX_SHA="1a2b3c4" \
bash -c '
  . "$1"
  pass=20 fail=0 skipped=0
  findings=()
  LEG_NAMES=("convergence" "re-converge (idempotence)")
  LEG_RESULTS=("PASS" "clean, no changes")
  emit_record "$2"
' _ "$FNS" "$WORK/record-green.md"
check "an all-green record says every leg ran and passed" 0 "Every leg ran and every check passed" \
  cat "$WORK/record-green.md"
check "an unmeasured rig line degrades to (unstamped), never to a blank field" 0 \
  "Rig under drill: 9.9.9, built from (unstamped) — unknown." cat "$WORK/record-green.md"
check "the default record path is independent of a checkout" 0 "/root/drills/9.9.9.md" \
  default_record_path 9.9.9
printf 'ssh-ed25519 AAAAone dan@laptop\nssh-ed25519 AAAAtwo dan@desktop\n' > "$WORK/github.keys"
# The positional parameters belong to the child bash, intentionally.
# shellcheck disable=SC2016
check "GitHub keys render one admin,box ledger line per key" 0 "danmt admin,box ssh-ed25519 AAAAtwo" \
  bash -c '. "$1"; render_github_users danmt < "$2"' _ "$FNS" "$WORK/github.keys"
publish_record "$WORK/record-green.md" > "$WORK/published-record"
check "the final record payload prints its path" 0 "record written: $WORK/record-green.md" \
  cat "$WORK/published-record"
check "the final record payload includes the full record" 0 "Every leg ran and every check passed" \
  cat "$WORK/published-record"

# =============================================================================
# the shipped script itself
# =============================================================================
# The instrument is the entry point now (#220 D2), so its MODE is part of the
# contract: drill/README.md's *Running it*, the script header and usage() all
# print '<root>/current/drill/drill.sh' as a path to type, and a tree that
# ships it 644 answers that with exit 126. Nothing downstream restores the bit
# — install.sh's set_exec() owns bin/rig and commands/*.sh only, and
# dist/make-installer.sh chmods the artifact, not its payload — so the bit has
# to be in the tree, and the recorded mode is what git archive, the artifact's
# tar and install.sh's copy all carry through untouched.
check "the shipped drill script is executable — the documented path is typed, not sourced" 0 "" \
  test -x "$ROOT/drill/drill.sh"
drill_recorded_mode() { git -C "$ROOT" ls-files -s -- drill/drill.sh | cut -d' ' -f1; }
# The staging copy is the one pipeline in this file whose verdict must be both
# tars'. Without pipefail a source-side failure that still emits a valid
# partial archive — an unreadable file is enough — reads as success, and the
# next statement is the rm -rf. The file cannot take pipefail globally (see its
# header), so the subshell is the shape, and the shape is what is asserted:
# there is no function here to extract and drive.
staging_pipeline_is_pipefailed() {
  # The single quotes are the point: $SELF_TREE is matched literally, as the
  # shipped bytes spell it, not expanded here.
  # shellcheck disable=SC2016
  grep -qF 'if ! ( set -o pipefail; tar -C "$SELF_TREE"' "$ROOT/drill/drill.sh"
}
check "the staging copy's verdict is both tars', not just the extractor's" 0 "" \
  staging_pipeline_is_pipefailed
# The wipe operand and install.sh's destination have to be ONE value, not two
# separately-derived ones that agree: install.sh reads ${RIG_HOME:-…} itself.
# So the drill canonicalizes, judges the canonical value, exports THAT, and
# only then wipes — and the ORDER is the whole of the guarantee. Canonicalizing
# after the export would leave install.sh writing to the spelling while rm -rf
# took the resolved path, which is worse than either alone. Order is what is
# asserted; like the pipeline above there is no function here to extract.
canonicalize_precedes_export_and_wipe() {
  local canon_at export_at wipe_at
  # Single-quoted: the shipped bytes are matched literally, not expanded here.
  # shellcheck disable=SC2016
  canon_at="$(grep -nF 'RIG_HOME="$(realpath -m' "$ROOT/drill/drill.sh" | head -n1 | cut -d: -f1)"
  export_at="$(grep -nxF 'export RIG_HOME' "$ROOT/drill/drill.sh" | head -n1 | cut -d: -f1)"
  # shellcheck disable=SC2016
  wipe_at="$(grep -nF 'rm -rf "$RIG_HOME" "$RIG_BIN/rig"' "$ROOT/drill/drill.sh" | head -n1 | cut -d: -f1)"
  [ -n "$canon_at" ] && [ -n "$export_at" ] && [ -n "$wipe_at" ] &&
    [ "$canon_at" -lt "$export_at" ] && [ "$export_at" -lt "$wipe_at" ]
}
check "the root is canonicalized before it is exported, and exported before it is wiped" 0 "" \
  canonicalize_precedes_export_and_wipe
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  check "…and the bit is recorded in the tree, not just on this working copy" 0 "100755" \
    drill_recorded_mode
fi

# Arg refusals fire before the root check (repo doctrine, bootstrap.sh:114),
# which is what makes them provable here without a throwaway machine.
check "drill.sh refuses to run without box's ref pinned (#103)" 2 "--box-ref" \
  env -u BOX_REF bash "$ROOT/drill/drill.sh" --yes
# The instrument's own name for its subject must not come back by any route —
# not a flag, not a variable, not a comment. #220's acceptance criterion,
# mechanised so a re-introduction reds here rather than in a reviewer's eye.
drill_names_no_removed_rig_flag() {
  grep -c 'RIG_REPO\|RIG_REF\|rig-repo\|rig-ref' "$ROOT/drill/drill.sh" || true
}
check "the removed rig repo/ref names survive nowhere in the instrument, comments included" 0 "0" \
  drill_names_no_removed_rig_flag
drill_help_has_removed_rig_repo_flag() { bash "$ROOT/drill/drill.sh" --help | grep -q -- '--rig-repo'; }
drill_help_has_removed_rig_ref_flag() { bash "$ROOT/drill/drill.sh" --help | grep -q -- '--rig-ref'; }
check "drill.sh help names no removed --rig-repo flag" 1 "" drill_help_has_removed_rig_repo_flag
check "drill.sh help names no removed --rig-ref flag" 1 "" drill_help_has_removed_rig_ref_flag
drill_help_has_retired_flag() { bash "$ROOT/drill/drill.sh" --help | grep -q -- '--runner-'; }
drill_help_has_retired_coolify_flag() { bash "$ROOT/drill/drill.sh" --help | grep -q -- '--coolify-version'; }
drill_help_spills_internal_commentary() {
  bash "$ROOT/drill/drill.sh" --help | grep -q "probe && ok"
}
drill_process_substitution_help() {
  bash <(cat "$ROOT/drill/drill.sh") --help
}
drill_leg_count() { grep -Ec '^phase "Leg [0-9]+' "${1:-$ROOT/drill/drill.sh}"; }
docker_source_precedes_db() {
  local docker_line db_line
  docker_line="$(grep -nF 'apt-get install -y docker.io' "$ROOT/drill/drill.sh" | cut -d: -f1)"
  db_line="$(grep -nF 'phase "Leg 2 — db dump/restore round-trip' "$ROOT/drill/drill.sh" | cut -d: -f1)"
  [ -n "$docker_line" ] && [ -n "$db_line" ] && [ "$docker_line" -lt "$db_line" ]
}
DRILL_LEG_COUNT_FIXTURE="$WORK/three-numbered-legs.sh"
printf '%s\n' \
  'phase "Leg 1 — one"' \
  'phase "Leg 2 — two"' \
  'phase "Leg 3 — three"' > "$DRILL_LEG_COUNT_FIXTURE"
check "drill.sh help names no retired runner flag" 1 "" drill_help_has_retired_flag
check "drill.sh help names no retired Coolify flag" 1 "" drill_help_has_retired_coolify_flag
check "drill.sh help ends before internal commentary" 1 "" drill_help_spills_internal_commentary
# --help stays cheap: it answers before the pre-flight resolves a subject, so a
# reader with no tree yet still gets told how to get one.
check "drill.sh help works through process substitution" 0 "THROWAWAY" \
  drill_process_substitution_help
check "…and the help says where the subject comes from now" 0 "the tree this script is part of" \
  bash "$ROOT/drill/drill.sh" --help
check "drill.sh runs exactly three numbered legs (Leg 3: the tenant, #229/#230)" 0 "3" drill_leg_count
check "drill leg counter sees a synthetic third leg" 0 "3" \
  drill_leg_count "$DRILL_LEG_COUNT_FIXTURE"
check "drill installs Docker directly before the db leg" 0 "" docker_source_precedes_db
check "…and the refusal shows that the ref is missing" 2 "<unset>" \
  env -u BOX_REF bash "$ROOT/drill/drill.sh" --yes
# The subject refusal, on the shipped script: a drill script with no rig tree
# around it stops before it can spend anything. It fires after box's ref, so
# the invocation pins one.
drill_outside_a_rig_tree() {
  mkdir -p "$WORK/lonely/drill"
  cp "$ROOT/drill/drill.sh" "$WORK/lonely/drill/drill.sh"
  bash "$WORK/lonely/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
}
check "a drill script with no rig tree around it refuses — there is nothing to drill" 2 \
  "cannot find the rig tree this script ships in" drill_outside_a_rig_tree
check "…and the refusal points at the artifact as the way to get one on the machine" 2 \
  "dist/release-artifact.sh" drill_outside_a_rig_tree
check "an install root that is not sane is refused before anything is wiped" 2 "not a sane install root" \
  env RIG_HOME=/ bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
# THE GATE IS ON THE RESOLVED ROOT, NOT ON ITS SPELLING (#220 round 2). The
# depth rule is a glob and counts slashes in a string; `rm -rf` operates on
# what that string RESOLVES to. A '..' component has two components as spelled
# and can be anything at all — '/opt/rig/../..' IS the '/' the case above
# refuses. These fire on the spelling so a re-introduction reds here rather
# than on a drill host, and they read the RESOLVED path out of the refusal so
# what they pin is the canonicalization and not one more literal.
check "a traversal spelling of / is refused — the gate judges the resolved root" 2 \
  "not a sane install root" \
  env RIG_HOME=/opt/rig/../.. bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
check "…and the refusal names what it resolved to, not only what was typed" 2 \
  "it resolves to /, and that is the path rm -rf would have taken" \
  env RIG_HOME=/opt/rig/../.. bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
check "a traversal spelling of a one-component root is refused the same way" 2 \
  "it resolves to /etc" \
  env RIG_HOME=/tmp/../etc bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
# Resolution cannot be trusted with the absolute half, so the absolute half is
# asked first: realpath -m resolves a relative root against $PWD and returns
# something absolute and deep, which would PROMOTE a refused spelling into an
# accepted one. This case reds on a gate that canonicalizes before it checks
# absoluteness — the shape the first cut of this fix had.
check "a relative install root is refused before it is resolved against \$PWD" 2 \
  "refused BEFORE it is resolved" \
  env RIG_HOME=relative/path bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
# The other half: it stays a DEPTH rule and does not become an allowlist. A
# traversal spelling that resolves deep enough is as fine as one typed flat,
# and gets as far as the users file, which is the next gate along.
check "a traversal spelling that resolves deep enough still passes the gate" 2 \
  "cannot read users file" \
  env RIG_HOME=/tmp/../tmp/drill-gate-probe/root bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
check "a tenant role is refused — the drill converges machines, not guests" 2 "not a machine role" \
  bash "$ROOT/drill/drill.sh" --box-ref b --role claude-box --yes
check "no users source is a refusal" 2 "exactly one of --users <path> or --users-from-github <handle>" \
  bash "$ROOT/drill/drill.sh" --box-ref b --yes
check "both users sources are refused" 2 "exactly one of --users <path> or --users-from-github <handle>" \
  bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --users-from-github danmt --yes
check "an unreadable users file dies before anything is spent" 2 "cannot read users file" \
  bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
check "a GitHub users handle must also be a valid rig username" 2 "valid rig username" \
  bash "$ROOT/drill/drill.sh" --box-ref b --users-from-github BadHandle --yes
check "root is refused as a GitHub-derived operator during pre-flight" 2 "root is reserved" \
  bash "$ROOT/drill/drill.sh" --box-ref b --users-from-github root --yes
check "a non-admin SUDO_USER is refused before its users source is read" 2 "incus exec <box> -- bash -l" \
  env SUDO_USER=dev bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
check "the SUDO_USER refusal also names the environment fix" 2 "unset SUDO_USER" \
  env SUDO_USER=dev bash "$ROOT/drill/drill.sh" --box-ref b --users "$WORK/no-such-users" --yes
check "an unknown flag dies loudly, exit 2" 2 "unknown option" \
  bash "$ROOT/drill/drill.sh" --frobnicate
check "--help prints the header and exits 0" 0 "THROWAWAY" \
  bash "$ROOT/drill/drill.sh" --help

echo "---"
# Leg 3 converges a TENANT inside a box — where #229/#230 live — from the
# installed tree's own template snapshot, and diffs a second converge.
# shellcheck disable=SC2016  # literal source text
check "Leg 3 reads the tenant definition from the installed snapshot" 0 "" \
  grep -qF 'find "$RIG_TREE"/templates@*/"$TENANT"' "$ROOT/drill/drill.sh"
# shellcheck disable=SC2016  # literal source text
check "…carries the installed tree in with box cp, offline" 0 "" \
  grep -qF 'box cp "$RIG_TREE" "$tenant_box:/root/rig-src"' "$ROOT/drill/drill.sh"
check "…and asserts swap only where the box is a VM" 0 "" \
  grep -qF 'skip "SWAP_SIZE: the tenant box is a container' "$ROOT/drill/drill.sh"
check "drill.sh help names --tenant" 0 "--tenant" bash "$ROOT/drill/drill.sh" --help

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

