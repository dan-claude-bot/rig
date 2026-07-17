#!/usr/bin/env bash
# rig users close-root — shut the human-class root SSH door, once and only
# once a named admin can already get in. class decides root SSH's fate (#26):
# on class=human a root login is unattributable noise, so it goes; on
# class=server root IS the control plane's automation identity, so closing it
# would sever fleet management — this command refuses there, and no --force
# exists. Convergent: a second run is a no-op and says so.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"

log()  { printf 'rig-users: %s\n' "$*"; }
die()  { printf 'rig-users: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig users close-root

Shuts the root SSH door: installs /etc/ssh/sshd_config.d/00-rig-users.conf
carrying exactly `PermitRootLogin no`, which beats bootstrap's drop-in by
first-wins include order.

Human class ONLY. On class=server, root SSH is the control plane's (Coolify's)
automation identity — closing it severs fleet management — so close-root
refuses there, with no --force. It also refuses without a role marker (re-run
rig bootstrap; never shut the root door blind) and refuses while no rig-admin
member holds a working authorized_keys (run rig users apply first; never close
the only door).

Before running, verify your admin login in a SEPARATE session — `ssh
<admin>@<box>` while this one stays open. Root SSH is the door being welded
shut; the admin door must be proven, not presumed.

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

# Marker gate — the policy lives in assert_marker_human (lib) so the harness
# can prove its refusals against fixture markers as non-root; RIG_ROLE_MARKER
# exists for the same reason: it keeps the command's own gate pointable at
# fixtures instead of only at the real /etc/rig/role.
if ! WHY="$(assert_marker_human "${RIG_ROLE_MARKER:-/etc/rig/role}")"; then
  die "$WHY"
fi

# Admin-door gate — never close the only door. Root SSH goes away below, so at
# least one rig-admin member must already hold a non-empty authorized_keys:
# "verified in a separate session" cannot be automated, but a key at the door
# can be, and its absence is proof enough to stop.
ADMIN_OK=0
while IFS= read -r a; do
  [ -n "$a" ] || continue
  h="$(getent passwd "$a" | cut -d: -f6)"
  if [ -n "$h" ] && [ -s "$h/.ssh/authorized_keys" ]; then ADMIN_OK=1; break; fi
done < <(getent group rig-admin | cut -d: -f4 | tr ',' '\n')
[ "$ADMIN_OK" -eq 1 ] \
  || die "no admin user with a key on this box — run rig users apply first; never close the only door"

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
if cmp -s "$TMP" "$DROPIN" 2>/dev/null; then
  rm -f "$TMP"
  log "root already closed; nothing to do"
  exit 0
fi

BACKUP=""
[ -e "$DROPIN" ] && { BACKUP="$(mktemp)"; cp -a "$DROPIN" "$BACKUP"; }
install -m 0644 "$TMP" "$DROPIN"
rm -f "$TMP"

# Validate the MERGED config BEFORE bouncing the daemon (the bootstrap shape):
# on a box whose only door is SSH — exactly what this box is about to become —
# restarting into a config the daemon refuses to parse leaves no listener and
# no way back in. Roll back and stop rather than shut the door on a maybe.
if ! sshd -t 2>/dev/null; then
  if [ -n "$BACKUP" ]; then cp -a "$BACKUP" "$DROPIN"; else rm -f "$DROPIN"; fi
  rm -f "$BACKUP"
  die "sshd rejects the merged config; drop-in rolled back, daemon untouched. Run 'sshd -t' to see which file is bad."
fi
rm -f "$BACKUP"

systemctl restart ssh

# Assert the EFFECTIVE config, not the file's existence — a drop-in sorting
# even earlier would win the first-wins fight silently. `sshd -T` is what the
# daemon actually resolved.
eff="$(sshd -T 2>/dev/null)" || die "sshd -T failed; refusing to claim root is closed"
echo "$eff" | grep -qx 'permitrootlogin no' \
  || die "sshd still resolves permitrootlogin != no — a drop-in is beating ${DROPIN}; check ls /etc/ssh/sshd_config.d/"
log "root door closed (sshd -T resolves permitrootlogin no); humans enter as themselves now"
