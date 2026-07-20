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
# user's lines, root as username (root's keys are root-door policy's business,
# not this file's), malformed line (fewer than 3 fields, or a key field that does
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
      errs+=("line $n: 'root' is not a rig-managed user — this file names operators; root SSH's fate is root-door policy")
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
# (`role=... root-door=... host=... join=...`), or nothing when absent. NO
# policy here: what an absent marker or a given trait MEANS is each caller's
# call (apply notes it, close-root refuses on it) — this reader only reads.
read_role_marker() {
  [ -r "$1" ] || return 0
  head -n1 "$1"
}

# root_door_of <marker line> — resolve the root-door trait from a marker LINE,
# reading both the current `root-door=` vocabulary and the `class=` one it
# replaced (#77). Prints exactly one of:
#
#   closed    the root SSH door is meant to shut once named operators exist
#             (`rig users close-root`) — was class=human
#   open      root SSH stays as the control plane's automation door
#             — was class=server
#   conflict  the marker names BOTH vocabularies and they DISAGREE
#   (empty)   the marker names neither, or names one with a value that is
#             not in its value set
#
# Text->text and total, so the harness proves every arm off a literal string
# (repo precedent: deny_verdict, group_allow_verdict). Callers turn a verdict
# into policy; this function has none.
#
# WHY THE COMPAT READ IS NOT OPTIONAL, and why it is here rather than at each
# call site. #77 renamed the trait because `class=human|server` was named for
# who lives on the box while what it decides is whether root SSH stays open as
# the control plane's automation door — the axis that made `dev-server` a
# `class=human` box, a suffix and a trait that read as a contradiction. But
# unlike #76's role rename, this field is not informational: it is written into
# /etc/rig/role and read back on live machines, where it gates `rig users
# close-root`. Every box bootstrapped before this change carries `class=` and
# carries it FOREVER, until someone re-bootstraps it — there is no migration
# step that reaches a fleet. So dropping the old read breaks in both directions
# at once, and both are incidents: a machine whose door should close stops
# being able to close it (close-root refuses on a marker it no longer
# understands), and — through bootstrap-tenant's machine-marker guard, which
# used `class=` as its "this is a machine" detector — a real fleet box stops
# looking like a machine at all and a tenant converge will happily clobber it.
# One resolver, consulted everywhere the trait is read, is what keeps those
# two readings from drifting apart.
#
# BOTH FIELDS PRESENT is a state bootstrap never writes — it writes one line,
# fresh, in the new vocabulary only — so a marker carrying both was
# hand-edited, and the two answers are a question about intent that rig cannot
# settle. Agreement is taken (it says one thing twice); disagreement resolves
# to `conflict` and every caller fails CLOSED on it, because the alternative is
# picking a winner between two equally-authored claims about a root door. The
# repair is the same one the rest of the marker family names: re-run bootstrap,
# which rewrites the line whole.
#
# NEITHER FIELD PRESENT resolves empty and is likewise fail-closed everywhere,
# unchanged from before: a marker that names no door policy cannot authorize
# shutting a door.
root_door_of() {
  local marker="$1" new="" old="" padded
  # FIELD-ANCHORED, not substring. The marker is one line of space-separated
  # `key=value` fields (bootstrap writes it with a single printf), so padding
  # both ends and matching whole fields is exact. Unanchored patterns matched
  # any value that EXTENDS a real one: `root-door=closedish` resolved as
  # `closed` and passed close-root's gate — the one arm that authorizes an
  # irreversible act — and `class=humanoid` did the same through the compat
  # arm. That contradicted this function's own promise above, that a value
  # outside the set resolves empty and fails closed. Only reachable by hand
  # editing, but this is the function every consumer trusts, so it owes them
  # exactness rather than "close enough" (found in review on #77).
  # Whitespace is normalised first so a hand-edit using tabs or double spaces
  # is read the same way rather than silently failing to match.
  padded=" ${marker//[[:space:]]/ } "
  case "$padded" in
    *" root-door=closed "*) new=closed ;;
    *" root-door=open "*)   new=open ;;
  esac
  case "$padded" in
    *" class=human "*)  old=closed ;;
    *" class=server "*) old=open ;;
  esac
  if [ -n "$new" ] && [ -n "$old" ] && [ "$new" != "$old" ]; then
    printf 'conflict'; return 0
  fi
  # New wins where both are readable and agree; the old field answers alone on
  # every marker written before #77, which is the whole point.
  printf '%s' "${new:-$old}"
}

# assert_marker_closes_root <marker_path> — close-root's marker gate: return 0,
# silently, only when the marker's root-door trait resolves to `closed`;
# otherwise print the refusal reason on stdout and return 1 (the caller wraps
# it in its own die). The policy is a pure lib function on purpose: the CLI
# path sits behind the root check, so the harness proves every refusal HERE,
# against fixture markers, non-root (repo precedent: parse_users_file,
# assert_runner_repo).
assert_marker_closes_root() {
  local marker
  marker="$(read_role_marker "$1")"
  if [ -z "$marker" ]; then
    # No marker means rig cannot know whether root here is a human's bad habit
    # or the control plane's automation door — refuse to shut it blind.
    printf '%s\n' "no /etc/rig/role marker: re-run rig bootstrap so this box knows what it is; refusing to shut the root door blind"
    return 1
  fi
  case "$(root_door_of "$marker")" in
    closed) return 0 ;;
    open)
      # Root SSH on such a box IS the control plane's (Coolify's) automation
      # identity — closing it severs fleet management. No --force exists.
      # Deliberately keyed on the DOOR, not on the role: #17's original table
      # let the runner role close root ("no Coolify involved"), but the trait
      # model (#26) supersedes that — every root-door=open box, runner
      # included, is an automation identity whose management plane is root
      # SSH, and rig itself converges through that door. A CI box someone
      # administers like a human machine is --root-door closed at bootstrap,
      # not an exception carved out here.
      printf '%s\n' "root-door=open: root here is the control plane's automation identity — closing it severs fleet management. Every root-door=open box (runner included) keeps root deliberately: it is an automation identity, and root SSH is its management plane; a box meant to be administered like a human machine is --root-door closed at bootstrap, not an exception here"
      return 1 ;;
    conflict)
      # Hand-edited into naming both vocabularies, disagreeing. Fail closed:
      # see root_door_of's header for why rig refuses to pick a winner.
      printf '%s\n' "marker names both root-door= and the pre-#77 class= and they disagree (${marker}): rig will not pick a winner between two claims about a root door — re-run rig bootstrap to rewrite the marker, and refusing to shut the root door meanwhile"
      return 1 ;;
    *)
      printf '%s\n' "marker names no root-door policy (${marker}): re-run rig bootstrap; refusing to shut the root door blind"
      return 1 ;;
  esac
}

# assert_marker_hosts_vms <marker_path> — the box role's gate: return 0,
# silently, only when the marker says host=yes; otherwise print the reason on
# stdout and return 1 (the caller decides whether that is a warn or a die).
# Same shape and same reason as assert_marker_closes_root above: the policy is a
# pure marker->verdict function so the harness can prove every arm against
# fixture markers, non-root, while the CLI path sits behind the root check.
#
# The MARKER decides, not the machine (#58). Apply used to consult host= only
# when group incus was ABSENT — so a box whose marker said host=no but which
# happened to carry the group (box's setup-host ran, then the box was
# re-bootstrapped with different traits, or given --host no) handed box-role
# users a bare `usermod -aG incus`: the socket with no tier behind it. That is
# the worst of the three states, because incus-user answers a socket it is
# given by lazily creating an UNHARDENED project for whoever opens it —
# incusbr-<uid>, NAT on v4 and v6, no ACL, no dns.mode=none, no port
# isolation. The alternative considered was to let the group's presence win
# and converge anyway with a warning, on the theory that a real incus install
# is evidence the machine really does host VMs. It was rejected: the marker is
# what this box CLAIMS to be, and every other host= decision in the family
# already treats it as authoritative rather than as a hint to be second-
# guessed by probing the machine. A box that lies about itself gets its lie
# taken seriously and gets told, loudly, to re-run bootstrap — which is a
# cheap repair — instead of rig quietly provisioning a VM-host tier on a box
# that does not claim to be one. Deciding from the marker alone also means the
# verdict is the SAME whether or not the group exists, which is the property
# that was missing.
#
# No marker, and a marker with no host= trait, both land here as "not a VM
# host" for the same fail-closed reason: rig cannot tell an unbootstrapped box
# from a repurposed one, and the safe error is withholding VM access that can
# be granted by a re-run, not granting VM access that cannot be un-granted
# once a project exists under it.
assert_marker_hosts_vms() {
  local marker
  marker="$(read_role_marker "$1")"
  case "$marker" in
    *host=yes*) return 0 ;;
    *host=no*)
      printf '%s\n' "this box does not host VMs (host=no)"
      return 1 ;;
    "")
      printf '%s\n' "no /etc/rig/role marker, so this box names no host= trait — re-run rig bootstrap so it knows whether it hosts VMs"
      return 1 ;;
    *)
      printf '%s\n' "the role marker names no host= trait (${marker}) — re-run rig bootstrap so this box knows whether it hosts VMs"
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

# group_deny_verdict <space-separated groups> <denygroups token...>
#
# deny_verdict's sibling for sshd's DenyGroups, judged against the
# candidate's ACTUAL group membership (id -Gn), same fail-closed rule:
# empty output = every token is provably irrelevant — literal and naming
# none of the candidate's groups. A literal token naming a group they are
# in flags, and so does any pattern or host-qualified token, because a
# token this side of sshd cannot prove irrelevant may be the one that
# denies. Pure text→text, sourced by the harness.
group_deny_verdict() {
  local groups="$1" tok g; shift
  for tok in "$@"; do
    case "$tok" in
      *[*?]*) printf "sshd DenyGroups has pattern entry '%s' — cannot prove it misses this user's groups; make it literal or remove it, then re-run" "$tok"; return 0 ;;
      *@*) printf "sshd DenyGroups has host-qualified entry '%s' — whether it bites depends on the client address, which no local check can prove; make it literal or remove it, then re-run" "$tok"; return 0 ;;
      *) for g in $groups; do
           if [ "$tok" = "$g" ]; then
             printf "sshd DenyGroups names '%s' — a group this user is in" "$g"; return 0
           fi
         done ;;
    esac
  done
  return 0
}

# group_allow_verdict <space-separated groups> <allowgroups token...>
#
# AllowGroups' direction: when the directive is set, sshd admits only
# members of a matching group, so the proof must be a LITERAL token
# naming a group the candidate is in. A pattern that would in fact admit
# them proves nothing here (same stance as AllowUsers: over-refusing is
# the safe error), so no literal hit → flag. Pure text→text.
group_allow_verdict() {
  local groups="$1" tok g; shift
  for tok in "$@"; do
    for g in $groups; do
      [ "$tok" = "$g" ] && return 0
    done
  done
  printf "sshd AllowGroups is set and no entry literally names a group this user is in — add their group (or them to a named group), then re-run"
  return 0
}
