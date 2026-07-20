#!/usr/bin/env bash
# /etc/rig/manifest — PROVENANCE: which rig converged this machine, and when
# (#61). Sourced by bootstrap.sh, bootstrap-tenant.sh and the test harness.
#
# The file is `key=value`, one per line — not JSON, not YAML. Same constraint
# stated three times in the tree already (lib/users-config.sh:6-12,
# lib/runner-config.sh:6 and :24): a rig-bootstrapped box has no YAML parser
# and no jq, which is why json_field() is grep-and-sed. This is the one file
# that must stay readable on the most broken machine in the fleet, so `read`
# parses it for free.
#
# WHAT GOES IN HERE: facts that are DECIDED. Which rig ran, and when it ran.
# Facts that are OBSERVED — cores, RAM, disk, kernel — belong to `rig platform`
# (#64), which computes them fresh and stores nothing. That split is not
# tidiness: a stored spec goes stale on its own (someone adds RAM; the
# unattended-upgrades bootstrap.sh itself enables patches the kernel), and
# refreshing it on every run collides head-on with bootstrap.sh:3 —
# "Convergent: safe to re-run; a second run changes nothing." Keeping only
# immutable content removes that problem instead of managing it.
#
# NEVER A CREDENTIAL. This file is 0644 and world-readable by design — it is
# an audit record, and an audit record nobody can read is not one. Later
# commands may append their own provenance (runner_installed_at,
# coolify_installed_at, box_version), subject to the same two rules: the EVENT
# of installing something, never its current state, and never a secret. Same
# law runner-install.sh:190 already states for `.rig-labels` — "box-local
# metadata, never a credential."

# The schema version, an INTEGER, independent of the rig versions recorded in
# the file. Bumped only when a key is REMOVED or REPURPOSED — adding a key is
# not a bump, and readers must ignore keys they do not know, so a newer rig's
# manifest stays readable to an older one. No `schema=` line means pre-manifest.
MANIFEST_SCHEMA=1

# The five keys rig's provenance block owns. Everything else in the file is a
# later command's line and is preserved verbatim (see manifest_foreign).
MANIFEST_KEYS='schema bootstrapped_by bootstrapped_at converged_by converged_at'

# manifest_path — where the manifest lives. RIG_MANIFEST overrides it so tests
# point at fixtures (repo precedent: RIG_ROLE_MARKER, bin/rig:148).
manifest_path() {
  printf '%s' "${RIG_MANIFEST:-/etc/rig/manifest}"
}

# manifest_value <path> <key> — the value of one key, or nothing when the file
# or the key is absent. First occurrence wins. NO policy here: what a missing
# key MEANS is each caller's call (this reader only reads — repo precedent:
# read_role_marker).
manifest_value() {
  [ -r "$1" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    [ "$k" = "$2" ] || continue
    printf '%s' "$v"
    return 0
  done < "$1"
}

# manifest_has <path> <key> — is the key PRESENT, regardless of its value.
# Separate from manifest_value because "absent" and "present but empty" are
# different answers and command substitution collapses both to the empty
# string. Key comparison is a string equality, never a pattern: `rig manifest`
# passes operator input straight in, and a key of `.*` must find nothing rather
# than match the first line.
manifest_has() {
  [ -r "$1" ] || return 1
  local k
  while IFS='=' read -r k _; do
    [ "$k" = "$2" ] && return 0
  done < "$1"
  return 1
}

# manifest_foreign <path> — every line rig's provenance block does NOT own,
# in file order. A newer rig (or a later command) may have written keys this
# one has never heard of; rewriting the file must not eat them, or the schema's
# "readers ignore keys they do not know" promise would only hold for readers
# and not for the writer.
manifest_foreign() {
  [ -r "$1" ] || return 0
  local line key
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    case " $MANIFEST_KEYS " in
      *" $key "*) continue ;;
    esac
    printf '%s\n' "$line"
  done < "$1"
}

# manifest_render <path> <version> <now> — the WHOLE convergence contract, as
# a pure text→text function: existing file + running version + a clock reading
# in, the file's desired content out. No side effects, so the harness proves
# the rules non-root against fixtures (repo precedent: parse_users_file,
# assert_marker_human).
#
# Purity is what makes convergence testable rather than asserted. The rendered
# content is a function of (existing file, running version) ALONE — <now> is
# consulted only on the paths that were going to change anyway — so calling
# this twice with two DIFFERENT clock readings must produce byte-identical
# output. test/cli.sh pins exactly that, which is stronger than re-running the
# writer fast enough that the second matches by luck.
#
# Rule 1 — bootstrapped_* is FIRST-WRITE-WINS. Birth is pinned forever. If the
# file already carries a bootstrapped_at, both birth fields are preserved
# verbatim. Regenerating it as now() on every run would make every re-run a
# diff, which is the exact trap that keeping specs out of this file closed.
#
# Rule 2 — converged_* updates ONLY when the version actually differs.
# converged_at is "the time the converging version last changed", NOT the time
# of the last run. If it tracked every run it would be a clock, and a clock in
# a cmp-guarded file makes every re-run a fake change. So: compare the running
# version against the recorded converged_by; equal means the pair is already
# true and is copied through untouched.
#
# Under those two rules a re-run by the SAME rig renders byte-identical content
# and the cmp-guard stays silent, while a re-converge by a DIFFERENT rig
# renders a real diff — and the guard firing there is correct, not spurious. It
# was only ever the clock that was the fake change, never the version.
manifest_render() {
  local path="$1" ver="$2" now="$3"
  local b_by b_at c_by c_at
  b_by="$(manifest_value "$path" bootstrapped_by)"
  b_at="$(manifest_value "$path" bootstrapped_at)"
  c_by="$(manifest_value "$path" converged_by)"
  c_at="$(manifest_value "$path" converged_at)"

  # Rule 1. bootstrapped_at is the field that decides, because it is the one
  # that can never be reconstructed: a machine's birth version can at least be
  # guessed at, its birth INSTANT cannot. So an existing at-stamp pins the
  # pair, and a birth-stamp with no birth version records `unknown` rather
  # than backfilling today's version as if it had always been there — a
  # manifest that lies about which rig built the box is worse than one that
  # admits it does not know.
  if [ -z "$b_at" ]; then
    b_by="$ver"; b_at="$now"
  elif [ -z "$b_by" ]; then
    b_by=unknown
  fi

  # Rule 2. The empty-at case is a one-time repair of a truncated file, not a
  # clock: once written it satisfies the equality on every later run.
  if [ "$c_by" != "$ver" ] || [ -z "$c_at" ]; then
    c_by="$ver"; c_at="$now"
  fi

  printf 'schema=%s\n' "$MANIFEST_SCHEMA"
  printf 'bootstrapped_by=%s\n' "$b_by"
  printf 'bootstrapped_at=%s\n' "$b_at"
  printf 'converged_by=%s\n' "$c_by"
  printf 'converged_at=%s\n' "$c_at"
  manifest_foreign "$path"
}

# manifest_running_version <rig root> — the version that IS RUNNING, captured
# at run time from the tree's own VERSION file. NOT `rig --version` read back
# later: a machine outlives the rig that built it, so what is installed today
# answers a different question than what converged it. First line only — a
# stray second line would inject a bogus key into a key=value file.
manifest_running_version() {
  local v=""
  [ -r "$1/VERSION" ] && v="$(head -n1 "$1/VERSION")"
  printf '%s' "${v:-unknown}"
}

# manifest_stamp <version> — the writer. Renders, cmp-guards like every file
# rig converges, installs 0644 beside the role marker and the users ledger.
# Returns 0 when it CHANGED the file and 1 when the file was already current,
# so the caller owns the log line (and, under set -e, must call it in an `if`).
manifest_stamp() {
  local path tmp rc
  path="$(manifest_path)"
  tmp="$(mktemp)"
  manifest_render "$path" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  if cmp -s "$tmp" "$path" 2>/dev/null; then
    rc=1
  else
    mkdir -p "$(dirname "$path")"
    install -m 0644 "$tmp" "$path"
    rc=0
  fi
  rm -f "$tmp"
  return "$rc"
}
