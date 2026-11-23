#!/usr/bin/env bash
# drill/drill.sh — rig's release drill: the instrument behind drills/README.md.
#
#   ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY Debian machine you
#     can format. It wipes any installed rig and reinstalls THE TREE THIS
#     SCRIPT SHIPS IN, hardens sshd, sets the hostname, joins the tailnet,
#     installs box and its Incus stack, and installs Docker for the db
#     round-trip. Never run it on a machine you care about.
#
#   read -rs TS_AUTHKEY && export TS_AUTHKEY   # the key never goes on a command line
#   /root/.local/share/rig/current/drill/drill.sh \
#     --box-ref 0.10.0 --users-from-github danmt \
#     --run-id drill-2026-07-24-a --yes
#   (--box-ref is a tag: since #103 the box that ships is the BOX_RELEASE tag.)
#
# THE SUBJECT IS THE TREE THE HARNESS IS IN (#220). There is no flag pointing
# the drill at a tree somewhere else, because there is no correct use of one:
# separating the instrument from its subject has only ever produced mismatch,
# and a record naming what was REQUESTED rather than what RAN proves nothing
# later. Get the candidate onto the machine — `dist/release-artifact.sh` builds
# one scp-able file — install it, and run the drill out of what landed.
# rig's drill asserts CONVERGENCE — a machine reaches its role, idempotently.
# The legs (drills/README.md, issue #105):
#
#   1. convergence + idempotence — `rig bootstrap <role> --users <path>`
#      reaches the declared role; a re-run produces an EMPTY state diff,
#      mechanically, never by eye. Rides along: the --host yes assertions
#      (the pinned box installed, its host stack stands — and it STOPS there;
#      the isolation boundary is box's drill's assertion, not this one's).
#   2. db — the real dump/restore round-trip, test/db-integration.sh.
#
# Execution order is 1, 2. The drill installs Debian's Docker package directly
# before leg 2 so the db round-trip is real even on a pristine machine. Docker
# provisioning is a prerequisite, not a rig surface or a separate evidence leg.
#
# Exit 0 = no check failed. A FAILED drill still emits a complete record —
# the gate wants evidence, not success — and skipped legs are counted and
# named, never folded into the passes (heavy-duty/box#153's defect class).
#
# The file is one long 'probe && ok "…" || no "…"'. ok/no always return 0, so
# the C-may-run-when-A-is-true trap SC2015 warns about cannot fire here.
# shellcheck disable=SC2015
#
# NOT -e: a failing check is data, not a crash — a drill that aborts on its
# first failure reports one problem per afternoon. NOT pipefail: checks of the
# 'refusal 2>&1 | grep -q text' shape have a left side that exits non-zero BY
# DESIGN, and 'grep -q' SIGPIPEs the left side on early match — box's first
# live run turned both into false FAILs. The pipeline verdict must be grep's
# alone. (box drill/drill.sh's header, the discipline #105 prescribes.)
set -u

BOXREPO="${BOX_REPO:-heavy-duty/box}"
BOXREF="${BOX_REF:-}"
# The template registry the converge will read (#110). No explicitness
# demand here, unlike box's ref above: the DEFAULT is already a pin — the
# drilled tree's RIG_TEMPLATES_PIN, read after install from what actually
# landed — so an unset override means "the ref the release will really use",
# not "whatever main was that afternoon".
TPLREPO="${RIG_TEMPLATES_REPO:-heavy-duty/rig-templates}"
TPLREF="${RIG_TEMPLATES_REF:-}"
TPL_SHA=""
TPL_SOURCE="fetched"
ROLE=staging-server
USERS_FILE="${DRILL_USERS_FILE:-}"
USERS_FROM_GITHUB=""
GENERATED_USERS_FILE=""
RUN_ID="${DRILL_RUN_ID:-drill-$(date -u +%F)}"
RECORD="${DRILL_RECORD:-}"
YES=0
# The tree under drill. SELF_* is measured off the tree this script ships in,
# before anything is installed: it is what gets staged, installed and asserted
# against. RIG_* is measured off the tree that actually LANDED, and it is what
# the record cites — the two are asserted equal rather than assumed, which is
# the whole of #220's "measured, never argued". Defaulted here so the record
# emitter stays drivable from fixtures.
SELF_TREE=""
SELF_VERSION="unknown"
SELF_FROM="unknown"
SELF_SOURCE_COMMIT="(unstamped)"
RIG_FROM="unknown"
RIG_SOURCE_COMMIT="(unstamped)"

usage() {
  cat <<'EOF'
drill/drill.sh — rig's release drill: the instrument behind drills/README.md.

  ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY Debian machine you
    can format. It wipes any installed rig and reinstalls THE TREE THIS
    SCRIPT SHIPS IN, hardens sshd, sets the hostname, joins the tailnet,
    installs box and its Incus stack, and installs Docker for the db
    round-trip. Never run it on a machine you care about.

  read -rs TS_AUTHKEY && export TS_AUTHKEY   # the key never goes on a command line
  /root/.local/share/rig/current/drill/drill.sh \
    --box-ref 0.10.0 --users-from-github danmt \
    --run-id drill-2026-07-24-a --yes
  (--box-ref is a tag: since #103 the box that ships is the BOX_RELEASE tag.)

The subject is the tree this script is part of — there is no flag naming one
somewhere else. Put the candidate on the machine first: build a scp-able
installer with dist/release-artifact.sh, run it, then run this drill out of
the tree it installed.

Options:
  --box-repo <owner/repo>       box repository (default: heavy-duty/box)
  --box-ref <tag>               required box release tag
  --role <machine-role>         role to converge (default: staging-server)
  --users <path>                existing rig users ledger
  --users-from-github <handle>  render an admin,box ledger from public keys
  --run-id <id>                 shared drill run ID
  --record <path>               record destination
  --yes, -y                     skip the destructive confirmation
  --help, -h                    show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --box-repo) BOXREPO="$2"; shift 2 ;;
    --box-ref) BOXREF="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --users) USERS_FILE="$2"; shift 2 ;;
    --users-from-github) USERS_FROM_GITHUB="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --record) RECORD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "drill: unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# --- the reporting verbs (box drill/drill.sh:52-58, the parts worth copying) --
# ok/no/skip/note always return 0: the body stays one long sequence of
# 'probe && ok || no' without fighting the shell. SKIP is its own verb and its
# own counter — a leg that did not run must be visually and arithmetically
# distinct from one that passed (box#153's defect class: a silent skip reads
# as a pass in the record, months later).
pass=0; fail=0; skipped=0; findings=()
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); findings+=("FAIL: $*"); }
skip() { printf '  \033[35mSKIP\033[0m  %s\n' "$*"; skipped=$((skipped + 1)); findings+=("SKIP: $*"); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$*"; findings+=("NOTE: $*"); }
inf()  { printf '        %s\n' "$*"; }
phase(){ printf '\n\033[1m══ %s\033[0m\n' "$*"; }

# The record's leg table, appended as legs run. One row per leg, result text
# written at the moment the leg's verdict is known — never reconstructed from
# memory at the end (an invented number is worse than no number).
LEG_NAMES=(); LEG_RESULTS=()
leg() { LEG_NAMES+=("$1"); LEG_RESULTS+=("$2"); }

# Everything this run creates outside the machine's own state, removed on any
# exit. ONE trap, appended to: a second `trap … EXIT` silently replaces the
# first, and this run now has two things to clean up — the rendered ledger and
# the staged tree — either of which would otherwise be the one left behind.
CLEANUP_PATHS=()
cleanup() { [ "${#CLEANUP_PATHS[@]}" -eq 0 ] || rm -rf "${CLEANUP_PATHS[@]}"; }
trap cleanup EXIT

# run_logged <log> <cmd...> — run a long command with its narration in a file
# and a dot every 5s on the terminal: a silent multi-minute apt/install run is
# indistinguishable from a wedge, and that ambiguity has cost box whole
# evenings. Returns the command's exit code.
run_logged() {
  local log="$1"; shift
  inf "watch it live in another terminal:  tail -f $log"
  "$@" >"$log" 2>&1 </dev/null &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 5; done
  printf '\n'
  wait "$pid"
}

# tree_of <cli-path> — the versioned install tree a CLI's symlink chain lands
# in. Both rig and box install as <root>/versions/<v>/bin/<cli> behind a
# 'current' link, so the tree is two dirnames above the resolved binary —
# derived from the chain itself, never from a hardcoded install root (root vs
# user installs put the root in different places).
tree_of() {
  local real
  real="$(readlink -f "$1" 2>/dev/null)"
  # -e as well as -n: GNU readlink -f resolves a path whose LAST component
  # does not exist (exit 0), so a dangling link would hand back a tree that
  # is not there.
  { [ -n "$real" ] && [ -e "$real" ]; } || return 1
  dirname "$(dirname "$real")"
}

# self_tree <this-script's-path> — the rig tree this drill SHIPS IN, which is
# the tree it drills (#220). drill/drill.sh sits one directory below its tree's
# root, so the root is the parent of the script's directory — and it is only a
# rig tree if it looks like one, which is what turns "I could not find it" into
# a refusal instead of a guess.
#
# The refusal it enables is the whole point of the check. Piped or process-
# substituted, the script's path is a /dev/fd pipe with no directory behind it
# and no tree above that; a bare copy dropped into /root has a directory but no
# tree. Both used to be legitimate entry paths, because the subject arrived
# over the network; now neither has anything to drill, and inventing a subject
# there would put a record's name on a tree nobody chose.
# readlink -f FIRST, like tree_of: the drill's own advertised entry path runs
# through the install's 'current' symlink, and a logical resolution of that
# hands back '<root>/current' — a directory rig_home_of cannot read a versioned
# root out of, so the drill would wipe the installer's default root while the
# install re-created this one. The physical tree is the only one both agree on.
# -f as well as -n, because readlink -f resolves a path whose last component
# does not exist and would otherwise promote a missing script to a tree.
self_tree() {
  local src="$1" real d
  real="$(readlink -f "$src" 2>/dev/null)"
  { [ -n "$real" ] && [ -f "$real" ]; } || return 1
  d="$(dirname "$(dirname "$real")")"
  { [ -f "$d/install.sh" ] && [ -f "$d/VERSION" ] && [ -f "$d/bin/rig" ]; } || return 1
  printf '%s' "$d"
}

# rig_home_of <tree> — the install root a VERSIONED tree sits in, since
# install.sh lays every install out as <root>/versions/<v>. Empty (return 1)
# for a tree that is not installed — a checkout — where the installer's own
# default root is the right answer and this must not invent another.
#
# The drill needs this because it wipes rig before reinstalling: the root it
# wipes has to be the root the install will re-create, or the drill measures
# one install while leaving another on the machine.
rig_home_of() {
  local parent
  parent="$(dirname "$1")"
  [ "$(basename "$parent")" = versions ] || return 1
  dirname "$parent"
}

# assert_installed_from <what> <tree> <want> — ASSERT WHAT LANDED, never trust
# that the install obeyed.
#
# ITS ORIGINAL REASON IS GONE AND IT KEEPS ITS PLACE ON A NARROWER ONE (#220).
# It was written to catch a stale ref exported into the drill's environment:
# an installer told nothing falls back to a sane default, and a drill that
# thinks it exercised the candidate but actually got the default has proven
# nothing while leaving a record that LOOKS like evidence. rig no longer has a
# ref to be stale about — the subject is the tree the harness is in.
#
# What survives is the claim the drill still cannot do without: THE INSTALL
# LANDED WHERE WE THINK IT DID, FROM THE SOURCE WE THINK IT DID. Two live ways
# for that to be false remain. box is still installed by ref and still defaults
# to the BOX_RELEASE pin when BOX_REF does not reach it. And rig's own install
# is asserted through whatever answers on PATH, which is not necessarily the
# install this drill just performed — a second rig on the machine, an older
# symlink healed to a different root. Either way every result below would
# describe a tree that is not the one under drill.
assert_installed_from() {
  local what="$1" tree="$2" want="$3" got
  got="$(cat "$tree/INSTALLED_FROM" 2>/dev/null || echo '<unreadable>')"
  if [ "$got" != "$want" ]; then
    printf 'drill: FATAL — asked to install %s from %s, but the installed tree says %s.\n' "$what" "$want" "$got" >&2
    printf '  (tree: %s)\n' "$tree" >&2
    printf '  A drill that silently drills the wrong code is worse than one that fails:\n' >&2
    printf '  every result below would describe a tree that is not the one under drill.\n' >&2
    printf '  Check what answers on PATH and which install root it resolves to, remove\n' >&2
    printf '  the rig that is not this one, and re-run.\n' >&2
    return 1
  fi
  return 0
}

# tree_source_commit <tree> — the commit an artifact build stamped into the
# tree it packed (dist/release-artifact.sh writes SOURCE_COMMIT), suffixed
# '-dirty' when that build's work tree was dirty. A tree no artifact built — a
# plain checkout — is '(unstamped)', said in those words: a record that cannot
# be reproduced says so on its face rather than inventing a commit.
tree_source_commit() {
  local sc
  sc="$(head -n1 "$1/SOURCE_COMMIT" 2>/dev/null || true)"
  printf '%s' "${sc:-(unstamped)}"
}

# assert_source_commit <tree> <want> — THE DRILLED TREE IS THE TREE THAT
# SHIPPED, asserted rather than read off a log. The install is a copy of a
# copy: staged out of this script's own tree, then packed and unpacked again by
# install.sh, so "the artifact I built at commit X is the rig that got drilled"
# is a claim with three places to go wrong. The build stamp travels with the
# tree through all of them, so comparing it end to end is what makes the record
# say something about a commit instead of about an intention.
#
# An unstamped tree compares equal to an unstamped tree, which is right: a
# checkout drilling itself is a real use, and it is recorded as unreproducible
# rather than refused.
assert_source_commit() {
  local tree="$1" want="$2" got
  got="$(tree_source_commit "$tree")"
  if [ "$got" != "$want" ]; then
    printf 'drill: FATAL — this drill ships in a tree built from %s, but the installed tree was built from %s.\n' "$want" "$got" >&2
    printf '  (tree: %s)\n' "$tree" >&2
    printf '  The drill installs the tree it ships in, so these are the same commit or\n' >&2
    printf '  the install did not come from here. Every result below would be evidence\n' >&2
    printf '  for a commit nobody chose to drill.\n' >&2
    return 1
  fi
  return 0
}

# classify_leg <rc> <outfile> — pass | skip | fail. The skip contract is
# test/db-integration.sh's, copied carefully: it skips CLEANLY (exit 0) with a
# 'skip: <reason>' line when it cannot run, so exit code alone reads a
# not-run leg as a pass. The reason line is the verdict's tiebreaker; a
# non-zero exit is a fail whatever the output says (a die after a skip line
# would be a broken harness, not a skip).
classify_leg() {
  local rc="$1" out="$2"
  if [ "$rc" -eq 0 ] && grep -q '^skip:' "$out" 2>/dev/null; then
    printf 'skip'
  elif [ "$rc" -eq 0 ]; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

# capture_state <outfile> — the convergent surface bootstrap owns, as one
# diffable text file. Leg 1's idempotence claim is decided by capturing this
# BEFORE and AFTER the re-run and diffing — mechanically, because idempotence
# is the single easiest property to convince yourself of by eye (#105).
#
# What is captured is what bootstrap CONVERGES, nothing that legitimately
# moves between two back-to-back runs: no package lists (unattended-upgrades
# may act between captures), no clocks. The manifest is included WHOLE on
# purpose — lib/manifest.sh's contract is that a same-version re-run renders
# byte-identical content (converged_at tracks the version, not the run), so
# the diff ENFORCES that contract instead of exempting it.
#
# Every path is overridable so test/drill.sh proves the capture-and-diff
# machinery against fixtures, without root (repo precedent: RIG_ROLE_MARKER,
# RIG_MANIFEST). Absent files and commands degrade to a deterministic
# '(absent)' — a capture must never fail, only describe.
capture_state() {
  local out="$1" marker manifest ledger autoup hosts u state home keys
  marker="${RIG_ROLE_MARKER:-/etc/rig/role}"
  manifest="${RIG_MANIFEST:-/etc/rig/manifest}"
  ledger="${DRILL_LEDGER:-/etc/rig/users}"
  autoup="${DRILL_AUTOUPGRADES:-/etc/apt/apt.conf.d/20auto-upgrades}"
  hosts="${DRILL_ETC_HOSTS:-/etc/hosts}"
  {
    printf 'hostname: %s\n' "$(hostname 2>/dev/null || echo '(absent)')"
    printf 'hosts.127.0.1.1: %s\n' "$(grep -E '^127\.0\.1\.1[[:space:]]' "$hosts" 2>/dev/null || echo '(absent)')"
    printf 'role-marker: %s\n' "$(cat "$marker" 2>/dev/null || echo '(absent)')"
    printf 'manifest:\n'
    sed 's/^/  /' "$manifest" 2>/dev/null || printf '  (absent)\n'
    printf 'auto-upgrades:\n'
    sed 's/^/  /' "$autoup" 2>/dev/null || printf '  (absent)\n'
    printf 'sshd-effective:\n'
    if command -v sshd >/dev/null 2>&1; then
      sshd -T 2>/dev/null | sort | sed 's/^/  /' || printf '  (sshd -T failed)\n'
    else
      printf '  (sshd absent)\n'
    fi
    # Self's Tags is the FIRST occurrence in the status JSON (Self serializes
    # before Peer). Tags only, nothing livelier: peers joining, IPs renewing
    # or a backend-state flap between two captures is not a convergence diff
    # on this box, and a capture that can move on its own poisons the
    # idempotence verdict with noise.
    printf 'tailscale.self.tags: %s\n' "$(tailscale status --json 2>/dev/null | tr -d '\n ' | grep -o '"Tags":\[[^]]*\]' | head -n1 || true)"
    printf 'users-ledger:\n'
    sed 's/^/  /' "$ledger" 2>/dev/null || printf '  (absent)\n'
    # Per-operator effective state: the account, its groups, its lock state,
    # its keys. sha256 of authorized_keys, not the keys themselves — the
    # capture may end up quoted in a record and keys are long, not secret.
    while read -r u state; do
      [ -n "${u:-}" ] || continue
      if ! id -u "$u" >/dev/null 2>&1; then
        printf 'user.%s: (no account)\n' "$u"
        continue
      fi
      printf 'user.%s: state=%s groups=%s lock=%s\n' "$u" "${state:-active}" \
        "$(id -Gn "$u" 2>/dev/null | tr ' ' ',')" \
        "$(passwd -S "$u" 2>/dev/null | awk '{print $2}' || echo '?')"
      home="$(getent passwd "$u" | cut -d: -f6)"
      keys="$home/.ssh/authorized_keys"
      printf 'user.%s.authorized_keys: %s\n' "$u" \
        "$(sha256sum "$keys" 2>/dev/null | cut -d' ' -f1 || echo '(none)')"
    done < <(cat "$ledger" 2>/dev/null)
    printf 'sudoers.d:\n'
    find "${DRILL_SUDOERS_DIR:-/etc/sudoers.d}" -maxdepth 1 -type f 2>/dev/null | sort \
      | while read -r u; do printf '  %s %s\n' "$(sha256sum "$u" | cut -d' ' -f1)" "$u"; done
    printf 'box: %s\n' "$(command -v box 2>/dev/null || echo '(absent)')"
  } > "$out"
}

# ref_sha <owner/repo> <ref> — the commit the record cites FOR THE THINGS THAT
# ARE STILL FETCHED BY REF: box, and the template registry. rig is not among
# them any more — its commit comes off the installed tree's own build stamp
# (#220) — but box is still installed over the network at --box-ref and the
# registry is still resolved from a pin, so both still owe the record a SHA.
# Tags outrank branches (the installer's own precedence, install.sh:117-120).
# Resolved once up front and reused, so the record and the install describe the
# same instant even if the branch moves mid-drill. Empty on failure — including
# on a machine with no git, which a throwaway Debian may well be — and the
# record then says 'unresolved' rather than inventing one.
ref_sha() {
  local sha
  sha="$(git ls-remote "https://github.com/$1" "refs/tags/$2" 2>/dev/null | head -n1 | cut -f1)"
  [ -n "$sha" ] || sha="$(git ls-remote "https://github.com/$1" "refs/heads/$2" 2>/dev/null | head -n1 | cut -f1)"
  printf '%s' "${sha:0:7}"
}

# default_record_path <version> — deliberately NOT beside the instrument. The
# drill now ships inside the tree it installs (#220), so the drills/ directory
# next to it is one the drill is about to delete and re-create; a record
# written there would be evidence stored in the thing under test. /root is
# outside every install root and survives the run.
default_record_path() {
  printf '/root/drills/%s.md' "$1"
}

# render_github_users <handle> — turn github.com/<handle>.keys on stdin into
# rig's ledger format. Every key grants the same operator roles by design.
render_github_users() {
  local user="$1"
  awk -v user="$user" 'NF && $1 !~ /^#/ { print user, "admin,box", $0 }'
}

# publish_record <path> — the final stdout payload: where the record lives,
# followed by the complete paste-ready record and nothing after it.
publish_record() {
  printf '\n        record written: %s\n\n' "$1"
  cat "$1"
}

# emit_record <path> — drills/<version>.md, in the shape drills/README.md
# defines: what ran, on what host, the pinned refs and SHAs, the numbers, and
# what failed. Emitted on EVERY completed run — a failed drill is still a
# valid record; the gate wants evidence, not success. Skipped legs are listed
# by name: a record with no failures listed reads as "nothing broke", so a leg
# that was not run says so instead of being omitted.
emit_record() {
  local out="$1" i os cpus ram virt line
  os="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
  cpus="$(nproc 2>/dev/null || echo '?')"
  ram="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  {
    printf '# Release drill — %s — %s\n\n' "$DRILL_VERSION" "$(date -u +%F)"
    printf 'Run ID: %s. Host: %s, %s vCPU / %s GB RAM (%s).\n' "$RUN_ID" "${os:-unknown}" "$cpus" "$ram" "$virt"
    # The rig line is MEASURED off the installed tree, never echoed from an
    # argument (#220): its VERSION, the commit its artifact was built from, and
    # the provenance install.sh recorded. box keeps a ref because box is still
    # installed by one.
    printf 'Rig under drill: %s, built from %s — %s.\n' \
      "$DRILL_VERSION" "${RIG_SOURCE_COMMIT:-(unstamped)}" "${RIG_FROM:-unknown}"
    printf 'Candidate box: box@%s (BOX_REF=%s).\n' "${BOX_SHA:-unresolved}" "$BOXREF"
    printf 'Template registry: %s@%s (ref %s, %s) — the rig-templates source the converge read (#110/#153).\n' \
      "${TPLREPO:-heavy-duty/rig-templates}" "${TPL_SHA:-unresolved}" \
      "${TPLREF:-unresolved}" "${TPL_SOURCE:-fetched}"
    printf 'Instrument: drill/drill.sh, legs in execution order.\n\n'
    printf '| Leg | Result |\n'
    printf '| --- | --- |\n'
    for i in "${!LEG_NAMES[@]}"; do
      printf '| %s | %s |\n' "${LEG_NAMES[$i]}" "${LEG_RESULTS[$i]}"
    done
    printf '\nChecks: %s passed, %s failed, %s skipped.\n' "$pass" "$fail" "$skipped"
    if [ "$fail" -eq 0 ] && [ "$skipped" -eq 0 ]; then
      printf '\nFailed: nothing. Every leg ran and every check passed.\n'
    else
      # printf --: a format opening with '- ' reads as an option to bash's
      # printf and emits NOTHING — a record whose Failed section silently
      # vanished is exactly the lie this file exists to make impossible.
      [ "$fail" -gt 0 ] && printf '\nFailed:\n'
      for line in "${findings[@]:-}"; do
        case "$line" in FAIL:*) printf -- '- %s\n' "$line" ;; esac
      done
      [ "$skipped" -gt 0 ] && printf '\nSkipped — these did NOT run, and this record is not evidence for them:\n'
      for line in "${findings[@]:-}"; do
        case "$line" in SKIP:*) printf -- '- %s\n' "$line" ;; esac
      done
    fi
    printf '\nThe isolation boundary was NOT asserted here: it is box'\''s drill'\''s\n'
    printf 'assertion (heavy-duty/box drill/drill.sh), joined to this record by the run ID.\n'
  } > "$out"
}

# =============================================================================
# Pre-flight — every refusal this run can see coming fires here, before
# anything is installed or any credential is spent. Args are validated BEFORE
# the root check (repo doctrine, bootstrap.sh:114 — so the refusals are
# testable without root, and a typo costs a re-type, never a re-ssh).
# =============================================================================
# box's ref EXPLICIT, or nothing runs. Defaulting it to a moving ref is the
# #103 hazard this harness exists to refuse: "I drilled the release" must not
# quietly mean "I drilled whatever the default resolved to that afternoon".
# rig's own ref is not asked for and cannot be given (#220) — the subject is
# the tree below, so the only way to drill a different rig is to install a
# different rig first, which is a thing you can see yourself doing.
if [ -z "$BOXREF" ]; then
  echo "drill: box's ref must be pinned explicitly — a drill against an unstated ref is not evidence (#103):" >&2
  echo "  --box-ref <ref>   (or BOX_REF)   the box that will ship with this rig   [got: ${BOXREF:-<unset>}]" >&2
  exit 2
fi

# The subject, resolved before anything is spent. A run that cannot name the
# tree it ships in has nothing to drill, and the two ways to arrive here
# without one are the two the record could not survive: through a pipe or a
# process substitution (no file, no directory, no tree), or as a lone copy of
# this script somewhere with no rig around it.
if ! SELF_TREE="$(self_tree "${BASH_SOURCE[0]}")"; then
  echo "drill: cannot find the rig tree this script ships in — and that tree IS the subject (#220)." >&2
  echo "  This drill installs and drills its own tree, so it must run from a file inside one:" >&2
  echo "  an installed rig (…/rig/current/drill/drill.sh) or a checkout (./drill/drill.sh)." >&2
  echo "  Piping it, or process-substituting it, leaves it with no tree to drill." >&2
  echo "  Put the candidate on the machine first — dist/release-artifact.sh builds one" >&2
  echo "  scp-able installer — run that, then run the drill out of what it installed." >&2
  exit 2
fi
SELF_VERSION="$(head -n1 "$SELF_TREE/VERSION" 2>/dev/null || echo unknown)"
SELF_SOURCE_COMMIT="$(tree_source_commit "$SELF_TREE")"
# The provenance to reinstall UNDER. install.sh names a local source 'local:<dir>'
# by default, and the directory it would name is the staging copy — a temp path
# that will not exist by the time anyone reads the record. Carry this tree's own
# provenance across instead: the reinstall installs the identical bytes, so
# 'artifact:rig-0.4.0.sh sha256:…' stays the true answer to where this rig came
# from. A tree with no provenance at all — a checkout — says so as itself.
SELF_FROM="$(cat "$SELF_TREE/INSTALLED_FROM" 2>/dev/null || true)"
[ -n "$SELF_FROM" ] || SELF_FROM="local:$SELF_TREE"

# The install root to wipe and re-create. It must be the root the install will
# use, or the drill measures one install and leaves another on the machine —
# so it is derived from where the tree under drill actually sits, and exported
# so install.sh reaches the same answer. A checkout has no versioned root and
# falls through to the installer's own default.
if [ -z "${RIG_HOME:-}" ]; then
  RIG_HOME="$(rig_home_of "$SELF_TREE" || true)"
fi
RIG_HOME="${RIG_HOME:-$HOME/.local/share/rig}"
RIG_BIN="${RIG_BIN:-/usr/local/bin}"
# That root is about to be handed to `rm -rf`, and unlike the hardcoded path it
# replaces it is now derived — from a tree's location, or from the operator's
# own environment. Absolute with at least two components, or nothing runs:
# '/', '/opt' and any relative path are refused here rather than discovered.
#
# CANONICALIZE BEFORE JUDGING, AND JUDGE WHAT COMES BACK. The refusal below is
# a glob: it counts slashes in a string, while `rm -rf` operates on the path
# that string RESOLVES to. Those are two different questions, and the gap is
# precisely the operator-supplied half — rig_home_of runs on a readlink -f'd
# path and can never hand back a '..' component, but an environment string can:
# '/opt/rig/../..' is two components as spelled and IS '/', the one value the
# paragraph above names as refused. Resolving first makes the depth rule mean
# what it says; it stays a depth rule and not an allowlist, so a literal
# '/etc/rig' is as permitted as it always was.
#
# realpath -m rather than readlink -f, though -f is this file's idiom elsewhere:
# the install root legitimately need not exist yet, and that is exactly where
# readlink -f gives up. Same coreutils package either way.
command -v realpath >/dev/null 2>&1 || { echo "drill: realpath is required — the install root is canonicalized before it is wiped, and this drill will not hand an unresolved path to rm -rf" >&2; exit 2; }
# ABSOLUTE IS ASKED FIRST, BEFORE RESOLVING, and it is the half that resolution
# cannot be trusted with: realpath -m resolves a relative path against $PWD and
# hands back something absolute and deep, so 'rig' would arrive at the depth
# rule below as "$PWD/rig" and PASS — canonicalization would have quietly
# promoted a spelling this gate refuses into one it accepts, and the drill
# wipes what it resolves. Spelling first, then the resolved value.
case "$RIG_HOME" in
  /*) ;;
  *) echo "drill: RIG_HOME=$RIG_HOME is not a sane install root — it must be absolute, and a relative path is refused BEFORE it is resolved: resolving it against \$PWD would make it absolute and deep enough to pass, and the drill wipes what it resolves" >&2; exit 2 ;;
esac
RIG_HOME_GIVEN="$RIG_HOME"
RIG_HOME="$(realpath -m -- "$RIG_HOME" 2>/dev/null || true)"
case "$RIG_HOME" in
  /*/?*) ;;
  *)
    echo "drill: RIG_HOME=$RIG_HOME_GIVEN is not a sane install root — the drill wipes and re-creates this path, so it must be an absolute path at least two components deep" >&2
    [ "$RIG_HOME_GIVEN" = "$RIG_HOME" ] || echo "drill:   it resolves to ${RIG_HOME:-<unresolvable>}, and that is the path rm -rf would have taken" >&2
    exit 2 ;;
esac
# ONE VALUE FROM HERE ON. The path the wipe takes and the path install.sh
# writes to must be the same computed string rather than two separately-derived
# ones that happen to agree: install.sh reads ${RIG_HOME:-$HOME/.local/share/rig}
# itself, so without this export the default case is agreement by coincidence
# and the canonical case is not agreement at all — the drill would wipe the
# resolved root and install to the spelling.
export RIG_HOME

case "$ROLE" in
  staging-server|dev-server|control-plane-server|workload-server|runner-server) ;;
  *) echo "drill: --role $ROLE is not a machine role this drill can converge unattended" >&2; exit 2 ;;
esac

if { [ -n "$USERS_FILE" ] && [ -n "$USERS_FROM_GITHUB" ]; } ||
   { [ -z "$USERS_FILE" ] && [ -z "$USERS_FROM_GITHUB" ]; }; then
  echo "drill: exactly one of --users <path> or --users-from-github <handle> is required — leg 1 asserts operators converged" >&2
  exit 2
fi
[ -z "$USERS_FROM_GITHUB" ] || {
  [[ "$USERS_FROM_GITHUB" == "${USERS_FROM_GITHUB,,}" &&
     "$USERS_FROM_GITHUB" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
    echo "drill: --users-from-github must also be a valid rig username (lowercase letter or '_', then lowercase letters, digits, '_' or '-'; max 32)" >&2
    exit 2
  }
  [ "$USERS_FROM_GITHUB" != root ] || {
    echo "drill: --users-from-github root is reserved and cannot be an operator; use --users <path> with a non-root operator" >&2
    exit 2
  }
}

# `box shell` preserves SUDO_USER even though the effective uid is root. The
# users family correctly refuses identity changes from a non-admin invoker, so
# catch that entry-path trap before fetching keys or spending a tailnet key.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] \
    && ! id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx rig-admin; then
  echo "drill: SUDO_USER=$SUDO_USER is not in rig-admin, so bootstrap's users phase will refuse. Enter with 'incus exec <box> -- bash -l' or unset SUDO_USER before running the drill." >&2
  exit 2
fi

[ -z "$USERS_FILE" ] || [ -r "$USERS_FILE" ] || { echo "drill: cannot read users file: $USERS_FILE" >&2; exit 2; }

[ "$(id -u)" -eq 0 ] || { echo "drill: must run as root (bootstrap, Docker and db all require it) — ssh in as root on the throwaway machine" >&2; exit 1; }

# The tailnet join needs a key unless this machine already joined (a re-drill
# on the same throwaway). Caught here, not 10 apt-minutes into bootstrap.
if [ -z "${TS_AUTHKEY:-}" ]; then
  if ! { command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; }; then
    echo "drill: TS_AUTHKEY is unset and this machine has not joined a tailnet — leg 1's bootstrap will refuse. Mint a single-use TAGGED pre-auth key and export TS_AUTHKEY without putting it on a command line (read -rs TS_AUTHKEY; export TS_AUTHKEY)." >&2
    exit 2
  fi
fi

# curl: rig no longer downloads itself, but box's install, the template
# registry fetch and --users-from-github all still go over it (#220 D6).
command -v curl >/dev/null 2>&1 || { echo "drill: curl is required (box's install, the template registry and --users-from-github download over it)" >&2; exit 1; }

if [ -n "$USERS_FROM_GITHUB" ]; then
  GENERATED_USERS_FILE="$(mktemp)"
  CLEANUP_PATHS+=("$GENERATED_USERS_FILE")
  if ! GITHUB_KEYS="$(curl -fsSL "https://github.com/$USERS_FROM_GITHUB.keys")"; then
    echo "drill: could not fetch public keys from https://github.com/$USERS_FROM_GITHUB.keys" >&2
    exit 2
  fi
  printf '%s\n' "$GITHUB_KEYS" | render_github_users "$USERS_FROM_GITHUB" > "$GENERATED_USERS_FILE"
  [ -s "$GENERATED_USERS_FILE" ] || { echo "drill: GitHub user $USERS_FROM_GITHUB has no public SSH keys" >&2; exit 2; }
  USERS_FILE="$GENERATED_USERS_FILE"
fi

if [ "$YES" -ne 1 ]; then
  cat <<EOF
This will, ON THIS HOST ($(hostname)):
  · wipe $RIG_HOME and reinstall THIS tree from scratch:
    $SELF_TREE (version $SELF_VERSION, built from $SELF_SOURCE_COMMIT)
  · run 'rig bootstrap $ROLE --users $USERS_FILE' — sshd hardening, hostname
    change, tailnet join, box ($BOXREPO@$BOXREF) + its Incus stack — TWICE
    (the second run is the idempotence assertion)
  · install Debian's Docker package for the database round-trip
Only do this on a THROWAWAY machine you can format.
EOF
  [ -t 0 ] || { echo "drill: no TTY to confirm on — pass --yes if you mean it." >&2; exit 2; }
  printf 'Continue? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes) ;; *) echo "stopped."; exit 1 ;; esac
fi

phase "Under drill"
BOX_SHA="$(ref_sha "$BOXREPO" "$BOXREF")"
inf "rig: $SELF_TREE — version $SELF_VERSION, built from $SELF_SOURCE_COMMIT"
inf "     provenance: $SELF_FROM"
inf "     install root: $RIG_HOME"
inf "box: $BOXREPO@$BOXREF (${BOX_SHA:-unresolved})"
inf "run ID: $RUN_ID — drills sharing this substrate share it (drills/README.md)"

# =============================================================================
phase "Installing rig from the tree this drill ships in"
# =============================================================================
# THE TRAP THIS SECTION EXISTS TO AVOID (#220 D2): the drill lives inside its
# own install destination. Run from an installed rig, $SELF_TREE is under
# $RIG_HOME — the directory the line below deletes. So the tree is STAGED
# first, outside every install root, and the install reads the staging copy;
# install.sh is never asked to copy $RIG_HOME onto itself, and never reads a
# source that the wipe already took.
#
# The script's own bytes are a different hazard and need no defence: rm unlinks
# the file, and bash keeps reading through the descriptor it already opened, so
# the running drill survives the deletion of the file it was read from. The
# staging is about the INSTALL SOURCE, which has no such protection.
STAGE="$(mktemp -d /tmp/drill-rig-tree.XXXXXX)"
CLEANUP_PATHS+=("$STAGE")
# tar rather than cp -a, and --exclude=.git: the same copy install.sh makes of
# a local source, so a checkout never carries its VCS state into the drill.
#
# pipefail in a SUBSHELL, the one place in this file that wants it: the header
# at the top explains why the file as a whole must not have it, and that reason
# (a left side that exits non-zero by design) does not apply to two tars. Read
# without it, this pipeline's verdict is the extracting tar's alone, so a
# source-side failure would report success on a truncated stream — and the next
# statement is the rm -rf. The subshell buys the verdict without touching the
# policy the rest of the file depends on.
if ! ( set -o pipefail; tar -C "$SELF_TREE" --exclude=.git -cf - . | tar -xf - -C "$STAGE" ); then
  echo "drill: could not stage $SELF_TREE — nothing has been touched yet; fix the copy and re-run." >&2
  exit 1
fi
[ -f "$STAGE/install.sh" ] || { echo "drill: the staged tree has no install.sh — the copy is incomplete" >&2; exit 1; }
inf "staged the tree under drill at $STAGE — the install reads this, not $RIG_HOME"

# The drill proves a tree from SCRATCH every run — a fresh machine, not a
# converged install — so any prior rig goes first, install root and PATH entry
# together. This is the line the staging above was needed for.
rm -rf "$RIG_HOME" "$RIG_BIN/rig"

# No network on rig's side of this any more (#220 D1): RIG_INSTALL_SOURCE is
# install.sh's local channel, and RIG_INSTALLED_FROM keeps the artifact's own
# provenance instead of the staging directory's temporary path.
if ! run_logged /tmp/drill-rig-install.log \
     env RIG_INSTALL_SOURCE="$STAGE" RIG_INSTALLED_FROM="$SELF_FROM" \
     bash "$STAGE/install.sh"; then
  echo "drill: rig's installer failed — tail of /tmp/drill-rig-install.log:" >&2
  tail -5 /tmp/drill-rig-install.log >&2
  exit 1
fi
# hash -r: this shell may have cached a 'rig' that the wipe just unlinked.
hash -r 2>/dev/null || true
command -v rig >/dev/null 2>&1 || { echo "drill: installer reported success but no 'rig' on PATH" >&2; exit 1; }

# ASSERT WHAT LANDED — both assertions fatal, before a single leg runs.
RIG_TREE="$(tree_of "$(command -v rig)")"
assert_installed_from rig "$RIG_TREE" "$SELF_FROM" || exit 1
assert_source_commit "$RIG_TREE" "$SELF_SOURCE_COMMIT" || exit 1
# The record's rig fields, MEASURED off what landed rather than off what was
# staged. The two are asserted identical just above, so this is the same
# answer by a different route — which is the point: the record cites the tree
# the legs will actually exercise.
DRILL_VERSION="$(head -n1 "$RIG_TREE/VERSION" 2>/dev/null || echo unknown)"
RIG_FROM="$(cat "$RIG_TREE/INSTALLED_FROM" 2>/dev/null || echo unknown)"
RIG_SOURCE_COMMIT="$(tree_source_commit "$RIG_TREE")"
ok "installed tree confirms: version $DRILL_VERSION, built from $RIG_SOURCE_COMMIT ($RIG_FROM)"

# The rig-templates ref this candidate converges (#110), for the record: the
# env override when the drill was pointed somewhere, else the pin read from
# the INSTALLED tree — what actually landed, never this checkout's copy. A
# 40-hex ref IS its own SHA (the pin's normal shape); anything else resolves
# through ref_sha like the two candidates above.
if [ -z "$TPLREF" ]; then
  TPLREF="$(sed -n 's/^RIG_TEMPLATES_PIN=//p' "$RIG_TREE/commands/lib/templates.sh" 2>/dev/null | head -n1)"
  if [ -n "$TPLREF" ] &&
     [ -n "$(find "$RIG_TREE/templates@$TPLREF" -mindepth 2 -maxdepth 2 -type f -name template.env -print -quit 2>/dev/null)" ]; then
    TPL_SOURCE="snapshot"
  fi
fi
if [[ "$TPLREF" =~ ^[0-9a-f]{40}$ ]]; then
  TPL_SHA="${TPLREF:0:7}"
elif [ -n "$TPLREF" ]; then
  TPL_SHA="$(ref_sha "$TPLREPO" "$TPLREF")"
fi
inf "templates: $TPLREPO@${TPLREF:-unresolved} (${TPL_SHA:-unresolved}, $TPL_SOURCE)"
[ -n "$RECORD" ] || RECORD="$(default_record_path "$DRILL_VERSION")"

# =============================================================================
phase "Leg 1 — convergence: rig bootstrap $ROLE"
# =============================================================================
# BOX_REPO/BOX_REF ride the environment into bootstrap's host=yes box install,
# so the box that lands is the pinned candidate, not what bootstrap falls back
# to unexported (the BOX_RELEASE pin, since rig#103 landed).
export BOX_REPO="$BOXREPO" BOX_REF="$BOXREF"

t0=$SECONDS
if run_logged /tmp/drill-bootstrap-1.log rig bootstrap "$ROLE" --users "$USERS_FILE"; then
  ok "rig bootstrap $ROLE --users … exited 0  ($((SECONDS - t0))s)"
  BOOTSTRAP_OK=1
else
  no "rig bootstrap $ROLE FAILED — tail: $(tail -3 /tmp/drill-bootstrap-1.log | tr '\n' ' ')"
  BOOTSTRAP_OK=0
fi

MARKER_LINE="$(cat "${RIG_ROLE_MARKER:-/etc/rig/role}" 2>/dev/null || true)"
if [ "$BOOTSTRAP_OK" -eq 1 ]; then
  # The role, asserted on EFFECTIVE state — the marker, the daemon's resolved
  # config, the netmap's granted tags — never on what was requested (the
  # sshd-first-wins lesson, lib/sshd.sh:63-70).
  case "$MARKER_LINE" in
    "role=$ROLE "*) ok "role marker: $MARKER_LINE" ;;
    *) no "role marker is '$MARKER_LINE' — expected role=$ROLE …" ;;
  esac
  sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' \
    && ok "sshd -T resolves passwordauthentication no (the hardening took)" \
    || no "sshd still resolves password auth — the 00-rig.conf drop-in is not winning"
  ts_tags="$(tailscale status --json 2>/dev/null | tr -d '\n ' | grep -o '"Tags":\[[^]]*\]' | head -n1)"
  if [ -n "$ts_tags" ] && [ "$ts_tags" != '"Tags":[]' ]; then
    ok "tailnet joined, tagged: $ts_tags"
  else
    no "tailnet join did not leave a tagged node (got: ${ts_tags:-nothing}) — bootstrap's verify should have refused this"
  fi
  grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null \
    && ok "unattended-upgrades enabled" || no "20auto-upgrades missing or wrong"
  grep -q "converged_by=$DRILL_VERSION" "${RIG_MANIFEST:-/etc/rig/manifest}" 2>/dev/null \
    && ok "manifest: converged_by=$DRILL_VERSION" || no "manifest does not name $DRILL_VERSION as the converging rig"
  users_bad=""
  while read -r u state; do
    [ "$state" = active ] || continue
    id -u "$u" >/dev/null 2>&1 || { users_bad="$users_bad $u(no-account)"; continue; }
    uhome="$(getent passwd "$u" | cut -d: -f6)"
    [ -s "$uhome/.ssh/authorized_keys" ] || users_bad="$users_bad $u(no-keys)"
  done < <(cat "${DRILL_LEDGER:-/etc/rig/users}" 2>/dev/null)
  # NOT 'grep -c … || echo 0': grep -c already prints 0 on no match (and then
  # exits 1), so the fallback would emit a second line into the substitution.
  n_users="$(grep -c ' active$' "${DRILL_LEDGER:-/etc/rig/users}" 2>/dev/null)" || true
  n_users="${n_users:-0}"
  [ -z "$users_bad" ] && [ "$n_users" -gt 0 ] \
    && ok "operators converged: $n_users active, accounts and keys present" \
    || no "operators NOT converged:${users_bad:- ledger empty}"
  leg "convergence — bootstrap $ROLE reaches its role" \
    "$([ "$fail" -eq 0 ] && echo "PASS ($((SECONDS - t0))s)" || echo "FAIL — see Failed below")"

  # --- idempotence: the claim this drill exists to make ----------------------
  # Capture, re-run, capture, diff. Mechanically — never "watched it not
  # obviously break". An empty diff IS the definition of converged.
  phase "Leg 1 — idempotence: the re-run must change nothing"
  pre="$(mktemp)"; post="$(mktemp)"
  capture_state "$pre"
  t0=$SECONDS
  if run_logged /tmp/drill-bootstrap-2.log rig bootstrap "$ROLE" --users "$USERS_FILE"; then
    ok "second bootstrap exited 0  ($((SECONDS - t0))s)"
  else
    no "second bootstrap FAILED — tail: $(tail -3 /tmp/drill-bootstrap-2.log | tr '\n' ' ')"
  fi
  capture_state "$post"
  if statediff="$(diff -u "$pre" "$post")"; then
    ok "re-converge is a no-op: the state diff is empty"
    leg "re-converge (idempotence)" "clean, no changes"
  else
    dlines="$(printf '%s\n' "$statediff" | grep -c '^[+-][^+-]')"
    no "re-converge CHANGED the box — $dlines state line(s) differ:"
    printf '%s\n' "$statediff" | sed 's/^/          /'
    leg "re-converge (idempotence)" "DIRTY — $dlines state line(s) changed on the re-run"
  fi
  rm -f "$pre" "$post"
else
  leg "convergence — bootstrap $ROLE reaches its role" "FAIL — bootstrap exited non-zero"
  skip "idempotence not asserted — the first converge already failed, a re-run diff would measure noise"
  leg "re-converge (idempotence)" "SKIPPED — first converge failed"
fi

# =============================================================================
phase "--host yes — the box that will ship"
# =============================================================================
# The assertions #105 settles this leg at: the installer ran, INSTALLED_FROM
# matches the requested BOX_REF, setup-host exited clean, the stack it claims
# stands. Then it STOPS. Not one isolation probe: two records that both claim
# the trust boundary will eventually disagree with no tiebreaker, and a
# partial isolation check reads — months later, in a record — as though the
# boundary was drilled (box#153's shape through a different door). Resist
# adding "just one" probe here; that is box's drill's whole job.
case "$MARKER_LINE" in
  *"host=yes"*)
    if command -v box >/dev/null 2>&1; then
      ok "box CLI on PATH"
      BOX_TREE="$(tree_of "$(command -v box)")"
      # Fatal, like rig's own: a wrong box under --host yes poisons the pair.
      assert_installed_from box "$BOX_TREE" "$BOXREPO@$BOXREF" || exit 1
      ok "installed box confirms: $BOXREPO@$BOXREF"
      if box doctor >/dev/null 2>&1; then
        ok "box doctor passes — setup-host converged; the host stack stands (box's own effective-state verdict)"
        leg "--host yes: pinned box installed, host stack up" "PASS — $BOXREPO@$BOXREF, box doctor clean"
      else
        no "box is installed but 'box doctor' does not pass — the host stack is unproven (run 'box doctor' for box's verdict)"
        leg "--host yes: pinned box installed, host stack up" "FAIL — box doctor does not pass"
      fi
    else
      no "no 'box' on PATH after a host=yes bootstrap — the box install did not take (bootstrap warns rather than dies there; the drill does not)"
      leg "--host yes: pinned box installed, host stack up" "FAIL — box CLI never landed"
    fi
    inf "isolation NOT asserted here — deliberately. The VM trust boundary is box's"
    inf "assertion, made by box's own drill (~85 probes); this leg stops at 'the pinned"
    inf "box installed and its host stack stands'. The records join on the run ID."
    ;;
  *)
    skip "--host yes assertions: role $ROLE left host=no (marker: ${MARKER_LINE:-absent})"
    leg "--host yes: pinned box installed, host stack up" "SKIPPED — this role does not host VMs"
    ;;
esac

# =============================================================================
phase "Preparing Docker for Leg 2"
# =============================================================================
# The throwaway starts without Docker. Install the Debian-owned package
# directly: this is drill scaffolding for the db evidence, not a rig command.
if run_logged /tmp/drill-docker.log bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker.io
  systemctl enable --now docker
'; then
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
    && ok "Docker installed directly and the daemon answers" \
    || no "Docker package installation exited 0 but the daemon does not answer"
else
  no "Docker prerequisite FAILED — tail: $(tail -3 /tmp/drill-docker.log | tr '\n' ' ')"
fi

# =============================================================================
phase "Leg 2 — db dump/restore round-trip (test/db-integration.sh)"
# =============================================================================
# Driven from the INSTALLED tree — the drill exercises what shipped, not the
# checkout this script happens to sit in. The leg's skip contract is the
# script's own (loud, reasoned, exit 0) and classify_leg keeps it a SKIP:
# counted, rendered distinctly, named in the record — never a pass.
db_out="$(mktemp)"
bash "$RIG_TREE/test/db-integration.sh" >"$db_out" 2>&1
db_rc=$?
case "$(classify_leg "$db_rc" "$db_out")" in
  pass)
    db_numbers="$(tail -1 "$db_out")"
    ok "db round-trip: $db_numbers"
    leg "test/db-integration.sh" "PASS — $db_numbers"
    ;;
  skip)
    db_reason="$(grep -m1 '^skip:' "$db_out")"
    skip "db round-trip did not run — $db_reason"
    leg "test/db-integration.sh" "SKIPPED — ${db_reason#skip: }"
    ;;
  fail)
    no "db round-trip FAILED (exit $db_rc) — tail: $(tail -3 "$db_out" | tr '\n' ' ')"
    leg "test/db-integration.sh" "FAIL — exit $db_rc"
    ;;
esac
rm -f "$db_out"

# =============================================================================
phase "Summary"
# =============================================================================
printf '  %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
if [ "${#findings[@]}" -gt 0 ]; then
  echo
  printf '  %s\n' "${findings[@]}"
fi

mkdir -p "$(dirname "$RECORD")"
emit_record "$RECORD"
publish_record "$RECORD"
[ "$fail" -eq 0 ]
