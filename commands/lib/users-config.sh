#!/usr/bin/env bash
# Shared parsing for the rig users family. Sourced by the users-* commands and
# by the test harness against fixture files; never executed on its own.

# The users file is line-based and whitespace-separated on purpose: a
# rig-bootstrapped box has no YAML parser and no jq, and `read` parses this
# shape for free — same jq-free reason runner-config.sh greps JSON. One line
# per key:
#
#   # user   roles          ssh public key
#   dan      admin,box      ssh-ed25519 AAAA... dan@laptop
#
# Repeated username lines are additional authorized keys; the roles field must
# be IDENTICAL on each — a repeated line means "another key", never a quiet
# role edit hiding mid-file. '#' comments and blank lines are skipped.
#
# The key field may also be the literal token '@root' (#17): "this user's
# authorized_keys becomes root's CURRENT /root/.ssh/authorized_keys at apply
# time". The operator provably holds a root private key — they SSHed in with
# it to run apply at all — so seeding it is the one key source that cannot
# lock them out; any pasted literal can be a key they do not hold. '@root'
# mixes with literal key lines: seeded keys come first, literal keys are
# APPENDED after them, and re-runs converge to root's then-current keys plus
# the literals. The parser only owns the token's shape — reading root's file
# needs root and is apply's business.

# parse_users_file <path>
#
# Emits one normalized 'user|roles|key' line per key line on stdout. On ANY
# validation error: EVERY error goes to stderr, each with its line number, no
# stdout, return 1. All errors in one pass because a bad file should cost one
# fix cycle, not one round-trip per line.
#
# Refusals: unknown role (the valid set is named), differing roles across one
# user's lines, root as username (root's keys are class policy's business, not
# this file's), malformed line (fewer than 3 fields, or a key field that does
# not start with an SSH key type and is not exactly '@root'), '@root' with
# trailing material (the token IS the whole field), invalid username (the
# charset below — '|' would corrupt this parser's own delimited stream, a
# leading '-' reads as a useradd flag), duplicate identical key line (a
# second '@root' for one user counts — the seen[] map catches it for free).
parse_users_file() {
  local path="$1"
  local -a errs=() out=() rlist=()
  local -A first_roles=() seen=()
  local line u r k role ok n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then continue; fi
    read -r u r k <<< "$line"
    if [ -z "${k:-}" ]; then
      errs+=("line $n: malformed — expected 'user roles ssh-public-key' (3+ whitespace-separated fields)")
      continue
    fi
    case "$k" in
      @root) ;;   # seed token — apply reads root's authorized_keys (#17)
      @root*)
        errs+=("line $n: '@root' is the whole key field — it names root's authorized_keys as this user's key source and takes no trailing material")
        continue ;;
      ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) ;;
      *)
        errs+=("line $n: malformed — key field must start with an SSH key type (ssh-..., ecdsa-...) or be the literal '@root'")
        continue ;;
    esac
    # The username feeds this parser's own '|'-delimited stream and then
    # useradd: 'fo|o' silently becomes user 'fo' with garbage keys, and a
    # leading '-' reads as a useradd flag mid-convergence. One safe charset
    # refuses both by construction (and ':', which would corrupt passwd).
    if ! [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      errs+=("line $n: invalid username '$u' — must match ^[a-z_][a-z0-9_-]{0,31}\$ (lowercase letter or '_' first, then lowercase, digits, '_', '-'; max 32)")
      continue
    fi
    if [ "$u" = "root" ]; then
      errs+=("line $n: 'root' is not a rig-managed user — this file names operators; root SSH's fate is class policy")
      continue
    fi
    ok=1
    IFS=',' read -ra rlist <<< "$r"
    for role in "${rlist[@]}"; do
      case "$role" in
        admin|rig|box) ;;
        *) errs+=("line $n: unknown role '$role' for $u (valid roles: admin rig box)"); ok=0 ;;
      esac
    done
    if [ -n "${first_roles[$u]:-}" ] && [ "${first_roles[$u]}" != "$r" ]; then
      errs+=("line $n: $u has roles '$r' here but '${first_roles[$u]}' earlier — repeated lines add keys, roles must be identical")
      ok=0
    fi
    if [ -z "${first_roles[$u]:-}" ]; then first_roles[$u]="$r"; fi
    if [ -n "${seen[$u|$k]:-}" ]; then
      errs+=("line $n: duplicate key line for $u (same key already on line ${seen[$u|$k]})")
      continue
    fi
    seen[$u|$k]="$n"
    if [ "$ok" -eq 1 ]; then out+=("$u|$r|$k"); fi
  done < "$path"
  if [ "${#errs[@]}" -gt 0 ]; then
    printf '%s\n' "${errs[@]}" >&2
    return 1
  fi
  if [ "${#out[@]}" -gt 0 ]; then printf '%s\n' "${out[@]}"; fi
  return 0
}

# read_role_marker <path> — the marker line bootstrap wrote
# (`role=... class=... host=... join=...`), or nothing when absent. NO policy
# here: what an absent marker or a given class MEANS is each caller's call
# (apply notes it, close-root refuses on it) — this reader only reads.
read_role_marker() {
  [ -r "$1" ] || return 0
  head -n1 "$1"
}

# assert_marker_human <marker_path> — close-root's marker gate: return 0,
# silently, only when the marker says class=human; otherwise print the refusal
# reason on stdout and return 1 (the caller wraps it in its own die). The
# policy is a pure lib function on purpose: the CLI path sits behind the root
# check, so the harness proves every refusal HERE, against fixture markers,
# non-root (repo precedent: parse_users_file, assert_runner_repo).
assert_marker_human() {
  local marker
  marker="$(read_role_marker "$1")"
  if [ -z "$marker" ]; then
    # No marker means rig cannot know whether root here is a human's bad habit
    # or the control plane's automation door — refuse to shut it blind.
    printf '%s\n' "no /etc/rig/role marker: re-run rig bootstrap so this box knows what it is; refusing to shut the root door blind"
    return 1
  fi
  case "$marker" in
    *class=human*) return 0 ;;
    *class=server*)
      # Root SSH on a server IS the control plane's (Coolify's) automation
      # identity — closing it severs fleet management. No --force exists.
      # Deliberately per-CLASS, not per-role: #17's original table let the
      # runner role close root ("no Coolify involved"), but the class model
      # (#26) supersedes that — every server-class box, runner included, is
      # an automation identity whose management plane is root SSH, and rig
      # itself converges through that door. A CI box someone administers
      # like a human machine is class=human at bootstrap, not an exception
      # carved out here.
      printf '%s\n' "class=server: root here is the control plane's automation identity — closing it severs fleet management. Every server-class box (runner included) keeps root deliberately: it is an automation identity, and root SSH is its management plane; a box meant to be administered like a human machine is --class human at bootstrap, not an exception here"
      return 1 ;;
    *)
      printf '%s\n' "marker names no class (${marker}): re-run rig bootstrap; refusing to shut the root door blind"
      return 1 ;;
  esac
}

# deny_verdict <user> <denyusers token...>
#
# Judge sshd's effective DenyUsers list against ONE candidate, fail closed.
# Empty output = every token is PROVABLY irrelevant to <user>: literal (no
# sshd pattern metacharacters, no host qualifier) and not this username.
# Anything else prints the reason and the caller flags the candidate:
#
#   - a literal hit — DenyUsers really names them;
#   - ANY pattern token (* or ?) — 'DenyUsers dan*' genuinely denies admin
#     'dan', and this side of sshd cannot re-implement its pattern engine
#     just to prove a miss, so an unprovable token counts as a hit;
#   - ANY host-qualified token (USER@HOST) — whether it bites depends on the
#     client's address, which no local probe knows.
#
# The asymmetry with AllowUsers is deliberate and points the same direction:
# AllowUsers must name the admin literally (a pattern that WOULD admit them
# still refuses — over-refusing is safe), DenyUsers refuses on anything it
# cannot prove misses. Both errors close toward "repair first", never toward
# a welded-shut root door. Pure text→text, sourced by the harness.
deny_verdict() {
  local u="$1" tok; shift
  for tok in "$@"; do
    case "$tok" in
      "$u") printf 'sshd DenyUsers names this user'; return 0 ;;
      *[*?]*) printf "sshd DenyUsers has pattern entry '%s' — cannot prove it misses this user; make it literal or remove it, then re-run" "$tok"; return 0 ;;
      *@*) printf "sshd DenyUsers has host-qualified entry '%s' — whether it bites depends on the client address, which no local check can prove; make it literal or remove it, then re-run" "$tok"; return 0 ;;
    esac
  done
  return 0
}
