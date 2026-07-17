#!/usr/bin/env bash
# rig users status — what this box's operator accounts actually are, read from
# the machine itself: roles derived from REAL group membership (not the
# ledger's memory of an apply), key counts from authorized_keys, and the
# active/revoked state from the ledger CORROBORATED by the account's actual
# expiry — apply locks every password always, so the lock flag says nothing;
# expiry is the switch that actually revokes, and a mismatch between ledger
# and expiry is drift worth shouting about. Reads only — no network, no
# writes.
set -euo pipefail

log()  { printf 'rig-users: %s\n' "$*"; }
warn() { printf 'rig-users: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-users: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig users status

Per rig-managed user (the /etc/rig/users ledger): roles derived from the
groups the user is ACTUALLY in (rig-admin -> admin, rig -> rig, incus -> box),
the authorized_keys count ('revoked' when only the .revoked-by-rig rename
remains), and whether the user is active or revoked — the ledger's word,
checked against the account's real expiry, with a loud warning when the two
disagree (a drifted box must never read as healthy). Reads the box only — no
network, no writes. Run as root (shadow is read).
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"

LEDGER=/etc/rig/users
if [ ! -r "$LEDGER" ]; then
  log "no rig-managed users (no $LEDGER yet — rig users apply creates it)"
  exit 0
fi

today=$(( $(date +%s) / 86400 ))
while read -r u lstate _; do
  [ -n "$u" ] || continue
  # Ledger lines are 'name active' / 'name revoked'; a legacy bare name (a
  # ledger written before states existed) reads as active.
  [ -n "${lstate:-}" ] || lstate=active
  if ! id -u "$u" >/dev/null 2>&1; then
    # In the ledger but off the box: someone deleted by hand what rig only
    # ever revokes. Say so rather than crash or silently skip.
    warn "$u: in the ledger but not on the box (rig never deletes — removed by hand?)"
    continue
  fi
  groups=" $(id -nG "$u") "
  roles=""
  case "$groups" in *" rig-admin "*) roles="admin" ;; esac
  case "$groups" in *" rig "*)       roles="${roles:+$roles,}rig" ;; esac
  case "$groups" in *" incus "*)     roles="${roles:+$roles,}box" ;; esac
  [ -n "$roles" ] || roles="none"
  home="$(getent passwd "$u" | cut -d: -f6)"
  keys=0
  if [ -r "$home/.ssh/authorized_keys" ]; then
    keys="$(grep -c . "$home/.ssh/authorized_keys" || true)"
  elif [ -e "$home/.ssh/authorized_keys.revoked-by-rig" ]; then
    # Only the rename apply's revocation performed remains: access revoked,
    # data kept.
    keys=revoked
  fi
  # Corroborate the ledger against the switch that actually revokes: shadow
  # field 8 is the expiry (days since epoch, empty = never). The ledger is
  # apply's memory; the expiry is the machine's present tense — when they
  # disagree, someone changed the account behind rig's back.
  exp="$(getent shadow "$u" 2>/dev/null | cut -d: -f8)"
  actual=active
  if [ -n "$exp" ] && [ "$exp" -le "$today" ] 2>/dev/null; then
    actual=revoked
  fi
  if [ "$actual" != "$lstate" ]; then
    warn "$u: DRIFT — ledger says $lstate but the account's expiry says $actual; re-run rig users apply"
    log "$u  roles=$roles  keys=$keys  $lstate (DRIFT: expiry says $actual)"
  else
    log "$u  roles=$roles  keys=$keys  $lstate"
  fi
done < "$LEDGER"
