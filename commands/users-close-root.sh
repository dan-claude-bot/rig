#!/usr/bin/env bash
# rig users close-root — shut the root SSH door on the boxes whose door is
# meant to shut, once and only once a named admin can already get in. The
# root-door trait decides root SSH's fate (#26, renamed by #77): on
# root-door=closed a root login is unattributable noise, so it goes; on
# root-door=open root IS the control plane's automation identity, so closing it
# would sever fleet management — this command refuses there, and no --force
# exists. Convergent: a second run is a no-op and says so.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"
# The sshd validator is shared with bootstrap's hardening on purpose: both
# commands ask sshd the same question before bouncing the daemon, and two
# copies of that judgement is drift by construction (#31's law, #92's bug —
# the flaw this fixes was present in both copies).
# shellcheck source=SCRIPTDIR/lib/sshd.sh
. "$HERE/lib/sshd.sh"

log()  { printf 'rig-users: %s\n' "$*"; }
warn() { printf 'rig-users: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-users: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig users close-root

Shuts the root SSH door: installs /etc/ssh/sshd_config.d/00-rig-users.conf
carrying exactly `PermitRootLogin no`, which beats bootstrap's drop-in by
first-wins include order.

root-door=closed boxes ONLY. On root-door=open, root SSH is the control plane's
(Coolify's) automation identity — closing it severs fleet management — so
close-root refuses there, with no --force. Markers written before #77 name this
trait as class=human|server and are read as closed|open respectively, so a box
bootstrapped before the rename gates exactly as it always did.
It also refuses without a role marker (re-run
rig bootstrap; never shut the root door blind) and refuses while no rig-admin
member holds a login this box would actually honor. Per candidate, in order:
the StrictModes shape (authorized_keys present and non-empty, home/.ssh/keys
owned by the user and not group/world-writable, a real login shell, account
not expired), then two reachability proofs (#17) — `sudo -n true` under
runuser must answer (NOPASSWD sudo is effective, not merely written), and
`sshd -T -C user=...` must resolve a per-user effective config that accepts
the login (pubkeyauthentication yes, no DenyUsers hit — where any pattern or
host-qualified Deny entry counts as a hit, fail closed — AllowUsers, if set,
names them literally, and the same pair of rules for DenyGroups/AllowGroups
judged against the admin's actual groups from id -Gn). The refusal names
which check failed, per candidate. Run rig users apply first; never close
the only door.

Before running, verify your admin login in a SEPARATE session — `ssh
<admin>@<box>` while this one stays open. Root SSH is the door being welded
shut; the admin door must be proven, not presumed. This is not ceremony: the
local probe resolves Match blocks against a synthetic loopback client
(addr=127.0.0.1), so a `Match Address` rule that treats real inbound clients
differently is invisible to it — only a real login proves the real door.

Run as root. Convergent: once root is closed, a re-run is a clean no-op.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- guards ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"

# Identity management gates its INVOKER, not just its uid: %rig's sudoers rule
# is binary-scoped but not argument-scoped, so without this gate a rig-role
# user could reshape who enters this box as whom — the scoped grant silently
# root-equivalent through the users family. Direct root (no SUDO_USER:
# bring-up, a root shell) proceeds.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] \
    && ! id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx rig-admin; then
  die "the users family changes who holds root — only rig-admin members (or root itself) may run it; role rig grants operational rig use, not identity management (invoker: $SUDO_USER)"
fi

# Marker gate — the policy lives in assert_marker_closes_root (lib) so the
# harness can prove its refusals against fixture markers as non-root;
# RIG_ROLE_MARKER exists for the same reason: it keeps the command's own gate
# pointable at fixtures instead of only at the real /etc/rig/role. The gate
# reads the pre-#77 class= spelling too — see root_door_of for why that compat
# read is load-bearing rather than courteous.
if ! WHY="$(assert_marker_closes_root "${RIG_ROLE_MARKER:-/etc/rig/role}")"; then
  die "$WHY"
fi

# Admin-door gate — never close the only door. Root SSH goes away below, so
# at least one rig-admin member must hold a login this box would actually
# HONOR — a non-empty authorized_keys alone proves a file exists, not a door:
# StrictModes rejects keys behind wrongly-owned or group/world-writable
# paths, a nologin shell never logs in, and an expired account fails PAM
# before the key is read. So every candidate is checked for the StrictModes
# shape, and then for REACHABILITY (#17): the shape checks prove the door
# SHOULD open, these prove what can be proven from inside — that NOPASSWD
# sudo actually answers (`sudo -n true` under runuser; a sudoers drop-in
# that never landed is a shape the file checks cannot see), and that sshd's
# per-user EFFECTIVE config would accept the login (`sshd -T -C user=...` —
# an AllowUsers or Match block elsewhere can quietly exclude the admin while
# every file looks right). The refusal names, per candidate, WHICH check
# failed — an operator staring at a refusal must see the repair. Honestly:
# the one thing no local check can prove is that the operator HOLDS the
# private key — the verify-in-a-separate-session advisory in --help stays
# load-bearing.
today=$(( $(date +%s) / 86400 ))
# runuser ships in util-linux on Debian — rig's target — but the gate must
# not die on a box without it: skip the live sudo proof with a loud warning
# rather than block close-root on a missing prover. Warned once, not per
# candidate.
HAVE_RUNUSER=0
if command -v runuser >/dev/null 2>&1; then
  HAVE_RUNUSER=1
else
  warn "runuser not found; skipping the live NOPASSWD-sudo proof — verify 'sudo -n true' as your admin by hand before trusting the closed door"
fi
# path_strict <path> <uid> <label> — flag the two StrictModes complaints
flag() { bad="${bad:+$bad, }$1"; }
path_strict() {
  local p="$1" uid="$2" l="$3" o m
  o="$(stat -c '%u' "$p" 2>/dev/null)" || return 0
  m="$(stat -c '%a' "$p" 2>/dev/null)"
  if [ "$o" != "$uid" ]; then flag "$l not owned by the user"; fi
  if [ $(( 8#$m & 8#022 )) -ne 0 ]; then flag "$l is group/world-writable (mode $m)"; fi
}
ADMIN_OK=0
CANDIDATES=0
DETAIL=""
while IFS= read -r a; do
  [ -n "$a" ] || continue
  CANDIDATES=$((CANDIDATES + 1))
  bad=""
  uid="$(id -u "$a" 2>/dev/null)" || { DETAIL="$DETAIL; $a: no such user"; continue; }
  ent="$(getent passwd "$a")"
  h="$(printf '%s' "$ent" | cut -d: -f6)"
  shell="$(printf '%s' "$ent" | cut -d: -f7)"
  if [ ! -d "$h" ]; then
    flag "home directory missing"
  else
    path_strict "$h" "$uid" "home"
    if [ ! -d "$h/.ssh" ]; then
      flag ".ssh directory missing"
    else
      path_strict "$h/.ssh" "$uid" ".ssh directory"
      if [ ! -s "$h/.ssh/authorized_keys" ]; then
        flag "authorized_keys missing or empty"
      else
        path_strict "$h/.ssh/authorized_keys" "$uid" "authorized_keys"
      fi
    fi
  fi
  case "$shell" in
    */nologin|*/false) flag "login shell $shell never logs in" ;;
  esac
  # shadow field 8 is the expiry in days-since-epoch; empty means never.
  exp="$(getent shadow "$a" 2>/dev/null | cut -d: -f8)"
  if [ -n "$exp" ] && [ "$exp" -le "$today" ] 2>/dev/null; then
    flag "account expired"
  fi
  # Reachability proof 1 — NOPASSWD sudo answers for real. `sudo -n` never
  # prompts: with the %rig-admin NOPASSWD rule effective it exits 0, and a
  # sudoers drop-in that failed to land (or a sudo that is simply absent)
  # exits non-zero right here instead of after root is welded shut.
  if [ "$HAVE_RUNUSER" -eq 1 ]; then
    if ! runuser -u "$a" -- sudo -n true >/dev/null 2>&1; then
      flag "sudo -n true fails as this user (NOPASSWD sudo not effective — re-run rig users apply)"
    fi
  fi
  # Reachability proof 2 — sshd's per-user EFFECTIVE config accepts them.
  # `sshd -T -C user=...` resolves Match blocks for exactly this login, so an
  # exclusion the global `sshd -T` never shows is caught. Allow/Deny entries
  # are judged fail-closed in BOTH directions: AllowUsers must name the admin
  # literally (a pattern that would in fact admit them still flags — the
  # operator proves patterns by hand), and DenyUsers flags on a literal hit
  # OR on any pattern/host-qualified token (deny_verdict, in the lib) —
  # 'DenyUsers dan*' really denies admin 'dan', and a token this check cannot
  # prove irrelevant must count as a hit, never as a pass. What no local
  # probe can resolve is a Match on the CLIENT's address — the -C probe pins
  # addr=127.0.0.1 — which is why the separate-session verification stays
  # load-bearing.
  if perT="$(sshd -T -C "user=$a,host=$(hostname),addr=127.0.0.1" 2>/dev/null)"; then
    if ! printf '%s\n' "$perT" | grep -qx 'pubkeyauthentication yes'; then
      flag "sshd resolves pubkeyauthentication != yes for this user"
    fi
    deny_line="$(printf '%s\n' "$perT" | grep -i '^denyusers ' | head -n1)"
    if [ -n "$deny_line" ]; then
      # shellcheck disable=SC2086  # word-splitting the tokens is the point
      deny_reason="$(deny_verdict "$a" ${deny_line#* })"
      [ -n "$deny_reason" ] && flag "$deny_reason"
    fi
    # The group directives close the same door through the other hinge: sshd
    # enforces Allow/DenyGroups against the candidate's ACTUAL membership, so
    # the gate resolves id -Gn and judges both with the same fail-closed
    # discipline as the *Users pair. id failing yields no groups, which makes
    # a set AllowGroups flag — the safe direction.
    a_groups="$(id -Gn -- "$a" 2>/dev/null)"
    denyg_line="$(printf '%s\n' "$perT" | grep -i '^denygroups ' | head -n1)"
    if [ -n "$denyg_line" ]; then
      # shellcheck disable=SC2086  # word-splitting the tokens is the point
      denyg_reason="$(group_deny_verdict "$a_groups" ${denyg_line#* })"
      [ -n "$denyg_reason" ] && flag "$denyg_reason"
    fi
    allowg_line="$(printf '%s\n' "$perT" | grep -i '^allowgroups ' | head -n1)"
    if [ -n "$allowg_line" ]; then
      # shellcheck disable=SC2086  # word-splitting the tokens is the point
      allowg_reason="$(group_allow_verdict "$a_groups" ${allowg_line#* })"
      [ -n "$allowg_reason" ] && flag "$allowg_reason"
    fi
    if printf '%s\n' "$perT" | grep -qi '^allowusers ' \
        && ! printf '%s\n' "$perT" | grep -i '^allowusers ' | tr ' ' '\n' | grep -qx "$a"; then
      flag "sshd AllowUsers is set and does not name this user"
    fi
  else
    flag "sshd -T -C user=$a failed — cannot resolve the per-user config sshd would apply"
  fi
  if [ -z "$bad" ]; then ADMIN_OK=1; break; fi
  DETAIL="$DETAIL; $a: $bad"
done < <(getent group rig-admin | cut -d: -f4 | tr ',' '\n')
if [ "$ADMIN_OK" -ne 1 ]; then
  if [ "$CANDIDATES" -eq 0 ]; then
    die "no admin user with a key on this box — run rig users apply first; never close the only door"
  fi
  die "no rig-admin member would pass sshd's door${DETAIL} — repair, prove the login in a separate session, then re-run; never close the only door"
fi

# --- the drop-in --------------------------------------------------------------
# The NAME is the entire mechanism: sshd_config is FIRST-wins ("for each
# keyword, the first obtained value will be used" — sshd_config(5)), Include
# expands its glob in lexical order, and '-' (0x2D) sorts before '.' (0x2E),
# so 00-rig-users.conf is read BEFORE bootstrap's 00-rig.conf and this
# PermitRootLogin beats its prohibit-password. Rename the file and it silently
# loses that fight — the harness asserts the comparison the glob makes.
DROPIN=/etc/ssh/sshd_config.d/00-rig-users.conf
TMP="$(mktemp)"
printf 'PermitRootLogin no\n' > "$TMP"

# Convergence needs two proofs, and matching bytes are only half of one. The
# file can be right while the DOOR is still open: a prior run that died
# between install and restart leaves a daemon that never read this file, and
# `sshd -T` cannot tell — it re-parses disk, it does not interrogate the
# running daemon. The only proof the running sshd carries this config is a
# (re)start AFTER the last change to anything sshd reads: the main config,
# the drop-in dir itself (creates/deletes/renames inside touch its mtime, so
# a since-removed override is caught), and every drop-in. So the no-op is
# taken only when the bytes match AND systemd says sshd started strictly
# after the newest of those mtimes; anything less restarts, and the
# effective-config assertion at the bottom runs on EVERY path — claiming
# "already closed" from file bytes is exactly what let bootstrap's
# first-wins bug ship green.
RESTART=1
BACKUP=""
INSTALLED=0
if cmp -s "$TMP" "$DROPIN" 2>/dev/null; then
  newest="$(stat -c '%Y' /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sort -rn | head -n1)"
  started="$(systemctl show ssh -p ExecMainStartTimestamp --value 2>/dev/null)" || started=""
  if [ -n "$started" ] && started_s="$(date -d "$started" +%s 2>/dev/null)" \
      && [ -n "$newest" ] && [ "$started_s" -gt "$newest" ]; then
    RESTART=0
  fi
else
  [ -e "$DROPIN" ] && { BACKUP="$(mktemp)"; cp -a "$DROPIN" "$BACKUP"; }
  install -m 0644 "$TMP" "$DROPIN"
  INSTALLED=1
fi
rm -f "$TMP"

if [ "$RESTART" -eq 1 ]; then
  # Validate the MERGED config BEFORE bouncing the daemon (the bootstrap
  # shape): on a box whose only door is SSH — exactly what this box is about
  # to become — restarting into a config the daemon refuses to parse leaves
  # no listener and no way back in. Roll back (when we installed anything)
  # and stop rather than shut the door on a maybe.
  if ! sshd_config_ok; then
    if [ "$INSTALLED" -eq 1 ]; then
      if [ -n "$BACKUP" ]; then cp -a "$BACKUP" "$DROPIN"; else rm -f "$DROPIN"; fi
      rm -f "$BACKUP"
      die "sshd rejects the merged config; drop-in rolled back, daemon untouched: $sshd_err"
    fi
    die "sshd rejects the current config; daemon untouched: $sshd_err"
  fi
  rm -f "$BACKUP"
  systemctl restart ssh
fi

# Assert the EFFECTIVE config, not the file's existence — a drop-in sorting
# even earlier would win the first-wins fight silently. `sshd -T` is what the
# daemon actually resolved, and it gates the no-op claim too: "already
# closed" is a statement about the door, never about the file.
eff="$(sshd -T 2>/dev/null)" || die "sshd -T failed; refusing to claim root is closed"
echo "$eff" | grep -qx 'permitrootlogin no' \
  || die "sshd still resolves permitrootlogin != no — a drop-in is beating ${DROPIN}; check ls /etc/ssh/sshd_config.d/"
if [ "$RESTART" -eq 0 ]; then
  log "root already closed (sshd -T resolves permitrootlogin no); nothing to do"
else
  log "root door closed (sshd -T resolves permitrootlogin no); humans enter as themselves now"
fi
